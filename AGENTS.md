# Agent Guidelines for noble-concourse-nested-cpi-validation

This repository contains BOSH deployment manifests and Concourse pipelines for deploying and testing nested BOSH directors with CPI validation. This guide is designed for AI coding agents working in this codebase.

## Repository Overview

This is a BOSH operations repository focused on:
- Deploying Concourse CI via BOSH director
- Creating Concourse pipelines that spin up nested BOSH directors using docker-cpi
- Testing deployment workflows with zookeeper-release as a validation target

**Tech Stack**: Bash scripting, BOSH manifests (YAML), Concourse pipelines (YAML), vendir for dependency management

## Build/Run/Test Commands

### Environment Setup
```bash
# Load direnv environment (adds bin/ to PATH)
direnv allow

# Install dependencies (fetch vendored manifests)
vendir sync

# Deploy Concourse to existing BOSH director
./deploy-concourse.sh

# Login to Concourse and download fly CLI
./fly-login.sh
```

### Pipeline Operations
```bash
# Set and unpause the nested BOSH pipeline
./repipe.sh

# Trigger the pipeline job manually
fly -t local trigger-job -j nested-bosh-zookeeper/deploy-zookeeper-on-docker-bosh -w

# Check resource status
fly -t local check-resource -r nested-bosh-zookeeper/zookeeper-release

# View pipeline in browser
open http://10.246.0.21:8080/teams/main/pipelines/nested-bosh-zookeeper
```

### BOSH Operations
```bash
# Check deployment status
bosh -d concourse instances

# SSH into instance
bosh -d concourse ssh concourse/0

# View logs
bosh -d concourse ssh -c "sudo tail -100 /var/vcap/sys/log/worker/worker.stderr.log"

# Redeploy after changes
./deploy-concourse.sh

# Delete deployment
bosh -d concourse delete-deployment -n
```

### Testing
There are no automated tests in this repository. Validation is done by:
1. Deploying Concourse successfully: `./deploy-concourse.sh`
2. Setting pipeline successfully: `./repipe.sh`
3. Running pipeline job: `fly -t local trigger-job -j nested-bosh-zookeeper/deploy-zookeeper-on-docker-bosh -w`

## Code Style Guidelines

### Shell Scripts

**Naming**: Use kebab-case for script files (e.g., `deploy-concourse.sh`, `fly-login.sh`)

**Shebang and Options**:
- Always use `#!/bin/bash`
- Use `set -eu` for deployment scripts (allow pipefail flexibility)
- Use `set -euo pipefail` for strict error handling in utility scripts

**Variables**:
- Environment variables: `UPPER_SNAKE_CASE` with defaults using `${VAR:-default}`
- Local variables: `lower_snake_case`
- Always quote variable expansions: `"${VAR}"` not `$VAR`

**Script Structure**:
```bash
#!/bin/bash
set -eu

# Script-level constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration with defaults
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-concourse}"

# Main logic
echo "Starting deployment..."
```

**Error Handling**:
- Check command availability: `if ! command -v fly &> /dev/null; then`
- Validate file existence before using: `if [ ! -f "${FILE}" ]; then`
- Use meaningful error messages: `echo "Error: Pipeline file '${PIPELINE_FILE}' not found."`

**Output**:
- Use `echo` for user-facing messages
- Group related output with section headers: `echo "=== Deploying Concourse ==="`
- Show configuration values before execution for transparency

### YAML Files

**BOSH Manifests and Ops Files**:
- Use 2-space indentation (no tabs)
- Include descriptive comments above complex operations
- Ops file naming: Purpose-based with suffix (e.g., `concourse-dev.yml`, `zookeeper-single-instance.yml`)

**Ops File Structure**:
```yaml
# Use Director to deploy Concourse for development/testing
# This ops file converts the create-env style deployment to work with a BOSH director

# Remove networks - networks are defined in cloud-config
- type: remove
  path: /networks

# Replace network configuration to use cloud-config with static IP
- type: replace
  path: /instance_groups/name=concourse/networks
  value:
  - name: default
    static_ips: [((concourse_static_ip))]
```

