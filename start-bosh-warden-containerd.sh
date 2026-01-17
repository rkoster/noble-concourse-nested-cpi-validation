#!/usr/bin/env bash

set -e

local_bosh_dir="/tmp/local-bosh/director"

echo "=== Configuring Garden to use containerd backend (bypassing GrootFS) ==="

# Export environment variable to enable containerd mode
export GARDEN_CONTAINERD_MODE=true

# Create containerd directories
mkdir -p /var/vcap/data/containerd/root
mkdir -p /var/vcap/sys/run/containerd/state
mkdir -p /var/vcap/sys/log/garden

echo "=== Starting containerd runtime ==="

# Create containerd configuration
cat > /var/vcap/jobs/garden/config/containerd.toml <<'CONTAINERD_CONFIG'
version = 3
root = '/var/vcap/data/containerd/root'
state = '/var/vcap/sys/run/containerd/state'

# Disable all snapshotters except native (we'll use overlayfs in practice)
# The key is that containerd doesn't require XFS like GrootFS does
disabled_plugins = ['io.containerd.snapshotter.v1.aufs',
  'io.containerd.snapshotter.v1.btrfs',
  'io.containerd.snapshotter.v1.devmapper',
  'io.containerd.snapshotter.v1.zfs',
  'io.containerd.grpc.v1.walking',
  'io.containerd.gc.v1.scheduler']

oom_score = -999

[grpc]
  address = '/var/vcap/sys/run/containerd/containerd.sock'

[debug]
  address = '/var/vcap/sys/run/containerd/debug.sock'
  level = 'info'
CONTAINERD_CONFIG

# Start containerd in background
/var/vcap/packages/containerd/bin/containerd -c /var/vcap/jobs/garden/config/containerd.toml \
  >> /var/vcap/sys/log/garden/containerd.stdout.log \
  2>> /var/vcap/sys/log/garden/containerd.stderr.log &

containerd_pid=$!
echo $containerd_pid > /var/vcap/sys/run/garden/containerd.pid

# Wait for containerd to be ready
echo "Waiting for containerd to become available..."
for i in {1..30}; do
  if /var/vcap/packages/containerd/bin/ctr --connect-timeout 100ms c ls &>/dev/null; then
    echo "Containerd is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "ERROR: Containerd failed to start within 30 seconds"
    exit 1
  fi
  sleep 1
done

echo "=== Starting Garden with containerd runtime ==="

# Garden will use containerd instead of runc+GrootFS
# No need to run pre-start since we're not using GrootFS
/var/vcap/jobs/garden/bin/garden_ctl start &
sleep 5

# Verify Garden is running
if ! pgrep -f "gdn server" > /dev/null; then
  echo "ERROR: Garden failed to start"
  exit 1
fi

echo "=== Garden started successfully with containerd backend ==="

echo "=== Starting BOSH Director deployment ==="

additional_ops_files=""
if [ "${USE_LOCAL_RELEASES:="true"}" != "false" ]; then
  additional_ops_files="-o /usr/local/releases/local-releases.yml"
fi

pushd ${BOSH_DEPLOYMENT_PATH:-/usr/local/bosh-deployment} > /dev/null
  export BOSH_DIRECTOR_IP="192.168.56.6"

  mkdir -p ${local_bosh_dir}

  bosh int bosh.yml \
    -o bosh-lite.yml \
    -o warden/cpi.yml \
    -o uaa.yml \
    -o credhub.yml \
    -o jumpbox-user.yml \
    ${additional_ops_files} \
    -v director_name=bosh-lite \
    -v internal_ip=${BOSH_DIRECTOR_IP} \
    -v internal_gw=192.168.56.1 \
    -v internal_cidr=192.168.56.0/24 \
    -v outbound_network_name=NatNetwork \
    -v garden_host=127.0.0.1 \
    ${@} > "${local_bosh_dir}/bosh-director.yml"

  bosh create-env "${local_bosh_dir}/bosh-director.yml" \
       --vars-store="${local_bosh_dir}/creds.yml" \
       --state="${local_bosh_dir}/state.json"

  bosh int "${local_bosh_dir}/creds.yml" --path /director_ssl/ca > "${local_bosh_dir}/ca.crt"

  cat <<ENVFILE > "${local_bosh_dir}/env"
export BOSH_ENVIRONMENT="${BOSH_DIRECTOR_IP}"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=`bosh int "${local_bosh_dir}/creds.yml" --path /admin_password`
export BOSH_CA_CERT="${local_bosh_dir}/ca.crt"
ENVFILE
  source "${local_bosh_dir}/env"

  bosh -n update-cloud-config warden/cloud-config.yml
  ip route add   10.244.0.0/15 via ${BOSH_DIRECTOR_IP}
popd > /dev/null
