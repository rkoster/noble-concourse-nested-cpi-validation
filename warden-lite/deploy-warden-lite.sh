#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Use devbox bosh if available
if [ -f "${REPO_ROOT}/.devbox/nix/profile/default/bin/bosh" ]; then
  BOSH_CMD="${REPO_ROOT}/.devbox/nix/profile/default/bin/bosh"
else
  BOSH_CMD="bosh"
fi

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-warden-lite}"
VARS_FILE="${VARS_FILE:-${SCRIPT_DIR}/vars.yml}"

echo "Deploying Warden Lite BOSH Director..."
echo "  Deployment name: ${DEPLOYMENT_NAME}"
echo "  BOSH environment: ${BOSH_ENVIRONMENT}"
echo "  Vars file: ${VARS_FILE}"
echo ""

if [ ! -d "${REPO_ROOT}/vendor/bosh-deployment" ]; then
  echo "Error: bosh-deployment not found in vendor/"
  echo "Run: vendir sync"
  exit 1
fi

echo "Deploying warden lite BOSH director..."
${BOSH_CMD} -n deploy \
  -d "${DEPLOYMENT_NAME}" \
  "${REPO_ROOT}/vendor/bosh-deployment/bosh.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/bosh-lite.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/warden/cpi.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/warden/use-jammy.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/misc/source-releases/bosh.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/misc/source-releases/bpm.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/uaa.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/misc/source-releases/uaa.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/credhub.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/misc/source-releases/credhub.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/jumpbox-user.yml" \
  -o "${REPO_ROOT}/vendor/bosh-deployment/misc/bosh-dev.yml" \
  -o "${SCRIPT_DIR}/warden-lite-ops.yml" \
  --vars-store="${VARS_FILE}" \
  -v director_name=warden-lite \
  -v internal_ip=10.246.0.22 \
  -v internal_gw=10.246.0.1 \
  -v internal_cidr=10.246.0.0/16 \
  -v outbound_network_name=default \
  -v garden_host=10.246.0.21

echo ""
echo "Deployment complete!"
echo ""
echo "To target the warden-lite director, run:"
echo "  ${SCRIPT_DIR}/target-warden-lite.sh"
echo ""
