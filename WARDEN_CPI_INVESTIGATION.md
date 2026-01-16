# Warden-CPI Investigation on Noble (Ubuntu 24.04)

## Executive Summary

**Status**: ❌ **Warden-CPI is incompatible with Noble in nested container environments**

**Recommendation**: ✅ **Use docker-cpi for Noble + nested container deployments**

This document details the investigation into why warden-cpi fails on Ubuntu Noble (24.04) when running BOSH directors in nested containers (Concourse workers running in containers).

## Background

### Goal
Enable nested BOSH director deployments using warden-cpi on Ubuntu Noble (24.04) within Concourse CI pipelines, where Concourse workers run inside containers.

### Test Environment
- **Lab Concourse**: http://10.246.0.21:8080
- **Pipeline**: nested-bosh-zookeeper
- **Job**: deploy-zookeeper-on-warden-bosh
- **Base Image**: bosh/warden-cpi (Noble-based)
- **Container Runtime**: Privileged container with cgroup v2

## Investigation Timeline

### Build History

| Build | Status | Duration | Key Finding |
|-------|--------|----------|-------------|
| 1-2 | Failed | 2-3min | Loop device errors: `losetup: failed to set up loop device: Operation not permitted` |
| 3 | Failed | 4s | Base64 corruption in pipeline |
| 4 | Failed | 2m4s | Sed patterns didn't match nested YAML structure |
| 5 | Failed | 2m5s | Patches applied too early (before config generation) |
| 6 | Failed | 2m6s | Garden timeout - first successful patch application |
| 7 | Failed | 2m3s | Final confirmation: XFS filesystem requirement |

### Progression of Understanding

1. **Initial symptom**: Garden server timeouts after 119 attempts (~120 seconds)
2. **First clue**: Loop device errors in GrootFS logs
3. **Attempted fix**: Disable backing store file (`store_size_bytes: 0`, `with_direct_io: true`)
4. **Deeper issue**: Filesystem validation failure even without backing store
5. **Root cause**: GrootFS requires XFS filesystem, containers provide overlay filesystem

## Root Cause Analysis

### The Fundamental Incompatibility

