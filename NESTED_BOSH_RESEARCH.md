# Nested BOSH Director Research Notes

## Problem Statement

Running a BOSH director inside a Garden container (nested containerization) on Ubuntu Noble (24.04) with cgroup v2 fails due to BPM/runc conflicts with eBPF cgroup device filters.

## Environment

- **Host OS**: Ubuntu 24.04.3 LTS (Noble Numbat)
- **Kernel**: 5.15.0-164-generic
- **Cgroup Version**: v2 (unified hierarchy)
- **Outer Container Runtime**: Garden with runc 1.4.0
- **Inner Container Runtime**: BPM with runc 1.2.8

## Issues Identified

### Issue 1: Warden CPI StreamIn File Visibility (FIXED)

**Symptom**: Files extracted via `StreamIn` to `/tmp` weren't visible to subsequent `Run` commands.

**Root Cause**: Race condition with overlayfs/containerd when using temp directory then moving files.

**Fix Applied**: Modified `warden_file_service.go` to stream directly to destination directory.
- Fork: `https://github.com/rkoster/bosh-warden-cpi-release` branch `fix-overlayfs-race-condition`
- File: `src/bosh-warden-cpi/vm/warden_file_service.go`

### Issue 2: eBPF Cgroup Device Filter Conflicts (RESOLVED - NOT BLOCKING)

**Symptom**: When BPM starts processes inside the nested director VM, runc logs warnings about removing existing eBPF filters:

```
time="2026-01-29T22:01:59Z" level=info msg="found more than one filter (2) attached to a cgroup -- removing extra filters!"
time="2026-01-29T22:01:59Z" level=info msg="removing old filter 0 from cgroup" id=6979 name= run_count=0 runtime=0s tag=531db05b114e9af3 type=CGroupDevice
```

**Root Cause Analysis**:

On cgroup v2, device access control uses eBPF programs instead of file-based rules (cgroup v1). When runc attaches a new cgroup device filter program, it detects and removes existing filters from the parent container.

