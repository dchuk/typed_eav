# frozen_string_literal: true

require "active_support/configurable"

module TypedEAV
  # Gem-level configuration for field type registration.
  #
  #   TypedEAV.configure do |c|
  #     c.register_field_type :phone, "MyApp::Fields::Phone"
  #   end
  #
  # Accessible from anywhere via `TypedEAV.config` (which returns this
  # class; class-level `field_types` / `register_field_type` / `field_class_for`
  # / `type_names` methods are defined below).
  class Config
    include ActiveSupport::Configurable

    # Default ambient-scope resolver. Auto-detects `acts_as_tenant` when
    # loaded so AAT users get zero-config behavior. Apps using any other
    # multi-tenancy primitive (Rails `Current` attributes, a subdomain
    # lookup, a thread-local, etc.) override via `TypedEAV.configure`.
    #
    # ## Return-value contract (Phase 1, breaking change from v0.1.x)
    #
    # Returns either `nil` (no resolver / opt-out) or a 2-element Array
    # `[scope, parent_scope]`. The `acts_as_tenant` gem has no
    # `parent_scope` analog, so the parent slot is unconditionally `nil`.
    # When AAT is not loaded we return `nil` (the sentinel: no resolver
    # consulted). When AAT is loaded but `current_tenant` is itself nil
    # we return `[nil, nil]` (the sentinel: AAT consulted, no tenant) —
    # intentionally NOT auto-collapsed to nil, to preserve the distinction
    # between "no resolver" and "resolver returned nothing".
    #
    # ## Migration note for v0.1.x custom resolvers
    #
    # Custom resolver lambdas configured via `Config.scope_resolver = ->{ ... }`
    # MUST be updated to return a 2-element Array `[scope, parent_scope]`
    # (or `nil`). A bare-scalar return — the v0.1.x shape — raises
    # `ArgumentError` from `TypedEAV.current_scope`. The shim alternative
    # (auto-coerce scalar to `[scalar, nil]`) was rejected during Phase 1
    # design; we want the breaking change to be loud, not silent. See the
    # CHANGELOG and README migration section for the upgrade pattern.
    DEFAULT_SCOPE_RESOLVER = lambda {
      next nil unless defined?(::ActsAsTenant)

      [::ActsAsTenant.current_tenant, nil]
    }

    # Map of type names to their STI class names.
    # Add custom types via TypedEAV.configure.
    BUILTIN_FIELD_TYPES = {
      text: "TypedEAV::Field::Text",
      long_text: "TypedEAV::Field::LongText",
      integer: "TypedEAV::Field::Integer",
      decimal: "TypedEAV::Field::Decimal",
      boolean: "TypedEAV::Field::Boolean",
      date: "TypedEAV::Field::Date",
      date_time: "TypedEAV::Field::DateTime",
      select: "TypedEAV::Field::Select",
      multi_select: "TypedEAV::Field::MultiSelect",
      integer_array: "TypedEAV::Field::IntegerArray",
      decimal_array: "TypedEAV::Field::DecimalArray",
      text_array: "TypedEAV::Field::TextArray",
      date_array: "TypedEAV::Field::DateArray",
      email: "TypedEAV::Field::Email",
      url: "TypedEAV::Field::Url",
      color: "TypedEAV::Field::Color",
      json: "TypedEAV::Field::Json",
    }.freeze

    # Mutable registry of type_name => class_name pairs. Seeded from
    # BUILTIN_FIELD_TYPES on first access; extended via register_field_type.
    config_accessor(:field_types) { BUILTIN_FIELD_TYPES.dup }

    # Callable returning the ambient scope (partition key) for class-level
    # queries. Invoked by `TypedEAV.current_scope` when no explicit
    # `scope:` kwarg is passed and no `with_scope` block is active.
    #
    # ## Resolver contract (strict — Phase 1 breaking change)
    #
    # The resolver MUST return either:
    #   - `nil`                              — opt out / no scope to resolve
    #   - `[scope, parent_scope]` 2-Array    — both elements may be `nil`
    #
    # Any other shape — most importantly a bare scalar (the v0.1.x shape) —
    # raises `ArgumentError` in `TypedEAV.current_scope`. There is no
    # auto-coercion. `parent_scope` non-nil + `scope` nil (orphan parent)
    # is rejected by model-level validators (plans 03 / 04), NOT here —
    # this layer is a contract surface, not a validation surface.
    #
    # Note: `TypedEAV.with_scope(value)` is a DIFFERENT surface — its block
    # API is BC-permissive and accepts a scalar. The resolver-callable
    # contract is strict; the `with_scope` block contract is not. Both
    # surfaces, two contracts.
    config_accessor :scope_resolver, default: DEFAULT_SCOPE_RESOLVER

    # When true, class-level queries on a model that declared
    # `has_typed_eav scope_method: ...` raise `TypedEAV::ScopeRequired`
    # if no scope can be resolved (explicit arg, active `with_scope` block,
    # or configured resolver all returned nil). Bypass per-call via
    # `TypedEAV.unscoped { ... }`.
    config_accessor :require_scope, default: true

    # Public single-proc slot for value-change events.
    # Signature: ->(value, change_type, context) { ... }
    # - value:        TypedEAV::Value (the just-committed row)
    # - change_type:  :create | :update | :destroy
    # - context:      Hash (TypedEAV.current_context — frozen)
    #
    # Errors raised inside this proc are rescued by EventDispatcher and
    # logged via Rails.logger.error — they do NOT propagate to the
    # user's save call (the row is already committed). Internal subscribers
    # (Phase 04 versioning, Phase 07 matview) fire BEFORE this proc and
    # their errors DO propagate. See 03-CONTEXT.md §User-callback error policy.
    #
    # Reassignment after gem initialization does NOT disable internal
    # subscribers — those live on EventDispatcher.value_change_internals,
    # not here.
    config_accessor :on_value_change, default: nil

    # Public single-proc slot for field-change events.
    # Signature: ->(field, change_type) { ... }
    # - field:        TypedEAV::Field::Base (or subclass)
    # - change_type:  :create | :update | :destroy | :rename
    #
    # Note: TWO args, no context — asymmetric vs on_value_change by design.
    # Field changes are CRUD-on-config (admin operations on field
    # definitions), not per-entity user actions, so thread context is
    # less relevant. The asymmetry is locked at 03-CONTEXT.md §Phase Boundary.
    #
    # :rename fires when `name` is among Field#saved_changes, even
    # combined with other attr changes (sort_order, options, etc.) —
    # Phase 07 matview needs the rename signal to regenerate column names
    # even when the rename was bundled with other edits.
    config_accessor :on_field_change, default: nil

    class << self
      # Register a custom field type.
      def register_field_type(name, class_name)
        field_types[name.to_sym] = class_name
      end

      # Resolve a type name to its STI class.
      def field_class_for(type_name)
        class_name = field_types[type_name.to_sym]
        raise ArgumentError, "Unknown field type: #{type_name}" unless class_name

        class_name.constantize
      end

      # All registered type names.
      def type_names
        field_types.keys
      end

      # Restore defaults (test isolation).
      def reset!
        self.field_types = BUILTIN_FIELD_TYPES.dup
        self.scope_resolver = DEFAULT_SCOPE_RESOLVER
        self.require_scope = true
        # Test isolation: scoping_spec/field_spec/etc. call Config.reset! in
        # `after` hooks — this ensures user procs set in earlier tests don't
        # leak across examples. Internal subscribers
        # (EventDispatcher.value_change_internals/field_change_internals) are
        # deliberately NOT reset here — they're populated at engine load by
        # Phase 04+ and must persist across Config.reset!. Test teardown
        # that needs to clear EVERYTHING calls EventDispatcher.reset! too.
        self.on_value_change = nil
        self.on_field_change = nil
      end
    end
  end
end
