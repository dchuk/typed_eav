# frozen_string_literal: true

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
  #
  # Implementation note: class-level accessors are hand-rolled (plain class
  # instance variables behind reader/writer methods) rather than provided by
  # ActiveSupport::Configurable. Configurable was deprecated without
  # replacement in Rails 8.1 and will be removed in Rails 8.2; rolling our
  # own keeps the public API stable across the migration. The `defined?(@var)`
  # idiom on the readers preserves the "never set vs explicitly nil"
  # distinction that callers rely on (e.g., spec_helper's snapshot/restore
  # hook explicitly assigns `nil` and expects the reader to return `nil`,
  # not silently fall through to a default).
  class Config
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
      currency: "TypedEAV::Field::Currency",
      date: "TypedEAV::Field::Date",
      date_time: "TypedEAV::Field::DateTime",
      select: "TypedEAV::Field::Select",
      multi_select: "TypedEAV::Field::MultiSelect",
      percentage: "TypedEAV::Field::Percentage",
      reference: "TypedEAV::Field::Reference",
      integer_array: "TypedEAV::Field::IntegerArray",
      decimal_array: "TypedEAV::Field::DecimalArray",
      text_array: "TypedEAV::Field::TextArray",
      date_array: "TypedEAV::Field::DateArray",
      email: "TypedEAV::Field::Email",
      file: "TypedEAV::Field::File",
      image: "TypedEAV::Field::Image",
      url: "TypedEAV::Field::Url",
      color: "TypedEAV::Field::Color",
      json: "TypedEAV::Field::Json",
    }.freeze

    class << self
      # Mutable registry of type_name => class_name pairs. Seeded from
      # BUILTIN_FIELD_TYPES on first access; extended via register_field_type.
      def field_types
        @field_types ||= BUILTIN_FIELD_TYPES.dup
      end
      attr_writer :field_types # rubocop:disable Style/AccessorGrouping

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
      def scope_resolver
        defined?(@scope_resolver) ? @scope_resolver : DEFAULT_SCOPE_RESOLVER
      end
      attr_writer :scope_resolver # rubocop:disable Style/AccessorGrouping

      # When true, class-level queries on a model that declared
      # `has_typed_eav scope_method: ...` raise `TypedEAV::ScopeRequired`
      # if no scope can be resolved (explicit arg, active `with_scope` block,
      # or configured resolver all returned nil). Bypass per-call via
      # `TypedEAV.unscoped { ... }`.
      def require_scope
        defined?(@require_scope) ? @require_scope : true
      end
      attr_writer :require_scope # rubocop:disable Style/AccessorGrouping

      # Master kill-switch for Phase 04 versioning. When false (default), the
      # Phase 04 internal subscriber is NOT registered with EventDispatcher
      # at engine boot — zero overhead for apps that don't use versioning.
      # When true, the subscriber registers but only writes a version row
      # when value.entity_type belongs to a host model that opted in via
      # `has_typed_eav versioned: true` (per-entity opt-in flows through
      # Registry; both layers land in plan 04-02).
      #
      # Decoupling the master switch from the per-entity decision: disabling
      # for all is one toggle here; enabling for some is a per-host decision
      # in `has_typed_eav`. Apps that want to A/B-test versioning across
      # environments toggle this single flag.
      #
      # Default false because the schema migration only matters for apps that
      # opt in. A v0.1.x deployment that pulls in Phase 04 without changing
      # any config or model declarations sees no behavior change — the
      # subscriber doesn't register, no version rows are written, no perf
      # impact at all. The migration is still copied (idempotent), but the
      # table sits empty.
      def versioning
        defined?(@versioning) ? @versioning : false
      end
      attr_writer :versioning # rubocop:disable Style/AccessorGrouping

      # Permissive actor resolver. Mirrors the `scope_resolver` callable
      # shape (lib/typed_eav.rb:94: `Config.scope_resolver&.call`) but the
      # return contract is permissive: any value the app chooses (AR object,
      # integer, string, nil) is acceptable, and nil is the documented
      # fail-permissive sentinel.
      #
      # Called from TypedEAV::Versioning::Subscriber (plan 04-02) once per
      # version row write: `actor = TypedEAV.config.actor_resolver&.call`.
      # The return is coerced via `normalize_one`-style String coercion
      # (gem's existing pattern at lib/typed_eav.rb:239-243) before storage
      # in the typed_eav_value_versions.changed_by column. nil flows through
      # as nil — the column is nullable (db/migrate/20260505000000).
      #
      # Why permissive (vs. scope_resolver's strict return contract):
      # missing scope is a tenant-isolation hazard (catastrophic, fail-
      # closed). Missing actor is a degraded audit log (recoverable,
      # sometimes legitimate — system writes, migrations, console).
      # Forcing every Versioned write to have an actor would reject every
      # console save, every migration backfill, every job that didn't set
      # `with_context(actor: ...)` — hostile defaults for a gem.
      # 04-CONTEXT.md §"actor_resolver returning nil" locks the permissive
      # contract; apps that need strict enforcement do it inside their own
      # resolver lambda (`-> { Current.user || raise SomeAppError }`).
      #
      # Default nil (no resolver) means every version row's changed_by is
      # nil. Apps wire this up by setting `c.actor_resolver = -> { ... }`
      # in an initializer alongside `c.versioning = true`.
      def actor_resolver
        defined?(@actor_resolver) ? @actor_resolver : nil
      end
      attr_writer :actor_resolver # rubocop:disable Style/AccessorGrouping

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
      attr_accessor :on_value_change

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
      attr_accessor :on_field_change

      # Phase 05 hook: fires from after_commit on TypedEAV::Value when a
      # Field::Image-typed Value gains (or replaces) an attachment. Receives
      # `(value, blob)`. Default nil — no-op when not configured.
      #
      # Hook ordering: fires AFTER versioning (Phase 04) and AFTER
      # on_value_change (Phase 03). The hook is informational ("an image
      # was attached"), not mutational; running it last avoids polluting
      # earlier hooks' snapshots / context with attachment-derived state.
      #
      # Active Storage soft-detect (Gating Decision 1, Phase 05): when
      # Active Storage is not loaded at engine boot, the after_commit
      # dispatcher on TypedEAV::Value short-circuits via the
      # `defined?(::ActiveStorage::Blob)` guard — this accessor exists
      # regardless (set/get is a no-op if no dispatcher fires). Mirrors
      # the on_value_change / on_field_change idiom (plain attr_accessor
      # rather than the hand-rolled `defined?(@var)` reader because the
      # hook contract is "nil means unset"; there is no "explicitly nil
      # vs never set" distinction this hook needs to surface).
      #
      # File-attached has no parallel hook in Phase 05 — the on_image_attached
      # name is image-specific by ROADMAP design. Apps that want a generic
      # file-attached signal use on_value_change (Phase 03) or subscribe to
      # ActiveSupport::Notifications directly.
      attr_accessor :on_image_attached

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
        # Phase 04 versioning master switch + actor resolver. Reset to defaults
        # (false / nil) so test isolation matches `Config.on_value_change` / etc.
        # Internal subscribers (TypedEAV::Versioning::Subscriber, registered
        # at engine load by plan 04-02) are deliberately NOT cleared here —
        # they live on EventDispatcher.value_change_internals and survive
        # Config.reset! by design (the snapshot/restore split is locked at
        # 03-CONTEXT.md §Reset split). Test teardown that needs to clear
        # subscribers too calls EventDispatcher.reset!.
        self.versioning = false
        self.actor_resolver = nil
        # Test isolation: scoping_spec/field_spec/etc. call Config.reset! in
        # `after` hooks — this ensures user procs set in earlier tests don't
        # leak across examples. Internal subscribers
        # (EventDispatcher.value_change_internals/field_change_internals) are
        # deliberately NOT reset here — they're populated at engine load by
        # Phase 04+ and must persist across Config.reset!. Test teardown
        # that needs to clear EVERYTHING calls EventDispatcher.reset! too.
        self.on_value_change = nil
        self.on_field_change = nil
        # Phase 05 image-attached hook (parallel to on_value_change /
        # on_field_change reset for test isolation).
        self.on_image_attached = nil
      end
    end
  end
end
