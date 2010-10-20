require 'rubygems'
require 'rake'
require "rake/rdoctask"
require "rake/testtask"
require "spec/rake/spectask"
require "fileutils"

# Load code annotation support library
require File.expand_path("../tools/annotation_extract", __FILE__)

include FileUtils

desc "Run the specs."
task :default => :specs

task :merb => [:clean, :rdoc, :package]


##############################################################################
# Documentation
##############################################################################
task :doc => [:rdoc]
namespace :doc do

  Rake::RDocTask.new do |rdoc|
    files = ["README", "LICENSE", "CHANGELOG", "lib/**/*.rb"]
    rdoc.rdoc_files.add(files)
    rdoc.main = "README"
    rdoc.title = "Merb Docs"
    rdoc.rdoc_dir = "doc/rdoc"
    rdoc.options << "--line-numbers"
  end

  begin
    require 'yard'

    YARD::Rake::YardocTask.new do |t|
      t.files   = ['lib/**/*.rb']
      t.options = [
        '--output-dir', 'doc/yard',
        '--tag', 'overridable:Overridable',
        '--markup', 'markdown',
      ]
    end
  rescue
  end

  desc "run webgen"
  task :webgen do
    sh %{cd doc/site; webgen}
  end

end

##############################################################################
# rSpec & rcov
##############################################################################
desc "Run :specs, :rcov"
task :aok => [:specs, :rcov]

def setup_specs(name, spec_cmd='spec', run_opts = "-c")
  except = []
  except += Dir["spec/**/memcache*_spec.rb"] if ENV['MEMCACHED'] == 'no'

  public_globs = Dir["#{Dir.pwd}/spec/public/**/*_spec.rb"].reject{|file| file.include?('/gems/')}
  public_globs_10 = 
    Dir["#{Dir.pwd}/spec10/public/**/*_spec.rb"].reject{|file| file.include?('/gems/')}

  private_globs = Dir["#{Dir.pwd}/spec/private/**/*_spec.rb"]

  desc "Run all specs (#{name})"
  task "specs:#{name}" do
    require "lib/merb-core/test/run_specs"
    globs = public_globs + private_globs
    run_specs(globs, spec_cmd, ENV['RSPEC_OPTS'] || run_opts, except)
  end
  
  desc "Run 1.0 frozen specs"
  task "specs:oneoh" do
    require "lib/merb-core/test/run_specs"
    globs = public_globs_10
    run_specs(globs, spec_cmd, ENV['RSPEC_OPTS'] || run_opts, except)
  end
  
  desc "Run private specs (#{name})"
  task "specs:#{name}:private" do
    require "lib/merb-core/test/run_specs"
    run_specs(private_globs, spec_cmd, ENV['RSPEC_OPTS'] || run_opts)
  end

  desc "Run public specs (#{name})"
  task "specs:#{name}:public" do
    require "lib/merb-core/test/run_specs"
    run_specs(public_globs, spec_cmd, ENV['RSPEC_OPTS'] || run_opts)
  end
  
  # With profiling formatter
  desc "Run all specs (#{name}) with profiling formatter"
  task "specs:#{name}_profiled" do
    require "lib/merb-core/test/run_specs"
    run_specs("spec/**/*_spec.rb", spec_cmd, "-c -f o")
  end

  desc "Run private specs (#{name}) with profiling formatter"
  task "specs:#{name}_profiled:private" do
    require "lib/merb-core/test/run_specs"
    run_specs("spec/private/**/*_spec.rb", spec_cmd, "-c -f o")
  end

  desc "Run public specs (#{name}) with profiling formatter"
  task "specs:#{name}_profiled:public" do
    require "lib/merb-core/test/run_specs"
    run_specs("spec/public/**/*_spec.rb", spec_cmd, "-c -f o")
  end  
end

setup_specs("mri", "spec")
setup_specs("jruby", "jruby -S spec")

task "specs:core_ext" do
  require "lib/merb-core/test/run_specs"
  run_specs("spec/public/core_ext/*_spec.rb", "spec", "-c -f o")
end

task "spec"           => ["specs:mri"]
task "specs"          => ["specs:mri"]
task "specs:private"  => ["specs:mri:private"]
task "specs:public"   => ["specs:mri:public"]

