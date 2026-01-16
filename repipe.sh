#!/bin/bash

set -euo pipefail

# Check if fly CLI is available
if ! command -v fly &> /dev/null; then
    echo "Error: fly CLI not found. Please run ./fly-login.sh first."
    exit 1
fi

# Default values
TARGET="${CONCOURSE_TARGET:-local}"
PIPELINE_NAME="${PIPELINE_NAME:-nested-bosh-zookeeper}"
PIPELINE_FILE="${PIPELINE_FILE:-pipeline.yml}"

echo "=== Setting Concourse Pipeline ==="
echo "Target: ${TARGET}"
echo "Pipeline: ${PIPELINE_NAME}"
echo "Pipeline File: ${PIPELINE_FILE}"
echo ""

# Check if pipeline file exists
if [ ! -f "${PIPELINE_FILE}" ]; then
    echo "Error: Pipeline file '${PIPELINE_FILE}' not found."
    exit 1
fi

# Set the pipeline
fly -t "${TARGET}" set-pipeline \
    -p "${PIPELINE_NAME}" \
    -c "${PIPELINE_FILE}" \
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
