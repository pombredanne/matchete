require 'set'
require_relative 'matchete/exceptions'

module Matchete
  def self.included(klass)
    klass.extend ClassMethods
    klass.instance_variable_set "@methods", {}
    klass.instance_variable_set "@default_methods", {}
  end

  Any = -> (x) { true }
  None = -> (x) { false }

  module ClassMethods
    def on(*args, **kwargs)
      if kwargs.count.zero?
        *guard_args, method_name = args
        guard_kwargs = {}
      else
        method_name = kwargs[:method]
        kwargs.delete :method
        guard_args = args
        guard_kwargs = kwargs
      end
      @methods[method_name] ||= []
      @methods[method_name] << [guard_args, guard_kwargs, instance_method(method_name)]
      convert_to_matcher method_name
    end

    def default(method_name)
      @default_methods[method_name] = instance_method(method_name)
      convert_to_matcher method_name
    end

    # Matches something like sum types:
    # either(Integer, Array)
    # matches both [2] and 2
    def either(*guards)
      -> arg { guards.any? { |g| match_guard(g, arg) } }
    end

    # Matches an exact value
    # useful if you want to match a string starting with '#' or the value of a class
    # exact(Integer) matches Integer, not 2
    def exact(value)
      -> arg { arg == value }
    end

    # Matches property results
    # e.g. having('#to_s': '[]') will match []
    def having(**properties)
      -> arg do
        properties.all? { |prop, result| arg.respond_to?(prop[1..-1]) && arg.send(prop[1..-1]) == result }
      end
    end

    # Matches each guard
    # full_match(Integer, '#value')
    # matches only instances of Integer which respond to '#value'
    def full_match(*guards)
      -> arg { guards.all? { |g| match_guard(g, arg) } }
    end

    def supporting(*method_names)
      -> object do
        method_names.all? do |method_name|
          object.respond_to? method_name
        end
      end
    end

    def convert_to_matcher(method_name)
      define_method(method_name) do |*args, **kwargs|
        call_overloaded(method_name, args: args, kwargs: kwargs)
      end
    end
  end

  def call_overloaded(method_name, args: [], kwargs: {})
    handler = find_handler(method_name, args, kwargs)

    if kwargs.empty?
      handler.bind(self).call *args
    else
      handler.bind(self).call *args, **kwargs
    end
    #insane workaround, because if you have
    #def z(f);end
    #and you call it like that
    #empty = {}
    #z(2, **empty)
    #it raises wrong number of arguments (2 for 1)
    #clean up later
  end

  def find_handler(method_name, args, kwargs)
    guards = self.class.instance_variable_get('@methods')[method_name].find do |guard_args, guard_kwargs, _|
      match_guards guard_args, guard_kwargs, args, kwargs
    end

    if guards.nil?
      default_method = self.class.instance_variable_get('@default_methods')[method_name]
      if default_method
        default_method
      else
        raise NotResolvedError.new("No matching #{method_name} method for args #{args}")
      end
    else
      guards.last
    end
  end

  def match_guards(guard_args, guard_kwargs, args, kwargs)
    return false if guard_args.count != args.count ||
                    guard_kwargs.count != kwargs.count
    guard_args.zip(args).all? do |guard, arg|
      match_guard guard, arg
    end and
    guard_kwargs.all? do |label, guard|
      match_guard guard, kwargs[label]
    end
  end

  def match_guard(guard, arg)
    case guard
      when Module
        arg.is_a? guard
      when Symbol
        if guard.to_s[-1] == '?'
          send guard, arg
        else
          guard == arg
        end
      when Proc
        instance_exec arg, &guard
      when Regexp
        arg.is_a? String and guard.match arg
      when Array
        arg.is_a?(Array) and
        guard.zip(arg).all? { |child_guard, child| match_guard child_guard, child }
      else
        if guard.is_a?(String) && guard[0] == '#'
          arg.respond_to? guard[1..-1]
        else
          guard == arg
        end
    end
  end
end

