# Agent-Managed Firewall Implementation Plan

## Overview

This document describes the implementation plan for migrating firewall management from stemcell scripts to the bosh-agent. The agent will manage firewall rules for monit API access and NATS communication using nftables via the kernel netlink interface.

**Key Achievement**: This implementation properly handles all deployment scenarios including:
- Jammy VM on Jammy host (cgroup v1)
- Jammy container on Noble host (cgroup v2) ← Previously problematic, addressed by superseded PR #468
- Noble VM on Noble host (cgroup v2)
- Noble container on Noble host (cgroup v2)

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Firewall Backend | nftables everywhere | Modern, unified, pure Go implementation available |
| Go Library | `github.com/google/nftables` | Pure Go, no C dependencies, uses kernel netlink directly |
| Cgroup Detection | Runtime detection | Check `/proc/self/cgroup` at runtime, not OS-based |
| NATS Firewall Logic | OS-based (Jammy only) | Noble uses ephemeral NATS credentials |
| Monit Firewall | Always enabled | Both Jammy and Noble need monit protection |
| Stemcell Changes | Minimal | No new packages required for Jammy |
| Old Scripts | Remove | Clean break, agent manages everything |
| Rule Persistence | Hybrid | Base lockdown persisted, exceptions in-memory |

## Architecture

### Current State

**Jammy (cgroup v1):**
- `restrict-monit-api-access` script uses iptables + cgroup v1 `net_cls.classid`
- `monit-access-helper.sh` provides `permit_monit_access()` function
- Monit wrapper calls helper to add itself to special cgroup
- Agent sets up NATS firewall in `SetupNetworking()` using iptables

**Noble (cgroup v2):**
- `monit-nftables.nft` with cgroupv2 socket matching (hardcoded paths)
- `monit.service` loads nftables rules at startup
- Agent skips NATS firewall on cgroup v2
- No monit wrapper or helper scripts

### Target State

```
┌─────────────────────────────────────────────────────────────┐
│ Stemcell Boot                                                │
├─────────────────────────────────────────────────────────────┤
│ 1. systemd loads base-firewall.nft (DROP all local traffic) │
│    - Monit port 2822 blocked                                 │
│    - NATS ports blocked (4222, 4223)                         │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Agent Bootstrap (agent/bootstrap.go::Run)                    │
├─────────────────────────────────────────────────────────────┤
│ 1. Detect cgroup version from /proc/self/cgroup             │
│ 2. Detect OS version from /var/vcap/bosh/etc/operating_system│
│ 3. SetupFirewall() opens agent's own exceptions:            │
│    - Add rule: bosh-agent cgroup → monit:2822 ACCEPT        │
│    - Add rule: bosh-agent cgroup → NATS ACCEPT (Jammy only) │
│ 4. StartMonit()                                              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Monit Startup                                                │
├─────────────────────────────────────────────────────────────┤
│ 1. monit wrapper script calls:                               │
│    /var/vcap/bosh/bin/bosh-agent firewall-allow monit       │
│ 2. Agent validates request (only "monit" allowed)           │
│ 3. Agent adds exception: caller's cgroup → monit:2822       │
│ 4. Monit can now communicate with monit API                  │
└─────────────────────────────────────────────────────────────┘
```

### Cgroup Version Detection

The agent detects cgroup version at **runtime** by parsing `/proc/self/cgroup`:

```go
// Cgroup v2 (unified hierarchy): "0::/system.slice/bosh-agent.service"
// Cgroup v1 (legacy): "12:net_cls,net_prio:/system.slice/bosh-agent.service"

func detectCgroupVersion() CgroupVersion {
    data, _ := os.ReadFile("/proc/self/cgroup")
    if strings.Contains(string(data), "0::") {
        return CgroupV2
    }
    return CgroupV1
}
```

This correctly handles:
- **Jammy VM on Jammy host**: Detects cgroup v1
- **Jammy container on Noble host**: Detects cgroup v2 (inherits from host!)
- **Noble anywhere**: Detects cgroup v2

### NFTables Rule Structure

**Base lockdown** (loaded by stemcell at boot):
```nft
table inet bosh_filter {
    chain local_services {
        type filter hook output priority 0; policy accept;
        
        # Allow established/related connections
        ct state established,related accept
        
        # Block monit API (2822)
        ip daddr 127.0.0.1 tcp dport 2822 counter drop
        
        # Block NATS ports (4222, 4223)
        tcp dport { 4222, 4223 } counter drop
    }
}
```