**Concourse Pipelines**:
- Use inline task configurations (not external task files)
- Resources must be remote or from container images (no local file dependencies)
- Use heredocs for ops-files or configuration within tasks:
```yaml
- task: example
  config:
    run:
      path: bash
      args:
        - -c
        - |
          cat > /tmp/ops-file.yml <<'EOF'
          ---
          - type: replace
            path: /some/path
            value: some_value
          EOF
```

**Variable Naming**:
- BOSH variables: `lower_snake_case` (e.g., `concourse_static_ip`, `external_url`)
- Environment variables in scripts: `UPPER_SNAKE_CASE`

### Git Conventions

**Commit Messages**:
- Imperative mood: "Add feature" not "Added feature"
- Start with capital letter
- No period at end
- Format: `<Action> <what>`
- Examples:
  - `Add BOSH deployment for self-contained Concourse`
  - `Add fly CLI setup and login automation`
  - `Configure DNS servers for containerd worker`

**What to Commit**:
- ✅ Scripts, manifests, ops-files, pipeline definitions
- ❌ Generated secrets (`vars.yml`)
- ❌ Vendored dependencies (`vendor/`, `vendir.lock.yml`)
- ❌ Downloaded binaries (`bin/`)

## Key Technical Patterns

### BOSH Operations
- Always use ops-files for environment-specific customization (never modify vendored manifests)
- Use named cloud-configs for deployment-specific VM types: `bosh update-config --type=cloud --name=concourse`
- Store generated secrets in `vars.yml` with `--vars-store` flag (gitignored)
- Use `bosh interpolate` to extract values from vars-store: `bosh interpolate vars.yml --path=/password`

### Concourse Patterns
- Concourse 8.0+ uses containerd runtime (not garden-runc)
- Cannot use `CONCOURSE_GARDEN_*` environment variables with containerd
- DNS configuration: Use `containerd.dns_servers` property, not `garden.dns_servers`
- Pipelines should use remote resources only (GitHub repos, Docker images)
- Inline ops-files and configuration using heredocs in task scripts

### Common Pitfalls
1. **DNS in nested environments**: Worker containers need explicit DNS servers configured via `containerd.dns_servers`
2. **Garden vs Containerd**: Don't set garden properties with containerd runtime
3. **Pipeline resources**: Never reference local repository in pipeline (use remote resources or inline content)
4. **Variable quoting**: Always quote paths with spaces in bash: `mkdir "path with spaces"` not `mkdir path with spaces`

## Environment Variables

Required for BOSH operations:
- `BOSH_ENVIRONMENT`: BOSH director URL
- `BOSH_CLIENT`: BOSH client username (usually `admin`)
- `BOSH_CLIENT_SECRET`: BOSH client password
- `BOSH_CA_CERT`: CA certificate (optional if using trusted certs)

Optional overrides:
- `DEPLOYMENT_NAME`: Override deployment name (default: `concourse`)
- `CONCOURSE_STATIC_IP`: Override static IP (default: `10.246.0.21`)
- `EXTERNAL_URL`: Override external URL (default: `http://10.246.0.21:8080`)
- `CONCOURSE_TARGET`: Override fly target name (default: `local`)
- `PIPELINE_NAME`: Override pipeline name (default: `nested-bosh-zookeeper`)

## File Organization

```
.
├── ops-files/              # BOSH ops-files for customization
│   ├── concourse-dev.yml   # Convert lite deployment to director-based
│   └── zookeeper-single-instance.yml  # Single instance configuration
├── deploy-concourse.sh     # Deploy Concourse to BOSH director
├── fly-login.sh           # Download fly CLI and login to Concourse
├── repipe.sh              # Set and unpause pipeline
├── pipeline.yml           # Concourse pipeline for nested BOSH testing
├── cloud-config-concourse.yml  # Named cloud-config with VM types
├── vendir.yml             # Dependency management configuration
├── .envrc                 # Direnv configuration (adds bin/ to PATH)
└── vendor/                # Vendored manifests (gitignored, managed by vendir)
```

## Additional Notes

- This repository targets Ubuntu Noble (24.04) stemcells
- Uses nested CPI architecture (likely Incus/LXD based on cloud properties)
- Network subnet: `10.246.0.0/16` (static IPs: `10.246.0.21-10.246.0.100`)
- Concourse VM: 8 CPU, 32GB RAM (instance_type: `c8-m32`)
