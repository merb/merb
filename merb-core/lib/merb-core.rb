# require 'merb' must happen after Merb::Config is instantiated

# Add the local gems dir if found within the app root; any dependencies loaded
# hereafter will try to load from the local gems before loading system gems.
root_key = %w[-m --merb-root].detect { |o| ARGV.index(o) }
root = ARGV[ARGV.index(root_key) + 1] if root_key
root = root.to_a.empty? ? Dir.getwd : root

require "thread"
require "set"
require "fileutils"
require "socket"
require "pathname"
require "extlib"
require "extlib/dictionary"

Thread.abort_on_exception = true

__DIR__ = File.dirname(__FILE__)

$LOAD_PATH.unshift __DIR__ unless
  $LOAD_PATH.include?(__DIR__) ||
  $LOAD_PATH.include?(File.expand_path(__DIR__))

# Some dependencies tend to require&rescue for optionally required files;
# doing so will load the full rubygems, even though it was just optional.
$MINIGEMS_SKIPPABLE = ['encoding/character/utf-8']

module Merb
  # Create stub module for global controller helpers.
  module GlobalHelpers; end
  class ReservedError < StandardError; end
  
  class << self
    attr_reader :exiting

    # List procs that are called on exit.
    #
    # @return [Array] The current list of procs that have been registered
    #   with Merb to run when Merb exits gracefully.
    #
    # @api private
    def at_exit_procs
      @at_exit_procs ||= []
    end

    # Set the current exiting state of Merb.
    #
    # Setting this state to true also alerts Extlib to exit and clean up
    # its state.
    #
    # @return [Boolean] The current exiting state of Merb
    #
    # @api private
    def exiting=(bool)
      Extlib.exiting = bool
      @exiting = bool
      if bool
        if Extlib.const_defined?("Pooling") && Extlib::Pooling.scavenger
          Extlib::Pooling.scavenger.wakeup
        end
        while prc = self.at_exit_procs.pop
          prc.call
        end unless Merb::Config[:reap_workers_quickly]
      end
      @exiting
    end
    
    # Register a proc to run when Merb is exiting gracefully. It will *not*
    # be run when Merb exits quickly.
    #
    # @return [Array] The current list of procs to run when Merb exits
    #   gracefully.
    #
    # @api plugin
    def at_exit(&blk)
      self.at_exit_procs << blk
    end

    # Merge environment settings.
    #
    # This can allow you to, e.g., have a "localdev" environment that runs
    # like your "development", or a "staging" environment that runs identical
    # to your "production" environment. It is best used from any environment
    # config file, e.g., development.rb, custom.rb, localdev.rb, staging.rb,
    # etc.
    #
    # @example From any environment config file:
    #       Merb.merge_env "production"         # We want to use all the settings production uses
    #       Merb::Config.use do |c|
    #         c[:log_level]         = "debug"   # except we want debug log level
    #         c[:log_stream]        = @some_io  # and log to this IO handle
    #         c[:exception_details] = true      # and we want to see exception details
    #       end
    #
    # @param [String] env Environment to run like
    # @param [Boolean] use_db Should Merb use the merged environments DB connection.
    #
    # @api public
    def merge_env(env,use_db=false)
      if Merb.environment_info.nil?
        Merb.environment_info = {
          :real_env => Merb.environment,
          :merged_envs => [],
          :db_env => Merb.environment
        }
      end
      
      #Only load if it hasn't been loaded
      unless Merb.environment_info[:merged_envs].member? env
        Merb.environment_info[:merged_envs] << env
        
        env_file = Merb.dir_for(:config) / "environments" / ("#{env}.rb")
        if File.exists?(env_file)
          load(env_file)
        else
          Merb.logger.warn! "Environment file does not exist! #{env_file}"
        end
      end
      
      # Mark specific environment to load when ORM loads,
      # if multiple environments are loaded, the last one
      # with use_db as TRUE will be loaded
      if use_db
        Merb.environment_info[:db_env] = env
      end
    end

    # Start Merb by setting up the Config and then starting the server.
    # Set the Merb application environment and the root path.
    #
    # @param [String, Hash] argv The config arguments to start Merb with.
    #
    # @api public
    def start(argv = ARGV)
      Merb::Config[:original_log_stream] = Merb::Config[:log_stream]
      Merb::Config[:log_stream] ||= STDOUT
      if Hash === argv
        Merb::Config.setup(argv)
      elsif !argv.nil?
        Merb::Config.parse_args(argv)
      end

      # Keep information that we run inside IRB to guard it against overriding in init.rb
      @running_irb = Merb::Config[:adapter] == 'irb'

      Merb::Config[:log_stream] = STDOUT
      
      Merb.environment = Merb::Config[:environment]
      Merb.root = Merb::Config[:merb_root]

      case Merb::Config[:action]
      when :kill
        Merb::Server.kill(Merb::Config[:port], 2)
      when :kill_9
        Merb::Server.kill(Merb::Config[:port], 9)
      when :fast_deploy
        Merb::Server.kill("main", "HUP")
      else
        Merb::Server.start(Merb::Config[:port], Merb::Config[:cluster])
        @started = true
      end
    end

    # Start the Merb environment, but only if it hasn't been loaded yet.
    #
    # @param [String, Hash] argv The config arguments to start Merb with.
    #
    # @api public
    def start_environment(argv=ARGV)
      start(argv) unless (@started ||= false)
    end

    # Restart the Merb environment explicitly.
    #
    # @param [String, Hash] argv The config arguments to restart Merb with.
    #   Given values are merged over the contents of `Merb::Config`.
    #
    # @api public
    def restart_environment(argv={})
      @started = false
      start_environment(Merb::Config.to_hash.merge(argv))
    end

    # @api public
    attr_accessor :environment, :adapter
    # @api private
    attr_accessor :load_paths, :environment_info, :started

    # @api public
    alias :env :environment
    # @api public
    alias :started? :started

    Merb.load_paths = Dictionary.new { [Merb.root] } unless Merb.load_paths.is_a?(Dictionary)

    # Set up your application layout.
    #
    # There are three application layouts in Merb:
    #
    # 1. Regular app/:type layout of Ruby on Rails fame:
    #
    #    * `app/models`      for models
    #    * `app/mailers`     for mailers (special type of controllers)
    #    * `app/parts`       for parts, Merb components
    #    * `app/views`       for templates
    #    * `app/controllers` for controller
    #    * `lib`             for libraries
    #
    # 2. Flat application layout:
    #
    #    * `application.rb`      for models, controllers, mailers, etc
    #    * `config/init.rb`      for initialization and router configuration
    #    * `config/framework.rb` for framework and dependencies configuration
    #    * `views`               for views
    #
    # 3. Camping-style "very flat" application layout, where the whole Merb
    #    application and configs are contained within a single file.
    #
    # Autoloading for lib uses an empty glob by default. If you want to
    # have your libraries under lib use autoload, add the following to Merb
    # init file:
    #
    #     Merb.push_path(:lib, Merb.root / "lib", "**/*.rb") # glob set explicity.
    #
    # Then `lib/magicwand/lib/magicwand.rb` with MagicWand module will
    # be autoloaded when you first access that constant.
    #
    # @example Custom application structure
    #     # This method gives you a way to build up your own application
    #     # to reflect the structure Rails uses to simplify transition of
    #     # legacy application, you can set it up like this:
    #
    #     Merb.push_path(:model,      Merb.root / "app" / "models",      "**/*.rb")
    #     Merb.push_path(:mailer,     Merb.root / "app" / "models",      "**/*.rb")
    #     Merb.push_path(:controller, Merb.root / "app" / "controllers", "**/*.rb")
    #     Merb.push_path(:view,       Merb.root / "app" / "views",       "**/*.rb")
    #
    # @param [Symbol] type The type of path being registered, e.g., `:view`
    # @param [String] path The full path
    # @param [String] file_glob A glob that will be used to autoload files
    #   under the path.
    #
    # @api public
    def push_path(type, path, file_glob = "**/*.rb")
      enforce!(type => Symbol)
      load_paths[type] = [path, file_glob]
    end

    # Removes given types of application components from load path Merb
    # uses for autoloading.
    #
    # This can for example be used to make Merb use app/models for mailers
    # just like Ruby on Rails does, when used together with {Merb::GlobalHelpers.push_path},
    # by making your Merb application use legacy Rails application components:
    #
    #     Merb.root = "path/to/legacy/app/root"
    #     Merb.remove_paths(:mailer)
    #     Merb.push_path(:mailer, Merb.root / "app" / "models", "**/*.rb")
    #
    # @param [Array<Symbol>] *args Component names, e.g., `[:views, :models]`
    #
    # @api public
    def remove_paths(*args)
      args.each {|arg| load_paths.delete(arg)}
    end

    # Get the directory for a given type
    #
    # @param [Symbol] type The type of path to retrieve directory for,
    #   e.g., +:view+.
    #
    # @return [String] The directory for the requested type.
    #
    # @api public
    def dir_for(type)
      Merb.load_paths[type].first
    end

    # Get the path glob for a given type.
    #
    # @param [Symbol] type The type of path to retrieve glob for, e.g. :view.
    #
    # @return [String] The pattern with which to match files within the type directory.
    #
    # @api public
    def glob_for(type)
      Merb.load_paths[type][1]
    end

    # Get the Merb root path.
    #
    # @api public
    def root
      @root || Merb::Config[:merb_root] || File.expand_path(Dir.pwd)
    end

    # Set the Merb root path.
    #
    # @param [String] value Path to the root directory.
    #
    # @api public
    def root=(value)
      @root = value
    end

    # Expand a relative path.
    #
    # Given a relative path or a list of path components, returns an
    # absolute path within the application.
    #
    #     Merb.root = "/home/merb/app"
    #     Merb.path("images") # => "/home/merb/app/images"
    #     Merb.path("views", "admin") # => "/home/merb/app/views/admin"
    #
    # @param [String] *path The relative path (or list of path components)
    #   to a directory under the root of the application.
    #
    # @return [String] The full path including the root.
    #
    # @api public
    def root_path(*path)
      File.join(root, *path)
    end

    # Return the Merb Logger object for the current thread.
    # Set it up if it does not exist.
    # 
    # @api public
    def logger
      Thread.current[:merb_logger] ||= Merb::Logger.new
    end

    # Removes the logger for the current thread (nil).
    #
    # @api public
    def reset_logger!
      Thread.current[:merb_logger] = nil
    end

    # Get the IO object used for logging.
    #
    # If this Merb instance is not running as a daemon or with forced
    # logging to file, this will return +STDOUT+.
    #
    # @return [IO] Stream for log output.
    #
    # #### Notes
    # When Merb.testing? the port is modified to become :test - this keeps this
    # special environment situation from ending up in the memoized @streams
    # just once, thereby never taking changes into account again. Now, it will
    # be memoized as :test - and just logging to merb_test.log.
    #
    # @api public
    def log_stream(port = "main")
      port = :test if Merb.testing?
      @streams ||= {}
      @streams[port] ||= begin
        log = if Merb.testing?
          log_path / "merb_test.log"
        elsif !Merb::Config[:daemonize] && !Merb::Config[:force_logging]
          STDOUT
        else
          log_path / "merb.#{port}.log"
        end
        
        if log.is_a?(IO)
          stream = log
        elsif File.exist?(log)
          stream = File.open(log, (File::WRONLY | File::APPEND))
        else
          FileUtils.mkdir_p(File.dirname(log))
          stream = File.open(log, (File::WRONLY | File::APPEND | File::CREAT))
          stream.write("#{Time.now.httpdate} #{Merb::Config[:log_delimiter]} " \
            "info #{Merb::Config[:log_delimiter]} Logfile created\n")
        end
        stream.sync = true
        stream
      end
    end

    # Get the path to the directory containing the current log file.
    #
    # @return [String]
    #
    # @api public
    def log_path
      case Merb::Config[:log_file]
      when String then File.dirname(Merb::Config[:log_file])
      else Merb.root_path("log")
      end
    end

    # Get the path of root directory of the Merb framework.
    #
    # @return [String]
    #
    # @api public
    def framework_root
      @framework_root ||= File.dirname(__FILE__)
    end

    # Get the regular expression against which deferred actions are
    # matched by Rack application handler.
    #
    # @return [RegExp]
    #
    # #### Notes
    # Concatenates :deferred_actions configuration option values.
    # 
    # @api public
    def deferred_actions
      @deferred ||= begin
        if Merb::Config[:deferred_actions].empty?
          /^\0$/
        else
          /#{Merb::Config[:deferred_actions].join("|")}/
        end
      end
    end

    # Perform a hard Exit.
    #
    # Print a backtrace to the merb logger before exiting if verbose is enabled.
    #
    # @api private
    def fatal!(str, e = nil)
      Merb::Config[:log_stream] = STDOUT if STDOUT.tty?
      Merb.reset_logger!

      Merb.logger.fatal!
      Merb.logger.fatal!("\e[1;31;47mFATAL: #{str}\e[0m")
      Merb.logger.fatal!

      print_colorized_backtrace(e) if e && Merb::Config[:verbose]

      if Merb::Config[:show_ugly_backtraces]
        raise e
      else
        exit(1)
      end
    end

    # Print a colorized backtrace to the merb logger.
    #
    # @api private
    def print_colorized_backtrace(e)      
      e.backtrace.map! do |line|
        line.gsub(/^#{Merb.framework_root}/, "\e[34mFRAMEWORK_ROOT\e[31m")
      end
      
      Merb.logger.fatal! "\e[34mFRAMEWORK_ROOT\e[0m = #{Merb.framework_root}"
      Merb.logger.fatal!
      Merb.logger.fatal! "\e[31m#{e.class}: \e[1;31;47m#{e.message}\e[0m"
      e.backtrace.each do |line|
        Merb.logger.fatal! "\e[31m#{line}\e[0m"
      end      
    end

    # Set up default variables under Merb
    attr_accessor :klass_hashes, :orm, :test_framework, :template_engine

    # Returns the default ORM for this application. For instance, `:datamapper`.
    #
    # @return [Symbol] Default ORM.
    #
    # @api public
    def orm
      @orm ||= :none
    end

    # @deprecated
    def orm_generator_scope
      Merb.logger.warn!("WARNING: Merb.orm_generator_scope is deprecated!")
      return :merb_default if Merb.orm == :none
      Merb.orm
    end

    # Returns the default test framework for this application. For instance `:rspec`.
    #
    # @return [Symbol] Default test framework.
    #
    # @api public
    def test_framework
      @test_framework ||= :rspec
    end

    # @deprecated
    def test_framework_generator_scope
      Merb.logger.warn!("WARNING: Merb.test_framework_generator_scope is deprecated")
      Merb.test_framework
    end

    # Returns the default template engine for this application. For instance `:haml`.
    #
    # @return [Symbol] Default template engine.
    #
    # @api public
    def template_engine
      @template_engine ||= :erb
    end

    Merb.klass_hashes = []

    # Check if Merb is running as an application with bundled gems.
    #
    # @return [Boolean] True if Merb is running as an application with bundled gems.
    #
    # #### Notes
    # Bundling required gems makes your application independent from the 
    # environment it runs in. It is a good practice to freeze application 
    # framework and gems and is very useful when application is run in 
    # some sort of sandbox, for instance, shared hosting with preconfigured gems.
    #
    # @api public
    def bundled?
      $BUNDLE || ENV.key?("BUNDLE")
    end

    # Check if verbose logging is enabled.
    #
    # @return [Boolean] True if Merb is running in debug or verbose mode
    #
    # @api public
    def verbose_logging?
      (ENV['DEBUG'] || $DEBUG || Merb::Config[:verbose]) && Merb.logger
    end

    # Load configuration and assign the logger.
    #
    # @param [Hash] options Options to pass on to the Merb config.
    # @option options [String] :host (0.0.0.0) Host to bind to.
    # @option options [Fixnum] :port (4000) Port to run Merb application on.
    # @option options [String] :adapter ("runner") Name of Rack adapter to use.
    # @option options [String] :rackup ("rack.rb") Name of Rack init file to use.
    # @option options [Boolean] :reload_classes (true) Whether Merb should reload
    #   classes on each request.
    # @option options [String] :environment ("development") Name of environment to use.
    # @option options [String] :merb_root (Dir.pwd) Merb application root.
    # @option options [Boolean] :use_mutex (true) Turns action dispatch
    #   synchronization on or off.
    # @option options [String] :log_delimiter (" ~ ")What Merb logger uses as
    #   delimiter between message sections.
    # @option options [Boolean] :log_auto_flush (true) Whether the log should
    #   automatically flush after new messages are added.
    # @option options [IO] :log_stream (STDOUT) IO handle for logger.
    # @option options [String] :log_file File path for logger. Overrides `:log_stream`.
    # @option options [Symbol] :log_level (:info) Logger level.
    # @option options [Array(Symbol)] :disabled_components ([]) Array of disabled
    #   component names, for instance, to disable json gem, specify :json.
    # @option options [Array(Symbol, String)] :deferred_actions ([]) Names of
    #   actions that should be deferred no matter what controller they
    #   belong to.
    #
    # Some of these options come from command line on Merb
    # application start, some of them are set in Merb init file
    # or environment-specific.
    #
    # @api public
    def load_config(options = {})
      Merb::Config.setup(Merb::Config.defaults.merge(options))
      Merb::BootLoader::Logger.run
    end

    # Load all basic dependencies (selected BootLoaders only).
    # This sets up Merb framework component paths
    # (directories for models, controllers, etc) using
    # framework.rb or default layout, loads init file
    # and dependencies specified in it and runs before_app_loads hooks.
    #
    # @param [Hash] options Options to pass on to the Merb config.
    #
    # @api public
    def load_dependencies(options = {})
      load_config(options)
      Merb::BootLoader::BuildFramework.run
      Merb::BootLoader::Dependencies.run
      Merb::BootLoader::BeforeAppLoads.run
    end

    # Reload application and framework classes.
    # See {Merb::BootLoader::ReloadClasses} for details.
    #
    # @api public
    def reload
      Merb::BootLoader::ReloadClasses.reload
    end

    # Check if running in a testing environment.
    #
    # @return [Boolean] True if Merb environment is testing for instance,
    #   Merb is running with RSpec, Test::Unit of other testing facility.
    #
    # @api public
    def testing?
      $TESTING ||= env?(:test) || Merb::Config[:testing]
    end

    # Check if Merb is running in a specified environment.
    #
    #     Merb.env                 #=> production
    #     Merb.env?(:production)   #=> true
    #     Merb.env?(:development)  #=> false
    #
    # @param [Symbol, Strinig] env Name of the environment to query
    #
    # @api public
    def env?(env)
      Merb.env == env.to_s
    end

    # If block was given configures using the block.
    #
    #     Merb.config do
    #       beer               "good"
    #       hashish            :foo => "bar"
    #       environment        "development"
    #       log_level          "debug"
    #       use_mutex          false
    #       exception_details  true
    #       reload_classes     true
    #       reload_time        0.5
    #     end
    #
    # @param &block Configuration parameter block, see example below.
    #
    # @return [Hash] The current configuration.
    #
    # #### Notes
    # See {Merb::GlobalHelpers.load_config} for configuration
    # options list.
    #
    # @api public
    def config(&block)
      Merb::Config.configure(&block) if block_given?
      Config
    end

    # Disables the given core components, like a Gem for example.
    #
    # @param *args One or more symbols of Merb internal components.
    #
    # @api public
    def disable(*components)
      disabled_components.push(*components)
    end

    # Set disabled components.
    #
    # @param [Array] components All components that should be disabled.
    #
    # @api public
    def disabled_components=(components)
      disabled_components.replace components
    end

    # @return [Array] All components that have been disabled.
    #
    # @api public
    def disabled_components
      Merb::Config[:disabled_components] ||= []
    end

    # @param [Symbol] *components One or more component names
    # @return [Boolean] True if all components (or just one) are disabled.
    # @todo Is the param description right? (Type)
    #
    # @api public
    def disabled?(*components)
      components.all? { |c| disabled_components.include?(c) }
    end

    # Find out what paths Rakefiles are loaded from.
    #
    # @return [Array(String)] Paths Rakefiles are loaded from.
    #
    # @api public
    def rakefiles
      @rakefiles ||= []
    end

    # Find out what paths generators are loaded from.
    #
    # @return [Array(String)] Paths generators are loaded from.
    #
    # @api public
    def generators
      @generators ||= []
    end

    # Add Rakefiles load path for plugins authors.
    #
    # @param [String] *rakefiles One or more Rakefile path(s) to add to
    #   the list of Rakefiles.
    #
    # @api public
    def add_rakefiles(*rakefiles)
      @rakefiles ||= []
      @rakefiles += rakefiles
    end

    # Add Generator load paths for plugin authors.
    #
    # @param [String] *generators One or more Generator path(s) to add
    #   to the list of generators.
    #
    # @api public
    def add_generators(*generators)
      @generators ||= []
      @generators += generators
    end

    # Install a signal handler for a given signal unless signals have
    # been disabled with Merb.disable(:signals)
    #
    # @param signal The name of the signal to install a handler for.
    # @param &block The block to be run when the given signal is received.
    #
    # @api public
    def trap(signal, &block)
      if Signal.list.include?(signal)
        Kernel.trap(signal, &block) unless Merb.disabled?(:signals)
      end
    end

    # @api plugin
    def forking_environment?
      !on_windows? && !on_jruby?
    end

    # @api plugin
    def on_jruby?
      RUBY_PLATFORM =~ Merb::Const::JAVA_PLATFORM_REGEXP
    end

    # @api plugin
    def on_windows?
      RUBY_PLATFORM =~ Merb::Const::WIN_PLATFORM_REGEXP
    end

    def run_later(&blk)
      Merb::Dispatcher.work_queue << blk
    end

    # @api private
    def running_irb?
      @running_irb
    end
  end
end

require "merb-core/autoload"
require "merb-core/server"
require "merb-core/gem_ext/erubis"
require "merb-core/logger"
require "merb-core/version"
require "merb-core/controller/mime"

# Set the environment if it hasn't already been set.
Merb.environment ||= ENV["MERB_ENV"] || Merb::Config[:environment] || (Merb.testing? ? "test" : "development")
