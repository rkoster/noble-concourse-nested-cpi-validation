#!/bin/bash
set -euo pipefail

# Test loop device access in user namespace via BOSH SSH
# Usage: ./test-loop-in-namespace.sh <deployment-name> <vm-name>
#
# This reproduces the core issue: Noble kernel 6.8 blocks loop device
# operations (LOOP_SET_FD ioctl) when executed inside user namespaces,
# which is exactly what Guardian/Garden containers do.

echo "=== Testing Loop Device Access in User Namespace ==="
export BOSH_DEPLOYMENT=test-garden

for VM_NAME in garden-noble garden-jammy; do
    # Create and run test script on the BOSH VM
    echo -e "\n--- Running test script on ${VM_NAME} ---\n"
    bosh scp ./inner-run-test-script.sh "${VM_NAME}:/tmp/"
    bosh ssh "${VM_NAME}" --command "
      sudo mv /tmp/inner-run-test-script.sh /home/vcap;
      sudo chmod +x /home/vcap/inner-run-test-script.sh;
      sudo /home/vcap/inner-run-test-script.sh;
    "

done 2>&1 | grep -v "Unauthorized\|strictly prohibited\|subject to logging\|Connection to.*closed"

echo ""
echo "=== Test Complete ==="
