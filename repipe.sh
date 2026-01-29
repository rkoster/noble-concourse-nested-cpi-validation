#!/bin/bash

set -euo pipefail

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command-line flags
DRY_RUN=false
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

# Check if ytt is available
if ! command -v ytt &> /dev/null; then
    echo "Error: ytt not found. Please install ytt: https://carvel.dev/ytt/"
    exit 1
fi

# Check if fly CLI is available (not required for dry-run with output to stdout)
if [[ "${DRY_RUN}" == "false" ]]; then
  if ! command -v fly &> /dev/null; then
      echo "Error: fly CLI not found. Please run ./fly-login.sh first."
      exit 1
  fi
fi

# Default values
TARGET="${CONCOURSE_TARGET:-local}"
PIPELINE_NAME="${PIPELINE_NAME:-nested-bosh-zookeeper}"

echo "=== Processing Pipeline from Modular Job Files ===" >&2
echo "Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")" >&2
echo "" >&2

# Validate required files exist
if [ ! -f "${SCRIPT_DIR}/start-bosh-patched.sh" ]; then
    echo "Error: start-bosh-patched.sh not found." >&2
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/warden-cpi-runc/start-bosh.sh" ]; then
    echo "Error: warden-cpi-runc/start-bosh.sh not found." >&2
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/pipeline-jobs/schema.yml" ]; then
    echo "Error: pipeline-jobs/schema.yml not found." >&2
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/pipeline-jobs/resources.yml" ]; then
    echo "Error: pipeline-jobs/resources.yml not found." >&2
    exit 1
fi

# Function to build the complete pipeline by combining modular files
build_pipeline() {
  # Add resources section (includes YTT load statements and base64 encoding)
  cat "${SCRIPT_DIR}/pipeline-jobs/resources.yml"
  echo ""
  
  # Add jobs section header
  echo "jobs:"
  
  # Combine all job files (alphabetically for consistency)
  # Skip schema.yml and resources.yml
  for job_file in "${SCRIPT_DIR}/pipeline-jobs"/*.yml; do
    filename=$(basename "${job_file}")
    if [[ "${filename}" != "schema.yml" && "${filename}" != "resources.yml" ]]; then
      echo "  Including: ${filename}" >&2
      cat "${job_file}"
      echo ""
    fi
  done
}

# Function to process pipeline with ytt
process_pipeline() {
  # Pass schema as a separate file to ytt (it has @data/values-schema annotation)
  # Pass the concatenated pipeline via stdin
  build_pipeline | ytt \
    -f "${SCRIPT_DIR}/pipeline-jobs/schema.yml" \
    -f - \
    --data-value-file start_bosh_script="${SCRIPT_DIR}/start-bosh-patched.sh" \
    --data-value-file warden_start_bosh_script="${SCRIPT_DIR}/warden-cpi-runc/start-bosh.sh"
}

# Extract docker registry credentials from vars.yml if it exists
DOCKER_REGISTRY_PASSWORD=""
DOCKER_REGISTRY_HOST="${CONCOURSE_STATIC_IP:-10.246.0.21}:5000"

if [ -f "${SCRIPT_DIR}/vars.yml" ]; then
    echo "Extracting docker registry credentials from vars.yml..." >&2
    DOCKER_REGISTRY_PASSWORD=$(bosh interpolate "${SCRIPT_DIR}/vars.yml" --path=/docker_registry_password 2>/dev/null || echo "")
fi

# Build fly command with variables
FLY_VARS=""
if [ -n "${DOCKER_REGISTRY_PASSWORD}" ]; then
    FLY_VARS="--var docker_registry_password=${DOCKER_REGISTRY_PASSWORD} --var docker_registry_host=${DOCKER_REGISTRY_HOST}"
    echo "Docker registry configured: ${DOCKER_REGISTRY_HOST}" >&2
else
    echo "Warning: Docker registry password not found in vars.yml" >&2
    echo "Pipeline may fail if docker-registry ops file is used" >&2
fi

# Execute based on mode
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "" >&2
  echo "=== Setting Pipeline (DRY-RUN) ===" >&2
  echo "Target: ${TARGET}" >&2
  echo "Pipeline: ${PIPELINE_NAME}" >&2
  echo "" >&2
  
  # Use fly set-pipeline --check-creds to validate against Concourse
  process_pipeline | \
    fly -t "${TARGET}" set-pipeline \
      -p "${PIPELINE_NAME}" \
      -c /dev/stdin \
      ${FLY_VARS} \
      --check-creds
else
  echo "" >&2
  echo "=== Setting Concourse Pipeline ===" >&2
  echo "Target: ${TARGET}" >&2
  echo "Pipeline: ${PIPELINE_NAME}" >&2
  echo "" >&2
  
  # Set the pipeline
  process_pipeline | \
    fly -t "${TARGET}" set-pipeline \
      -p "${PIPELINE_NAME}" \
      -c /dev/stdin \
      ${FLY_VARS} \
      --non-interactive
  
  echo "" >&2
  echo "=== Unpausing Pipeline ===" >&2
  fly -t "${TARGET}" unpause-pipeline -p "${PIPELINE_NAME}"
  
  echo "" >&2
  echo "=== Pipeline Set and Unpaused Successfully ===" >&2
  echo "" >&2
  echo "To trigger a job manually, run:" >&2
  echo "  fly -t ${TARGET} trigger-job -j ${PIPELINE_NAME}/<job-name> -w" >&2
  echo "" >&2
  echo "To view the pipeline in the web UI:" >&2
  echo "  http://10.246.0.21:8080/teams/main/pipelines/${PIPELINE_NAME}" >&2
fi