GrootFS (Garden's root filesystem manager) uses the **overlay-xfs driver** which has a hard requirement for an XFS filesystem. This requirement cannot be satisfied in nested container environments.

### Technical Details

**Error Message from Build #7:**
```
validating store path filesystem: overlay-xfs filesystem validation: 
Store path filesystem (/var/vcap/data/grootfs/store/unprivileged) is incompatible with native driver (must be XFS mountpoint)
expected type (hex): 58465342, actual type (hex): 794c7630
```

**Filesystem Signatures:**
- `58465342` = XFS filesystem magic number
- `794c7630` = overlay filesystem magic number

**Why This Matters:**
- GrootFS validates filesystem type during `init-store` operation
- The overlay-xfs driver uses XFS project quotas for disk quota enforcement
- No fallback driver exists for non-XFS filesystems
- Even with `store_size_bytes: 0`, filesystem validation still runs

### Architecture Constraints

```
┌─────────────────────────────────────────────────────┐
│ Concourse Worker Container (Ubuntu Noble)          │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Garden/Warden-CPI Container                     │ │
│ │ ┌─────────────────────────────────────────────┐ │ │
│ │ │ GrootFS                                     │ │ │
│ │ │ - overlay-xfs driver                        │ │ │
│ │ │ - Requires: XFS filesystem ❌               │ │ │
│ │ │ - Actual: overlay filesystem ✅             │ │ │
│ │ │ - Result: Incompatible ⚠️                   │ │ │
│ │ └─────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Why Loop Devices Don't Work

Creating an XFS backing store file was the original approach, but fails on Noble:
1. GrootFS creates a 12GB file
2. Formats it as XFS
3. Attempts to mount it via loop device (`losetup`)
4. **Fails**: Loop device operations are restricted in cgroup v2 privileged containers

**Error:**
```
losetup: /dev/loop0: failed to set up loop device: Operation not permitted
```

### GrootFS Architecture

**Code Location**: `/var/vcap/jobs/garden/bin/overlay-xfs-setup`

```bash
init_unprivileged_store() {
  grootfs --config ${config_path} init-store \
    --uid-mapping "..." \
    --gid-mapping "..."
  
  # This fails - requires XFS for quota testing
  /var/vcap/packages/grootfs/bin/tardis limit \
    --disk-limit-bytes 102400 \
    --image-path "$xfs_quota_test_dir"
}
```

**Key Functions:**
- `init-store`: Validates filesystem type, initializes store
- `tardis limit`: Tests XFS project quotas
- Both require XFS filesystem to function

## Attempted Solutions

### 1. Disable Backing Store File ✅ Patches Applied, ❌ Still Failed

**Approach**: Set `store_size_bytes: 0` to prevent loop device creation

**Implementation**: `start-bosh-warden-patched.sh`
```bash
sed -i 's/  store_size_bytes: [0-9]*/  store_size_bytes: 0/' "$GROOTFS_CONFIG"
sed -i 's/  with_direct_io: false/  with_direct_io: true/' "$GROOTFS_CONFIG"
```

**Result**: Patches applied successfully but GrootFS still validates filesystem type

### 2. Pre-create Store Directories ✅ Created, ❌ Wrong Filesystem

**Approach**: Create directories before GrootFS init to avoid "no such file" errors

**Implementation**:
```bash
mkdir -p /var/vcap/data/grootfs/store/unprivileged
mkdir -p /var/vcap/data/grootfs/store/privileged
chmod 755 /var/vcap/data/grootfs/store/*
```

**Result**: Directories created successfully but still on overlay filesystem, not XFS

### 3. Alternative Solutions Considered ❌ Not Viable

**Option A: Create XFS Filesystem in Memory**
- Would require loop device support (unavailable in cgroup v2)
- Or require mounting from a file (same restriction)

**Option B: Use Different GrootFS Driver**
- Only two drivers exist: overlay-xfs and btrfs
- Both require specific filesystem types (XFS or btrfs)
- Overlay filesystem not supported by either

**Option C: Modify Garden to Skip Image Plugin**
- Garden architecture requires image plugin for container rootfs management
- No simpler alternative plugin available
- Would require significant upstream changes

## Working Solution: Docker-CPI

### Why Docker-CPI Works

Docker-CPI successfully runs on Noble in nested containers because:

1. **Uses Docker's native storage**: Relies on Docker's overlay2 storage driver
2. **No XFS requirement**: Docker overlay2 works with any underlying filesystem
3. **Simpler architecture**: No Garden/GrootFS complexity
4. **Proven compatibility**: Already validated in build pipeline

### Docker-CPI Architecture

```
┌─────────────────────────────────────────────────────┐
│ Concourse Worker Container (Ubuntu Noble)          │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Docker Daemon                                   │ │
│ │ ┌─────────────────────────────────────────────┐ │ │
│ │ │ BOSH Director Container                     │ │ │
│ │ │ - Docker CPI                                │ │ │
│ │ │ - Uses: Docker overlay2 storage ✅          │ │ │
│ │ │ - Works with: Any filesystem ✅             │ │ │
│ │ │ - Result: Compatible ✅                     │ │ │
│ │ └─────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Test Results

**Docker-CPI Job**: `deploy-zookeeper-on-docker-bosh`
- ✅ Successfully starts BOSH director
- ✅ Deploys zookeeper release
- ✅ Passes all tests
- ✅ Works reliably on Noble with cgroup v2

## Recommendations

### For Production Use

**Use docker-cpi for Noble (Ubuntu 24.04) nested container deployments**

Reasons:
- ✅ Proven compatibility with Noble and cgroup v2
- ✅ Simpler architecture (fewer moving parts)
- ✅ No filesystem requirements
- ✅ Well-tested in production environments

### For Development/Testing

If warden-cpi is required for specific testing scenarios:
- ⚠️ Use Ubuntu Jammy (22.04) or earlier
- ⚠️ Or run on bare metal/VMs with XFS filesystems
- ⚠️ Avoid nested container environments

### Future Possibilities

For warden-cpi support on Noble in containers to work, one of these would be needed:

1. **GrootFS Enhancement**: Add overlay-only driver (no XFS requirement)
   - Requires upstream changes to cloudfoundry/garden
   - Would need alternative quota enforcement mechanism
   - Significant engineering effort

2. **Kernel Changes**: Enable loop devices in cgroup v2 privileged containers
   - Requires kernel/systemd changes
   - Security implications
   - Out of scope for application-level fixes

3. **Alternative Image Plugin**: Develop simpler image plugin for Garden
   - Requires Garden architecture changes
   - Would need to maintain compatibility
   - Significant development effort

## Files Modified During Investigation

### Core Files
- `start-bosh-warden-patched.sh`: Patch script with GrootFS configuration changes
- `start-bosh-warden-patched.sh.b64`: Base64-encoded version for pipeline embedding
- `pipeline.yml`: Warden-CPI job definition with patched script

### Investigation Commits
- `56cc49a`: Add investigation of GrootFS XFS filesystem requirement
- `492ebd1`: Fix GrootFS patch order: run pre-start before patching
- `1fed033`: Fix GrootFS patching to handle nested YAML structure
- `795099f`: Fix corrupted base64 string in warden-cpi pipeline
- `7262977`: Patch warden-cpi to work on Noble with cgroup v2

## Verification Commands

### Check GrootFS Configuration
```bash
fly -t local hijack -j nested-bosh-zookeeper/deploy-zookeeper-on-warden-bosh \
  -b 7 -s start-bosh-and-deploy-zookeeper -- \
  cat /var/vcap/jobs/garden/config/grootfs_config.yml
```

### Check Garden Error Logs
```bash
fly -t local hijack -j nested-bosh-zookeeper/deploy-zookeeper-on-warden-bosh \
  -b 7 -s start-bosh-and-deploy-zookeeper -- \
  cat /var/vcap/sys/log/garden/garden_ctl.stderr.log
```

### Check Filesystem Type
```bash
fly -t local hijack -j nested-bosh-zookeeper/deploy-zookeeper-on-warden-bosh \
  -b 7 -s start-bosh-and-deploy-zookeeper -- \
  df -T /var/vcap/data
```

Output shows: `overlay` filesystem (794c7630), not XFS (58465342)

## References

### Documentation
- [Garden GrootFS Documentation](https://github.com/cloudfoundry/garden-runc-release/blob/develop/docs/grootfs.md)
- [BOSH Warden CPI](https://github.com/cloudfoundry/bosh/tree/main/src/bosh-director/lib/cloud/warden)
- [Docker CPI](https://github.com/cloudfoundry/bosh-docker-cpi-release)

### Related Issues
- Original Issue: https://github.com/rkoster/rubionic-workspace/issues/273
- Repository Issue: https://github.com/rkoster/noble-concourse-nested-cpi-validation/issues/1

### Lab Environment
- **Concourse UI**: http://10.246.0.21:8080
- **Pipeline**: nested-bosh-zookeeper
- **Working Job**: deploy-zookeeper-on-docker-bosh ✅
- **Failed Job**: deploy-zookeeper-on-warden-bosh ❌

## Conclusion

Warden-CPI cannot function on Ubuntu Noble (24.04) in nested container environments due to fundamental architectural constraints in GrootFS. The overlay-xfs driver's hard requirement for XFS filesystems, combined with cgroup v2's restrictions on loop devices, makes this configuration impossible to support without significant upstream changes.

**The docker-cpi provides a working alternative** that is fully compatible with Noble, cgroup v2, and nested container deployments. It is the recommended approach for production use.
