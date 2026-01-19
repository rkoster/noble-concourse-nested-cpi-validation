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
  
  # Get all packages from the release (including dependencies)
  release_manifest = YAML.load_file(File.join(workspace, 'release.MF'))
  all_packages = release_manifest['packages'].map { |p| p['name'] }
  
  # Compile all packages (dependencies first, then job packages)
  # golang-1-linux is a dependency of warden_cpi, so we compile it first
  packages_to_compile = all_packages & (job_spec['packages'] + ['golang-1-linux'])
  packages_to_compile.uniq!
  
  # Sort to ensure golang-1-linux comes before warden_cpi
  packages_to_compile.sort_by! { |p| p == 'golang-1-linux' ? 0 : 1 }
  
  packages_to_compile.each do |package_name|
    package_path = File.join('/', 'var', 'vcap', 'packages', package_name)
    FileUtils.mkdir_p(package_path)
    
    # Extract source package
    compile_dir = File.join(workspace, "compile_#{package_name}")
    FileUtils.mkdir_p(compile_dir)
    `tar xzf #{File.join(workspace, 'packages', "#{package_name}.tgz")} -C #{compile_dir}`
    
    # Read package spec to find dependencies
    package_spec_path = File.join(compile_dir, 'packaging')
    
    if File.exist?(package_spec_path)
      puts "Compiling package: #{package_name}"
      
      # Set up BOSH compile environment variables
      ENV['BOSH_COMPILE_TARGET'] = compile_dir
      ENV['BOSH_INSTALL_TARGET'] = package_path
      ENV['BOSH_PACKAGES_DIR'] = '/var/vcap/packages'
      
      # Run the packaging script
      result = system("cd #{compile_dir} && bash packaging")
      unless result
        raise "Failed to compile package #{package_name}"
      end
    else
      puts "No packaging script for #{package_name}, assuming pre-compiled"
    end
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
