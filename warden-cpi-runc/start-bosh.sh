#!/usr/bin/env bash

set -e

local_bosh_dir="/tmp/local-bosh/director"

# Run pre-start if not already done
if [ ! -f /var/vcap/data/garden/.pre-start-done ]; then
  /var/vcap/jobs/garden/bin/pre-start
  touch /var/vcap/data/garden/.pre-start-done
fi

# Initialize GrootFS stores if not already done
if [ ! -f /var/vcap/data/garden/.grootfs-init-done ]; then
  echo "Initializing GrootFS stores..."
  /var/vcap/packages/grootfs/bin/grootfs --config /var/vcap/jobs/garden/config/grootfs_config.yml init-store || true
  /var/vcap/packages/grootfs/bin/grootfs --config /var/vcap/jobs/garden/config/privileged_grootfs_config.yml init-store || true
  touch /var/vcap/data/garden/.grootfs-init-done
fi

# Start Garden (gdn) directly if not already running
# Note: garden_ctl requires systemd which isn't available in container environments
# Force Garden to listen on TCP port 7777 for Warden CPI compatibility
GARDEN_ADDR="127.0.0.1:7777"

# Check if Garden is already running
if curl -sf "http://${GARDEN_ADDR}/ping" >/dev/null 2>&1; then
  echo "Garden already running on ${GARDEN_ADDR}"
else
  echo "Starting gdn server on ${GARDEN_ADDR}..."
  
  /var/vcap/packages/guardian/bin/gdn server \
    --config /var/vcap/jobs/garden/config/config.ini \
    --bind-ip 127.0.0.1 \
    --bind-port 7777 \
    --image-plugin /var/vcap/packages/grootfs/bin/grootfs \
    --image-plugin-extra-arg="--config" \
    --image-plugin-extra-arg="/var/vcap/jobs/garden/config/grootfs_config.yml" \
    --privileged-image-plugin /var/vcap/packages/grootfs/bin/grootfs \
    --privileged-image-plugin-extra-arg="--config" \
    --privileged-image-plugin-extra-arg="/var/vcap/jobs/garden/config/privileged_grootfs_config.yml" \
    >> /var/vcap/sys/log/garden/garden.stdout.log \
    2>> /var/vcap/sys/log/garden/garden.stderr.log &
  
  # Wait for Garden to be ready
  echo "Waiting for Garden API..."
  timeout 60 bash -c '
    until curl -sf "http://'"${GARDEN_ADDR}"'/ping" >/dev/null 2>&1; do
      sleep 1
    done
  ' || {
    echo "Garden failed to start"
    cat /var/vcap/sys/log/garden/garden.stdout.log || true
    cat /var/vcap/sys/log/garden/garden.stderr.log || true
    exit 1
  }
  echo "Garden is ready on ${GARDEN_ADDR}"
fi

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