**Agent-managed exceptions** (added dynamically via netlink):
```nft
table inet bosh_filter {
    # Priority -1 runs BEFORE local_services (priority 0)
    chain agent_exceptions {
        type filter hook output priority -1; policy accept;
        
        # Cgroup v2: Agent's monit access
        socket cgroupv2 level 2 "system.slice/bosh-agent.service" \
            ip daddr 127.0.0.1 tcp dport 2822 accept
        
        # Cgroup v2: Agent's NATS access (Jammy only)
        socket cgroupv2 level 2 "system.slice/bosh-agent.service" \
            ip daddr <nats-ip> tcp dport <nats-port> accept
        
        # Cgroup v2: Monit's own monit access (added by firewall-allow command)
        socket cgroupv2 level 2 "system.slice/monit.service" \
            ip daddr 127.0.0.1 tcp dport 2822 accept
    }
}
```

For cgroup v1, uses `meta cgroup <classid>` instead of `socket cgroupv2`.

---

## Repository Changes

### 1. bosh-agent

**Repository**: https://github.com/cloudfoundry/bosh-agent
**Branch**: `main`

#### 1.1 New Package: `platform/firewall/`

Create new firewall management package:

```
platform/firewall/
├── firewall.go              # Interface definitions
├── nftables_firewall.go     # nftables implementation (linux)
├── nftables_firewall_test.go
├── firewall_other.go        # No-op for non-linux (build tag)
├── cgroup.go                # Cgroup detection utilities
├── cgroup_test.go
└── fakes/
    └── fake_firewall.go     # Test fake
```

##### `platform/firewall/firewall.go`

```go
package firewall

// Service represents a local service that can be protected by firewall
type Service string

const (
    ServiceMonit Service = "monit"
    // Future services can be added here
)

// AllowedServices is the list of services that can be requested via CLI
var AllowedServices = []Service{ServiceMonit}

// CgroupVersion represents the cgroup hierarchy version
type CgroupVersion int

const (
    CgroupV1 CgroupVersion = 1
    CgroupV2 CgroupVersion = 2
)

// Manager manages firewall rules for local service access
type Manager interface {
    // SetupBaseRules sets up the agent's own firewall exceptions during bootstrap
    // Called once during agent bootstrap after networking is configured
    SetupBaseRules(mbusURL string) error

    // AllowService opens firewall for the calling process to access a service
    // Returns error if service is not in AllowedServices
    // Called by external processes via "bosh-agent firewall-allow <service>"
    AllowService(service Service, callerPID int) error

    // Cleanup removes all agent-managed firewall rules
    // Called during agent shutdown (optional)
    Cleanup() error
}
```

##### `platform/firewall/nftables_firewall.go`

