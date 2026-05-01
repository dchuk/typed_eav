# frozen_string_literal: true

require "active_support/inflector"
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "EAV"
end

require_relative "typed_eav/version"
require_relative "typed_eav/engine"

module TypedEAV
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Registry
  autoload :HasTypedEAV
  autoload :QueryBuilder
  autoload :EventDispatcher

  # Raised when a model declared `has_typed_eav scope_method: ...` but no
  # scope can be resolved at query time and `config.require_scope` is truthy.
  class ScopeRequired < StandardError; end

  THREAD_SCOPE_STACK   = :typed_eav_scope_stack
  THREAD_UNSCOPED      = :typed_eav_unscoped
  THREAD_CONTEXT_STACK = :typed_eav_context_stack
  private_constant :THREAD_SCOPE_STACK, :THREAD_UNSCOPED, :THREAD_CONTEXT_STACK

  # Shared frozen Hash returned by `current_context` when no `with_context`
  # block is active. Using a single shared instance avoids allocating a new
  # Hash on every empty-context dispatch (the hot path inside
  # `EventDispatcher.dispatch_value_change` when no with_context block is
  # active). Per locked decision (03-CONTEXT.md, pre-Lead resolution):
  # always-frozen, never bare {}.
  EMPTY_FROZEN_CONTEXT = {}.freeze
  private_constant :EMPTY_FROZEN_CONTEXT

  class << self
    def config
      yield Config if block_given?
      Config
    end

    alias configure config

    def registry = Registry

    # Current ambient scope tuple. Resolution order:
    #   1. Inside `unscoped { }`      → nil (hard bypass)
    #   2. Innermost `with_scope(v)`  → tuple stored on the stack
    #   3. Configured `scope_resolver` callable
    #   4. nil
    #
    # ## Return-value contract (Phase 1, breaking change from v0.1.x)
    #
    # Returns either `nil` (no ambient scope) or a 2-element Array
    # `[scope, parent_scope]` where each element is a String or nil.
    # Never returns a bare scalar.
    #
    # ## scope_resolver contract (strict)
    #
    # The resolver lambda configured via `Config.scope_resolver = ->{ ... }`
    # MUST return either `nil` or a 2-element Array. Both elements may be
    # nil. Any other shape — most importantly a bare scalar (the v0.1.x
    # shape) — raises `ArgumentError` directly inside `current_scope`,
    # BEFORE any normalization is applied. We deliberately do NOT auto-coerce
    # a bare-scalar return into `[scalar, nil]`; the BC-shim path was
    # rejected during Phase 1 design (see `.vbw-planning/phases/01-*/01-CONTEXT.md`
    # § "Deferred Ideas"). The strict raise is the chokepoint that makes
    # the breaking change visible — silent coercion here would hide a
    # contract violation in user-supplied resolver code.
    #
    # `parent_scope` non-nil + `scope` nil (orphan parent) is invalid; the
    # check belongs to model-level validators added by plans 03/04, NOT
    # to this resolver layer. The resolver is a contract surface, not a
    # validation surface.
    #
    # `with_scope(scalar)` block API remains BC-permissive and is a
    # DIFFERENT surface from the resolver-callable contract — see
    # `with_scope` doc and `normalize_scope` doc.
    def current_scope
      return nil if Thread.current[THREAD_UNSCOPED]

      stack = Thread.current[THREAD_SCOPE_STACK]
      # The stack stores tuples already (with_scope normalized on push), so
      # reads bypass normalize_scope entirely — no risk of double-coercion.
      return stack.last if stack.present?

      # Resolver-callable strict-contract path. We deliberately do NOT pass
      # the raw return value through `normalize_scope`, because that helper
      # is permissive (`scalar` → `[scalar, nil]`) for `with_scope` block BC.
      # Routing the resolver through it would silently swallow a contract
      # violation by a custom resolver returning a bare scalar.
      raw = Config.scope_resolver&.call
      return nil if raw.nil?

      unless raw.is_a?(Array) && raw.size == 2
        raise ArgumentError,
              "TypedEAV.config.scope_resolver must return a 2-element " \
              "[scope, parent_scope] Array (or nil). Got: #{raw.inspect}. " \
              "v0.1.x resolvers returning a bare scalar must be updated — " \
              "see CHANGELOG and the README migration note."
      end

      # Tuple shape verified — normalize each slot through the same scalar
      # coercion that `normalize_scope` uses on the with_scope path. We pass
      # the verified 2-element Array through normalize_scope (which is one
      # of its accepted input shapes) to produce the canonical
      # `[String|nil, String|nil]` tuple.
      normalize_scope(raw)
    end

    # Run the block with `value` as the ambient scope, restoring the prior
    # stack on exit (exception-safe). Nests cleanly.
    #
    # ## Accepted input shapes (BC-permissive — public block API)
    #
    # - `with_scope("t1")`            — single-arg BC: pushes `["t1", nil]`.
    # - `with_scope(ar_record)`       — pushes `[ar_record.id.to_s, nil]`.
    # - `with_scope(["t1", "ps1"])`   — Phase 1 tuple form: pushes the tuple.
    # - `with_scope(nil)`             — pushes nil (sentinel: no scope).
    #
    # The single-arg signature `with_scope(value)` keeps its v0.1.x meaning:
    # `scope = value`, `parent_scope = nil`. Apps that have only ever passed
    # a scalar do not need to update on upgrade.
    #
    # The internal stack stores normalized tuples (or nil), NOT raw values,
    # so `current_scope` can return `stack.last` directly without further
    # coercion.
    #
    # NOTE: this is the BC-permissive surface. The strict-contract surface
    # is `Config.scope_resolver` — see `current_scope` doc. Two surfaces,
    # two contracts: `with_scope`'s scalar-OK behavior is BC-preserving;
    # the resolver-callable contract rejects bare scalars.
    def with_scope(value)
      stack = (Thread.current[THREAD_SCOPE_STACK] ||= [])
      stack.push(normalize_scope(value))
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

    # Run the block with `kwargs` merged into the ambient event context,
    # restoring the prior stack on exit (exception-safe). Nests cleanly with
    # shallow per-key merge — outer keys remain visible inside nested blocks
    # unless overridden by name; deep-merge of nested Hash values is NOT
    # promised.
    #
    # The pre-merged hash is FROZEN before being pushed so callbacks invoked
    # downstream (`Config.on_value_change` user proc, internal subscribers)
    # cannot mutate context for the current or outer blocks. Without freeze,
    # a callback that did `ctx[:added] = true` would corrupt the stack for
    # every wrapping block on the same thread.
    #
    # ## Why **kwargs and not positional Hash
    #
    # `def with_context(**kwargs)` enforces the keyword-syntax call form.
    # Per Ruby 3.0+ kwargs/Hash separation, `TypedEAV.with_context({ foo: 1 })`
    # raises ArgumentError ("wrong number of arguments") — the only accepted
    # form is `TypedEAV.with_context(foo: 1)`. Without **kwargs, callers
    # could push arbitrary Hash shapes (including nested Arrays or non-symbol
    # keys) that wouldn't merge cleanly across nesting and wouldn't match
    # the documented context shape that hooks read.
    #
    # See `with_scope` (above) for the parallel ensure-pop pattern. Mirrors
    # `with_scope`'s shape exactly except for: (a) **kwargs vs positional
    # value, (b) merge-into-outer-on-push vs replace-on-push.
    def with_context(**kwargs)
      stack  = (Thread.current[THREAD_CONTEXT_STACK] ||= [])
      merged = (stack.last || EMPTY_FROZEN_CONTEXT).merge(kwargs).freeze
      stack.push(merged)
      yield
    ensure
      stack&.pop
    end

    # Returns the current thread's top-of-stack context Hash, or a shared
    # frozen empty Hash when no `with_context` block is active. The return
    # value is ALWAYS frozen — callers can rely on read-only semantics
    # regardless of whether a block is active. NEVER returns nil.
    def current_context
      Thread.current[THREAD_CONTEXT_STACK]&.last || EMPTY_FROZEN_CONTEXT
    end

    # BC-permissive normalizer for `with_scope` block input and explicit
    # tuple inputs. Always returns either `nil` or a 2-element tuple
    # `[scope, parent_scope]` where each element is a `String` or `nil`.
    #
    # Accepted inputs:
    #
    # - `nil`                          → `nil` (sentinel: nothing resolved).
    # - `[a, b]` (2-element Array)     → `[normalize_one(a), normalize_one(b)]`.
    #   This is the canonical Phase-1 input shape; callers that already have
    #   a tuple (a custom resolver, a future `with_scope([s, ps])`) pass it
    #   through unchanged. `[scope, nil]` is the canonical "scope-only" tuple.
    #   `[nil, "ps1"]` (orphan-parent) is intentionally accepted at this
    #   layer — orphan-parent rejection happens in the model validator
    #   added by plans 03/04, NOT here. Keeping normalize permissive lets
    #   tests construct invalid states intentionally.
    # - any other value (scalar / AR record) → `[normalize_one(value), nil]`.
    #   This is the BC path for `with_scope(scalar)` — single-arg block usage
    #   continues to mean "scope=scalar, parent_scope=nil".
    #
    # ## NOT a contract chokepoint for resolver returns
    #
    # `current_scope` deliberately does NOT route a custom-resolver return
    # value through this helper, because the bare-scalar passthrough above
    # would silently coerce a contract violation. Resolver shape is checked
    # in `current_scope` BEFORE this helper is called. This split — strict
    # on the resolver-callable surface, permissive on the with_scope block
    # surface — is the Phase 1 design.
    def normalize_scope(value)
      return nil if value.nil?
      return [normalize_one(value[0]), normalize_one(value[1])] if value.is_a?(Array) && value.size == 2

      [normalize_one(value), nil]
    end

    private

    # Coerce a single scope slot (scalar or AR record) into a String or nil.
    # The previous v0.1.x scalar-coercion lives here unchanged — we just
    # apply it per-slot now that scope is a tuple.
    def normalize_one(value)
      return nil if value.nil?

      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end
  end
end
