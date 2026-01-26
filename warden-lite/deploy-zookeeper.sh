#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-zookeeper}"

echo "Deploying Zookeeper to warden-lite BOSH director..."
echo "  Deployment name: ${DEPLOYMENT_NAME}"
echo "  BOSH environment: ${BOSH_ENVIRONMENT}"
echo ""

if [ ! -d "${REPO_ROOT}/vendor/zookeeper-release" ]; then
  echo "Error: zookeeper-release not found in vendor/"
  echo "Run: vendir sync"
  exit 1
fi

echo "Uploading zookeeper release (if not already uploaded)..."
bosh upload-release --name=zookeeper \
  "${REPO_ROOT}/vendor/zookeeper-release/releases/zookeeper/zookeeper-0.0.10.yml" || true

echo ""
echo "Deploying zookeeper..."
bosh -n deploy \
  -d "${DEPLOYMENT_NAME}" \
  "${REPO_ROOT}/vendor/zookeeper-release/manifests/zookeeper.yml" \
  -o "${REPO_ROOT}/ops-files/zookeeper-single-instance.yml" \
  -o "${REPO_ROOT}/ops-files/use-jammy-stemcell.yml"

echo ""
echo "Deployment complete!"
echo ""
echo "To run smoke tests:"
echo "  bosh -d ${DEPLOYMENT_NAME} run-errand smoke-tests"
echo ""
echo "To check zookeeper status:"
echo "  bosh -d ${DEPLOYMENT_NAME} run-errand status"
echo ""
