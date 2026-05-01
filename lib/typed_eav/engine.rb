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
  end
end