desc "Run coverage suite"
task :rcov do
  require 'fileutils'
  FileUtils.rm_rf("coverage") if File.directory?("coverage")
  FileUtils.mkdir("coverage")
  path = File.expand_path(Dir.pwd)
  files = Dir["spec/**/*_spec.rb"]
  files.each do |spec|
    puts "Getting coverage for #{File.expand_path(spec)}"
    command = %{rcov #{File.expand_path(spec)} --aggregate #{path}/coverage/data.data --exclude ".*" --include-file "lib/merb-core(?!\/vendor)"}
    command += " --no-html" unless spec == files.last
    `#{command} 2>&1`
  end
end

desc "Run a specific spec with TASK=xxxx"
Spec::Rake::SpecTask.new("spec") do |t|
  t.spec_opts = ["--colour"]
  t.libs = ["lib", "server/lib" ]
  t.spec_files = (ENV["TASK"] || '').split(',').map do |task|
    "spec/**/#{task}_spec.rb"
  end
end

desc "Run all specs output html"
Spec::Rake::SpecTask.new("specs_html") do |t|
  t.spec_opts = ["--format", "html"]
  t.libs = ["lib", "server/lib" ]
  t.spec_files = Dir["spec/**/*_spec.rb"].sort
end

##############################################################################
# CODE STATISTICS
##############################################################################

STATS_DIRECTORIES = [
  ['Code', 'lib/'],
  ['Unit tests', 'spec']
].collect { |name, dir| [ name, "./#{dir}" ] }.
  select  { |name, dir| File.directory?(dir) }

desc "Report code statistics (KLOCs, etc) from the application"
task :stats do
  require File.expand_path("../tools/code_statistics", __FILE__)
  # require "extra/stats"
  verbose = true
  CodeStatistics.new(*STATS_DIRECTORIES).to_s
end

##############################################################################
# SYNTAX CHECKING
##############################################################################

task :check_syntax do
  `find . -name "*.rb" |xargs -n1 ruby -c |grep -v "Syntax OK"`
  puts "* Done"
end


# Run specific tests or test files. Searches nested spec directories as well.
#
# Based on a technique popularized by Geoffrey Grosenbach
rule "" do |t|
  spec_cmd = (RUBY_PLATFORM =~ /java/) ? "jruby -S spec" : "spec"
  # spec:spec_file:spec_name
  if /spec:(.*)$/.match(t.name)
    arguments = t.name.split(':')

    file_name = arguments[1]
    spec_name = arguments[2..-1]

    spec_filename = "#{file_name}_spec.rb"
    specs = Dir["spec/**/#{spec_filename}"]

    if path = specs.detect { |f| spec_filename == File.basename(f) }
      run_file_name = path
    else
      puts "No specs found for #{t.name.inspect}"
      exit
    end

    example = " -e '#{spec_name}'" unless spec_name.empty?

    sh "#{spec_cmd} #{run_file_name} --colour #{example}"
  end
end

##############################################################################
# Flog
##############################################################################

namespace :flog do
  task :worst_methods do
    require "flog"
    flogger = Flog.new
    flogger.flog_files Dir["lib/**/*.rb"]
    totals = flogger.totals.sort_by {|k,v| v}.reverse[0..10]
    totals.each do |meth, total|
      puts "%50s: %s" % [meth, total]
    end
  end
  
  task :total do
    require "flog"
    flogger = Flog.new
    flogger.flog_files Dir["lib/**/*.rb"]
    puts "Total: #{flogger.total}"
  end
  
  task :per_method do
    require "flog"
    flogger = Flog.new
    flogger.flog_files Dir["lib/**/*.rb"]
    methods = flogger.totals.reject { |k,v| k =~ /\#none$/ }.sort_by { |k,v| v }
    puts "Total Flog:    #{flogger.total}"
    puts "Total Methods: #{flogger.totals.size}"
    puts "Flog / Method: #{flogger.total / methods.size}"
  end
end

namespace :tools do
  namespace :tags do
    desc "Generates Emacs tags using Exuberant Ctags."
    task :emacs do
      sh "ctags -e --Ruby-kinds=-f -o TAGS -R lib"
    end
  end
end
