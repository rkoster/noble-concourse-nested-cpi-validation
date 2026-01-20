#!/bin/bash

set -eu

# This script expects the BOSH CLI to be configured using environment variables
# Required environment variables:
#   BOSH_ENVIRONMENT
#   BOSH_CLIENT
#   BOSH_CLIENT_SECRET
#   BOSH_CA_CERT (optional)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Variables file for storing generated secrets
VARS_FILE="${VARS_FILE:-${SCRIPT_DIR}/vars.yml}"

# Default values (can be overridden)
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-concourse}"
CONCOURSE_VERSION="${CONCOURSE_VERSION:-8.0.0}"
CONCOURSE_SHA1="${CONCOURSE_SHA1:-sha256:5b2dac1b9693993055c1734fc68719133a79106d962498fe4a721c96e9535557}"
BPM_VERSION="${BPM_VERSION:-1.4.24}"
BPM_SHA1="${BPM_SHA1:-sha256:285257b54fe1564a40cda096e6867d14166abd1a7157961cc68223afa23a414f}"
POSTGRES_VERSION="${POSTGRES_VERSION:-53.0.3}"
POSTGRES_SHA1="${POSTGRES_SHA1:-sha256:ee8f1d44a7bbfd3d34595de45e1974daf9eb70b50432425f7680e16072cc1bee}"

# Concourse configuration
CONCOURSE_STATIC_IP="${CONCOURSE_STATIC_IP:-10.246.0.21}"
EXTERNAL_URL="${EXTERNAL_URL:-http://${CONCOURSE_STATIC_IP}:8080}"

echo "Deploying Concourse..."
echo "  Deployment name: ${DEPLOYMENT_NAME}"
echo "  Concourse version: ${CONCOURSE_VERSION}"
echo "  BOSH environment: ${BOSH_ENVIRONMENT}"
echo "  Static IP: ${CONCOURSE_STATIC_IP}"
echo "  External URL: ${EXTERNAL_URL}"
echo "  Vars file: ${VARS_FILE}"
echo ""

echo "Updating cloud config with Concourse VM types..."
bosh -n update-config --type=cloud --name=concourse "${SCRIPT_DIR}/cloud-config-concourse.yml"
echo ""

bosh -n deploy \
  -d "${DEPLOYMENT_NAME}" \
  "${SCRIPT_DIR}/vendor/concourse-bosh-deployment/lite/concourse.yml" \
  -o "${SCRIPT_DIR}/ops-files/concourse-dev.yml" \
  -o "${SCRIPT_DIR}/ops-files/use-jammy-stemcell.yml" \
  -o "${SCRIPT_DIR}/ops-files/docker-registry.yml" \
  -o "${SCRIPT_DIR}/ops-files/garden-allow-host-access.yml" \
  -o "${SCRIPT_DIR}/ops-files/guardian-runtime.yml" \
  --vars-store="${VARS_FILE}" \
  -v concourse_version="${CONCOURSE_VERSION}" \
  -v concourse_sha1="${CONCOURSE_SHA1}" \
  -v bpm_version="${BPM_VERSION}" \
  -v bpm_sha1="${BPM_SHA1}" \
  -v postgres_version="${POSTGRES_VERSION}" \
  -v postgres_sha1="${POSTGRES_SHA1}" \
  -v concourse_static_ip="${CONCOURSE_STATIC_IP}" \
  -v external_url="${EXTERNAL_URL}"

echo ""
echo "Deployment complete!"
echo ""
echo "Concourse should be available at: ${EXTERNAL_URL}"
echo ""
echo "Login credentials:"
echo "  Username: concourse"
echo "  Password: $(bosh interpolate ${VARS_FILE} --path=/concourse_password)"
echo ""
