#!/usr/bin/env bash

set -e

local_bosh_dir="/tmp/local-bosh/director"

# Run pre-start to generate configuration files
/var/vcap/jobs/garden/bin/pre-start

echo "=== Patching GrootFS configuration for Noble (Ubuntu 24.04) compatibility ==="
echo "Disabling loop device usage to work with cgroup v2..."

# Pre-create GrootFS store directories
echo "Creating GrootFS store directories..."
mkdir -p /var/vcap/data/grootfs/store/unprivileged
mkdir -p /var/vcap/data/grootfs/store/privileged
chmod 755 /var/vcap/data/grootfs
chmod 755 /var/vcap/data/grootfs/store
chmod 755 /var/vcap/data/grootfs/store/unprivileged
chmod 755 /var/vcap/data/grootfs/store/privileged

GROOTFS_CONFIG="/var/vcap/jobs/garden/config/grootfs_config.yml"
if [ -f "$GROOTFS_CONFIG" ]; then
  echo "Original GrootFS config:"
  cat "$GROOTFS_CONFIG"
  
  echo ""
  echo "Applying patches..."
  
  sed -i 's/  store_size_bytes: [0-9]*/  store_size_bytes: 0/' "$GROOTFS_CONFIG"
  sed -i 's/  with_direct_io: false/  with_direct_io: true/' "$GROOTFS_CONFIG"
  
  echo ""
  echo "Patched GrootFS config:"
  cat "$GROOTFS_CONFIG"
  echo ""
fi

/var/vcap/jobs/garden/bin/garden_ctl start &
/var/vcap/jobs/garden/bin/post-start

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

  cat <<EOF > "${local_bosh_dir}/env"
export BOSH_ENVIRONMENT="${BOSH_DIRECTOR_IP}"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=`bosh int "${local_bosh_dir}/creds.yml" --path /admin_password`
export BOSH_CA_CERT="${local_bosh_dir}/ca.crt"
EOF
  source "${local_bosh_dir}/env"

  bosh -n update-cloud-config warden/cloud-config.yml
  ip route add   10.244.0.0/15 via ${BOSH_DIRECTOR_IP}
popd > /dev/null
