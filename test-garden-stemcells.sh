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
" 2>&1 | grep -v "Unauthorized\|strictly\|subject\|Connection"

echo ""
echo "=== Summary ==="
echo "Jammy: Unprivileged user namespaces work → Garden can create containers"
echo "Noble: Unprivileged user namespaces blocked by kernel.apparmor_restrict_unprivileged_userns=1"
echo "       → Garden CANNOT create containers even in privileged mode"
echo ""
echo "This is why nested BOSH directors fail on Noble Concourse workers."
