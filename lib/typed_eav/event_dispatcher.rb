# frozen_string_literal: true

module TypedEAV
  # In-process event-dispatch hub for Value and Field after_commit lifecycle
  # events. Implements the contract that Phase 04 versioning and Phase 07
  # materialized index both depend on.
  #
  # ## Contract surface
  #
  # - `Config.on_value_change` / `Config.on_field_change` are PUBLIC single
  #   proc slots (nil-default), backed by ActiveSupport::Configurable. Users
  #   set them via `TypedEAV.configure { |c| c.on_value_change = ->(...) }`.
  # - `register_internal_value_change(callable)` / `register_internal_field_change(callable)`
  #   are FIRST-PARTY hooks for in-gem features (Phase 04 versioning, Phase 07
  #   matview DDL regen). They are not private_class_method because Phase 04
  #   lives in `TypedEAV::Versioning::*` and cannot reach a truly-private class
  #   method — the `register_internal_*` naming + this comment block signal
  #   first-party-only intent.
  # - Internal subscribers fire FIRST, in registration order. User proc fires
  #   LAST. Phase 04 reserves slot 0 of `value_change_internals` by convention.
  #
  # ## Error policy (split, locked at 03-CONTEXT.md §User-callback error policy)
  #
  # - Internal subscribers: exceptions PROPAGATE (fail-closed). Versioning
  #   corruption must be loud — silent failure leaves typed_eav_value_versions
  #   inconsistent with the live row. Without propagation, Phase 04 bugs
  #   would be invisible until someone audited the version table.
  # - User proc: rescued via `rescue StandardError`, logged via
  #   `Rails.logger.error`, and SWALLOWED. The Value/Field row is already
  #   committed by the time the after_commit fires, so re-raising here would
  #   surface a misleading "save failed" error to the caller — the save
  #   actually succeeded.
  #
  # ## Out of scope for this module
  #
  # - `:rename` detection happens in `Field`'s after_commit callback (the
  #   model has direct access to `saved_change_to_attribute?(:name)`).
  # - Orphan-Value handling (`field.nil?` because the field row was destroyed
  #   in the same transaction) is filtered at the model layer, not here. The
  #   dispatcher receives a guaranteed-non-nil object.
  #
  # See `.vbw-planning/phases/03-event-system/03-CONTEXT.md` for the locked
  # design decisions this module implements.
  module EventDispatcher
    class << self
      # Internal subscribers for Value lifecycle events. Populated at engine
      # boot by Phase 04 versioning (slot 0) and Phase 07 matview (subsequent
      # slots). Exposed as a reader for test introspection — first-party
      # registration goes through `register_internal_value_change`.
      def value_change_internals
        @value_change_internals ||= []
      end

      # Internal subscribers for Field lifecycle events. Same registration
      # protocol as `value_change_internals`.
      def field_change_internals
        @field_change_internals ||= []
      end

      # Register an in-gem value-change subscriber. Called at engine boot by
      # Phase 04 versioning and Phase 07 matview. Subscribers are invoked in
      # registration order with `(value, change_type, context)`. Exceptions
      # raised here PROPAGATE — fail-closed because versioning corruption
      # must be loud. See module-level comment §"Error policy".
      #
      # NOT private_class_method: Phase 04 lives in TypedEAV::Versioning::*
      # and cannot call a truly-private class method. The `register_internal_*`
      # naming + this comment signal first-party-only intent.
      def register_internal_value_change(callable)
        value_change_internals << callable
      end

      # Register an in-gem field-change subscriber. Same first-party-only
      # contract as `register_internal_value_change`. Field subscribers are
      # invoked with `(field, change_type)` — TWO args, no context. The
      # asymmetry vs value-change is locked at 03-CONTEXT.md §Phase Boundary.
      def register_internal_field_change(callable)
        field_change_internals << callable
      end

      # Dispatch a value lifecycle event. Called from `Value#after_commit` in
      # plan 03-02. Internals fire FIRST (raises propagate), then the user
      # proc fires LAST (errors logged + swallowed).
      #
      # Signature: `(value, change_type, TypedEAV.current_context)` for both
      # internals and user proc — context is injected here, not by callers.
      # `change_type` is one of `:create | :update | :destroy`.
      def dispatch_value_change(value, change_type)
        context = TypedEAV.current_context
        # Internals fire first, in registration order. Exceptions propagate —
        # versioning failure (Phase 04) must surface, never be silent.
        value_change_internals.each { |cb| cb.call(value, change_type, context) }

        user = TypedEAV::Config.on_value_change
        return unless user

        # User proc fires last. Wrapped in rescue because the Value row is
        # already committed — re-raising would surface a misleading "save
        # failed" error to the caller. Internal-vs-user error policy split
        # is locked at 03-CONTEXT.md §User-callback error policy.
        begin
          user.call(value, change_type, context)
        rescue StandardError => e
          Rails.logger.error(
            "[TypedEAV] on_value_change raised: #{e.class}: #{e.message} " \
            "(value_id=#{value.id} field_id=#{value.field_id} change_type=#{change_type})",
          )
        end
      end

      # Dispatch a field lifecycle event. Called from `Field#after_commit` in
      # plan 03-02. Same internals-first / user-last ordering and same error
      # policy split as `dispatch_value_change`.
      #
      # Signature: `(field, change_type)` — TWO args, no context. Field
      # changes are CRUD-on-config (admin operations on field definitions),
      # not per-entity user actions, so thread context is less relevant.
      # Asymmetry vs `dispatch_value_change` is intentional and locked.
      # `change_type` is one of `:create | :update | :destroy | :rename`.
      def dispatch_field_change(field, change_type)
        field_change_internals.each { |cb| cb.call(field, change_type) }

        user = TypedEAV::Config.on_field_change
        return unless user

        begin
          user.call(field, change_type)
        rescue StandardError => e
          Rails.logger.error(
            "[TypedEAV] on_field_change raised: #{e.class}: #{e.message} " \
            "(field_id=#{field.id} field_name=#{field.name} change_type=#{change_type})",
          )
        end
      end

      # Clear ONLY the internal-subscribers arrays. Does NOT touch
      # `Config.on_value_change` / `Config.on_field_change` — `Config.reset!`
      # owns the user-proc state.
      #
      # Splitting reset is load-bearing: Phase 04 versioning registers on the
      # internal list at engine load. Calling `EventDispatcher.reset!` must
      # NOT require re-running engine load to restore versioning. Test
      # teardown that needs to clear EVERYTHING calls Config.reset! AND
      # EventDispatcher.reset! — see 03-CONTEXT.md §"Reset split".
      def reset!
        @value_change_internals = []
        @field_change_internals = []
      end
    end
  end
end