```go
//go:build linux

package firewall

import (
    "fmt"
    "net"
    "os"
    "strings"

    "github.com/google/nftables"
    "github.com/google/nftables/expr"
    bosherr "github.com/cloudfoundry/bosh-utils/errors"
    boshlog "github.com/cloudfoundry/bosh-utils/logger"
)

const (
    // BOSH classid namespace: 0xb054XXXX (b054 = "BOSH" leet-ified)
    // 0xb0540001 = monit access (used by stemcell scripts)
    // 0xb0540002 = NATS access (used by agent)
    MonitClassID uint32 = 0xb0540001 // 2958295041
    NATSClassID  uint32 = 0xb0540002 // 2958295042

    tableName = "bosh_filter"
    chainName = "agent_exceptions"
)

type NftablesFirewall struct {
    conn          *nftables.Conn
    cgroupVersion CgroupVersion
    osVersion     string
    logger        boshlog.Logger
    logTag        string
    table         *nftables.Table
    chain         *nftables.Chain
}

func NewNftablesFirewall(logger boshlog.Logger) (Manager, error) {
    conn, err := nftables.New()
    if err != nil {
        return nil, bosherr.WrapError(err, "Creating nftables connection")
    }

    f := &NftablesFirewall{
        conn:   conn,
        logger: logger,
        logTag: "NftablesFirewall",
    }

    // Detect cgroup version at construction time
    f.cgroupVersion, err = DetectCgroupVersion()
    if err != nil {
        return nil, bosherr.WrapError(err, "Detecting cgroup version")
    }

    // Read OS version
    f.osVersion, err = readOperatingSystem()
    if err != nil {
        f.logger.Warn(f.logTag, "Could not read operating system: %s", err)
        f.osVersion = "unknown"
    }

    f.logger.Info(f.logTag, "Initialized with cgroup version %d, OS: %s", 
        f.cgroupVersion, f.osVersion)

    return f, nil
}

func (f *NftablesFirewall) SetupBaseRules(mbusURL string) error {
    f.logger.Info(f.logTag, "Setting up base firewall rules")

    // Create or get our table
    if err := f.ensureTable(); err != nil {
        return bosherr.WrapError(err, "Creating nftables table")
    }

    // Create our chain with priority -1 (runs before base rules at priority 0)
    if err := f.ensureChain(); err != nil {
        return bosherr.WrapError(err, "Creating nftables chain")
    }

    // Get agent's own cgroup path/classid
    agentCgroup, err := f.getProcessCgroup(os.Getpid())
    if err != nil {
        return bosherr.WrapError(err, "Getting agent cgroup")
    }

    // Add rule: agent can access monit
    if err := f.addMonitRule(agentCgroup); err != nil {
        return bosherr.WrapError(err, "Adding agent monit rule")
    }

    // Add NATS rules only for Jammy (regardless of cgroup version)
    if f.needsNATSFirewall() && mbusURL != "" {
        if err := f.addNATSRules(agentCgroup, mbusURL); err != nil {
            return bosherr.WrapError(err, "Adding agent NATS rules")
        }
    }

    // Commit all rules
    if err := f.conn.Flush(); err != nil {
        return bosherr.WrapError(err, "Flushing nftables rules")
    }

    f.logger.Info(f.logTag, "Successfully set up firewall rules")
    return nil
}

func (f *NftablesFirewall) AllowService(service Service, callerPID int) error {
    // Validate service is in allowlist
    if !isAllowedService(service) {
        return fmt.Errorf("service %q not in allowed list", service)
    }

    f.logger.Info(f.logTag, "Allowing service %s for PID %d", service, callerPID)

    // Get caller's cgroup
    callerCgroup, err := f.getProcessCgroup(callerPID)
    if err != nil {
        return bosherr.WrapError(err, "Getting caller cgroup")
    }

    switch service {
    case ServiceMonit:
        if err := f.addMonitRule(callerCgroup); err != nil {
            return bosherr.WrapError(err, "Adding monit rule for caller")
        }
    default:
        return fmt.Errorf("service %q not implemented", service)
    }

    if err := f.conn.Flush(); err != nil {
        return bosherr.WrapError(err, "Flushing nftables rules")
    }

    f.logger.Info(f.logTag, "Successfully added firewall exception for %s", service)
    return nil
}

func (f *NftablesFirewall) Cleanup() error {
    f.logger.Info(f.logTag, "Cleaning up firewall rules")
    
    // Delete our chain (this removes all rules in it)
    if f.chain != nil {
        f.conn.DelChain(f.chain)
    }
    
    return f.conn.Flush()
}

// needsNATSFirewall returns true if this OS needs NATS firewall protection
func (f *NftablesFirewall) needsNATSFirewall() bool {
    // Only Jammy needs NATS firewall (Noble has ephemeral credentials)
    return strings.Contains(f.osVersion, "jammy")
}

func (f *NftablesFirewall) ensureTable() error {
    f.table = &nftables.Table{
        Family: nftables.TableFamilyINet,
        Name:   tableName,
    }
    f.conn.AddTable(f.table)
    return nil
}

func (f *NftablesFirewall) ensureChain() error {
    // Priority -1 ensures our ACCEPT rules run before base DROP rules (priority 0)
    priority := nftables.ChainPriorityFilter - 1
    
    f.chain = &nftables.Chain{
        Name:     chainName,
        Table:    f.table,
        Type:     nftables.ChainTypeFilter,
        Hooknum:  nftables.ChainHookOutput,
        Priority: &priority,
        Policy:   nftables.ChainPolicyAccept,
    }
    f.conn.AddChain(f.chain)
    return nil
}

func (f *NftablesFirewall) addMonitRule(cgroup ProcessCgroup) error {
    // Build rule: <cgroup match> + dst 127.0.0.1 + dport 2822 -> accept
    exprs := f.buildCgroupMatchExprs(cgroup)
    exprs = append(exprs, f.buildDestIPExprs(net.ParseIP("127.0.0.1"))...)
    exprs = append(exprs, f.buildDestPortExprs(2822)...)
    exprs = append(exprs, &expr.Verdict{Kind: expr.VerdictAccept})

    f.conn.AddRule(&nftables.Rule{
        Table: f.table,
        Chain: f.chain,
        Exprs: exprs,
    })
    
    return nil
}

func (f *NftablesFirewall) addNATSRules(cgroup ProcessCgroup, mbusURL string) error {
    // Parse NATS URL to get host and port
    host, port, err := parseNATSURL(mbusURL)
    if err != nil {
        return bosherr.WrapError(err, "Parsing NATS URL")
    }

    // Resolve host to IP addresses
    addrs, err := net.LookupIP(host)
    if err != nil {
        return bosherr.WrapError(err, "Resolving NATS host")
    }

    for _, addr := range addrs {
        exprs := f.buildCgroupMatchExprs(cgroup)
        exprs = append(exprs, f.buildDestIPExprs(addr)...)
        exprs = append(exprs, f.buildDestPortExprs(port)...)
        exprs = append(exprs, &expr.Verdict{Kind: expr.VerdictAccept})

        f.conn.AddRule(&nftables.Rule{
            Table: f.table,
            Chain: f.chain,
            Exprs: exprs,
        })
    }

    return nil
}

func (f *NftablesFirewall) buildCgroupMatchExprs(cgroup ProcessCgroup) []expr.Any {
    if f.cgroupVersion == CgroupV2 {
        // Cgroup v2: match on cgroup path using socket expression
        // socket cgroupv2 level 2 "<path>"
        return []expr.Any{
            &expr.Socket{
                Key:   expr.SocketKeyCgroupv2,
                Level: 2,
            },
            &expr.Cmp{
                Op:       expr.CmpOpEq,
                Register: 1,
                Data:     []byte(cgroup.Path + "\x00"),
            },
        }
    }
    
    // Cgroup v1: match on classid
    // meta cgroup <classid>
    return []expr.Any{
        &expr.Meta{
            Key:      expr.MetaKeyCGROUP,
            Register: 1,
        },
        &expr.Cmp{
            Op:       expr.CmpOpEq,
            Register: 1,
            Data:     binaryutil.NativeEndian.PutUint32(cgroup.ClassID),
        },
    }
}

func (f *NftablesFirewall) buildDestIPExprs(ip net.IP) []expr.Any {
    if ip4 := ip.To4(); ip4 != nil {
        return []expr.Any{
            // Load IP protocol header
            &expr.Payload{
                DestRegister: 1,
                Base:         expr.PayloadBaseNetworkHeader,
                Offset:       16, // Destination IP offset in IPv4 header
                Len:          4,
            },
            &expr.Cmp{
                Op:       expr.CmpOpEq,
                Register: 1,
                Data:     ip4,
            },
        }
    }
    // IPv6 handling similar but with offset 24, len 16
    return nil
}

func (f *NftablesFirewall) buildDestPortExprs(port int) []expr.Any {
    return []expr.Any{
        // Check protocol is TCP
        &expr.Meta{
            Key:      expr.MetaKeyL4PROTO,
            Register: 1,
        },
        &expr.Cmp{
            Op:       expr.CmpOpEq,
            Register: 1,
            Data:     []byte{unix.IPPROTO_TCP},
        },
        // Load destination port
        &expr.Payload{
            DestRegister: 1,
            Base:         expr.PayloadBaseTransportHeader,
            Offset:       2, // Destination port offset in TCP header
            Len:          2,
        },
        &expr.Cmp{
            Op:       expr.CmpOpEq,
            Register: 1,
            Data:     binaryutil.BigEndian.PutUint16(uint16(port)),
        },
    }
}

// Helper functions

func isAllowedService(s Service) bool {
    for _, allowed := range AllowedServices {
        if s == allowed {
            return true
        }
    }
    return false
}

func readOperatingSystem() (string, error) {
    data, err := os.ReadFile("/var/vcap/bosh/etc/operating_system")
    if err != nil {
        return "", err
    }
    return strings.TrimSpace(string(data)), nil
}

func parseNATSURL(mbusURL string) (string, int, error) {
    // Parse nats://user:pass@host:port format
    u, err := url.Parse(mbusURL)
    if err != nil {
        return "", 0, err
    }
    
    host, portStr, err := net.SplitHostPort(u.Host)
    if err != nil {
        return "", 0, err
    }
    
    port, err := strconv.Atoi(portStr)
    if err != nil {
        return "", 0, err
    }
    
    return host, port, nil
}
```

