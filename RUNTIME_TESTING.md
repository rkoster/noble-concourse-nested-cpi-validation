# Runtime Testing: runc vs containerd for Warden CPI on Noble

## Executive Summary

This document tracks systematic testing of different Garden runtime configurations to determine the optimal approach for running warden-cpi in nested containers on Ubuntu Noble (24.04).

**Goal**: Identify why upstream BOSH CI pipelines successfully use GrootFS while our initial attempts with containerd encountered issues.

---

## Background

### Initial Hypothesis (Containerd Approach)

Our initial investigation (see `WARDEN_CPI_INVESTIGATION.md` and `CONCOURSE_RUNTIME_ANALYSIS.md`) concluded that:
- GrootFS requires XFS filesystem via loop devices
- Loop devices fail in cgroup v2 containers on Noble
- **Solution tried**: Switch to containerd runtime to bypass GrootFS

### New Hypothesis (runc + GrootFS Approach)

**Key Observation**: Upstream BOSH CI pipelines run in containers and successfully use GrootFS with the runc backend.

**New hypothesis**: The containerd runtime itself may be causing compatibility issues, rather than GrootFS being fundamentally incompatible with nested containers.

---

## Test Matrix

| Test | Runtime | Image Plugin | GrootFS Modifications | Expected Outcome | Status |
|------|---------|--------------|----------------------|------------------|--------|
| **Baseline** | runc | grootfs (default) | None (stock config) | Show what error occurs | 🔄 Pending |
| **Test 1** | runc | grootfs | Minimal patches only | Test if simple fixes work | 🔄 Pending |
| **Test 2** | containerd | none (no_image_plugin) | Disabled entirely | Current approach | ⏸️ Paused |
| **Test 3** | runc | grootfs | XFS backing store config tuning | Test alternative XFS setup | 🔄 Pending |
| **Test 4** | runc | simple-overlay-plugin | Custom lightweight plugin | Fallback option | 🔄 Pending |

Legend:
- ✅ Success - Configuration works
- ❌ Failed - Configuration doesn't work
- 🔄 Pending - Not yet tested
- ⏸️ Paused - Testing suspended

---

## Test Configurations

### Baseline: Stock runc + GrootFS

**Configuration**:
```ruby
# install-garden.rb
'garden' => {
  'allow_host_access': true,
  'debug_listen_address': '127.0.0.1:17013',
  'default_container_grace_time': '0',
  'destroy_containers_on_start': true,
  'graph_cleanup_threshold_in_mb': '0',
  'listen_address': '127.0.0.1:7777',
  'listen_network': 'tcp',
  # NO containerd_mode, NO no_image_plugin, NO runtime_plugin overrides
}
```

**Purpose**: Establish baseline behavior with no modifications

**Expected Result**: Reproduce the original GrootFS initialization failure

---

### Test 1: runc + GrootFS with Minimal Patches

**Configuration**:
```ruby
'garden' => {
  'allow_host_access': true,
  # ... other settings ...
  # Keep runc as default runtime (no containerd_mode)
  # Keep GrootFS as image plugin (no no_image_plugin)
}
```

**Patches Applied**:
1. Allow overlay filesystem (not just XFS) for GrootFS store
2. Skip loop device creation if unavailable
3. Disable XFS project quotas (accept no per-container disk limits)

**Purpose**: Test if GrootFS can work with minimal modifications to support overlay filesystem

**Expected Result**: If upstream BOSH CI works with this approach, we should see success

---

### Test 2: containerd + No Image Plugin (Current Approach)

**Configuration**:
```ruby
'garden' => {
  'containerd_mode': true,
  'no_image_plugin': true,
  'runtime_plugin': '/usr/bin/containerd',
  # ... other settings ...
}
```

**Purpose**: Document the containerd-based approach we've been pursuing

**Current Status**: 
- ✅ Custom warden-cpi image builds successfully
- ⏸️ Testing paused to explore runc approach first

---

### Test 3: runc + GrootFS with XFS Configuration Tuning

**Configuration**:
```ruby
'garden' => {
  # Default runc runtime
  'image_plugin': '/var/vcap/packages/grootfs/bin/grootfs',
  'image_plugin_extra_args': [
    '--store', '/var/vcap/data/grootfs/store',
    '--store-size-bytes', '0',  # Disable backing store creation
    '--with-direct-io', 'true',  # Avoid loop device buffering
  ]
}
```

**Purpose**: Test if GrootFS configuration flags can bypass loop device requirements

---

### Test 4: runc + Simple Overlay Plugin

**Configuration**:
```ruby
'garden' => {
  'image_plugin': '/usr/local/bin/simple-overlay-plugin',
  'image_plugin_extra_args': ['--store', '/var/vcap/data/overlay-store']
}
```