This is **expected behavior** per runc issue [#2976](https://github.com/opencontainers/runc/issues/2976) - the warning was added to debug cases where `BPF_F_REPLACE` flag isn't supported.

**Conclusion**: These warnings are **benign** - BPM processes start successfully despite the warnings. Confirmed by observing running director processes (nats, postgres, director, workers, nginx, uaa) inside the nested VM.

**Related Issues**:
- [runc#2976](https://github.com/opencontainers/runc/issues/2976) - "found more than one filter" warning (closed)
- [runc#2986](https://github.com/opencontainers/runc/pull/2986) - Fix for BPF_F_REPLACE support (merged 2021-06-08)
- [runc#3196](https://github.com/opencontainers/runc/issues/3196) - Setting cgroup v2 rules without overriding (open)
- [runc#3604](https://github.com/opencontainers/runc/issues/3604) - Race condition updating device rules (open)
- [bpm#67](https://github.com/cloudfoundry/bpm-release/issues/67) - Conflict with concourse worker (closed 2018)
- [bpm#143](https://github.com/cloudfoundry/bpm-release/issues/143) - /dev/console access in bosh-lite (closed 2020)
- [bpm#172](https://github.com/cloudfoundry/bpm-release/issues/172) - Cgroups v2 support (closed)

### Issue 3: Postgres Role Creation Race Condition (RESOLVED - SELF-HEALING)

**Symptom**: Director fails to connect to postgres because the `postgres` role doesn't exist yet.

```
2026-01-29 22:02:00 GMT LOG:  database system is ready to accept connections
2026-01-29 22:02:01 GMT FATAL:  role "postgres" does not exist
```

**Root Cause**: The `create-database` script runs asynchronously but director tries to connect before role is created.

**Resolution**: The postgres role IS eventually created. Monit retries failed services, so after the role exists, director starts successfully. This is a timing issue that self-heals via monit's retry mechanism.

**Evidence**: Later logs show successful connections:
```
postgres: postgres bosh 127.0.0.1(56762) idle
```

### Issue 4: GrootFS Mount Failures - Inner Garden (BLOCKING)

**Symptom**: Inner Garden (for creating VMs from the nested director) fails to initialize unprivileged store:

```json
{"level":"error","source":"grootfs","message":"grootfs.init-store.store-manager-init-store.initializing-filesystem-failed",
 "data":{"error":"Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only."}}
```

**Root Cause**: When running inside a container, GrootFS cannot create loop-mounted XFS filesystems with user namespace mappings. The mount syscall is restricted.

**Technical Details**:
- GrootFS tries to create a backing store file and loop-mount it with XFS + pquota
- User namespace mappings are configured but mount fails with "operation permitted for root only"
- This is a fundamental limitation of running nested containers with user namespaces

**Potential Workarounds**:
1. Use privileged-only mode for inner Garden (skip unprivileged store)
2. Pre-create the stores in the stemcell image
3. Use a different rootfs manager (e.g., overlay2 without loop mounts)
4. Grant additional capabilities to the outer container

### Issue 5: Health Monitor EBADF Error (NEW)

**Symptom**: Health monitor fails with epoll file descriptor error:

```
/gems/async-2.34.0/lib/async/scheduler.rb:453:in `select': Bad file descriptor - select_internal_with_gvl:epoll_wait (Errno::EBADF)
```

**Root Cause**: The Ruby async gem's epoll-based scheduler encounters issues with file descriptors in the nested BPM container environment. This may be related to:
- BPM's file descriptor handling
- Inherited file descriptors being closed
- epoll behavior differences in nested namespaces

**Impact**: Health monitor cannot start, but director still functions for deployments.

## Historical Context

### Previous Fixes for Similar Issues

1. **BPM Issue #67 (2018)**: Concourse worker conflicted with BPM cgroup mounts
   - Workaround: `umount /cgroup/bpm/*`
   - Fix: Released in BPM after adjusting cgroup mounting

2. **BPM Issue #143 (2020)**: /dev/console access denied in bosh-lite
   - Cause: runc removed /dev/console access for security
   - Fix: Bump BPM's runc to match Garden's runc version (rc91)

3. **BPM Issue #172 (2024)**: Cgroups v2 experimental support
   - Status: Merged, cgroups v2 now supported on Jammy/Noble stemcells

## Technical Details

### Cgroup Hierarchy (Inside Concourse Container)

```
13:net_cls,net_prio:/43e91f7b-dc83-43d0-97a8-88c95fb942c2
10:devices:/system.slice/garden.service/43e91f7b-dc83-43d0-97a8-88c95fb942c2
0::/43e91f7b-dc83-43d0-97a8-88c95fb942c2
```

### BPM Process Configuration

BPM creates separate runc containers per process with:
- Namespaces: ipc, mount, uts, pid (NO network namespace)
- Shared host network between BPM processes

### Key Log Locations

```bash
CONTAINER=$(gaol list | head -1)
EPHEMERAL="/var/vcap/store/warden_cpi/ephemeral_bind_mounts_dir/$CONTAINER"
ROOTFS="/var/vcap/data/grootfs/store/privileged/images/$CONTAINER/rootfs"

# Logs:
$EPHEMERAL/sys/log/nats/nats.stderr.log          # eBPF filter messages
$EPHEMERAL/sys/log/postgres/postgres.stderr.log  # eBPF + role errors
$EPHEMERAL/sys/log/director/director.stderr.log  # Connection failures
$EPHEMERAL/sys/log/director/bpm.log              # BPM lifecycle
$ROOTFS/var/vcap/monit/monit.log                 # Service failures
```

## Potential Solutions to Investigate

### Option A: Disable BPM for Inner BOSH

Check if bosh-deployment has ops-files to run director processes without BPM containerization.

### Option B: Configure BPM to Skip Device Cgroup Management

Research if BPM/runc has options to not manage device cgroups when nested.

### Option C: Use systemd Cgroup Driver

Both outer and inner runc support systemd cgroup driver - may handle nesting better than cgroupfs.

### Option D: Match runc Versions

Ensure outer Garden runc and inner BPM runc are same version to avoid compatibility issues.

Current versions:
- Outer Garden runc: 1.4.0
- Inner BPM runc: 1.2.8

### Option E: Run Director Processes Directly (No BPM)

Modify director VM to run nats, postgres, director without BPM isolation.

## Progress Tracking

| Component | Status | Notes |
|-----------|--------|-------|
| Light stemcell image | Working | Pushed to registry |
| Warden CPI StreamIn fix | Working | Direct destination streaming |
| VM Creation | Working | Agent connects successfully |
| BPM Process Start | Working | eBPF warnings are benign |
| Postgres | Working | Role creation race self-heals via monit retry |
| NATS | Working | Running successfully |
| Director | Working | Puma + workers running |
| UAA | Working | Running successfully |
| Director Nginx | Working | Running successfully |
| Blobstore | Working | Nginx running successfully |
| Scheduler | Working | Running successfully |
| Sync-DNS | Working | Running successfully |
| Health Monitor | Failing | EBADF error with async gem |
| Inner Garden | Failing | GrootFS mount permission denied |
| Zookeeper deployment | Blocked | Waiting for inner Garden |

## Current State Summary (Build #52)

The inner BOSH director is **mostly functional**:
- All core director services running (nats, postgres, director, uaa, blobstore, nginx)
- Can accept bosh CLI commands
- **Blocking issue**: Cannot deploy VMs because inner Garden fails to initialize

The eBPF warnings we investigated are **not the problem**. The real blocking issue is GrootFS in the nested environment.

## Next Steps

1. **Fix GrootFS mount issue** - This is the primary blocker
   - Option A: Configure inner Garden to use privileged-only mode
   - Option B: Pre-initialize stores in the stemcell
   - Option C: Use a different CPI approach (docker-cpi instead of warden-cpi for nested VMs)
   
2. **Fix Health Monitor EBADF** - Lower priority, director works without it

3. **Test director functionality** - Once Garden works, deploy zookeeper

## Debugging Commands

```bash
# Hijack into build
fly -t local hijack -j nested-bosh-zookeeper/deploy-zookeeper-on-upstream-warden -b <build#> -s deploy-with-upstream-warden-cpi -- bash

# Get container ID
CONTAINER=$(ls /var/vcap/data/grootfs/store/privileged/images/ | head -1)
EPHEMERAL="/var/vcap/store/warden_cpi/ephemeral_bind_mounts_dir/$CONTAINER"

# Check service status via nsenter (PID 3034 = inner garden-init)
nsenter -t 3034 -m -u -i -p -C -- ps aux | grep -E "bpm|nats|postgres|director"

# Check logs
cat $EPHEMERAL/sys/log/director/director.stderr.log
cat $EPHEMERAL/sys/log/garden/garden_ctl.stderr.log
```

## References

- [runc cgroups v2 device controller](https://github.com/opencontainers/runc/blob/main/libcontainer/cgroups/ebpf/devicefilter/devicefilter.go)
- [BPM release](https://github.com/cloudfoundry/bpm-release)
- [Garden runc release](https://github.com/cloudfoundry/garden-runc-release)
- [BOSH deployment](https://github.com/cloudfoundry/bosh-deployment)
