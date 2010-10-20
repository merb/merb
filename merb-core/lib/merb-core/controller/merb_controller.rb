class Merb::Controller < Merb::AbstractController

  class_inheritable_accessor :_hidden_actions, :_shown_actions, 
                             :_overridable, :_override_bang

  self._hidden_actions ||= []
  self._shown_actions  ||= []
  self._overridable    ||= []
  self._override_bang  ||= []

  cattr_accessor :_subclasses
  self._subclasses = Set.new

  # @api private
  def self.subclasses_list() _subclasses end

  include Merb::ResponderMixin
  include Merb::ControllerMixin
  include Merb::AuthenticationMixin
  include Merb::ConditionalGetMixin

  # @param [Merb::Controller] klass The Merb::Controller inheriting from
  #   the base class.
  #
  # @api private
  def self.inherited(klass)
    _subclasses << klass.to_s
    super
    klass._template_root = Merb.dir_for(:view) unless self._template_root
  end

  # @param [Array<Symbol>] *names Array of method names that should be
  #   overridable in application controllers.
  #
  # @return [Array] The list of methods that are overridable
  #
  # @api plugin
  def self.overridable(*names)
    self._overridable.push(*names)
  end

  # Allow overriding methods.
  #
  # In an application controller, call override! before a method to indicate
  # that you want to override a method in Merb::Controller that is not
  # normally overridable.
  #
  # Doing this may potentially break your app in a future release of Merb,
  # and this is provided for users who are willing to take that risk.
  # Without using override!, Merb will raise an error if you attempt to
  # override a method defined on Merb::Controller.
  #
  # This is to help users avoid a common mistake of defining an action
  # that overrides a core method on Merb::Controller.
  #
  #     class Kontroller < Application
  #       def status
  #         render
  #       end
  #     end
  #
  # will raise a Merb::ReservedError, because {#status} is a method on
  # Merb::Controller.
  #
  #     class Kontroller < Application
  #       override! :status
  #       def status
  #         some_code || super
  #       end
  #     end
  #
  # will not raise a Merb::ReservedError, because the user specifically
  # decided to override the status method.
  #
  # @param [Array<Symbol>] *names An Array of methods that will override
  #   Merb core classes on purpose
  #
  # @api public
  def self.override!(*names)
    self._override_bang.push(*names)
  end

  # Hide each of the given methods from being callable as actions.
  #
  # @param [Array<#to_s>] *names Actions that should be added to the list.
  #
  # @return [Array<String>] Actions that should not be possible
  #   to dispatch to.
  #
  # @api public
  def self.hide_action(*names)
    self._hidden_actions = self._hidden_actions | names.map { |n| n.to_s }
  end

  # Makes each of the given methods being callable as actions. You can use
  # this to make methods included from modules callable as actions.
  #
  # @param [Array<#to_s>] *names Actions that should be added to the list.
  #
  # @return [Array<String>] Actions that should be dispatched to even if
  #   they would not otherwise be.
  #
  # @example Use like:
  #     module Foo
  #       def self.included(base)
  #         base.show_action(:foo)
  #       end
  #
  #       def foo
  #        # some actiony stuff
  #       end
  #
  #       def foo_helper
  #         # this should not be an action
  #       end
  #     end
  #
  # @api public
  def self.show_action(*names)
    self._shown_actions = self._shown_actions | names.map {|n| n.to_s}
  end

  # The list of actions that are callable, after taking defaults,
  # _hidden_actions and _shown_actions into consideration. It is calculated
  # once, the first time an action is dispatched for this controller.
  #
  # @return [SimpleSet<String>] Actions that should be callable.
  #
  # @api public
  def self.callable_actions
    @callable_actions ||= Extlib::SimpleSet.new(_callable_methods)
  end

  # Stub method so plugins can implement param filtering if they want.
  #
  # @param [Hash<Symbol => String>] params Parameters
  #
  # @return [Hash<Symbol => String>] A new list of params, filtered as desired
  #
  # @api plugin
  # @overridable
  def self._filter_params(params)
    params
  end
  overridable :_filter_params

  # All methods that are callable as actions.
  #
  # @return [Array] A list of method names that are also actions.
  #
  # @api private
  def self._callable_methods
    callables = []
    klass = self
    begin
      callables << (klass.public_instance_methods(false) + klass._shown_actions).map{|m| m.to_s} - klass._hidden_actions
      klass = klass.superclass
    end until klass == Merb::AbstractController || klass == Object
    callables.flatten.reject{|action| action =~ /^_.*/}.map {|x| x.to_s}
  end

  # MIME-type aware template locations.
  #
  # This is overridden from AbstractController, which defines a version
  # that does not involve mime-types.
  #
  # @see AbstractController#_template_location
  #
  # #### Notes
  # By default, this renders ":controller/:action.:type". To change this,
  # override it in your application class or in individual controllers.
  #
  # @api public
  # @overridable
  def _template_location(context, type, controller)
    _conditionally_append_extension(controller ? "#{controller}/#{context}" : "#{context}", type)
  end
  overridable :_template_location

  # MIME-type aware template locations.
  #
  # This is overridden from AbstractController, which defines a version
  # that does not involve mime-types.
  #
  # @see AbstractController#_template_location
  #
  # @param [String] template The absolute path to a template, without
  #   mime type and template extension. The mime-type extension is optional
  #   and will be appended from the current content type if it hasn't been
  #   added already.
  # @param [#to_s] type The mime-type of the template that will be rendered.
  #   Defaults to nil.
  #
  # @api public
  def _absolute_template_location(template, type)
    _conditionally_append_extension(template, type)
  end

  # Build a new controller.
  #
  # Sets the variables that came in through the dispatch as available to
  # the controller.
  #
  # @param [Merb::Request] request The Merb::Request that came in from Rack.
  # @param [Integer] status An integer code for the status.
  # @param [Hash<header => value>] headers A hash of headers to start the
  #   controller with. These headers can be overridden later by the #headers
  #   method.
  #
  # @api plugin
  # @overridable
  def initialize(request, status=200, headers={'Content-Type' => 'text/html; charset=utf-8'})
    super()
    @request, @_status, @headers = request, status, headers
  end
  overridable :initialize

  # Call the controller as a Rack endpoint.
  #
  # Expects:
  # * **`env["merb.status"]`:** the default status code to be returned
  # * **`env["merb.action_name"]`:** the action name to dispatch
  # * **`env["merb.request_start"]`:** a `Time` object representing the
  #   start of the request.
  #
  # @param [Hash] env A rack environment
  #
  # @return [Array<Integer, Hash, #each>] A standard Rack response
  #
  # @api public
  def self.call(env)
    new(Merb::Request.new(env), env["merb.status"])._call
  end

  # Dispatches the action and records benchmarks
  #
  # @return [Array<Integer, Hash, #each>] A standard Rack response
  # 
  # @api private
  def _call
    _dispatch(request.env["merb.action_name"])
    _benchmarks[:dispatch_time] = Time.now - request.env["merb.request_start"]
    Merb.logger.info { _benchmarks.inspect }
    Merb.logger.flush
    rack_response        
  end

  # Dispatch the action.
  #
  # Extends {AbstractController#_dispatch} with logging, error handling,
  # and benchmarking.
  #
  # @param [#to_s] action The action to dispatch to.
  #
  # @return [Merb::Controller] self
  # @todo See {AbstractController#_dispatch} and ticket #1335 about the
  #   return type.
  #
  # @raise [ActionNotFound] The requested action was not found in class.
  #
  # @api plugin
  def _dispatch(action=:index)
    Merb.logger.info { "Params: #{self.class._filter_params(request.params).inspect}" }
    start = Time.now
    if self.class.callable_actions.include?(action.to_s)
      super(action)
    else
      raise ActionNotFound, "Action '#{action}' was not found in #{self.class}"
    end
    @_benchmarks[:action_time] = Time.now - start
    self
  end

  # @api public
  attr_reader :request, :headers

  # Response status code.
  #
  # @return [Fixnum]
  #
  # @api public
  def status
    @_status
  end

  # Set the response status code.
  #
  # @param [Fixnum, Symbol] s A status code or named HTTP status
  #
  # @api public
  def status=(s)
    if s.is_a?(Symbol) && STATUS_CODES.key?(s)
      @_status = STATUS_CODES[s]
    elsif s.is_a?(Fixnum)
      @_status = s
    else
      raise ArgumentError, "Status should be of type Fixnum or Symbol, was #{s.class}"
    end
  end

  # The parameters from the request object.
  #
  # @return [Hash]
  #
  # @api public
  def params()  request.params  end

  # Generate URLs.
  #
  # Same as {AbstractController#url}, but allows to pass `:this` as a name
  # to use the name of the current {Request}. All parameters of the current
  # request are also added to the arguments.
  #
  # @see AbstractController#url
  #
  # @api public
  def url(name, *args)
    args << params
    name = request.route if name == :this
    Merb::Router.url(name, *args)
  end

  # Generates a URL for a single or nested resource.
  #
  # Same as {AbstractController#resource}, but all parameters of the current
  # request are also added to the arguments.
  #
  # @see AbstractController#resource
  #
  # @api public
  def resource(*args)
    args << params
    Merb::Router.resource(*args)
  end

  alias_method :relative_url, :url
  
  # Returns the absolute URL including the passed protocol and host.
  #
  # Calls {AbstractController#absolute_url} with the protocol and host
  # options pre-populated from the current request unless explicitly
  # specified.
  #
  # @see AbstractController#absolute_url
  #
  # @api public
  def absolute_url(*args)
    options  = extract_options_from_args!(args) || {}
    options[:protocol] ||= request.protocol
    options[:host] ||= request.host
    args << options
    super(*args)
  end

  # The results of the controller's render, to be returned to Rack.
  #
  # @return [Array<Integer, Hash, String>] The controller's status code,
  #   headers, and body
  #
  # @api private
  def rack_response
    [status, headers, Merb::Rack::StreamWrapper.new(body)]
  end

  # Sets a controller to be "abstract".
  #
  # This controller will not be able to be routed to and is used for super
  # classing only.
  #
  # @api public
  def self.abstract!
    @_abstract = true
  end

  # Asks a controller if it is abstract
  #
  # @return [Boolean] True if the controller has been set as abstract.
  #
  # @api public
  def self.abstract?
    !!@_abstract 
  end

  # Hide any methods that may have been exposed as actions before.
  hide_action(*_callable_methods)

  private

  # If not already added, add the proper mime extension to the template path.
  #
  # @param [#to_s] template The template path to append the mime type to.
  # @param [#to_s] type The extension to append to the template path
  #   conditionally.
  #
  # @api private
  def _conditionally_append_extension(template, type)
    type && !template.match(/\.#{type.to_s.escape_regexp}$/) ? "#{template}.#{type}" : template
  end
  
  # When a method is added to a subclass of Merb::Controller (i.e. an app controller) that
  # is defined on Merb::Controller, raise a Merb::ReservedError. An error will not be raised
  # if the method is defined as overridable in the Merb API.
  #
  # This behavior can be overridden by using `override! method_name` before attempting to
  # override the method.
  #
  # @param [#to_sym] meth The method that is being added
  #
  # @raise [Merb::ReservedError] If the method being added is in a subclass
  #   of Merb::Controller, the method is defined on Merb::Controller, it is
  #   not defined as overridable in the Merb API, and the user has not
  #   specified that it can be overridden.
  #
  # @return [nil]
  #
  # @api private
  def self.method_added(meth)
    if self < Merb::Controller && Merb::Controller.method_defined?(meth) && 
      !self._overridable.include?(meth.to_sym) && !self._override_bang.include?(meth.to_sym)

      raise Merb::ReservedError, "You tried to define #{meth} on " \
        "#{self.name} but it was already defined on Merb::Controller. " \
        "If you meant to override a core method, use override!"
    end
  end
end