##### `platform/firewall/cgroup.go`

```go
//go:build linux

package firewall

import (
    "fmt"
    "os"
    "strings"

    cgroups "github.com/containerd/cgroups/v3"
)

// ProcessCgroup represents a process's cgroup identity
type ProcessCgroup struct {
    Version CgroupVersion
    Path    string // For cgroup v2: full path like "/system.slice/bosh-agent.service"
    ClassID uint32 // For cgroup v1: net_cls classid
}

// DetectCgroupVersion detects the cgroup version at runtime
func DetectCgroupVersion() (CgroupVersion, error) {
    if cgroups.Mode() == cgroups.Unified {
        return CgroupV2, nil
    }
    return CgroupV1, nil
}

// getProcessCgroup gets the cgroup identity for a process
func (f *NftablesFirewall) getProcessCgroup(pid int) (ProcessCgroup, error) {
    cgroupFile := fmt.Sprintf("/proc/%d/cgroup", pid)
    data, err := os.ReadFile(cgroupFile)
    if err != nil {
        return ProcessCgroup{}, err
    }

    if f.cgroupVersion == CgroupV2 {
        return f.parseCgroupV2(string(data))
    }
    return f.parseCgroupV1(string(data), pid)
}

func (f *NftablesFirewall) parseCgroupV2(data string) (ProcessCgroup, error) {
    // Format: "0::/system.slice/bosh-agent.service"
    for _, line := range strings.Split(data, "\n") {
        if strings.HasPrefix(line, "0::") {
            path := strings.TrimPrefix(line, "0::")
            return ProcessCgroup{
                Version: CgroupV2,
                Path:    strings.TrimSpace(path),
            }, nil
        }
    }
    return ProcessCgroup{}, fmt.Errorf("cgroup v2 path not found in /proc/self/cgroup")
}

func (f *NftablesFirewall) parseCgroupV1(data string, pid int) (ProcessCgroup, error) {
    // For cgroup v1, we need to set up net_cls cgroup with our classid
    // The classid is used by iptables/nftables to match traffic
    
    // Find net_cls cgroup mount and path
    for _, line := range strings.Split(data, "\n") {
        if strings.Contains(line, "net_cls") {
            parts := strings.Split(line, ":")
            if len(parts) >= 3 {
                path := parts[2]
                return ProcessCgroup{
                    Version: CgroupV1,
                    Path:    strings.TrimSpace(path),
                    ClassID: NATSClassID, // Use our BOSH classid
                }, nil
            }
        }
    }
    
    // Fallback: use classid-based matching
    return ProcessCgroup{
        Version: CgroupV1,
        ClassID: NATSClassID,
    }, nil
}
```

