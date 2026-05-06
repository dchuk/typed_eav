# frozen_string_literal: true

module TypedEAV
  class Engine < ::Rails::Engine
    isolate_namespace TypedEAV

    initializer "typed_eav.autoload" do
      require_relative "column_mapping"
      require_relative "config"
      require_relative "registry"
      # Eager-loaded (not autoloaded) — Phase 04 versioning will register on
      # EventDispatcher at engine boot, before any model reference triggers
      # autoload. Without this require_relative, Phase 04's engine-time
      # `register_internal_value_change` call would const-resolve the module
      # for the first time and run a fresh `@value_change_internals = []`
      # AFTER versioning had already pushed onto a different instance.
      require_relative "event_dispatcher"
    end

    # Make `has_typed_eav` available on all ActiveRecord models
    initializer "typed_eav.active_record" do
      ActiveSupport.on_load(:active_record) do
        include TypedEAV::HasTypedEAV
      end
    end

    # Phase 04 versioning subscriber registration.
    #
    # CONDITIONAL on TypedEAV.config.versioning. When false (the default
    # for apps that don't enable versioning), no subscriber is registered:
    # zero callable in EventDispatcher.value_change_internals, zero per-write
    # dispatch overhead, zero config reads on the hot path. This is the
    # locked CONTEXT contract — line 17 says "zero overhead for apps that
    # don't use versioning", which means literally no callable, not "callable
    # that early-returns".
    #
    # We use `config.after_initialize` rather than a Rails `initializer` block
    # because we need to consult host-set config values. The host's
    # `config/initializers/typed_eav.rb` runs AFTER all engine initializers
    # but BEFORE `config.after_initialize`. By the time this block fires,
    # `TypedEAV.config.versioning` reflects the host's chosen value (or the
    # default `false` if the host never touched it).
    #
    # Trade-off (documented in 04-02-PLAN §Plan-time decisions §6): apps
    # that toggle `c.versioning = true` at runtime AFTER `after_initialize`
    # has fired (e.g., a Rails console session that monkey-patches Config,
    # or a feature-flag flip mid-process) will NOT get versioning until
    # process restart. Runtime toggle is not a documented use case — adding
    # a register/deregister API is out of scope for Phase 04. The Risk §1
    # late-toggle concern from RESEARCH is acceptably narrowed by this
    # trade-off.
    #
    # Slot 0 ordering: Phase 07 (future matview) will register its
    # subscriber via its own `config.after_initialize` block declared LATER
    # in this same engine file. Rails runs `after_initialize` blocks in
    # declaration order within a single Engine class, so versioning's block
    # fires first → slot 0. The regression spec (plan 04-03 P03) is the
    # ongoing guard.
    #
    # Why a one-line callable to a class method (not inline registration):
    # `TypedEAV::Versioning.register_if_enabled` is the testable seam. The
    # slot-0 regression spec (plan 04-03 P03) and the zero-overhead
    # verification spec (this plan, subscriber_spec) cannot reboot the Rails
    # process inside RSpec — but they CAN call the helper directly against
    # a fresh internals array to exercise both branches (versioning on/off)
    # in-process. Inlining the `if` here would force tests to either reboot
    # the engine or use brittle private-block extraction.
    config.after_initialize do
      TypedEAV::Versioning.register_if_enabled
    end

    # Phase 05 Active Storage soft-detect (Gating Decision 1).
    #
    # Mirrors the acts_as_tenant precedent (Config::DEFAULT_SCOPE_RESOLVER
    # in lib/typed_eav/config.rb lines 49-53): the gem detects without
    # requiring. When ActiveStorage::Blob is not defined at this point in
    # boot, has_one_attached is NOT registered on TypedEAV::Value — apps
    # that don't use Image/File field types pay zero overhead, AND the
    # gemspec stays free of an activestorage hard-dependency.
    #
    # When AS IS loaded (Rails 7.1+ with the rails meta-gem, or an
    # explicit `gem 'activestorage'` line), TypedEAV::Value gains a
    # single :attachment has_one_attached association that covers BOTH
    # Field::Image and Field::File typed Values. The Image vs File
    # distinction at runtime is `value.field.is_a?(Field::Image)` (used
    # by the on_image_attached dispatcher on TypedEAV::Value); the blob's
    # content_type is the source of truth for image-vs-other-file at
    # render time.
    #
    # Why a single shared association (not :image_attachment +
    # :file_attachment): TypedEAV::Value is a monolithic table — every
    # Value row gets every association declared on the class. Two
    # associations would double the AR association overhead on every
    # Value row (Text, Integer, etc.), even when no attachment is in
    # play. RESEARCH §Risk 3 documents this rationale.
    #
    # Second after_initialize block (versioning's is the first): Rails
    # runs after_initialize blocks in declaration order within a single
    # Engine class. Versioning's slot-0 dispatcher position at the
    # EventDispatcher level is preserved (dispatcher slots are an
    # EventDispatcher-internal concern; the engine's after_initialize
    # ordering is independent). Phase 07 matview will append its own
    # block after this one.
    #
    # Why a one-line callable to a class method (testable seam): the
    # active_storage_soft_detect_spec cannot reboot Rails inside RSpec
    # to exercise both branches. By extracting the body into
    # `Engine.register_attachment_associations!`, specs call the helper
    # directly with whatever ::ActiveStorage state they need to test.
    # Pattern matches Phase 04's `Versioning.register_if_enabled`.
    config.after_initialize do
      TypedEAV::Engine.register_attachment_associations!
    end

    # Conditionally register the :attachment has_one_attached association
    # on TypedEAV::Value. Idempotent — safe to call multiple times. The
    # idempotency guard (`@attachment_registered`) prevents double-
    # registration when specs invoke the seam in addition to the engine
    # boot path. Without the guard, AR's has_one_attached macro would
    # redefine the association methods (technically harmless but
    # generates RuntimeError noise on duplicate declaration in newer AS
    # versions).
    #
    # Returns truthy on first successful registration, falsy when AS is
    # unloaded or the association is already registered. The return is
    # not part of the public contract — specs that care about the
    # registration outcome inspect TypedEAV::Value.reflect_on_attachment
    # directly.
    def self.register_attachment_associations!
      return false unless defined?(::ActiveStorage::Blob)
      return false if @attachment_registered

      TypedEAV::Value.has_one_attached :attachment
      @attachment_registered = true
    end
  end
end
