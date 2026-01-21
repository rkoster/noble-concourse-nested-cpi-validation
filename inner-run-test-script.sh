#!/bin/bash

set -euo pipefail

GROOTFS_BIN="/var/vcap/packages/grootfs/bin/grootfs"
GROOTFS_CFG="/var/vcap/jobs/garden/config/grootfs_config.yml"
INSECURE_REGISTRY="10.246.0.21:5000"
IMAGE_REF="docker://10.246.0.21:5000/upstream-warden-cpi:latest"
HANDLE="test-warden-cpi-rootfs"

echo '=== System Information ==='
echo "OS: $(lsb_release -ds 2>/dev/null || grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'\"' -f2)"
echo "Kernel: $(uname -r)"
echo "AppArmor restriction: $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'not present (Jammy)')"
echo ''

# echo '=== Creating test image (10MB) ==='
# dd if=/dev/zero of=/tmp/test-loop.img bs=1M count=10 2>&1 | grep -v records
# echo 'Created: /tmp/test-loop.img'
# echo ''

# echo '=== Test 1: Loop device in root namespace (should work) ==='
# if sudo losetup -f /tmp/test-loop.img; then
#   LOOP_DEV="$(sudo losetup -j /tmp/test-loop.img | cut -d: -f1)"
#   echo "✅ SUCCESS: Attached to ${LOOP_DEV}"
#   sudo losetup -d "${LOOP_DEV}"
#   echo "   Detached ${LOOP_DEV}"
# else
#   echo '❌ FAILED: Could not attach loop device in root namespace'
#   echo '   This is unexpected - even Noble should work here'
# fi
# echo ''

# echo '=== Test 2: Can unprivileged user namespaces be created? ==='
# echo 'This is the key test - Noble blocks unpriv namespace creation entirely'

# # Test if we can create unprivileged user namespace (Noble blocks this)
# if unshare --user --map-root-user true 2>&1; then
#   echo '✅ SUCCESS: Unprivileged user namespaces allowed'
#   echo '   Guardian/Garden can create containers'
# else
#   echo '❌ FAILED: Unprivileged user namespaces blocked'
#   echo '   Error: kernel.apparmor_restrict_unprivileged_userns = 1'
#   echo '   Guardian/Garden CANNOT create containers'
# fi
# echo ''

# echo '=== Test 3: Loop device with CAP_SYS_ADMIN in user namespace ==='
# echo 'This simulates what Garden does: user namespace + capabilities'

# # Garden runs with CAP_SYS_ADMIN in the container
# # Test with sudo to have capabilities
# if sudo unshare --user --map-root-user --mount losetup -f /tmp/test-loop.img 2>&1; then
#   echo '✅ SUCCESS: Loop device works with capabilities in user namespace'
#   echo '   This is how Garden operates when it can create containers'
#   # Clean up loop device
#   LOOP_DEV="$(sudo losetup -j /tmp/test-loop.img | cut -d: -f1 || true)"
#   if [ -n "${LOOP_DEV}" ]; then
#     sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
#   fi
# else
#   echo '❌ FAILED: Loop device blocked even with capabilities'
#   echo '   This would prevent Garden from using grootfs'
# fi
# echo ''

# echo "Checking if '${HANDLE}' already exists in grootfs store..."
# if sudo "${GROOTFS_BIN}" --config "${GROOTFS_CFG}" list 2>/dev/null | grep -qE "/${HANDLE}$|\\b${HANDLE}\\b"; then
#   echo -e "\n✅ Image already present: ${HANDLE}\n"
#   echo 'Listing grootfs images...'
#   sudo "${GROOTFS_BIN}" --config "${GROOTFS_CFG}" list 2>/dev/null | head -20
#   exit 0
# fi

# echo 'Pulling upstream-warden-cpi image from registry...'
# if sudo "${GROOTFS_BIN}" \
#         --config "${GROOTFS_CFG}" \
#         create \
#         --insecure-registry "${INSECURE_REGISTRY}" \
#         "${IMAGE_REF}" \
#         "${HANDLE}" 2>&1
# then
#   echo -e '\n✅ Image pulled successfully!\n'
#   echo 'Listing grootfs images...'
#   sudo "${GROOTFS_BIN}" --config "${GROOTFS_CFG}" list 2>/dev/null | head -20
# else
#   echo '❌ FAILED to pull image'
#   exit 1
# fi

gaol destroy test-warden || true
gaol create -r docker://10.246.0.21:5000/upstream-warden-cpi:latest -p -n test-warden
gaol run test-warden -a -c /var/vcap/jobs/garden/bin/overlay-xfs-setup
gaol destroy test-warden

echo '=== Cleanup ==='
rm -f /tmp/test-loop.img
echo 'Removed test image'
echo ''

echo '=== Diagnosis ==='
KERNEL_VERSION="$(uname -r | cut -d. -f1,2)"
APPARMOR_RESTRICT="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo '0')"

if [ "${APPARMOR_RESTRICT}" = '1' ]; then
  echo '❌ PROBLEM DETECTED: kernel.apparmor_restrict_unprivileged_userns = 1'
  echo '   This Noble kernel (6.x) blocks loop devices in user namespaces'
  echo '   Guardian/Garden will FAIL to start on this VM'
  echo ''
  echo 'Solutions:'
  echo '  1. Use Jammy stemcell (kernel 5.15 without this restriction)'
  echo '  2. Set sysctl: kernel.apparmor_restrict_unprivileged_userns=0'
  echo '     (may not work for nested Docker containers)'
elif [ "${APPARMOR_RESTRICT}" = '0' ]; then
  echo '✅ GOOD: kernel.apparmor_restrict_unprivileged_userns = 0'
  echo '   Loop devices should work in user namespaces'
  echo '   Guardian/Garden should start successfully'
else
  echo '✅ GOOD: kernel.apparmor_restrict_unprivileged_userns not present'
  echo '   This is likely Jammy (kernel 5.15) without the restriction'
  echo '   Guardian/Garden should start successfully'
fi
