# frozen_string_literal: true

module TypedEAV
  # Phase 04 versioning namespace. Houses the Subscriber that writes
  # TypedEAV::ValueVersion rows in response to Value lifecycle events
  # dispatched by EventDispatcher.
  #
  # ## Architecture
  #
  # - TypedEAV::Versioning::Subscriber.call(value, change_type, context)
  #   is conditionally installed on Value's before-write callbacks at engine
  #   boot via `TypedEAV::Versioning.register_if_enabled`. The version row
  #   therefore shares the source transaction.
  #
  # - The subscriber is gated by TWO checks at call time (both must
  #   pass for a version row to be written):
  #     1. value.field is non-nil (orphan guard — Value's field_id may
  #        have been NULLed by Phase 02's ON DELETE SET NULL cascade).
  #     2. TypedEAV.registry.versioned?(value.entity_type) == true
  #        (per-entity opt-in via has_typed_eav versioned: true or
  #        include TypedEAV::Versioned).
  #   The `Config.versioning` master switch is NOT re-checked inside
  #   the callable — when false, the subscriber is never registered in
  #   the first place.
  #
  # - Errors raised by Subscriber.call PROPAGATE per the EventDispatcher
  #   internal-vs-user error policy (03-CONTEXT.md §User-callback error
  #   policy). Versioning corruption must be loud — silent failure
  #   leaves the audit log inconsistent with the live row.
  #
  # ## Public API surface
  #
  # The subscriber itself is gem-internal — apps do not call it directly.
  # The public API is:
  #   - `TypedEAV.config.versioning = true` — master switch.
  #   - `has_typed_eav versioned: true` (or `include TypedEAV::Versioned`) —
  #     per-entity opt-in.
  #   - `TypedEAV.config.actor_resolver = -> { ... }` — actor identification.
  #   - `TypedEAV.with_context(actor: ..., source: ...) { ... }` — request-
  #     scoped audit context.
  #   - `Value#history` and `Value#revert_to(version)` (plan 04-03).
  module Versioning
    # CRITICAL: declare nested autoload for Subscriber explicitly.
    # The top-level `autoload :Versioning` in lib/typed_eav.rb only resolves
    # this namespace shell — it does NOT recursively autoload nested
    # constants. Without the explicit declaration below, the engine's
    # config.after_initialize block (which references
    # `TypedEAV::Versioning::Subscriber`) raises
    # `NameError: uninitialized constant TypedEAV::Versioning::Subscriber`
    # at boot time, breaking every host that enables versioning.
    autoload :Subscriber, "typed_eav/versioning/subscriber"

    # Conditionally install the Subscriber on Value's before-write callbacks.
    # Called by the engine's `config.after_initialize` block.
    #
    # Extracted into a class method (not inlined inside the after_initialize
    # block) for testability: specs can call this seam in-process without
    # booting a second Rails application.
    #
    # Idempotent — safe to call multiple times. Pool validation happens before
    # any callback is installed, so a multi-database misconfiguration fails
    # closed without partial activation.
    #
    # When `TypedEAV.config.versioning` is false (default), this method is
    # a no-op: no callback is installed and the disabled path adds no
    # per-write predicate or dispatcher work.
    def self.register_if_enabled
      return unless TypedEAV.config.versioning

      value_pool = TypedEAV::Value.connection_pool
      version_pool = TypedEAV::ValueVersion.connection_pool
      unless value_pool.equal?(version_pool)
        raise ArgumentError, "TypedEAV versioning requires Value and ValueVersion to share a connection pool"
      end

      return if @callbacks_installed

      TypedEAV::Value.set_callback(:create, :after, :_write_version_create, prepend: true)
      TypedEAV::Value.set_callback(:update, :after, :_write_version_update, prepend: true)
      TypedEAV::Value.set_callback(:destroy, :before, :_write_version_destroy, prepend: true)
      @callbacks_installed = true
    end

    def self.atomic_callbacks_installed?
      @callbacks_installed == true
    end
  end
end
