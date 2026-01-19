require 'yaml'
require 'json'
require 'fileutils'
require 'tmpdir'

warden_cpi_archive_path = ARGV[0]

%w{
  /var/vcap/sys/run/warden_cpi
  /var/vcap/sys/log/warden_cpi
}.each {|path| FileUtils.mkdir_p path}

installed_job_path = File.join('/', 'var', 'vcap', 'jobs', 'warden_cpi')

Dir.mktmpdir do |workspace|
  `tar xzf #{warden_cpi_archive_path} -C #{workspace}`
  job_path = File.join(workspace, 'warden_cpi')
  FileUtils.mkdir_p job_path
  `tar xzf #{File.join(workspace, 'jobs', 'warden_cpi.tgz')} -C #{job_path}`
  job_spec_path = File.join(job_path, 'job.MF')
  job_spec = YAML.load_file(job_spec_path)
  job_spec['packages'].each do |package_name|
    package_path = File.join('/', 'var', 'vcap', 'packages', package_name)
    FileUtils.mkdir_p(package_path)
    `tar xzf #{File.join(workspace, 'compiled_packages', "#{package_name}.tgz")} -C #{package_path}`
  end
  context_path = File.join(workspace, 'context.json')
  context = {
    'default_properties' => job_spec['properties'].map { |key, value| [key, value['default']]}.to_h,
    'job_properties' => {}
  }
  File.write(context_path, context.to_json)
  templates = job_spec['templates']
  templates.each do |src, dst|
    src_path = File.join(job_path, 'templates', src)
    dest_path = File.join(installed_job_path, dst)
    FileUtils.mkdir_p(File.dirname(dest_path))
    `ruby #{File.join(__dir__, 'template-renderer.rb')} #{context_path} #{src_path} #{dest_path}`
  end
end

`chmod +x #{File.join(installed_job_path, 'bin', '*')}`
