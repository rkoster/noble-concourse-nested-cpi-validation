# Concourse Runtime Analysis for Warden-CPI on Noble

## Executive Summary

**Question**: Can we configure Concourse's container runtime to provide an environment where warden-cpi works on Ubuntu Noble (24.04)?

**Answer**: ❌ **No feasible solution exists** for running warden-cpi in nested containers on Noble.

**Recommendation**: ✅ **Use docker-cpi** for Noble + nested container deployments.

## Problem Statement

Warden-CPI requires GrootFS (Garden's root filesystem manager) which has a hard dependency on XFS filesystem. When running nested BOSH directors inside Concourse worker containers on Noble:

1. Concourse workers run in containers (overlay filesystem)
2. Warden-CPI tries to start Garden/GrootFS inside these containers
3. GrootFS requires XFS filesystem at `/var/vcap/data`
4. Loop device mounting fails in cgroup v2 privileged containers

## Investigation Summary

We explored three potential approaches to make Concourse provide an XFS-compatible environment:

### Approach 1: Containerd with XFS ❌

**Hypothesis**: Configure Concourse's containerd runtime to use XFS backing storage.

**Finding**: Not possible. Containerd storage snapshotters (overlayfs, native, devmapper) use the host filesystem as-is. Containerd does not provide filesystem-level virtualization.

**Relevant Code**: 
- Concourse worker spec: `containerd.dns_servers`, `containerd.network_pool`
- No XFS-specific storage configuration options exist

**Conclusion**: Containerd cannot provide XFS to nested containers.

### Approach 2: Switch to Guardian Runtime ⚠️

**Hypothesis**: Configure Concourse worker to use Guardian (garden-runc-release) instead of containerd, which might provide XFS via GrootFS.

**Finding**: Theoretically possible but hits the same blocker:

**Architecture**:
```
┌─────────────────────────────────────────┐
│ Concourse Worker (Guardian Runtime)     │
│ ┌─────────────────────────────────────┐ │
│ │ GrootFS for Worker Containers       │ │
│ │ - Needs XFS backing store           │ │
│ │ - Uses loop device mounting         │ │
│ │ - ❌ Fails in cgroup v2             │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**Configuration Analysis**:
```yaml
# Concourse worker with Guardian
runtime: guardian  # Instead of containerd
garden.no_image_plugin: true  # Disable GrootFS for worker
```

**Problem**: Even if we switch to Guardian, GrootFS still needs to create XFS backing stores via loop devices, which fail:
```
losetup: /dev/loop0: failed to set up loop device: Operation not permitted
```

**Relevant Research**:
- garden-runc-release docs: `docs/08-grootfs-store-configuration.md`
- GrootFS setup: `jobs/garden/templates/bin/overlay-xfs-setup`
- Store mount: `/var/vcap/data` (must be XFS or have loop device support)

**Conclusion**: Guardian would work on bare metal/VMs with XFS but still fails in nested cgroup v2 containers.

### Approach 3: External Garden-Runc-Release ⚠️

**Hypothesis**: Deploy garden-runc-release as an external service and point Concourse worker at it via `external_garden_url`.

**Finding**: Still requires loop devices.

**Architecture**:
```
┌──────────────────────────────────┐
│ External Garden-Runc-Release     │
│ ┌──────────────────────────────┐ │
│ │ GrootFS                      │ │
│ │ - Requires XFS              │ │
│ │ - Uses loop devices         │ │
│ │ - ❌ Fails in cgroup v2     │ │
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```

**Configuration**:
```yaml
# Concourse worker pointing to external Garden
external_garden_url: unix:///var/vcap/data/garden/garden.sock
```

**Problem**: The external Garden would still be running in a container (or need bare metal deployment), and GrootFS still needs loop devices for XFS backing stores.

**Research Sources**:
- garden-runc-release: https://github.com/cloudfoundry/garden-runc-release
- GrootFS config: `/var/vcap/jobs/garden/config/grootfs_config.yml`
- Store initialization: `grootfs init-store` requires XFS

**Conclusion**: Moving Garden external doesn't solve the fundamental loop device limitation.

## Root Cause Analysis

### The Dependency Chain

```
Warden-CPI
    ↓
Garden/Guardian
    ↓
GrootFS (root filesystem manager)
    ↓
overlay-xfs driver
    ↓
XFS filesystem with project quotas
    ↓
Loop-mounted backing store file
    ↓
❌ losetup (blocked in cgroup v2)
```

### Why Loop Devices Fail

Ubuntu Noble (24.04) uses cgroup v2 by default. Even with `privileged: true` containers:
- Loop device operations require `CAP_SYS_ADMIN` + specific cgroup device permissions
- cgroup v2 device controller doesn't allow loop device creation in containers
- Error: `losetup: /dev/loop0: failed to set up loop device: Operation not permitted`

### Why Docker-CPI Works

Docker-CPI bypasses the entire GrootFS/XFS requirement:

```
Docker-CPI
    ↓
Docker daemon
    ↓
overlay2 storage driver
    ↓
Works with any underlying filesystem
    ↓
✅ No loop devices needed
```

## Technical Deep Dive

### GrootFS Architecture

From garden-runc-release documentation:

> GrootFS uses `overlay` to efficiently combine filesystem layers, along with an `xfs` base filesystem mounted with a loop device to implement disk quotas.

**Key Requirements**:
1. **XFS filesystem**: For project quota enforcement
2. **Loop device**: To mount XFS backing store file
3. **XFS project quotas**: For per-container disk limits

**Setup Process** (from `overlay-xfs-setup`):
```bash
# 1. Create backing store file
dd if=/dev/zero of=/var/vcap/data/grootfs/store.backing-store bs=1M count=12288

# 2. Format as XFS
mkfs.xfs /var/vcap/data/grootfs/store.backing-store

# 3. Mount via loop device
losetup /dev/loop0 /var/vcap/data/grootfs/store.backing-store
mount /dev/loop0 /var/vcap/data/grootfs/store
```

**Step 3 fails in cgroup v2 containers.**

### Filesystem Type Validation

GrootFS validates filesystem type during initialization:

```go
// From grootfs source
expected := XFS_SUPER_MAGIC  // 0x58465342
actual := statfs(storePath)
if actual != expected {
    return Error("Store path filesystem is incompatible with native driver")
}
```

This validation cannot be bypassed without modifying GrootFS source code.

## Comparison Matrix

| Approach | XFS Support | Loop Devices Needed | Works in cgroup v2 | Effort |
|----------|-------------|--------------------|--------------------|---------|
| Containerd | ❌ No | N/A | N/A | Low |
| Guardian | ✅ Yes | ✅ Yes | ❌ No | Medium |
| External Garden | ✅ Yes | ✅ Yes | ❌ No | High |
| Docker-CPI | ✅ N/A | ❌ No | ✅ Yes | None |

## Recommendations

### For Production Use: Docker-CPI ✅

**Advantages**:
- ✅ Works on Noble (Ubuntu 24.04) with cgroup v2
- ✅ Works in nested containers
- ✅ Simpler architecture (no GrootFS complexity)
- ✅ Already validated in `deploy-zookeeper-on-docker-bosh` job

**Usage**:
```yaml
# Pipeline job using docker-cpi
- name: deploy-zookeeper-on-docker-bosh
  plan:
    - get: bosh-docker-cpi-image
    - task: deploy
      privileged: true
      # ... rest of job
```

### For Warden-CPI: Bare Metal or Traditional VMs

If warden-cpi is specifically required:
- ✅ Deploy on bare metal with XFS filesystem
- ✅ Deploy on traditional VMs (not nested containers)
- ✅ Use Ubuntu Jammy (22.04) or earlier on systems with XFS

### Future Improvements (Upstream Changes Required)

To support warden-cpi in nested containers would require:

**Option A: GrootFS Overlay-Only Mode**
- Modify GrootFS to support overlay without XFS
- Alternative quota enforcement (not via XFS project quotas)
- Estimated effort: Several engineering months

**Option B: User Namespaces + Loop Devices**
- Requires kernel support for loop devices in user namespaces
- cgroup v2 device controller modifications
- Estimated effort: Kernel-level changes, very high complexity

**Neither option is currently planned or available.**

## Verification Commands

### Check Filesystem Type
```bash
# On BOSH VM or container
stat -f -c "%T" /var/vcap/data
# Expected for working warden-cpi: xfs
# Actual in containers: overlayfs
```

### Test Loop Device Support
```bash
# Try to create loop device
dd if=/dev/zero of=/tmp/test.img bs=1M count=100
losetup /dev/loop0 /tmp/test.img
# Success: loop device works
# Failure: Operation not permitted (cgroup v2 blocker)
```

### Check GrootFS Store
```bash
# On working warden-cpi deployment
grootfs --config /var/vcap/jobs/garden/config/grootfs_config.yml init-store
# Success: store initialized
# Failure: filesystem validation error
```

## Conclusion

**Warden-CPI is architecturally incompatible with nested containers on Ubuntu Noble (24.04)** due to:
1. GrootFS's hard XFS filesystem requirement
2. Loop device mounting restrictions in cgroup v2
3. No configuration options to work around these constraints

**Docker-CPI is the correct solution** for Noble + nested container deployments and should be used going forward.

## References

### Documentation
- [Garden-Runc-Release Operation Manual](https://github.com/cloudfoundry/garden-runc-release/blob/develop/docs/01-operation-manual.md)
- [GrootFS Store Configuration](https://github.com/cloudfoundry/garden-runc-release/blob/develop/docs/08-grootfs-store-configuration.md)
- [Concourse Worker Spec](https://github.com/concourse/concourse-bosh-release/blob/master/jobs/worker/spec)

### Source Code
- [garden-runc-release](https://github.com/cloudfoundry/garden-runc-release)
- [GrootFS](https://github.com/cloudfoundry/grootfs)
- [Guardian](https://github.com/cloudfoundry/guardian)

### Related Investigation
- [WARDEN_CPI_INVESTIGATION.md](./WARDEN_CPI_INVESTIGATION.md) - Initial nested warden-cpi investigation
