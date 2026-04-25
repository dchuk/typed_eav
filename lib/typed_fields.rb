# frozen_string_literal: true

require_relative "typed_fields/version"
require_relative "typed_fields/engine"

module TypedFields
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Registry
  autoload :HasTypedFields
  autoload :QueryBuilder

  # Raised when a model declared `has_typed_fields scope_method: ...` but no
  # scope can be resolved at query time and `config.require_scope` is truthy.
  class ScopeRequired < StandardError; end

  THREAD_SCOPE_STACK = :typed_fields_scope_stack
  THREAD_UNSCOPED    = :typed_fields_unscoped
  private_constant :THREAD_SCOPE_STACK, :THREAD_UNSCOPED

  class << self
    def config
      yield Config if block_given?
      Config
    end

    alias configure config

    def registry = Registry

    # Current ambient scope value. Resolution order:
    #   1. Inside `unscoped { }`      → nil (hard bypass)
    #   2. Innermost `with_scope(v)`  → v
    #   3. Configured `scope_resolver` callable
    #   4. nil
    #
    # Returns a string (via normalize), or nil when nothing resolves.
    def current_scope
      return nil if Thread.current[THREAD_UNSCOPED]

      stack = Thread.current[THREAD_SCOPE_STACK]
      return normalize_scope(stack.last) if stack.present?

      normalize_scope(Config.scope_resolver&.call)
    end

    # Run the block with `value` as the ambient scope, restoring the prior
    # stack on exit (exception-safe). Nests cleanly.
    def with_scope(value)
      stack = (Thread.current[THREAD_SCOPE_STACK] ||= [])
      stack.push(value)
      yield
    ensure
      stack&.pop
    end

    # Run the block with scope enforcement disabled. Queries return results
    # across all scopes. Use for admin tools, migrations, and tests.
    def unscoped
      prev = Thread.current[THREAD_UNSCOPED]
      Thread.current[THREAD_UNSCOPED] = true
      yield
    ensure
      Thread.current[THREAD_UNSCOPED] = prev
    end

    # True when inside an `unscoped { }` block.
    def unscoped?
      !!Thread.current[THREAD_UNSCOPED]
    end

    # Coerce resolver/with_scope/explicit-kwarg inputs into the string shape
    # stored in the `scope` column. Accepts raw scalars or AR records.
    def normalize_scope(value)
      return nil if value.nil?

      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end
  end
end