##### `platform/firewall/firewall_other.go`

```go
//go:build !linux

package firewall

import (
    boshlog "github.com/cloudfoundry/bosh-utils/logger"
)

// NewNftablesFirewall returns a no-op firewall manager on non-Linux platforms
func NewNftablesFirewall(logger boshlog.Logger) (Manager, error) {
    return &noopFirewall{}, nil
}

type noopFirewall struct{}

func (f *noopFirewall) SetupBaseRules(mbusURL string) error {
    return nil
}

func (f *noopFirewall) AllowService(service Service, callerPID int) error {
    return nil
}

func (f *noopFirewall) Cleanup() error {
    return nil
}
```

#### 1.2 Platform Integration

##### `platform/platform_interface.go`

Add new method to Platform interface:

```go
// Add to Platform interface
SetupFirewall(mbusURL string) error
```

##### `platform/linux_platform.go`

```go
// Add import
import (
    boshfirewall "github.com/cloudfoundry/bosh-agent/v2/platform/firewall"
)

// Add field to linux struct
type linux struct {
    // ... existing fields ...
    firewallManager boshfirewall.Manager
}

// Add method
func (p linux) SetupFirewall(mbusURL string) error {
    if p.firewallManager == nil {
        return nil // Firewall not initialized (e.g., dummy platform)
    }
    return p.firewallManager.SetupBaseRules(mbusURL)
}
```

##### `platform/provider.go`

Instantiate firewall manager when creating linux platform:

```go
// In NewProvider or Get method
firewallManager, err := boshfirewall.NewNftablesFirewall(logger)
if err != nil {
    logger.Warn("PlatformProvider", "Failed to create firewall manager: %s", err)
    // Continue without firewall - don't fail agent startup
}

// Pass to linux platform constructor
```

##### `platform/dummy_platform.go`

Add no-op implementation:

```go
func (p dummyPlatform) SetupFirewall(mbusURL string) error {
    return nil
}
```

#### 1.3 Bootstrap Integration

##### `agent/bootstrap.go`

Add firewall setup after networking:

```go
func (boot bootstrap) Run() (err error) {
    // ... existing setup code ...

    if err = boot.platform.SetupNetworking(settings.Networks, settings.GetMbusURL()); err != nil {
        return bosherr.WrapError(err, "Setting up networking")
    }

    // NEW: Setup firewall after networking (so we have mbus URL)
    if err = boot.platform.SetupFirewall(settings.GetMbusURL()); err != nil {
        return bosherr.WrapError(err, "Setting up firewall")
    }

    // ... continue with ephemeral disk, etc ...
}
```

#### 1.4 New CLI Command: `firewall-allow`

##### `main/agent.go`

Add new command handler:

```go
import (
    boshfirewall "github.com/cloudfoundry/bosh-agent/v2/platform/firewall"
)

func main() {
    if len(os.Args) > 1 {
        switch cmd := os.Args[1]; cmd {
        case "compile":
            compileTarball(cmd, os.Args[2:])
            return
        case "firewall-allow":
            handleFirewallAllow(os.Args[2:])
            return
        }
    }
    // ... existing agent start logic ...
}

func handleFirewallAllow(args []string) {
    if len(args) < 1 {
        fmt.Fprintf(os.Stderr, "Usage: bosh-agent firewall-allow <service>\n")
        fmt.Fprintf(os.Stderr, "Allowed services: %v\n", boshfirewall.AllowedServices)
        os.Exit(1)
    }

    service := boshfirewall.Service(args[0])

    // Create minimal logger
    logger := boshlog.NewLogger(boshlog.LevelError)

    // Create firewall manager
    firewallMgr, err := boshfirewall.NewNftablesFirewall(logger)
    if err != nil {
        fmt.Fprintf(os.Stderr, "Error creating firewall manager: %s\n", err)
        os.Exit(1)
    }

    // Get parent PID (the process that called us)
    callerPID := os.Getppid()

    if err := firewallMgr.AllowService(service, callerPID); err != nil {
        fmt.Fprintf(os.Stderr, "Error allowing service: %s\n", err)
        os.Exit(1)
    }

    fmt.Printf("Firewall exception added for service: %s (PID: %d)\n", service, callerPID)
}
```

