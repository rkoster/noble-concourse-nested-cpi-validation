# Warden-CPI Runtime Testing on Ubuntu Noble

## Overview

This document tracks systematic testing of different Garden runtime configurations to determine the optimal approach for running warden-cpi on Ubuntu Noble (24.04) in nested Concourse containers.

**Goal**: Identify which runtime configuration (runc vs containerd) allows warden-cpi to work successfully on Noble with cgroup v2.

## Background

### Previous Investigation Findings

1. **Initial GrootFS + runc Testing** ([WARDEN_CPI_INVESTIGATION.md](./WARDEN_CPI_INVESTIGATION.md))
   - Testing revealed that GrootFS requires XFS filesystem
   - XFS requires loop device mounting (`losetup`)
   - Loop devices fail in cgroup v2 privileged containers with "Operation not permitted"
   - Error: `Store path filesystem is incompatible with native driver (must be XFS mountpoint)`

2. **Containerd Approach** ([CONCOURSE_RUNTIME_ANALYSIS.md](./CONCOURSE_RUNTIME_ANALYSIS.md))
   - Hypothesis: Containerd's overlayfs snapshotter would bypass XFS requirement
   - Implementation: Custom warden-cpi image with containerd runtime
   - Status: In testing (pipeline infrastructure complete)

3. **Key Insight from Upstream**
   - **Upstream BOSH director pipelines successfully use GrootFS without XFS issues**
   - This suggests the containerd runtime itself might be causing the GrootFS incompatibility
   - Testing hypothesis: Reverting to stock runc + GrootFS may work on Noble

4. **Concourse Runtime Evolution**
   - Concourse 8.0+ changed default runtime from guardian (runc) to containerd
   - Upstream BOSH CI pipelines still use Concourse < 8.0 with guardian runtime
   - **New hypothesis: Guardian runtime (not containerd) is the key to GrootFS compatibility**
   - Testing approach: Configure Concourse worker to use `runtime: guardian`

## Testing Strategy

### Test Matrix

| Test | Runtime | Image Plugin | Configuration Changes | Expected Outcome |
|------|---------|--------------|----------------------|------------------|
| **Baseline** (runc) | runc (stock) | GrootFS (default) | None - stock Garden config | Validate if stock config works on Noble |
| **Test 1** (containerd) | containerd | overlayfs snapshotter | `containerd_mode: true`<br>`runtime_plugin: '/usr/bin/containerd'` | Bypass XFS requirement with overlayfs |

### Test Baseline: Stock runc + GrootFS

**Configuration:**
```ruby
{
  'allow_host_access': true,
  'debug_listen_address': '127.0.0.1:17013',
  'default_container_grace_time': '0',
  'destroy_containers_on_start': true,
  'graph_cleanup_threshold_in_mb': '0',
  'listen_address': '127.0.0.1:7777',
  'listen_network': 'tcp',
  # NO containerd_mode
  # NO no_image_plugin  
  # NO runtime_plugin
  # Uses default runc runtime
  # Uses default GrootFS image plugin
}
```

**Key Differences from Previous Tests:**
- **No modifications to GrootFS configuration**
- **No attempt to disable backing store or loop devices**
- **No containerd runtime**
- **Exact same configuration as upstream BOSH director pipelines**

**Rationale:**
If upstream BOSH pipelines work with this configuration, it suggests:
1. GrootFS can work on Noble when properly configured
2. Previous failures may have been due to incorrect patches or containerd interference
3. The stock runc + GrootFS combination is the correct baseline

### Test 1: Containerd + overlayfs

**Configuration:**
```ruby
{
  'allow_host_access': true,
  'debug_listen_address': '127.0.0.1:17013',
  'default_container_grace_time': '0',
  'destroy_containers_on_start': true,
  'graph_cleanup_threshold_in_mb': '0',
  'listen_address': '127.0.0.1:7777',
  'listen_network': 'tcp',
  'containerd_mode': true,
  'runtime_plugin': '/usr/bin/containerd',
  # Containerd uses overlayfs snapshotter by default
}
```

