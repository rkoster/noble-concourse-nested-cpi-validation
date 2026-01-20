# Nested BOSH Garden Failure Analysis

## Problem Summary

The nested BOSH director fails to start garden inside the Concourse worker container. The error occurs when grootfs (Garden's filesystem management component) attempts to mount XFS filesystems using loop devices.

## Root Cause

**Loop device operations are blocked by Ubuntu 24.04 (Noble) kernel security restrictions on user namespaces.**

The issue is a **kernel-level security policy** introduced in Linux kernel 6.x series (Noble uses 6.8.0), specifically:
- `kernel.apparmor_restrict_unprivileged_userns = 1` (present in Noble 6.8, absent in Jammy 5.15)

This kernel parameter restricts what operations unprivileged user namespaces can perform, including loop device operations (LOOP_SET_FD ioctl).

Even though:
- Loop devices `/dev/loop*` are accessible in the container
- The container has full capabilities (`CapEff: 0000003fffffffff`)
- The container is NOT confined by AppArmor (`unconfined`)
- Both loop and device-mapper are built into the kernel (`CONFIG_BLK_DEV_LOOP=y`, `CONFIG_BLK_DEV_DM=y`)

The `losetup` command fails with `Operation not permitted` because Guardian/Garden containers run in user namespaces for isolation.

### Evidence

```bash
# Inside the Concourse worker container:
$ dd if=/dev/zero of=/tmp/test.img bs=1M count=10
10+0 records in
10+0 records out

$ losetup -f /tmp/test.img
losetup: /tmp/test.img: failed to set up loop device: Operation not permitted
```

### Garden Error Logs

From `/var/vcap/sys/log/garden/garden_ctl.stderr.log`:

```json
{
  "timestamp":"2026-01-20T12:06:56.370165535Z",
  "level":"error",
  "source":"grootfs",
  "message":"grootfs.init-store.store-manager-init-store.initializing-filesystem-failed",
  "data":{
    "error":"Mounting filesystem: exit status 32: mount: /var/vcap/data/grootfs/store/unprivileged: failed to setup loop device for /var/vcap/data/grootfs/store/unprivileged.backing-store.\n"
  }
}
```

## Environment Details

### Container Environment
- **CGroups**: v2 (cgroup2fs)
- **Available controllers**: cpuset cpu io memory hugetlb pids rdma misc
- **AppArmor**: unconfined (no profile applied to container process)
- **Capabilities**: Full (all capability bits set)
- **Loop devices**: 257 devices present (/dev/loop0 - /dev/loop256 + /dev/loop-control)

### Concourse Worker Configuration
- **Runtime**: Guardian (runc backend) - configured via ops-file
- **AppArmor config**: Explicitly disabled in garden config.ini (`apparmor =`)
- **Host access**: Enabled (`allow_host_access: true`)

### Host (Concourse VM) Details
- **OS**: Ubuntu Noble 24.04 (BOSH stemcell)
- **CGroups**: v2
- **AppArmor**: `garden-default` profile is loaded and in enforce mode on the host
  - Verified via: `sudo apparmor_status --json | jq '.' | grep garden`
  - Shows: `"garden-default": "enforce"`

## Kernel Version Comparison

Testing confirmed this is a kernel version difference, **not a missing module**:

### Jammy (Working)
- **Kernel**: 5.15.0-164-generic
- **OS**: Ubuntu 22.04.5 LTS
- **Key sysctl**: `kernel.apparmor_restrict_unprivileged_userns` = **NOT PRESENT**
- **Loop devices**: Work in user namespaces ✅
- **Modules**: loop and dm built-in (`CONFIG_BLK_DEV_LOOP=y`, `CONFIG_BLK_DEV_DM=y`)

### Noble (Broken)
- **Kernel**: 6.8.0-90-generic  
- **OS**: Ubuntu 24.04.3 LTS
- **Key sysctl**: `kernel.apparmor_restrict_unprivileged_userns = 1` ⚠️
- **Loop devices**: Blocked in user namespaces ❌
- **Modules**: loop and dm built-in (identical config)

## Why Loop Devices Don't Work on Noble

The kernel blocks the `LOOP_SET_FD` ioctl in unprivileged user namespaces due to:
1. Ubuntu kernel security hardening in 6.x series
2. AppArmor restrictions on unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`)
3. Guardian/Garden containers run in user namespaces for isolation

This is **by design** for security - not a bug or missing module.

## Potential Solutions

### Option 1: Enable Privileged Containers (Most Direct)

Configure Concourse worker to run task containers in privileged mode. This would require:

1. Add ops-file to enable privileged containers:
```yaml
- type: replace
  path: /instance_groups/name=concourse/jobs/name=worker/properties/garden/default_container_rootfs?
  value: "docker:///bosh/main-bosh-docker"

- type: replace
  path: /instance_groups/name=concourse/jobs/name=worker/properties/garden/default_container_grace_time?
  value: 5m

- type: replace
  path: /instance_groups/name=concourse/jobs/name=worker/properties/garden/destroy_containers_on_startup?
  value: true

# Critical: Allow privileged containers
- type: replace
  path: /instance_groups/name=concourse/jobs/name=worker/properties/garden/allow_privileged_containers?
  value: true
```

2. Modify the pipeline task to request privileged mode:
```yaml
privileged: true
```

**Pros**: Most straightforward, matches how BOSH CI works
**Cons**: Broader security implications

### Option 2: Use Overlay/Bind Mount Instead of Loop Devices

Modify the nested BOSH start script to avoid grootfs XFS mounts:

1. Configure garden to use overlay driver without XFS quotas
2. Use directory-based storage instead of file-backed XFS

**Pros**: No privileged mode needed
**Cons**: Requires modifying BOSH/garden configuration, may lose disk quotas

### Option 3: Switch to Docker CPI

Since the pipeline already uses docker-cpi successfully, focus on that path:

**Pros**: Already working in the pipeline
**Cons**: Different from production BOSH (which uses warden/garden)

### Option 4: Use Host Loop Devices Directly

Mount loop-control and loop devices with correct permissions from host:

```yaml
# In task config
inputs:
- name: bosh-deployment
mounts:
- path: /dev/loop-control
- path: /dev/loop0
- path: /dev/loop1
# ... etc
```

**Pros**: Minimal changes
**Cons**: May still be blocked by namespace restrictions

## Test Results

### Privileged Container Mode (Tested - INSUFFICIENT)

Enabled `garden.allow_privileged_containers: true` in Concourse worker configuration and set `privileged: true` in pipeline tasks.

**Result**: Loop device operations still fail with "Operation not permitted" on Noble

**Root Cause**: Even with full capabilities (including CAP_SYS_ADMIN), the containers run in **user namespaces**. The Noble kernel (6.8) restricts loop device operations from within unprivileged user namespaces as a security measure (`kernel.apparmor_restrict_unprivileged_userns = 1`).

**Evidence**:
```bash
# Container has all capabilities
$ capsh --decode=0000003fffffffff | grep sys_admin
cap_sys_admin  # ✓ Present

# But running in user namespace
$ ls -la /proc/self/ns/user  
user:[4026531837]  # ✗ In user namespace

# Loop device operation fails
$ losetup -f /tmp/test.img
losetup: /tmp/test.img: failed to set up loop device: Operation not permitted
```

**Conclusion**: Guardian/Garden runtime in Concourse uses user namespaces for isolation, which blocks loop device operations on Noble kernel even in "privileged" mode.

### Switch to Jammy Stemcell (Tested - SUCCESS ✅)

Switched Concourse worker from Noble (24.04, kernel 6.8) to Jammy (22.04, kernel 5.15) stemcell.

**Implementation**:
1. Created `ops-files/use-jammy-stemcell.yml` to override stemcell OS
2. Updated `deploy-concourse.sh` to apply the ops-file
3. Uploaded Jammy stemcell for OpenStack: `bosh-openstack-kvm-ubuntu-jammy-go_agent/1.1016`
4. Redeployed Concourse

**Result**: **Garden starts successfully!** ✅

**Evidence from pipeline build**:
```
2026-01-20T12:45:49.139114773Z - running thresholder
2026-01-20T12:45:49.145792231Z - done
2026-01-20T12:45:49.149526304Z: Pinging garden server...
2026-01-20T12:45:50.165527850Z: Success!
```

- Grootfs thresholder completed (requires loop device operations)
- Garden server responds successfully
- No "Operation not permitted" errors
- Loop devices work in user namespaces on Jammy kernel 5.15

## Recommended Solution

**Use Jammy (22.04) stemcell for Concourse workers** instead of Noble (24.04).

This is the same approach used by upstream BOSH CI, which runs Jammy-based Concourse workers for nested BOSH testing.

### Why This Works

- Jammy kernel 5.15 does not have `kernel.apparmor_restrict_unprivileged_userns` restriction
- Loop device operations work in user namespaces on older kernels
- No changes needed to Guardian/Garden configuration
- Maintains security through user namespace isolation (just without the additional 6.x restrictions)

### Alternative Solutions (Not Recommended)

1. **Docker CPI**: Already working in pipeline but different from production BOSH
2. **Overlay-only garden**: Requires modifying BOSH/garden config, may lose disk quotas  
3. **Disable user namespaces**: Not supported by Guardian runtime

## References

- Garden Runtime: https://github.com/concourse/concourse-bosh-release/blob/master/jobs/worker/spec
- GrootFS: https://github.com/cloudfoundry/grootfs-release
- Loop device requirements: https://man7.org/linux/man-pages/man4/loop.4.html
