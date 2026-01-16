#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
VARS_FILE="${VARS_FILE:-${SCRIPT_DIR}/vars.yml}"

# Concourse configuration
CONCOURSE_STATIC_IP="${CONCOURSE_STATIC_IP:-10.246.0.21}"
CONCOURSE_URL="${CONCOURSE_URL:-http://${CONCOURSE_STATIC_IP}:8080}"
CONCOURSE_TARGET="${CONCOURSE_TARGET:-local}"

# Create bin directory if it doesn't exist
mkdir -p "${BIN_DIR}"

echo "Setting up fly CLI..."
echo "  Concourse URL: ${CONCOURSE_URL}"
echo "  Target name: ${CONCOURSE_TARGET}"
echo ""

# Determine OS and architecture for fly CLI
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

FLY_BINARY="${BIN_DIR}/fly"

# Download fly CLI from Concourse
echo "Downloading fly CLI for ${OS}/${ARCH}..."
curl -sSL "${CONCOURSE_URL}/api/v1/cli?arch=${ARCH}&platform=${OS}" -o "${FLY_BINARY}"
chmod +x "${FLY_BINARY}"
echo "✓ fly CLI downloaded to ${FLY_BINARY}"
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
