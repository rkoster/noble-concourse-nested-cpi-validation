#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${VARS_FILE:-${SCRIPT_DIR}/vars.yml}"

# Concourse configuration
CONCOURSE_STATIC_IP="${CONCOURSE_STATIC_IP:-10.246.0.21}"
CONCOURSE_URL="${CONCOURSE_URL:-http://${CONCOURSE_STATIC_IP}:8080}"
CONCOURSE_TARGET="${CONCOURSE_TARGET:-local}"

# Ensure fly CLI is available on PATH (provided by devbox)
if ! command -v fly >/dev/null 2>&1; then
  echo "Error: fly CLI not found in PATH. Fly 8.0 is provided by the devbox; run 'direnv allow' or add fly to PATH."
  exit 1
fi
FLY_BINARY="$(command -v fly)"
echo "Using fly at ${FLY_BINARY}"
echo ""

# Get password from vars file
echo "Retrieving Concourse password from vars file..."
CONCOURSE_PASSWORD=$(bosh interpolate "${VARS_FILE}" --path=/concourse_password)
echo ""

# Login to Concourse
echo "Logging in to Concourse..."
"${FLY_BINARY}" -t "${CONCOURSE_TARGET}" login \
  -c "${CONCOURSE_URL}" \
  -u concourse \
  -p "${CONCOURSE_PASSWORD}"

echo ""
echo "✓ Successfully logged in to Concourse!"
echo ""
echo "You can now use fly with target '${CONCOURSE_TARGET}':"
echo "  fly -t ${CONCOURSE_TARGET} status"
echo "  fly -t ${CONCOURSE_TARGET} pipelines"
echo ""
