# frozen_string_literal: true

module TypedEAV
  # Phase 04 versioning namespace. Houses the Subscriber that writes
  # TypedEAV::ValueVersion rows in response to Value lifecycle events
  # dispatched by EventDispatcher.
  #
  # ## Architecture
  #
  # - TypedEAV::Versioning::Subscriber.call(value, change_type, context)
  #   is conditionally registered with
  #   EventDispatcher.register_internal_value_change at engine boot via
  #   `TypedEAV::Versioning.register_if_enabled`, which is invoked from
  #   the `config.after_initialize` block in lib/typed_eav/engine.rb.
  #   When TypedEAV.config.versioning is false (default), the helper
  #   returns early — no callable is added to the dispatcher chain.
  #   When true, the subscriber registers and runs FIRST in the value-
  #   change subscriber chain (slot 0 by `after_initialize` block
  #   declaration order — Phase 07 will declare its matview block LATER
  #   in the same engine to keep matview at slot ≥ 1).
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
    # `TypedEAV::Versioning::Subscriber.method(:call)`) raises
    # `NameError: uninitialized constant TypedEAV::Versioning::Subscriber`
    # at boot time, breaking every host that enables versioning.
    autoload :Subscriber, "typed_eav/versioning/subscriber"

    # Conditionally register the Subscriber with EventDispatcher's internal
    # value-change subscriber chain. Called by the engine's
    # `config.after_initialize` block (lib/typed_eav/engine.rb).
    #
    # Extracted into a class method (not inlined inside the after_initialize
    # block) for testability: specs can call this against a freshly-cleared
    # `EventDispatcher.value_change_internals` to exercise both branches
    # (versioning on/off) in-process, without booting the engine. The
    # slot-0 regression spec (plan 04-03 P03) and the zero-overhead
    # verification spec (this plan, subscriber_spec engine-boot block) both
    # rely on this seam.
    #
    # Idempotent — safe to call multiple times. Calling twice with
    # versioning on results in exactly ONE entry in
    # `EventDispatcher.value_change_internals`. The idempotency check uses
    # `Array#include?` against `Subscriber.method(:call)`; `Method#==`
    # compares receiver+name (semantic equality), so two fresh
    # `Subscriber.method(:call)` instances compare equal even though they
    # are different Method objects. The engine block runs this exactly
    # once per boot in production; the idempotency guard protects future
    # code paths that might re-invoke for any reason.
    #
    # When `TypedEAV.config.versioning` is false (default), this method is
    # a no-op: zero callable in `value_change_internals`, zero per-write
    # dispatch cost. That is the locked CONTEXT line 17 contract.
    def self.register_if_enabled
      return unless TypedEAV.config.versioning

      method_ref = TypedEAV::Versioning::Subscriber.method(:call)
      return if TypedEAV::EventDispatcher.value_change_internals.include?(method_ref)

      TypedEAV::EventDispatcher.register_internal_value_change(method_ref)
    end
  end
end