**Purpose**: Fallback option using a custom minimal image plugin (see `GROOTFS_ANALYSIS.md` for design)

---

## Test Results

### Baseline: Stock runc + GrootFS

**Build**: TBD

**Configuration Files**:
- Dockerfile: `warden-cpi-runc/Dockerfile`
- Garden installer: `warden-cpi-runc/install-garden-runc.rb`

**Execution Log**:
```
[To be filled after test run]
```

**Error Analysis**:
```
[To be filled after test run]
```

**Conclusion**:
```
[To be filled after analysis]
```

---

### Test 1: runc + GrootFS with Minimal Patches

**Build**: TBD

**Configuration Changes**:
```
[To be filled during implementation]
```

**Execution Log**:
```
[To be filled after test run]
```

**Error Analysis**:
```
[To be filled after test run]
```

**Conclusion**:
```
[To be filled after analysis]
```

---

### Test 2: containerd + No Image Plugin (Current)

**Build**: 17+ (see http://10.246.0.21:8080)

**Configuration Files**:
- Dockerfile: `warden-cpi-containerd/Dockerfile`
- Garden installer: `warden-cpi-containerd/install-garden.rb`
- Contains: `containerd_mode: true`, `no_image_plugin: true`

**Execution Log**:
```
Build 16: Image build failed (OCI configuration issue)
Build 17+: Image builds successfully, deployment testing in progress
```

**Current Status**: ⏸️ Paused pending runc test results

**Notes**:
- Successfully builds custom warden-cpi image with containerd runtime
- Bypasses GrootFS entirely by using `no_image_plugin: true`
- Testing suspended to investigate if runc approach is simpler/better

---

## Comparison with Upstream BOSH CI

### Upstream Configuration

**Source**: [cloudfoundry/bosh CI pipeline](https://github.com/cloudfoundry/bosh/tree/main/ci)

**Key Observations**:
```
[To be filled after reviewing upstream CI configuration]
```

**Differences from Our Setup**:
```
[To be filled after comparison]
```

---

## Recommendations

### If Baseline Test Succeeds
- Document the configuration that works
- Compare with our initial setup to identify what we changed that caused issues
- Update pipeline to use working configuration

### If Test 1 (Minimal Patches) Succeeds
- This is the preferred approach (closest to upstream)
- Minimal maintenance burden
- GrootFS features mostly intact

### If Only containerd Approach Works
- Continue with containerd-based solution
- Accept that this diverges from upstream but works for Noble
- Document limitations (no GrootFS image caching benefits)

### If All Tests Fail
- Investigate what makes upstream BOSH CI environment different
- Consider asking Cloud Foundry community for guidance
- Fall back to docker-cpi as validated working solution

---

## Next Steps

1. **Create runc-based test configurations**
   - [ ] Copy `warden-cpi-containerd/` to `warden-cpi-runc/`
   - [ ] Modify `install-garden.rb` to use default runc runtime
   - [ ] Remove containerd-specific patches
   - [ ] Update pipeline to add runc test job

2. **Run Baseline Test**
   - [ ] Trigger build with stock runc + GrootFS configuration
   - [ ] Document errors that occur
   - [ ] Compare with upstream BOSH CI behavior

3. **Iterate on Test 1 if needed**
   - [ ] Apply minimal patches based on baseline errors
   - [ ] Test with patched configuration
   - [ ] Document results

4. **Update This Document**
   - [ ] Fill in test results as builds complete
   - [ ] Add error logs and analysis
   - [ ] Provide final recommendation

---

## Appendix: Key Files

### Configuration Files (Containerd Approach)
- `warden-cpi-containerd/Dockerfile` - Custom image with containerd
- `warden-cpi-containerd/install-garden.rb` - Garden setup with containerd_mode
- `warden-cpi-containerd/start-bosh.sh` - BOSH director startup script

### Configuration Files (runc Approach) - To Be Created
- `warden-cpi-runc/Dockerfile` - Image without containerd dependencies
- `warden-cpi-runc/install-garden-runc.rb` - Garden setup with default runc
- `warden-cpi-runc/start-bosh.sh` - Same as containerd version

### Pipeline Configuration
- `pipeline-template.yml` - Concourse pipeline with build jobs
- `ops-files/docker-registry.yml` - Docker registry deployment
- `ops-files/garden-allow-host-access.yml` - Network access configuration

### Investigation Documents
- `WARDEN_CPI_INVESTIGATION.md` - Original loop device investigation (7 builds)
- `CONCOURSE_RUNTIME_ANALYSIS.md` - Runtime configuration analysis
- `GROOTFS_ANALYSIS.md` - Deep dive into GrootFS architecture
- `RUNTIME_TESTING.md` - This document (runtime comparison tests)

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-01-19 | Initial document created | OpenCode |