#### 1.5 Remove Legacy NATS Firewall Code

##### `platform/net/firewall_provider_linux.go`

Replace entire file with no-op:

```go
//go:build linux

package net

// SetupNatsFirewall is deprecated - firewall is now managed by platform.SetupFirewall
// This function is kept for backward compatibility but does nothing.
func SetupNatsFirewall(mbus string) error {
    // NATS firewall is now handled by platform/firewall package during bootstrap
    return nil
}
```

##### `platform/net/ubuntu_net_manager.go`

The calls to `SetupNatsFirewall()` at lines 119 and 187 will now be no-ops.
Consider removing them in a follow-up PR for cleanliness.

#### 1.6 Go Module Updates

##### `go.mod`

Add google/nftables dependency:

```
require (
    // ... existing deps ...
    github.com/google/nftables v0.2.0
)
```

Run `go mod tidy` to fetch dependencies.

---

### 2. bosh-linux-stemcell-builder (Jammy Branch)

**Repository**: https://github.com/cloudfoundry/bosh-linux-stemcell-builder
**Branch**: `ubuntu-jammy`

#### 2.1 New Stage: `bosh_base_firewall/`

Create new stage for base firewall lockdown:

```
stemcell_builder/stages/bosh_base_firewall/
├── apply.sh
└── assets/
    ├── base-firewall.nft
    └── base-firewall.service
```

##### `stemcell_builder/stages/bosh_base_firewall/apply.sh`

```bash
#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

# Install base firewall rules
mkdir -p $chroot/etc/nftables
cp $dir/assets/base-firewall.nft $chroot/etc/nftables/base-firewall.nft
chmod 644 $chroot/etc/nftables/base-firewall.nft

# Install and enable systemd service
cp $dir/assets/base-firewall.service $chroot/lib/systemd/system/
run_in_chroot $chroot "systemctl enable base-firewall.service"
```

##### `stemcell_builder/stages/bosh_base_firewall/assets/base-firewall.nft`

```nft
#!/usr/sbin/nft -f

# BOSH Base Firewall - Locks down local services by default
# Agent will add exceptions during bootstrap via netlink

table inet bosh_filter {
    chain local_services {
        type filter hook output priority 0; policy accept;
        
        # Allow established/related connections (critical for existing sessions)
        ct state established,related accept
        
        # Block monit API access (port 2822) - agent will add exceptions
        ip daddr 127.0.0.1 tcp dport 2822 counter drop
        
        # Block NATS ports - agent will add exceptions for Jammy
        tcp dport { 4222, 4223 } counter drop
    }
}
```

##### `stemcell_builder/stages/bosh_base_firewall/assets/base-firewall.service`

```ini
[Unit]
Description=BOSH Base Firewall Rules
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables/base-firewall.nft
ExecReload=/usr/sbin/nft -f /etc/nftables/base-firewall.nft
ExecStop=/usr/sbin/nft delete table inet bosh_filter

[Install]
WantedBy=sysinit.target
```

#### 2.2 Update Stage: `bosh_monit/`

##### `stemcell_builder/stages/bosh_monit/apply.sh`

Update to use agent-managed firewall:

```bash
#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash
source $base_dir/lib/prelude_bosh.bash

monit_basename=monit-5.2.5
monit_archive=$monit_basename.tar.gz

mkdir -p $chroot/$bosh_dir/src
cp -r $dir/assets/$monit_archive $chroot/$bosh_dir/src

pkg_mgr install "zlib1g-dev"

run_in_bosh_chroot $chroot "
cd src
tar zxvf $monit_archive
cd $monit_basename
./configure --prefix=$bosh_dir --without-ssl CFLAGS=\"-fcommon\"
make -j4 && make install
"

mkdir -p $chroot/$bosh_dir/etc
cp $dir/assets/monitrc $chroot/$bosh_dir/etc/monitrc
chmod 0700 $chroot/$bosh_dir/etc/monitrc

# monit refuses to start without an include file present
mkdir -p $chroot/$bosh_app_dir/monit
touch $chroot/$bosh_app_dir/monit/empty.monitrc

# Monit wrapper script - calls agent to request firewall access
mv $chroot/$bosh_dir/bin/monit $chroot/$bosh_dir/bin/monit-actual
cp $dir/assets/monit $chroot/$bosh_dir/bin/monit
chmod +x $chroot/$bosh_dir/bin/monit

# Helper script for permit_monit_access function
cp $dir/assets/monit-access-helper.sh $chroot/$bosh_dir/etc/
chmod +x $chroot/$bosh_dir/etc/monit-access-helper.sh

# REMOVED: restrict-monit-api-access (agent now manages firewall)
```

