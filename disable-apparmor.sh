#!/bin/bash
set -eu

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-concourse}"

echo "Disabling AppArmor garden-default profile on ${DEPLOYMENT_NAME}..."

# Remove the garden-default AppArmor profile from the kernel
# This writes the profile name to the .remove interface in the AppArmor securityfs
bosh ssh -d "${DEPLOYMENT_NAME}" --command "echo -n 'garden-default' | sudo tee /sys/kernel/security/apparmor/.remove"

echo ""
echo "Verifying AppArmor status..."
bosh ssh -d "${DEPLOYMENT_NAME}" --command "sudo aa-status 2>&1 | grep garden || echo 'No garden profiles found in enforce mode'"

echo ""
echo "AppArmor profile disabled successfully"
