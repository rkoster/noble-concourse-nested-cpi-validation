# Nested BOSH Garden Failure Analysis

## Problem Summary

The nested BOSH director fails to start garden inside the Concourse worker container. The error occurs when grootfs (Garden's filesystem management component) attempts to mount XFS filesystems using loop devices.

## Root Cause

**Loop device operations are not permitted inside Concourse worker containers.**

Even though:
- Loop devices `/dev/loop*` are accessible in the container
- The container has full capabilities (`CapEff: 0000003fffffffff`)
- The container is NOT confined by AppArmor (`unconfined`)

The `losetup` command fails with `Operation not permitted` when attempting to attach a file to a loop device.

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

## Why Loop Devices Don't Work

The issue is that **Concourse's containerd/runc worker does not grant the necessary privileges** for loop device operations, even when the container appears to have full capabilities.

Loop device operations require:
1. `CAP_SYS_ADMIN` capability (present)
2. Ability to call `LOOP_SET_FD` ioctl on loop devices (BLOCKED)

The kernel blocks the `LOOP_SET_FD` ioctl because:
- The container is in a user namespace (unprivileged container)
- OR seccomp filters block the operation
- OR the container runtime explicitly blocks loop device mounts

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

### Privileged Container Mode (Tested - FAILED)

Enabled `garden.allow_privileged_containers: true` in Concourse worker configuration and set `privileged: true` in pipeline tasks.

**Result**: Loop device operations still fail with "Operation not permitted"

**Root Cause**: Even with full capabilities (including CAP_SYS_ADMIN), the containers run in **user namespaces**. The Linux kernel restricts loop device operations from within user namespaces as a security measure.

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

**Conclusion**: Guardian/Garden runtime in Concourse uses user namespaces for isolation, which blocks loop device operations even in "privileged" mode. The only solution would be to disable user namespaces entirely (not supported by Guardian) or use overlay-only filesystem (Option 2).

## Next Steps

1. **Recommended**: Use Docker CPI (Option 3) - already proven to work
2. **Alternative**: Implement overlay-only garden configuration (Option 2) 
3. **Research**: Check upstream BOSH CI to see how they handle this

## References

- Garden Runtime: https://github.com/concourse/concourse-bosh-release/blob/master/jobs/worker/spec
- GrootFS: https://github.com/cloudfoundry/grootfs-release
- Loop device requirements: https://man7.org/linux/man-pages/man4/loop.4.html
