# Warden-CPI Containerd Implementation Progress

This document tracks the implementation of a custom warden-cpi Docker image with containerd support for Noble (Ubuntu 24.04).

## Goal

Build a custom warden-cpi image with containerd runtime to avoid the GrootFS XFS filesystem requirement that prevents warden-cpi from working in nested containers on Noble.

## Implementation Steps

### Step 1: Deploy Docker Registry ✅ Complete
**Status**: Complete
**Task**: Create BOSH ops file to deploy docker-registry-boshrelease on the Concourse instance

**Details**:
- Created `ops-files/docker-registry.yml` to colocate docker-registry with Concourse
- Configured basic auth with generated password
- Registry listens on port 5000 (HTTP)
- Updated `deploy-concourse.sh` to include the ops file
- Registry will be deployed on same instance as Concourse for simplicity

**Files Modified**:
- `ops-files/docker-registry.yml` - BOSH ops file for registry deployment
- `deploy-concourse.sh` - Added ops file to deployment command

**Commits**:
- 3a742ec - Add docker-registry ops file and progress tracking
- (pending) - Simplify docker-registry ops file and update deploy script

---

### Step 2: Fork BOSH Repository ✅ Complete (Alternative Approach)
**Status**: Complete  
**Task**: Fork cloudfoundry/bosh repository

**Approach Taken**:
- MCP fork tool encountered a technical issue (GraphQL mutation error)
- Cloned bosh repository locally instead for modifications
- Will build image from modified Dockerfile without requiring GitHub fork
- Concourse will build directly from local repository context

**Repository Location**: `/__w/rubionic-workspace/rubionic-workspace/opencode-workspace/bosh-fork`

---

### Step 3: Clone Forked Repository ✅ Complete
**Status**: Complete
**Task**: Clone the forked BOSH repository locally

**Details**:
- Cloned cloudfoundry/bosh repository (depth=1 for efficiency)
- Located warden-cpi Dockerfile at `ci/dockerfiles/warden-cpi/`
- Analyzed Dockerfile structure and dependencies

---

### Step 4: Create Branch ✅ Complete
**Status**: Complete
**Task**: Create feature branch for warden-cpi Dockerfile modifications

**Branch**: `warden-cpi-containerd-noble`
**Location**: bosh-fork repository

---

### Step 5: Modify Dockerfile ✅ Complete
**Status**: Complete
**Task**: Update warden-cpi Dockerfile to include containerd runtime support

**Changes Made**:
1. **Dockerfile**: Added `containerd` package to apt-get install
2. **install-garden.rb**: Added Garden containerd configuration
   - `containerd_mode: true`
   - `runtime_plugin: '/usr/bin/containerd'`

**Commits**:
- 7341353 - Add containerd support to warden-cpi Docker image

**Key Changes**:
- Containerd will replace runc+GrootFS as the container runtime
- Avoids XFS filesystem requirement (uses overlay instead)
- Should work in nested containers on Noble without loop device issues

---

### Step 6: Push Changes ⏸️ Pending
**Task**: Push Dockerfile changes to forked repository branch

---

### Step 7: Create Build Job ⏸️ Pending
**Task**: Add Concourse pipeline job to build custom warden-cpi image

**Requirements**:
- Job takes forked bosh repo as input
- Builds the warden-cpi Docker image
- Pushes to deployed Docker registry

---

### Step 8: Configure Registry Push ⏸️ Pending
**Task**: Extract Docker registry credentials and configure pipeline

**Implementation**:
- Use `bosh int vars.yml` to extract registry credentials
- Pass credentials to `fly set-pipeline` using `--var` arguments
- Update `repipe.sh` script

---

### Step 9: Update Containerd Job ⏸️ Pending
**Task**: Modify containerd job to use custom-built image

**Changes**:
- Replace `bosh/warden-cpi` image reference
- Point to custom image from local registry

---

### Step 10: End-to-End Testing ⏸️ Pending
**Task**: Test complete pipeline with custom warden-cpi image

**Validation**:
- Image builds successfully
- Registry push works
- Containerd starts properly
- Zookeeper deploys without XFS errors

---

## Commit History

*Commits will be tracked here as work progresses*

---

**Last Updated**: 2026-01-17 06:42 UTC
**Current Step**: 1/10
**Overall Status**: In Progress
