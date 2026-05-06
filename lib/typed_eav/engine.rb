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
  end
end