**Rationale:**
- Containerd's overlayfs snapshotter doesn't require XFS
- No loop devices needed for container storage
- May provide better compatibility with cgroup v2

## Test Execution

### Infrastructure Setup

1. **Concourse Lab**: http://10.246.0.21:8080
2. **Docker Registry**: `10.246.0.21:5000` (colocated with Concourse)
3. **Pipeline**: `nested-bosh-zookeeper`

### Concourse Runtime Configuration

**NEW APPROACH: Configure Concourse worker to use guardian runtime**

Based on the insight that upstream BOSH CI uses Concourse < 8.0 with guardian runtime (not containerd), we're now testing with the Concourse worker configured for guardian runtime:

```yaml
# ops-files/guardian-runtime.yml
- type: replace
  path: /instance_groups/name=concourse/jobs/name=worker/properties/runtime?
  value: guardian
```

**Key Changes**:
- Concourse worker runtime set to `guardian` (runc backend)
- Removes containerd-specific configuration
- Matches the runtime used in upstream BOSH CI pipelines
- Should provide proper environment for nested warden-cpi with GrootFS

**Expected Impact**:
- Guardian runtime provides proper Garden API implementation for GrootFS
- Nested containers created by warden-cpi should work with GrootFS
- No XFS/loop device errors (if this is the correct configuration)

### Baseline Test (runc + GrootFS)

**Build Job**: `build-warden-cpi-runc-image`
- Builds custom Docker image with stock Garden configuration
- No GrootFS patches or modifications
- Uses default runc runtime

**Deploy Job**: `deploy-zookeeper-on-warden-runc`
- Starts Garden with runc runtime
- Deploys BOSH director with warden-cpi
- Deploys single-instance zookeeper
- Tests zookeeper connectivity

**Trigger Commands:**
```bash
# Build the runc-based image
fly -t local trigger-job -j nested-bosh-zookeeper/build-warden-cpi-runc-image -w

# Test deployment (triggers automatically after build)
# Or manually trigger:
fly -t local trigger-job -j nested-bosh-zookeeper/deploy-zookeeper-on-warden-runc -w
```

### Containerd Test

**Build Job**: `build-warden-cpi-containerd-image`
- Builds custom Docker image with containerd package
- Garden configured for containerd mode
- Uses containerd's overlayfs snapshotter

**Deploy Job**: `deploy-zookeeper-on-warden-containerd`
- Starts containerd daemon
- Starts Garden with containerd backend
- Deploys BOSH director with warden-cpi
- Deploys single-instance zookeeper

**Trigger Commands:**
```bash
# Build the containerd-based image  
fly -t local trigger-job -j nested-bosh-zookeeper/build-warden-cpi-containerd-image -w

# Test deployment (triggers automatically after build)
# Or manually trigger:
fly -t local trigger-job -j nested-bosh-zookeeper/deploy-zookeeper-on-warden-containerd -w
```

## Test Results

### Baseline Test: runc + GrootFS

**Status**: 🔄 Pending

**Build**:
- [ ] Image builds successfully
- [ ] Build duration: ___ minutes
- [ ] Image size: ___ MB

**Deployment**:
- [ ] Garden starts with runc runtime
- [ ] GrootFS initializes without errors
- [ ] BOSH director starts
- [ ] Zookeeper deploys successfully
- [ ] Zookeeper responds to status checks

**Errors Encountered**:
```
# To be filled during testing
```

**Analysis**:
```
# To be filled after test completion
```

### Test 1: Containerd + overlayfs

**Status**: 🔄 In Progress (infrastructure complete, testing pending)

**Build**:
- [x] Image builds successfully
- [ ] Build duration: ___ minutes
- [ ] Image size: ___ MB

**Deployment**:
- [ ] Containerd daemon starts
- [ ] Garden starts with containerd backend
- [ ] BOSH director starts
- [ ] Zookeeper deploys successfully
- [ ] Zookeeper responds to status checks

