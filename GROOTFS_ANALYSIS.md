# GrootFS Analysis: Architecture and Nested Container Compatibility

## Executive Summary

This document provides a detailed analysis of GrootFS, Garden's image plugin for container filesystem management. The goal is to understand how GrootFS works internally and what would be required to create an alternative image plugin that works in nested container environments (like Docker does).

**Key Finding**: GrootFS's architecture is tightly coupled to XFS project quotas, which requires either:
1. A real XFS filesystem (not available in containers)
2. Loop device access to create XFS backing stores (blocked in cgroup v2)

**Recommendation**: Create a simpler overlay-only image plugin that trades disk quota enforcement for nested container compatibility.

---

## Table of Contents

1. [GrootFS Architecture Overview](#grootfs-architecture-overview)
2. [Core Components](#core-components)
3. [Data Flow Analysis](#data-flow-analysis)
4. [The XFS/Loop Device Dependency](#the-xfsloop-device-dependency)
5. [Why Docker Works](#why-docker-works)
6. [Proposed Alternative: Simple Overlay Plugin](#proposed-alternative-simple-overlay-plugin)
7. [Implementation Roadmap](#implementation-roadmap)

---

## GrootFS Architecture Overview

### What is GrootFS?

GrootFS is Garden's **image plugin** responsible for:
- Pulling container images from registries (Docker Hub, OCI)
- Managing a local store of image layers (volumes)
- Creating container root filesystems using overlayfs
- Enforcing disk quotas per container

### Component Hierarchy

```
grootfs (CLI binary)
├── commands/
│   ├── init-store    # Initialize the store filesystem
│   ├── create        # Create a container rootfs from image
│   ├── delete        # Delete a container rootfs
│   ├── stats         # Get disk usage stats
│   ├── clean         # Garbage collect unused layers
│   └── delete-store  # Destroy entire store
├── store/
│   ├── manager/          # Store initialization/deletion
│   ├── image_manager/    # Container image lifecycle
│   ├── filesystems/
│   │   ├── overlayxfs/   # XFS + overlayfs driver (MAIN)
│   │   ├── loopback/     # Loop device management
│   │   └── namespaced/   # User namespace support
│   ├── garbage_collector/
│   ├── locksmith/        # File-based locking
│   └── dependency_manager/
├── base_image_puller/    # Image fetching from registries
├── fetcher/              # Layer download logic
├── groot/                # Core business logic
└── sandbox/              # User namespace handling
```

### Store Directory Structure

When GrootFS initializes a store, it creates:

```
/var/lib/grootfs/                    # Default store path
├── images/                          # Container rootfs images
│   └── {container-id}/
│       ├── rootfs/                  # Mounted overlayfs (container sees this)
│       ├── diff/                    # Upper layer (container writes)
│       └── workdir/                 # Overlayfs work directory
├── volumes/                         # Cached image layers
│   └── {chain-id}/                  # Layer content (lower dirs)
├── meta/
│   ├── dependencies/                # Layer dependency tracking
│   ├── namespace                    # UID/GID mapping config
│   └── volume-{chain-id}            # Layer metadata (size)
├── locks/                           # File-based locks
├── tmp/                             # Temporary files
├── l/                               # Short symlinks to volumes
├── projectids/                      # XFS project ID tracking
└── whiteout_dev                     # Character device for whiteouts
```

---

## Core Components

### 1. Commands Layer (`commands/`)

**Entry Point**: `main.go` uses `urfave/cli` to define commands

| Command | Purpose | Key File |
|---------|---------|----------|
| `init-store` | Initialize store with UID/GID mappings | `init_store.go` |
| `create` | Create rootfs from image URL | `create.go` |
| `delete` | Remove a container rootfs | `delete.go` |
| `stats` | Report disk usage | `stats.go` |
| `clean` | GC unused layers | `clean.go` |

**Key Interfaces Used**:
- `StoreDriver`: Filesystem initialization (`overlayxfs.Driver`)
- `VolumeDriver`: Layer management
- `ImageDriver`: Container rootfs creation

### 2. Store Manager (`store/manager/`)

**Purpose**: Orchestrates store initialization and deletion

**Key Operations**:

```go
// InitStore creates the store structure and filesystem
func (m *Manager) InitStore(logger lager.Logger, spec InitSpec) error {
    // 1. Try to mount existing backing store file
    m.mountFileSystemIfBackingStoreExists()
    
    // 2. Validate filesystem type (MUST be XFS)
    m.storeDriver.ValidateFileSystem(path)  // <-- THIS FAILS IN CONTAINERS
    
    // 3. If no valid XFS, create backing store file
    m.createAndMountFilesystem(storeSizeBytes)  // <-- NEEDS LOOP DEVICE
    
    // 4. Create internal directories
    // 5. Apply UID/GID mappings
    // 6. Configure store (whiteout device, links dir)
}
```

**The Problem Location**: `store/manager/manager.go:91-96`
```go
if err = m.storeDriver.ValidateFileSystem(logger, validationPath); err != nil {
    if spec.StoreSizeBytes <= 0 {
        return errorspkg.Wrap(err, "validating store path filesystem")
    }
    // Try to create backing store...
}
```

### 3. Filesystem Driver (`store/filesystems/overlayxfs/`)

**File**: `driver.go` (798 lines)

This is the **core filesystem abstraction** that:
- Creates XFS-backed stores
- Manages overlay mount operations
- Enforces disk quotas via XFS project quotas

**Key Methods**:

| Method | Purpose | XFS Dependency |
|--------|---------|----------------|
| `InitFilesystem` | Format and mount XFS | **YES** - creates XFS |
| `ValidateFileSystem` | Check for XFS + pquota | **YES** - requires magic 0x58465342 |
| `CreateVolume` | Create layer directory | No |
| `CreateImage` | Mount overlayfs for container | No (uses generic overlayfs) |
| `DestroyImage` | Unmount and remove | No |
| `FetchStats` | Get disk usage via `tardis` | **YES** - uses XFS quotas |

**Critical Validation Code** (`store/filesystems/filesystems.go`):
```go
func CheckFSPath(path, fsType string, mountOpts ...string) error {
    // Checks filesystem type via statfs()
    // Returns error if not XFS (0x58465342)
}
```

### 4. Image Manager (`store/image_manager/`)

**Purpose**: Create and manage container root filesystems

**Create Flow**:
```go
func (b *ImageManager) Create(logger, spec) (ImageInfo, error) {
    // 1. Create image directory: /store/images/{id}/
    imagePath := path.Join(storePath, "images", spec.ID)
    os.Mkdir(imagePath)
    
    // 2. Call filesystem driver to create overlay mount
    mountInfo = b.imageDriver.CreateImage(ImageDriverSpec{
        BaseVolumeIDs: spec.BaseVolumeIDs,  // Lower layers
        ImagePath:     imagePath,
        Mount:         spec.Mount,
        DiskLimit:     spec.DiskLimit,      // Requires XFS quotas
    })
    
    // 3. Return mount info for container runtime
    return ImageInfo{
        Rootfs: imagePath + "/rootfs",
        Mounts: []MountInfo{mountInfo},
    }
}
```

### 5. Base Image Puller (`base_image_puller/`)

**Purpose**: Fetch and cache container image layers

**Key Interfaces**:
```go
type Fetcher interface {
    BaseImageInfo(logger) (groot.BaseImageInfo, error)
    StreamBlob(logger, layerInfo) (io.ReadCloser, int64, error)
    Close() error
}

type VolumeDriver interface {
    CreateVolume(logger, parentID, id string) (string, error)
    VolumePath(logger, id string) (string, error)
    DestroyVolume(logger, id string) error
    MoveVolume(logger, from, to string) error
    WriteVolumeMeta(logger, id string, data VolumeMeta) error
    HandleOpaqueWhiteouts(logger, id string, paths []string) error
}
```

**Pull Flow**:
```go
func (p *BaseImagePuller) Pull(logger, baseImageInfo, spec) error {
    // For each layer (bottom to top):
    for i := 0; i < len(layers); i++ {
        // 1. Check if layer already cached
        if p.volumeExists(layer.ChainID) { continue }
        
        // 2. Acquire lock for this layer
        lock := p.locksmith.Lock(layer.ChainID)
        
        // 3. Create temporary volume directory
        tempPath := p.volumeDriver.CreateVolume(parentChainID, tempName)
        
        // 4. Stream and unpack layer tarball
        stream := p.fetcher.StreamBlob(layer)
        p.unpacker.Unpack(UnpackSpec{
            Stream:     stream,
            TargetPath: tempPath,
        })
        
        // 5. Rename to final location
        p.volumeDriver.MoveVolume(tempPath, finalPath)
    }
}
```

---

## Data Flow Analysis

### Complete `create` Command Flow

```
User: grootfs create docker:///ubuntu:latest my-container
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. Parse image URL (docker:///ubuntu:latest)                    │
│ 2. Verify store is initialized                                  │
│ 3. Create Fetcher for Docker registry                          │
│ 4. Create BaseImagePuller with VolumeDriver                    │
└─────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ BaseImagePuller.FetchBaseImageInfo()                            │
│  - GET /v2/library/ubuntu/manifests/latest                     │
│  - Parse manifest, get layer digests and diff IDs              │
│  - Compute chain IDs for each layer                            │
└─────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ BaseImagePuller.Pull()                                          │
│  For each layer:                                                │
│  - Check if /store/volumes/{chainID} exists                    │
│  - If not: fetch blob, unpack to temp dir, rename              │
│  - Result: all layers cached in /store/volumes/                │
└─────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ ImageManager.Create()                                           │
│  - Create /store/images/my-container/                          │
│  - Create diff/, workdir/, rootfs/ subdirs                     │
│  - Mount overlay filesystem:                                    │
│      overlay on /rootfs type overlay                           │
│      (lowerdir=l/abc:l/def,upperdir=diff,workdir=workdir)     │
│  - Apply disk quota via tardis (REQUIRES XFS)                  │
└─────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ Output JSON spec:                                               │
│ {                                                               │
│   "root": {"path": "/store/images/my-container/rootfs"},       │
│   "process": {"env": ["PATH=/usr/bin", ...]},                  │
│   "mounts": [{"destination": "/", "type": "overlay", ...}]     │
│ }                                                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## The XFS/Loop Device Dependency

### Why XFS is Required

1. **Project Quotas**: XFS supports per-directory disk quotas via project IDs
   - GrootFS assigns each container a unique project ID
   - `tardis` binary (suid helper) sets quota limits
   - This enables `--disk-limit-size-bytes` functionality

2. **Backing Store Pattern**:
   - GrootFS creates a large file (e.g., 37GB)
   - Formats it as XFS with `mkfs.xfs`
   - Mounts via loop device: `mount -o loop,pquota /store.backing-store /store`
   - Provides isolated XFS filesystem with quota support

### The Nested Container Problem

```
Host Kernel
    │
    ▼
Concourse Worker Container (cgroup v2)
    │
    ├── Filesystem: overlay (from host)
    │   - No XFS project quota support
    │   - Cannot use /dev/loop* devices
    │
    ├── /dev/loop0: Permission denied
    │   - cgroup v2 device controller blocks loop access
    │   - Even with --privileged
    │
    └── GrootFS init-store fails:
        - Can't create XFS backing store (no loop device)
        - Can't use existing filesystem (not XFS)
```

### Specific Failure Points

1. **`store/manager/manager.go:280-304`** - `createAndMountFilesystem`
   ```go
   // Creates backing store file
   os.WriteFile(backingStoreFile, []byte{}, 0600)
   os.Truncate(backingStoreFile, storeSizeBytes)
   
   // This fails: InitFilesystem calls mount -o loop
   m.storeDriver.InitFilesystem(backingStoreFile, storePath)
   ```

2. **`store/filesystems/overlayxfs/driver.go:446-456`** - `mountFilesystem`
   ```go
   // Uses loop mount option
   allOpts := "loop,pquota,noatime"
   cmd := exec.Command("mount", "-o", allOpts, "-t", "xfs", source, destination)
   ```

3. **`store/filesystems/loopback/losetup.go:27-45`** - `FindAssociatedLoopDevice`
   ```go
   // Calls losetup which fails without /dev/loop* access
   cmd := exec.Command("losetup", "-j", filePath)
   ```

---

## Why Docker Works

Docker's overlay2 storage driver succeeds where GrootFS fails because:

### Docker's Approach

1. **No XFS Requirement**: Uses native overlayfs on any filesystem
2. **No Backing Store**: Layers stored directly in `/var/lib/docker/overlay2/`
3. **No Loop Devices**: No special device access needed
4. **No Project Quotas**: Uses cgroup memory limits instead (or no limits)

### Docker Layer Storage

```
/var/lib/docker/overlay2/
├── {layer-id}/
│   ├── diff/         # Layer content
│   ├── link          # Short ID for mount options
│   └── lower         # Parent layer reference
├── {container-id}/
│   ├── diff/         # Container upper layer (writes)
│   ├── merged/       # Mounted overlayfs view
│   ├── work/         # Overlayfs work directory
│   └── lower         # Colon-separated list of lower layers
└── l/
    └── {short-id} -> ../{layer-id}/diff  # Symlinks
```

### Docker Image Creation

```go
// Simplified Docker overlay2 logic
func (d *Driver) CreateImage(id string, layers []string) (string, error) {
    // 1. Create container directory
    containerDir := path.Join(d.home, id)
    os.MkdirAll(containerDir + "/diff")
    os.MkdirAll(containerDir + "/work")
    os.MkdirAll(containerDir + "/merged")
    
    // 2. Build lowerdir option (using short symlinks)
    lowerDirs := []string{}
    for _, layer := range layers {
        lowerDirs = append(lowerDirs, "l/" + layer.ShortID)
    }
    
    // 3. Mount overlay (no XFS required!)
    mountData := fmt.Sprintf(
        "lowerdir=%s,upperdir=%s/diff,workdir=%s/work",
        strings.Join(lowerDirs, ":"),
        containerDir, containerDir,
    )
    unix.Mount("overlay", containerDir+"/merged", "overlay", 0, mountData)
    
    return containerDir + "/merged", nil
}
```

**Key Difference**: Docker doesn't enforce per-container disk quotas at the storage driver level. It relies on:
- cgroup v2 IO limits (for write throttling)
- cgroup v2 memory limits (for tmpfs/page cache)
- Host filesystem limits (if any)

---

## Proposed Alternative: Simple Overlay Plugin

### Design Goals

1. **No XFS Dependency**: Work with any filesystem supporting overlayfs
2. **No Loop Devices**: Direct directory-based storage
3. **No Disk Quotas**: Trade quota enforcement for compatibility
4. **Minimal Changes**: Follow GrootFS architecture patterns
5. **Garden Compatible**: Implement same image plugin protocol

### Architecture

```
simple-overlay-plugin (binary)
├── commands/
│   ├── init-store    # Create directory structure (no filesystem validation)
│   ├── create        # Create overlayfs mount
│   ├── delete        # Remove container
│   ├── stats         # Return zeros (no quota support)
│   └── clean         # GC unused layers
├── store/
│   ├── manager/      # Simplified store init
│   ├── image/        # Create/destroy overlayfs mounts
│   └── volume/       # Layer directory management
└── puller/           # Can reuse GrootFS layer fetching code
```

### Key Simplifications

| GrootFS Feature | Simple Overlay | Notes |
|----------------|----------------|-------|
| XFS backing store | Direct directories | No `mount -o loop` |
| Filesystem validation | Skip entirely | Accept any FS |
| Project quotas | Not supported | Return stats as zeros |
| `tardis` binary | Not needed | No suid helper |
| Whiteout device | Use `.wh.` files | Standard overlay whiteouts |
| UID/GID mapping | Same as GrootFS | Reuse sandbox package |

### Implementation Approach

#### Option A: Fork and Simplify GrootFS

1. Remove `overlayxfs` driver's XFS validation
2. Remove `tardis` quota enforcement
3. Replace `InitFilesystem` with simple `mkdir`
4. Remove loopback package dependency

**Pros**: Minimal new code, reuse image fetching
**Cons**: Large codebase to maintain

#### Option B: New Minimal Plugin

1. Write new Go binary with only essential commands
2. Implement `create`, `delete`, `stats` commands
3. Use containerd or Docker for image pulling
4. Simple overlayfs mounting logic

**Pros**: Clean slate, smaller codebase
**Cons**: More work, need to implement image pulling

#### Option C: Containerd-based Plugin

1. Use containerd as the backend for image/snapshot management
2. Thin wrapper that translates Garden protocol to containerd API
3. Containerd already handles overlayfs without XFS

**Pros**: Mature snapshot management, many storage drivers
**Cons**: Additional containerd dependency in container

### Recommended: Option A (Forked GrootFS)

Given time constraints and the working GrootFS codebase, forking and simplifying is the fastest path.

---

## Implementation Roadmap

### Phase 1: Proof of Concept (2-3 days)

1. **Fork GrootFS** to `simple-grootfs`
2. **Modify `store/filesystems/overlayxfs/driver.go`**:
   ```go
   func (d *Driver) ValidateFileSystem(logger, path string) error {
       // Skip XFS validation - accept any filesystem with overlay support
       return nil
   }
   
   func (d *Driver) InitFilesystem(logger, filesystemPath, storePath string) error {
       // Just create directory, no formatting or mounting
       return os.MkdirAll(storePath, 0755)
   }
   ```

3. **Remove quota enforcement from `CreateImage`**:
   ```go
   func (d *Driver) applyDiskLimit(logger, spec, volumeSize) error {
       // No-op: quotas not supported without XFS
       logger.Info("disk-limits-not-supported-in-simple-overlay-mode")
       return nil
   }
   ```

4. **Modify `FetchStats` to return zeros**:
   ```go
   func (d *Driver) FetchStats(logger, imagePath string) (groot.VolumeStats, error) {
       // Without XFS quotas, we can't track exclusive bytes
       return groot.VolumeStats{
           DiskUsage: groot.DiskUsage{
               TotalBytesUsed:     0,
               ExclusiveBytesUsed: 0,
           },
       }, nil
   }
   ```

5. **Build and test** in nested container

### Phase 2: Integration with Garden (2-3 days)

1. **Configure Garden to use new plugin**:
   ```yaml
   garden:
     image_plugin: /var/vcap/packages/simple-grootfs/bin/simple-grootfs
     image_plugin_extra_args:
       - "--store"
       - "/var/vcap/data/simple-grootfs/store"
   ```

2. **Test with Warden CPI**:
   - Create nested BOSH director
   - Deploy zookeeper
   - Verify container creation works

3. **Handle edge cases**:
   - Cleanup on failure
   - Concurrent image creation
   - Large image pulls

### Phase 3: Production Hardening (3-5 days)

1. **Add alternative disk limiting** (if needed):
   - Use cgroup v2 IO controller
   - Or accept no limits for nested use case

2. **Optimize layer storage**:
   - Implement proper symlink handling
   - Add layer garbage collection

3. **Add tests**:
   - Unit tests for modified components
   - Integration tests in nested container

4. **Documentation**:
   - Installation guide
   - Configuration options
   - Limitations (no quotas)

---

## Appendix: Key Code Locations

### Files to Modify for Simple Overlay Plugin

| File | Purpose | Changes Needed |
|------|---------|----------------|
| `store/filesystems/overlayxfs/driver.go` | FS driver | Remove XFS validation |
| `store/manager/manager.go` | Store init | Skip backing store creation |
| `commands/init_store.go` | CLI | Remove store-size-bytes requirement |
| `store/filesystems/loopback/` | Loop devices | Remove entirely |

### Files to Keep Unchanged

| File | Purpose | Why Keep |
|------|---------|----------|
| `base_image_puller/` | Image fetching | Works without XFS |
| `fetcher/` | Registry communication | No FS dependency |
| `groot/` | Business logic | Mostly FS-agnostic |
| `sandbox/` | User namespaces | Essential for unprivileged |
| `commands/create.go` | Create command | Uses driver abstraction |

### Garden Image Plugin Protocol

Garden calls the image plugin binary with these commands:

```bash
# Initialize store (called once at garden startup)
grootfs init-store --store /path/to/store

# Create container rootfs
grootfs create --store /path/to/store docker:///image container-id
# Returns JSON: {"root": {"path": "/path/to/rootfs"}, ...}

# Delete container rootfs
grootfs delete --store /path/to/store container-id

# Get stats
grootfs stats --store /path/to/store container-id
# Returns JSON: {"disk_usage": {"total_bytes_used": 123, ...}}

# Garbage collect
grootfs clean --store /path/to/store
```

---

## Conclusion

GrootFS's XFS requirement stems from its disk quota enforcement feature. By removing this requirement and accepting that disk quotas won't be available in nested containers, we can create a working image plugin.

The recommended approach is to fork GrootFS and strip out:
1. XFS filesystem validation
2. Loop device/backing store creation
3. `tardis` quota enforcement

This creates a "simple overlay" mode that works identically to Docker's overlay2 driver, which has been proven to work in nested container environments.
