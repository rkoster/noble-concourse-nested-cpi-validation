#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONCOURSE_TARGET="${CONCOURSE_TARGET:-local}"

# Parse arguments
if [ $# -lt 1 ]; then
  echo "Usage: $0 <build-number> [pipeline-name] [job-name]"
  echo ""
  echo "Example:"
  echo "  $0 4"
  echo "  $0 4 nested-bosh-zookeeper deploy-zookeeper-on-upstream-warden"
  echo ""
  exit 1
fi

BUILD_NUMBER="$1"
PIPELINE_NAME="${2:-nested-bosh-zookeeper}"
JOB_NAME="${3:-deploy-zookeeper-on-upstream-warden}"

echo "=========================================="
echo "Debugging Concourse Build #${BUILD_NUMBER}"
echo "Pipeline: ${PIPELINE_NAME}"
echo "Job: ${JOB_NAME}"
echo "=========================================="
echo ""

# Construct the hijack target
HIJACK_TARGET="-j ${PIPELINE_NAME}/${JOB_NAME} -b ${BUILD_NUMBER}"

echo "=== 1. CHECKING LOOPBACK DEVICES ==="
echo "Running: losetup -a"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "losetup -a || echo 'No loop devices found'"
echo ""

echo "=== 2. CHECKING AVAILABLE LOOP DEVICES ==="
echo "Running: ls -la /dev/loop* | head -20"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "ls -la /dev/loop* 2>&1 | head -20 || echo 'No /dev/loop* devices'"
echo ""

echo "=== 2b. TESTING LOOP DEVICE PERMISSIONS ==="
echo "Running: losetup -f && attempting to setup loop device"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "echo 'First free loop device:' && losetup -f && dd if=/dev/zero of=/tmp/test.img bs=1M count=10 2>&1 && losetup -f /tmp/test.img 2>&1 || echo 'FAILED: Cannot setup loop devices'"
echo ""

echo "=== 3. CHECKING CGROUPS VERSION ==="
echo "Running: stat -fc %T /sys/fs/cgroup"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "stat -fc %T /sys/fs/cgroup"
echo ""

echo "=== 4. CHECKING CGROUP CONTROLLERS ==="
echo "Running: cat /sys/fs/cgroup/cgroup.controllers"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "cat /sys/fs/cgroup/cgroup.controllers 2>&1 || echo 'cgroup.controllers not found (may be cgroup v1)'"
echo ""

echo "=== 5. CHECKING CGROUP SUBTREE CONTROL ==="
echo "Running: cat /sys/fs/cgroup/cgroup.subtree_control"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "cat /sys/fs/cgroup/cgroup.subtree_control 2>&1 || echo 'Not available'"
echo ""

echo "=== 6. CHECKING CURRENT PROCESS CGROUP ==="
echo "Running: cat /proc/self/cgroup"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "cat /proc/self/cgroup"
echo ""

echo "=== 7. CHECKING APPARMOR STATUS ==="
echo "Running: cat /proc/self/attr/current"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "cat /proc/self/attr/current 2>&1 || echo 'AppArmor not available'"
echo ""

echo "=== 8. CHECKING PRIVILEGED MODE ==="
echo "Running: capsh --print"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "capsh --print 2>&1 | grep 'Current:' || echo 'capsh not available'"
echo ""

echo "=== 9. CHECKING KERNEL MODULES ==="
echo "Running: lsmod | grep -E '(loop|overlay|dm_)'"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "lsmod | grep -E '(loop|overlay|dm_)' || echo 'Modules not found or lsmod not available'"
echo ""

echo "=== 10. CHECKING DEVICE MAPPER ==="
echo "Running: ls -la /dev/mapper/"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "ls -la /dev/mapper/ 2>&1 || echo '/dev/mapper not available'"
echo ""

echo "=== 11. CHECKING BOSH/GARDEN PROCESSES ==="
echo "Running: ps auxf | grep -E '(bosh|garden|containerd|runc)'"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "ps auxf 2>&1 | grep -E '(bosh|garden|containerd|runc)' | grep -v grep || echo 'No relevant processes found'"
echo ""

echo "=== 12. CHECKING GARDEN STDERR LOG (if exists) ==="
echo "Running: tail -50 /var/vcap/sys/log/garden/garden.stderr.log"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "tail -50 /var/vcap/sys/log/garden/garden.stderr.log 2>&1 || echo 'Garden log not found yet'"
echo ""

echo "=== 13. CHECKING GARDEN STDOUT LOG (if exists) ==="
echo "Running: tail -50 /var/vcap/sys/log/garden/garden.stdout.log"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "tail -50 /var/vcap/sys/log/garden/garden.stdout.log 2>&1 || echo 'Garden log not found yet'"
echo ""

echo "=== 14. CHECKING MONIT STATUS ==="
echo "Running: monit summary"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "monit summary 2>&1 || echo 'Monit not available or not running'"
echo ""

echo "=== 15. CHECKING MOUNTS ==="
echo "Running: mount | grep -E '(cgroup|overlay|loop)'"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "mount | grep -E '(cgroup|overlay|loop)' || echo 'No relevant mounts found'"
echo ""

echo "=== 16. CHECKING GARDEN LOGS FOR ERRORS ==="
echo "Running: cat /var/vcap/sys/log/garden/garden_ctl.stderr.log"
"${SCRIPT_DIR}/bin/fly" -t "${CONCOURSE_TARGET}" hijack ${HIJACK_TARGET} -- bash -c "cat /var/vcap/sys/log/garden/garden_ctl.stderr.log 2>&1 | tail -50 || echo 'Garden log not found'"
echo ""

echo "=========================================="
echo "Debug inspection complete"
echo ""
echo "SUMMARY:"
echo "- Loop devices available: Check section 2"
echo "- Loop device permissions: Check section 2b (CRITICAL)"
echo "- Garden errors: Check section 16"
echo "=========================================="