**Errors Encountered**:
```
# To be filled during testing
```

**Analysis**:
```
# To be filled after test completion
```

## Comparison with Upstream BOSH CI

### Upstream Configuration

Upstream BOSH director pipelines use:
- **Runtime**: runc (default)
- **Image Plugin**: GrootFS (default)
- **Base OS**: Ubuntu Jammy (22.04) and Noble (24.04)
- **Environment**: Docker-in-Docker (similar to our nested container setup)

**Key Difference**: Upstream uses the stock configuration without modifications or patches.

**Reference**: [cloudfoundry/bosh CI dockerfiles](https://github.com/cloudfoundry/bosh/tree/main/ci/dockerfiles/warden-cpi)

### Why Upstream Works

Possible reasons upstream doesn't encounter XFS/loop device issues:
1. **Proper cgroup v2 handling** in the base image
2. **Correct device permissions** in Docker-in-Docker setup
3. **No conflicting runtime modifications** (pure runc, no containerd)
4. **Proper filesystem preparation** for GrootFS backing store

## Conclusions

### If Baseline Test Succeeds

**Finding**: Stock runc + GrootFS configuration works on Noble

**Implications**:
- Previous failures were due to incorrect patches or containerd interference
- The solution is to use unmodified Garden configuration
- Upstream approach is the correct pattern

**Recommendation**: 
- Use stock warden-cpi configuration for Noble deployments
- Remove all GrootFS patches and modifications
- Follow upstream BOSH CI patterns exactly

### If Containerd Test Succeeds (and Baseline Fails)

**Finding**: Containerd's overlayfs snapshotter is required for Noble compatibility

**Implications**:
- GrootFS has fundamental incompatibility with Noble's cgroup v2 in nested containers
- Containerd bypasses the XFS requirement successfully
- This is a valid architectural solution for nested environments

**Recommendation**:
- Use containerd-based warden-cpi image for Noble nested deployments
- Maintain separate configurations for Noble vs earlier Ubuntu versions
- Document the containerd requirement for Noble + nested containers

### If Both Tests Fail

**Finding**: Warden-CPI has fundamental incompatibility with Noble nested containers

**Implications**:
- Both runtime approaches are blocked by cgroup v2 or other Noble-specific constraints
- The issue is deeper than just GrootFS vs containerd

**Recommendation**:
- Use docker-cpi as the validated solution for Noble + nested containers
- Document warden-cpi as incompatible with Noble nested environments
- Consider bare metal or traditional VM deployments for warden-cpi on Noble

## Next Steps

1. **Execute Baseline Test**
   - Build stock runc + GrootFS image
   - Deploy and validate on Noble
   - Document detailed results

2. **Compare with Containerd Test**
   - Review containerd test results (when available)
   - Compare error messages and behavior
   - Identify root cause differences

3. **Update Documentation**
   - Document successful configuration in this file
   - Update main README with recommendations
   - Create deployment guide for chosen approach

4. **Productionize Solution**
   - Clean up pipeline configuration
   - Remove unsuccessful test configurations
   - Document production deployment procedures

## References

- [WARDEN_CPI_INVESTIGATION.md](./WARDEN_CPI_INVESTIGATION.md) - Initial GrootFS XFS investigation
- [CONCOURSE_RUNTIME_ANALYSIS.md](./CONCOURSE_RUNTIME_ANALYSIS.md) - Concourse runtime configuration analysis
- [IMPLEMENTATION_PROGRESS.md](./IMPLEMENTATION_PROGRESS.md) - Containerd implementation progress
- [cloudfoundry/bosh warden-cpi](https://github.com/cloudfoundry/bosh/tree/main/ci/dockerfiles/warden-cpi) - Upstream reference

---

**Document Status**: Living document - Updated as tests progress  
**Last Updated**: 2026-01-19  
**Test Status**: Baseline test ready to execute
