# Warden-CPI Containerd Implementation Progress

This document tracks the implementation of a custom warden-cpi Docker image with containerd support for Noble (Ubuntu 24.04).

## Goal

Build a custom warden-cpi image with containerd runtime to avoid the GrootFS XFS filesystem requirement that prevents warden-cpi from working in nested containers on Noble.

## Implementation Steps

### Step 1: Deploy Docker Registry ⏳ In Progress
**Status**: Starting
**Task**: Create BOSH ops file to deploy docker-registry-boshrelease on the Concourse instance

**Details**:
- Need to deploy a private Docker registry to store the custom warden-cpi image
- Registry will be deployed via BOSH on the same director as Concourse
- Credentials will be stored in vars.yml for pipeline access

**Files to Create/Modify**:
- `ops-files/docker-registry.yml` - BOSH ops file for registry deployment

---

### Step 2: Fork BOSH Repository ⏸️ Pending
**Task**: Fork cloudfoundry/bosh repository using MCP GitHub tool

---

### Step 3: Clone Forked Repository ⏸️ Pending
**Task**: Clone the forked BOSH repository locally

---

### Step 4: Create Branch ⏸️ Pending
**Task**: Create feature branch for warden-cpi Dockerfile modifications

---

### Step 5: Modify Dockerfile ⏸️ Pending
**Task**: Update warden-cpi Dockerfile to include containerd runtime support

**Required Changes**:
- Add containerd packages to the image
- Ensure containerd binaries are available in standard paths
- Update any initialization scripts if needed

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
