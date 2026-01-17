#!/bin/bash

set -euo pipefail

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if fly CLI is available
if ! command -v fly &> /dev/null; then
    echo "Error: fly CLI not found. Please run ./fly-login.sh first."
    exit 1
fi

# Check if ytt is available
if ! command -v ytt &> /dev/null; then
    echo "Error: ytt not found. Please install ytt: https://carvel.dev/ytt/"
    exit 1
fi

# Default values
TARGET="${CONCOURSE_TARGET:-local}"
PIPELINE_NAME="${PIPELINE_NAME:-nested-bosh-zookeeper}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-pipeline-template.yml}"

echo "=== Processing Pipeline Template with ytt ==="
echo "Template: ${PIPELINE_TEMPLATE}"
echo ""

# Check if pipeline template exists
if [ ! -f "${SCRIPT_DIR}/${PIPELINE_TEMPLATE}" ]; then
    echo "Error: Pipeline template '${PIPELINE_TEMPLATE}' not found."
    exit 1
fi

# Check if start-bosh-patched.sh exists
if [ ! -f "${SCRIPT_DIR}/start-bosh-patched.sh" ]; then
    echo "Error: start-bosh-patched.sh not found."
    exit 1
fi

# Process template with ytt and set the pipeline
echo "=== Setting Concourse Pipeline ==="
echo "Target: ${TARGET}"
echo "Pipeline: ${PIPELINE_NAME}"
echo ""

# Extract docker registry credentials from vars.yml if it exists
DOCKER_REGISTRY_PASSWORD=""
DOCKER_REGISTRY_HOST="${CONCOURSE_STATIC_IP:-10.246.0.21}:5000"

if [ -f "${SCRIPT_DIR}/vars.yml" ]; then
    echo "Extracting docker registry credentials from vars.yml..."
    DOCKER_REGISTRY_PASSWORD=$(bosh interpolate "${SCRIPT_DIR}/vars.yml" --path=/docker_registry_password 2>/dev/null || echo "")
fi

# Build fly command with variables
FLY_VARS=""
if [ -n "${DOCKER_REGISTRY_PASSWORD}" ]; then
    FLY_VARS="--var docker_registry_password=${DOCKER_REGISTRY_PASSWORD} --var docker_registry_host=${DOCKER_REGISTRY_HOST}"
    echo "Docker registry configured: ${DOCKER_REGISTRY_HOST}"
else
    echo "Warning: Docker registry password not found in vars.yml"
    echo "Pipeline may fail if docker-registry ops file is used"
fi

ytt -f "${SCRIPT_DIR}/${PIPELINE_TEMPLATE}" \
    --data-value-file start_bosh_script="${SCRIPT_DIR}/start-bosh-patched.sh" | \
    fly -t "${TARGET}" set-pipeline \
        -p "${PIPELINE_NAME}" \
        -c /dev/stdin \
        ${FLY_VARS} \
        --non-interactive

echo ""
echo "=== Unpausing Pipeline ==="
fly -t "${TARGET}" unpause-pipeline -p "${PIPELINE_NAME}"

echo ""
echo "=== Pipeline Set and Unpaused Successfully ==="
echo ""
echo "To trigger the job manually, run:"
echo "  fly -t ${TARGET} trigger-job -j ${PIPELINE_NAME}/deploy-zookeeper-on-docker-bosh -w"
echo ""
echo "To view the pipeline in the web UI:"
echo "  http://10.246.0.21:8080/teams/main/pipelines/${PIPELINE_NAME}"
