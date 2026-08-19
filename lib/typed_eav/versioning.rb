# frozen_string_literal: true

module TypedEAV
  # Transactional versioning namespace. Houses the Subscriber that writes
  # TypedEAV::ValueVersion rows from Value lifecycle callbacks.
  #
  # ## Architecture
  #
  # - TypedEAV::Versioning::Subscriber.call(value, change_type, context)
  #   is conditionally installed on Value's transactional callbacks at engine
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
  # - Errors raised by Subscriber.call propagate. Versioning corruption must
  #   be loud — silent failure leaves the audit log inconsistent with the live
  #   row.
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

    CALLBACKS = {
      create: %i[_write_version_create after].freeze,
      update: %i[_write_version_update after].freeze,
      destroy: %i[_write_version_destroy before].freeze,
    }.freeze

    # Conditionally install the Subscriber on Value's transactional callbacks.
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

      callback_chains = callback_chains_for_installation

      callback_chains.each do |event, (filter, kind, chain)|
        next if chain.any? { |callback| callback.filter == filter && callback.kind == kind }

        TypedEAV::Value.set_callback(event, kind, filter, prepend: true)
      end
    end

    def self.callback_chains_for_installation
      CALLBACKS.to_h do |event, (filter, kind)|
        chain = TypedEAV::Value.send(:get_callbacks, event).to_a
        wrong_kind = chain.find { |callback| callback.filter == filter && callback.kind != kind }
        if wrong_kind
          raise ArgumentError,
                "TypedEAV versioning callback #{filter.inspect} on #{event} has kind " \
                "#{wrong_kind.kind.inspect}; expected #{kind.inspect}"
        end

        [event, [filter, kind, chain]]
      end
    end
    private_class_method :callback_chains_for_installation

    def self.atomic_callbacks_installed?
      CALLBACKS.all? do |event, (filter, kind)|
        TypedEAV::Value.send(:get_callbacks, event).to_a.any? do |callback|
          callback.filter == filter && callback.kind == kind
        end
      end
    end
  end
end
