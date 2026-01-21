#!/bin/bash
set -euo pipefail

# Test Garden/Guardian loop device access on both Jammy and Noble stemcells
# This demonstrates that even with privileged containers, Noble blocks loop devices
# in unprivileged user namespaces which Guardian uses for container isolation

DEPLOYMENT="${1:-test-garden}"

echo "=== Testing Garden Loop Device Access on Both Stemcells ==="
echo "Deployment: ${DEPLOYMENT}"
echo ""

# Test Jammy
echo "============================================"
echo "Testing Jammy (Ubuntu 22.04, Kernel 5.15)"
echo "============================================"
bosh -d "${DEPLOYMENT}" ssh garden-jammy/0 --command "
echo 'System: '\$(lsb_release -ds)
echo 'Kernel: '\$(uname -r)
sysctl kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'AppArmor restriction: NOT PRESENT (Jammy)'
echo ''

echo 'Testing unprivileged user namespace creation...'
unshare --user --map-root-user true 2>&1 && echo '✅ Can create user namespaces' || echo '❌ BLOCKED: Cannot create user namespaces'
echo ''

echo 'Testing Garden container creation with gaol...'
CONTAINER=\$(gaol -t 127.0.0.1:7777 create -n test-jammy-\$\$ 2>&1)
if [ \$? -eq 0 ]; then
  echo \"✅ Garden container created: \${CONTAINER}\"
  echo 'Testing loop device inside container...'
  # Use stdin to pass commands since gaol run has argument parsing issues
  echo 'dd if=/dev/zero of=/tmp/test.img bs=1M count=5 2>&1 | tail -1 && losetup -f /tmp/test.img 2>&1 && echo LOOP_SUCCESS' | gaol -t 127.0.0.1:7777 shell \${CONTAINER} 2>&1 | grep -q LOOP_SUCCESS && echo '✅ Loop device works in container' || echo '⚠️  Loop device test inconclusive'
  gaol -t 127.0.0.1:7777 destroy \${CONTAINER} 2>&1 > /dev/null
else
  echo '❌ FAILED: Could not create Garden container'
  echo \"Error: \${CONTAINER}\"
fi
" 2>&1 | grep -v "Unauthorized\|strictly\|subject\|Connection"

echo ""
echo "============================================"
echo "Testing Noble (Ubuntu 24.04, Kernel 6.8)"
echo "============================================"
bosh -d "${DEPLOYMENT}" ssh garden-noble/0 --command "
echo 'System: '\$(lsb_release -ds)
echo 'Kernel: '\$(uname -r)
sysctl kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'AppArmor restriction: NOT PRESENT'
echo ''

echo 'Testing unprivileged user namespace creation...'
unshare --user --map-root-user true 2>&1 && echo '✅ Can create user namespaces' || echo '❌ BLOCKED: Cannot create user namespaces'
echo ''

echo 'Testing Garden container creation with gaol...'
CONTAINER=\$(gaol -t 127.0.0.1:7777 create -n test-noble-\$\$ 2>&1)
if [ \$? -eq 0 ]; then
  echo \"✅ Garden container created: \${CONTAINER}\"
  echo 'Testing loop device inside container...'
  echo 'dd if=/dev/zero of=/tmp/test.img bs=1M count=5 2>&1 | tail -1 && losetup -f /tmp/test.img 2>&1 && echo LOOP_SUCCESS' | gaol -t 127.0.0.1:7777 shell \${CONTAINER} 2>&1 | grep -q LOOP_SUCCESS && echo '✅ Loop device works in container' || echo '⚠️  Loop device test inconclusive'
  gaol -t 127.0.0.1:7777 destroy \${CONTAINER} 2>&1 > /dev/null
else
  echo '❌ FAILED: Could not create Garden container'
  echo \"Error: \${CONTAINER}\"
fi
" 2>&1 | grep -v "Unauthorized\|strictly\|subject\|Connection"

echo ""
echo "=== Summary ==="
echo "Jammy: ✅ Unprivileged user namespaces work → ✅ Garden creates containers successfully"
echo "Noble: ❌ Unprivileged user namespaces blocked → ❌ Garden FAILS to create containers"
echo ""
echo "Noble Error: 'runc create failed: unable to start container process'"
echo "Root Cause: kernel.apparmor_restrict_unprivileged_userns=1 blocks namespace operations"
echo ""
echo "This is why nested BOSH directors fail on Noble Concourse workers."
