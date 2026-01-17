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

### Step 7: Create Build Job ✅ Complete
**Status**: Complete
**Task**: Add Concourse pipeline job to build custom warden-cpi image

**Changes**:
1. Added resources to pipeline-template.yml:
   - `warden-cpi-repo` - Git resource for this repository
   - `bosh-deployment-repo` - Git resource for bosh-deployment (needed in build context)
   - `warden-cpi-containerd-image` - Registry image resource for custom image
   - `bosh-cli-image` - Base image for build task

2. Added `build-warden-cpi-containerd-image` job:
   - Fetches warden-cpi-repo and bosh-deployment
   - Copies bosh-deployment into build context
   - Builds Docker image with BASE_IMAGE=ubuntu:noble
   - Pushes to local registry at `((docker_registry_host))/warden-cpi-containerd:latest`

**Commits**:
- 6afa98a - Add image build job to pipeline

---

### Step 8: Configure Registry Push ✅ Complete
**Status**: Complete  
**Task**: Extract Docker registry credentials and configure pipeline

**Implementation**:
- Updated `repipe.sh` to extract credentials using `bosh interpolate`
- Extracts `docker_registry_password` from `vars.yml`
- Passes credentials to pipeline via `--var` arguments
- Registry host: `${CONCOURSE_STATIC_IP}:5000` (default: 10.246.0.21:5000)

**Command Flow**:
```bash
DOCKER_REGISTRY_PASSWORD=$(bosh interpolate vars.yml --path=/docker_registry_password)
fly set-pipeline --var docker_registry_password=... --var docker_registry_host=...
```

---

### Step 9: Update Pipeline Jobs ✅ Complete
**Status**: Complete
**Task**: Add job to deploy using custom-built warden-cpi image

**New Job**: `deploy-zookeeper-on-warden-containerd`
- Uses `warden-cpi-containerd-image` (custom built image)
- Depends on successful image build (`passed: [build-warden-cpi-containerd-image]`)
- Starts containerd daemon before BOSH director
- Uses standard warden-cpi start-bosh script
- Deploys zookeeper to validate functionality
- Tests deployment and cleans up

**Key Differences from Docker-CPI Job**:
1. Starts containerd daemon explicitly
2. Waits for containerd to be ready (30s timeout)
3. Uses warden-cpi with Garden configured for containerd backend
4. No script patching needed (containerd handles filesystem properly)

**Commits**:
- (pending) - Add warden-containerd deployment job to pipeline

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
