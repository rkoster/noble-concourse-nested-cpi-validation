require 'fileutils'

# Create required directories for warden_cpi
# BOSH create-env will handle package compilation automatically
%w{
  /var/vcap/sys/run/warden_cpi
  /var/vcap/sys/log/warden_cpi
  /var/vcap/store/warden_cpi/disks
  /var/vcap/store/warden_cpi/stemcells
  /var/vcap/store/warden_cpi/ephemeral_bind_mounts_dir
  /var/vcap/store/warden_cpi/persistent_bind_mounts_dir
}.each { |path| FileUtils.mkdir_p path }

puts "Created warden_cpi directories. BOSH create-env will compile packages."
