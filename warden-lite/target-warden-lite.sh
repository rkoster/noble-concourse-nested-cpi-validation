#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${VARS_FILE:-${SCRIPT_DIR}/vars.yml}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-warden-lite}"

if [ ! -f "${VARS_FILE}" ]; then
  echo "Error: Vars file not found: ${VARS_FILE}"
  echo "Have you deployed the warden-lite director yet?"
  exit 1
fi

WARDEN_IP=$(bosh -d "${DEPLOYMENT_NAME}" instances --column=ips | grep -v "^Deployment" | grep -v "^$" | head -1 | tr -d '[:space:]')

if [ -z "${WARDEN_IP}" ]; then
  echo "Error: Could not determine warden-lite director IP"
  echo "Make sure the deployment exists and has running instances"
  exit 1
fi

echo "Extracting credentials from vars file..."
ADMIN_PASSWORD=$(bosh interpolate "${VARS_FILE}" --path=/admin_password)
CA_CERT=$(bosh interpolate "${VARS_FILE}" --path=/director_ssl/ca)

ENV_FILE="${SCRIPT_DIR}/warden-lite.env"
cat > "${ENV_FILE}" <<EOF
export BOSH_ENVIRONMENT="${WARDEN_IP}"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET="${ADMIN_PASSWORD}"
export BOSH_CA_CERT='${CA_CERT}'
EOF

echo ""
echo "Warden-lite BOSH environment credentials saved to: ${ENV_FILE}"
echo ""
echo "To target the warden-lite director, run:"
echo "  source ${ENV_FILE}"
echo "  bosh env"
echo ""
echo "Or in one command:"
echo "  source ${ENV_FILE} && bosh env"
echo ""
