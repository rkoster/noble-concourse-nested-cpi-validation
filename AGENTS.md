# Agent Guidelines for noble-concourse-nested-cpi-validation

This repository contains BOSH deployment manifests and Concourse pipelines for deploying and testing nested BOSH directors with CPI validation. This guide is designed for AI coding agents working in this codebase.

## Repository Overview

This is a BOSH operations repository focused on:
- Deploying Concourse CI via BOSH director
- Creating Concourse pipelines that spin up nested BOSH directors using docker-cpi
- Testing deployment workflows with zookeeper-release as a validation target
- Validating nested containerization on Ubuntu Noble (24.04) with cgroup v2

**Tech Stack**: Bash scripting, BOSH manifests (YAML), Concourse pipelines (YAML/YTT), Ruby (for BOSH job installation scripts), vendir for dependency management

**Key Achievement**: Successfully runs nested BOSH director in Docker inside Concourse worker container with cgroup v2 support

## Build/Run/Test Commands

### Environment Setup
```bash
# Load direnv environment (adds bin/ to PATH)
direnv allow

# Source BOSH environment credentials for lab director
source bosh.env

# Verify BOSH connection
bosh env

# Install dependencies (fetch vendored manifests)
vendir sync

# Deploy Concourse to existing BOSH director
./deploy-concourse.sh

# Login to Concourse and download fly CLI
./fly-login.sh
```

### Pipeline Operations
```bash
# Preview pipeline changes without applying (DRY-RUN)
./repipe.sh --dry-run

# Set and unpause the nested BOSH pipeline
./repipe.sh

# Trigger a specific pipeline job manually
fly -t local trigger-job -j nested-bosh-zookeeper/deploy-zookeeper-on-docker-bosh -w

# Trigger any job (replace <job-name>)
fly -t local trigger-job -j nested-bosh-zookeeper/<job-name> -w

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

```bash
# Test Garden deployment with specific manifest
bosh deploy -d test-garden test-garden.yml

# Run manual Garden tests in namespace
./test-loop-in-namespace.sh

# Test Garden stemcell compatibility
./test-garden-stemcells.sh

# Debug build issues (runs docker build with verbose output)
./debug-build.sh
```


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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-concourse}"

echo "Starting deployment..."
```

**Error Handling**:
- Check command availability: `if ! command -v fly &> /dev/null; then`
- Validate file existence: `if [ ! -f "${FILE}" ]; then`
- Use meaningful error messages: `echo "Error: Pipeline file not found." >&2`
- Exit with non-zero on errors: `exit 1`

**Command-Line Parsing**:
```bash
# Use while loop with case for flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run]"
      exit 1
      ;;
  esac
done
```

### Ruby Scripts

**Purpose**: Used for BOSH job installation and templating in Docker images

**Style**:
- Use 2-space indentation
- Use snake_case for variables and methods
- Use clear, descriptive variable names
- Use blocks with `{...}` for single-line operations
- Use `do...end` for multi-line blocks

**Example Pattern**:
```ruby
require 'yaml'
require 'json'
require 'fileutils'

%w{/var/vcap/sys/run /var/vcap/sys/log}.each {|path| FileUtils.mkdir_p path}

config = YAML.load_file(config_path)
config['packages'].each do |package_name|
  package_path = File.join('/', 'var', 'vcap', 'packages', package_name)
  FileUtils.mkdir_p(package_path)
end
```

### YAML Files

**BOSH Manifests and Ops Files**:
- Use 2-space indentation (no tabs)
- Include descriptive comments above complex operations
- Ops file naming: Purpose-based with suffix (e.g., `concourse-dev.yml`, `zookeeper-single-instance.yml`)

**Ops File Structure**:
```yaml
# Comments explain purpose
- type: remove
  path: /networks

- type: replace
  path: /instance_groups/name=concourse/networks
  value:
  - name: default
    static_ips: [((concourse_static_ip))]
```

**Concourse Pipeline Jobs** (modular structure):
- Each job in separate file in `pipeline-jobs/` directory
- Use plain job definition (no overlay syntax)
- Start directly with job definition: `- name: job-name`

**YTT Templating Pattern** (for embedding scripts in pipelines):
```yaml
#@ load("@ytt:data", "data")
#@ load("@ytt:base64", "base64")
#@ script_b64 = base64.encode(data.values.my_script)

jobs:
  - task: example
    config:
      run:
        args:
          - -c
          - #@ "base64 -d > /tmp/script.sh <<'B64'\n" + script_b64 + "\nB64\n"
```
Process: `ytt -f template.yml --data-value-file my_script=script.sh | fly set-pipeline ...`

**Concourse Inline Configuration**:
```bash
cat > /tmp/ops-file.yml <<'EOF'
---
- type: replace
  path: /some/path
  value: some_value
EOF
```

**Variable Naming**:
- BOSH variables: `lower_snake_case` (e.g., `concourse_static_ip`)
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
- ✅ Concourse vars file (`vars.yml`) - committed for long-running deployment
- ✅ BOSH environment credentials (`bosh.env`) - committed for long-running lab environment
- ❌ Vendored dependencies (`vendor/`, `vendir.lock.yml`)
- ❌ Downloaded binaries (`bin/`)
- ❌ Backup files (`*.bak`, `*.b64`, `*.tmp`)

## Key Technical Patterns

### BOSH Operations
- Always use ops-files for environment-specific customization (never modify vendored manifests)
- Use named cloud-configs for deployment-specific VM types: `bosh update-config --type=cloud --name=concourse`
- Store generated secrets in `vars.yml` with `--vars-store` flag (committed for long-running deployment)
- Use `bosh interpolate` to extract values from vars-store: `bosh interpolate vars.yml --path=/password`

### Concourse Patterns
- Concourse 8.0+ uses containerd runtime (not garden-runc)
- Cannot use `CONCOURSE_GARDEN_*` environment variables with containerd
- DNS configuration: Use `containerd.dns_servers` property, not `garden.dns_servers`
- Pipelines should use remote resources only (GitHub repos, Docker images)
- Inline ops-files and configuration using heredocs in task scripts

### Pipeline Modular Structure
- `pipeline-jobs/schema.yml` - YTT data values schema (passed separately to ytt)
- `pipeline-jobs/resources.yml` - All Concourse resources with YTT header
- `pipeline-jobs/*.yml` - Individual job definitions (one per file)
- `repipe.sh` combines all files: schema + resources + jobs

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