##### `stemcell_builder/stages/bosh_monit/assets/monit`

Update monit wrapper:

```bash
#!/bin/bash

set -e

source /var/vcap/bosh/etc/monit-access-helper.sh

permit_monit_access

exec /var/vcap/bosh/bin/monit-actual "$@"
```

##### `stemcell_builder/stages/bosh_monit/assets/monit-access-helper.sh`

Replace with agent-based helper:

```bash
#!/bin/bash
# Helper to request firewall access from bosh-agent
# This function is called by processes that need to access monit API

permit_monit_access() {
    # Call agent to open firewall exception for this process
    # The agent will detect our cgroup and add appropriate nftables rule
    if ! /var/vcap/bosh/bin/bosh-agent firewall-allow monit; then
        echo "Warning: Failed to request monit firewall access" >&2
        # Don't fail - let monit try to start anyway
        # If firewall blocks it, monit will fail with connection error
    fi
}
```

##### Remove `stemcell_builder/stages/bosh_monit/assets/restrict-monit-api-access`

Delete this file - no longer needed.

#### 2.3 Update Build Order

Ensure `bosh_base_firewall` stage runs before `bosh_go_agent`:

Update the appropriate stage ordering file (e.g., `stemcell_builder/stages/stages.rb` or similar) to include:

```ruby
# Add bosh_base_firewall before bosh_go_agent
stages = [
  # ... earlier stages ...
  'bosh_base_firewall',
  'bosh_go_agent',
  'bosh_monit',
  # ... later stages ...
]
```

---

### 3. bosh-linux-stemcell-builder (Noble Branch)

**Repository**: https://github.com/cloudfoundry/bosh-linux-stemcell-builder
**Branch**: `ubuntu-noble`

#### 3.1 New Stage: `bosh_base_firewall/`

Same as Jammy - copy the entire stage.

#### 3.2 Update Stage: `bosh_monit/`

##### `stemcell_builder/stages/bosh_monit/apply.sh`

Update to match Jammy approach:

```bash
#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash
source $base_dir/lib/prelude_bosh.bash

monit_basename=monit-5.2.5
monit_archive=$monit_basename.tar.gz

mkdir -p $chroot/$bosh_dir/src
cp -r $dir/assets/$monit_archive $chroot/$bosh_dir/src

pkg_mgr install "zlib1g-dev"

run_in_bosh_chroot $chroot "
cd src
tar zxvf $monit_archive
cd $monit_basename
./configure --prefix=$bosh_dir --without-ssl CFLAGS=\"-fcommon\"
make -j4 && make install
"

mkdir -p $chroot/$bosh_dir/etc
cp $dir/assets/monitrc $chroot/$bosh_dir/etc/monitrc
chmod 0700 $chroot/$bosh_dir/etc/monitrc

# monit refuses to start without an include file present
mkdir -p $chroot/$bosh_app_dir/monit
touch $chroot/$bosh_app_dir/monit/empty.monitrc

# Monit wrapper script - calls agent to request firewall access
mv $chroot/$bosh_dir/bin/monit $chroot/$bosh_dir/bin/monit-actual
cp $dir/assets/monit $chroot/$bosh_dir/bin/monit
chmod +x $chroot/$bosh_dir/bin/monit

# Helper script for permit_monit_access function
cp $dir/assets/monit-access-helper.sh $chroot/$bosh_dir/etc/
chmod +x $chroot/$bosh_dir/etc/monit-access-helper.sh

# Monit systemd service (no longer manages firewall)
cp $dir/assets/monit.service $chroot/lib/systemd/system/
run_in_chroot $chroot "systemctl enable monit.service"

# REMOVED: monit-nftables.nft (agent now manages firewall)
```

##### `stemcell_builder/stages/bosh_monit/assets/monit`

Add monit wrapper (same as Jammy):

```bash
#!/bin/bash

set -e

source /var/vcap/bosh/etc/monit-access-helper.sh

permit_monit_access

exec /var/vcap/bosh/bin/monit-actual "$@"
```

##### `stemcell_builder/stages/bosh_monit/assets/monit-access-helper.sh`

Add helper (same as Jammy):

```bash
#!/bin/bash
# Helper to request firewall access from bosh-agent

permit_monit_access() {
    if ! /var/vcap/bosh/bin/bosh-agent firewall-allow monit; then
        echo "Warning: Failed to request monit firewall access" >&2
    fi
}
```

##### `stemcell_builder/stages/bosh_monit/assets/monit.service`

Update to remove firewall management:

```ini
[Unit]
Description=Monit service
After=network.target bosh-agent.service
Wants=bosh-agent.service
ConditionPathExists=/var/vcap/data/sys/run

[Service]
ExecStart=/bin/bash -c 'PATH=/var/vcap/bosh/bin:$PATH exec nice -n -10 /var/vcap/bosh/bin/monit -I -c /var/vcap/bosh/etc/monitrc'
Restart=always
KillMode=process

[Install]
WantedBy=multi-user.target
```

##### Remove `stemcell_builder/stages/bosh_monit/assets/monit-nftables.nft`

Delete this file - agent now manages firewall.

---

## Testing Plan

### Unit Tests (bosh-agent)

1. **Firewall manager tests**
   - Test cgroup v1 rule generation
   - Test cgroup v2 rule generation
   - Test NATS URL parsing
   - Test service allowlist validation

2. **Cgroup detection tests**
   - Test cgroup v1 detection
   - Test cgroup v2 detection
   - Test process cgroup path extraction

3. **CLI command tests**
   - Test `firewall-allow monit` command
   - Test invalid service rejection
   - Test missing argument handling

### Integration Tests (nested BOSH in warden-cpi)

1. **Jammy on Jammy (cgroup v1)**
   - Deploy Jammy stemcell on Jammy host VM
   - Verify base firewall blocks monit initially
   - Verify agent opens own monit access
   - Verify agent opens NATS access
   - Verify monit wrapper requests access successfully
   - Deploy Zookeeper, verify monit commands work

2. **Jammy on Noble (cgroup v2)** ← Critical path (PR #468 scenario)
   - Deploy Jammy stemcell in container on Noble host
   - Verify agent detects cgroup v2
   - Verify agent uses cgroupv2 path matching
   - Verify NATS firewall is enabled (Jammy needs it)
   - Deploy Zookeeper, verify everything works

3. **Noble on Noble (cgroup v2)**
   - Deploy Noble stemcell on Noble host
   - Verify agent detects cgroup v2
   - Verify NATS firewall is NOT enabled
   - Verify monit access works
   - Deploy Zookeeper, verify everything works

### Regression Tests

1. **Existing BOSH functionality**
   - Agent can connect to NATS
   - Monit can start/stop jobs
   - SSH works
   - Logs work
   - All existing agent actions work

2. **No new package dependencies on Jammy**
   - Verify no new apt packages needed
   - Agent binary is self-contained

---

## Rollout Plan

### Phase 1: Development & Testing
1. Implement agent changes in feature branch
2. Build test agent binary
3. Test manually in nested BOSH setup
4. Implement stemcell changes in feature branches
5. Build test stemcells
6. Run full integration tests

### Phase 2: Review & Merge
1. Submit agent PR, get reviews
2. Submit stemcell PRs (Jammy & Noble), get reviews
3. Merge agent changes first
4. Release new agent version
5. Merge stemcell changes
6. Build new stemcells with new agent

### Phase 3: Validation
1. Deploy to test BOSH directors
2. Run full test suites
3. Test specific scenarios (Jammy-on-Noble container)
4. Close PR #468 as superseded

### Phase 4: Release
1. Include in next stemcell release
2. Update documentation
3. Announce changes in release notes

---

## Backward Compatibility

### Old Stemcells with New Agent
- Agent's `SetupFirewall()` may fail if base firewall not present
- Agent should handle this gracefully (warn, don't fail)
- Old iptables-based firewall continues to work

### New Stemcells with Old Agent
- Base firewall blocks all local service access
- Monit wrapper calls `bosh-agent firewall-allow monit`
- Old agent doesn't have this command → fails with "unknown command"
- Monit will fail to connect → deployment fails fast
- Clear error message, easy to diagnose

### Recommendation
- Release agent and stemcells together
- Update minimum agent version requirement in stemcell release notes

---

## Open Items

1. **Kernel version requirements**: Verify nftables netlink API is available in Jammy kernel (5.15+) - should be fine
2. **SELinux/AppArmor**: Verify agent can manipulate nftables when security modules are enabled
3. **Container capabilities**: Verify agent has CAP_NET_ADMIN in container scenarios
4. **Cleanup on agent restart**: Should agent flush old rules on startup? Current plan: leave them (idempotent adds)

---

## References

- PR #468: https://github.com/cloudfoundry/bosh-linux-stemcell-builder/pull/468 (superseded by this plan)
- google/nftables: https://github.com/google/nftables
- nftables cgroup matching: https://wiki.nftables.org/wiki-nftables/index.php/Matching_cgroups
- containerd/cgroups: https://github.com/containerd/cgroups
