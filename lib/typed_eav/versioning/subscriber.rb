# frozen_string_literal: true

module TypedEAV
  module Versioning
    # The Phase 04 internal subscriber. Conditionally registered with
    # EventDispatcher.register_internal_value_change at engine boot via
    # `TypedEAV::Versioning.register_if_enabled`. When registered, runs
    # at slot 0 of the value-change subscriber chain.
    #
    # ## Contract
    #
    # `call(value, change_type, context)` — called by EventDispatcher.
    # Returns nil (return value is ignored by EventDispatcher; the
    # method's job is the side effect of writing a ValueVersion row).
    #
    # Two-gate short-circuit (the master switch is enforced at
    # registration time, NOT here — when off, this callable is never
    # registered):
    #   1. `value.field` is nil → return nil (orphan guard).
    #   2. `TypedEAV.registry.versioned?(value.entity_type) != true` →
    #      return nil.
    #
    # ## Why a class method (not a class-with-state)
    #
    # The subscriber holds NO instance state — it's a stateless function
    # of (value, change_type, context, gem state). A module method is
    # cheaper to register (single proc reference, no allocation per call)
    # and easier to mock in specs (`allow(Subscriber).to receive(:call)`).
    # If future versions need per-call state (e.g., batching), the call
    # body can construct an instance internally without API change.
    #
    # ## Snapshot logic
    #
    # The before_value / after_value hashes are keyed by typed-column
    # name (locked in 04-CONTEXT.md). For each column in
    # `field.class.value_columns`:
    #   - :create → after = value[col]; before key absent (empty hash).
    #   - :update → before = value.attribute_before_last_save(col);
    #               after = value[col].
    #   - :destroy → before = value[col] (still in-memory on the
    #               destroyed record per Phase 03 P04 live-validation);
    #               after key absent.
    # Column names are stringified for jsonb storage so query patterns
    # like `WHERE before_value->>'integer_value' = '42'` work uniformly
    # regardless of how the subscriber wrote them.
    #
    # ## Actor resolution
    #
    # `TypedEAV.config.actor_resolver&.call` returns an AR record,
    # scalar, or nil. We coerce via the same `respond_to?(:id) ? .id.to_s
    # : .to_s` pattern as lib/typed_eav.rb:239-243 (normalize_one). nil
    # flows through as nil (the typed_eav_value_versions.changed_by
    # column is nullable per 04-CONTEXT.md §"actor_resolver returning
    # nil").
    module Subscriber
      class << self
        # Public entry point. EventDispatcher calls this with the locked
        # 3-arg signature `(value, change_type, context)`.
        #
        # NOTE: there is NO `Config.versioning` gate here. The subscriber
        # is only registered with EventDispatcher when `Config.versioning`
        # was true at engine `config.after_initialize` time (see
        # `TypedEAV::Versioning.register_if_enabled`, invoked from
        # lib/typed_eav/engine.rb's `config.after_initialize` block). If
        # versioning is off, the subscriber is never registered and never
        # reached. The remaining gates are:
        #   1. field-presence (orphan guard — Value's field_id may have
        #      been NULLed by Phase 02's ON DELETE SET NULL cascade).
        #   2. per-entity opt-in (Registry.versioned?).
        def call(value, change_type, context)
          return unless value.field
          return unless TypedEAV.registry.versioned?(value.entity_type)

          write_version_row(value, change_type, context)
        end

        private

        def write_version_row(value, change_type, context)
          # Build before_value / after_value snapshots from value_columns
          # (plural — Phase 05 Currency forward-compat). For all 17
          # current single-cell types, value_columns returns a one-
          # element Array.
          columns = value.field.class.value_columns

          before_value = build_before_snapshot(value, change_type, columns)
          after_value  = build_after_snapshot(value, change_type, columns)

          # CRITICAL: for :destroy events, write `value_id: nil`.
          # By the time `after_commit on: :destroy` fires, the parent row
          # in `typed_eav_values` has already been deleted (Postgres
          # commits the DELETE before invoking after_commit callbacks).
          # The FK is `ON DELETE SET NULL`, but at the moment we INSERT
          # the version row, Postgres validates the FK against the
          # current state of typed_eav_values — which no longer contains
          # the parent. Writing `value.id` (still readable in-memory on
          # the destroyed AR record) would FK-fail at INSERT.
          #
          # The audit trail for destroy events stays queryable via:
          #   - entity_type + entity_id (host record identity)
          #   - field_id (Field is NOT destroyed by Value destruction)
          #   - before_value (snapshot of the columns at destroy time)
          # `field_id` remains populated because destroying a Value does
          # not destroy its Field — `value.field_id` is a live reference.
          #
          # For :create and :update events, `value_id: value.id` is
          # correct (parent row exists at after_commit time).
          version_value_id = change_type == :destroy ? nil : value.id

          # Phase 06 bulk-operations correlation tag. Plan 06-03's
          # `bulk_set_typed_eav_values` API injects a UUID via
          # `TypedEAV.with_context(version_group_id: uuid) { ... }` so every
          # version row produced inside the block shares a single
          # correlation token. Non-bulk writes omit the key, the value
          # falls through as nil, and the column (added in
          # `db/migrate/20260506000001`) stays NULL — backward-compatible:
          # unchanged subscribers and unchanged callers continue to work.
          TypedEAV::ValueVersion.create!(
            value_id: version_value_id,
            field_id: value.field_id,
            entity_type: value.entity_type,
            entity_id: value.entity_id,
            changed_by: resolve_actor,
            before_value: before_value,
            after_value: after_value,
            context: context.to_h, # frozen → unfrozen jsonb-serializable hash
            version_group_id: context[:version_group_id],
            change_type: change_type.to_s,
            changed_at: Time.current,
          )
        end

        def build_before_snapshot(value, change_type, columns)
          case change_type
          when :create
            # No "before" exists — empty hash is the locked semantic for
            # "no recorded value" (distinct from {col: nil} = "recorded
            # nil"). 04-CONTEXT.md §"Version row jsonb shape".
            {}
          when :update
            # `attribute_before_last_save(col)` returns the value as it
            # was BEFORE the just-committed save. For columns that didn't
            # change in this save, returns the current value (no diff —
            # that's fine for the snapshot). For Phase 05 Currency
            # multi-cell, both columns appear in the snapshot regardless
            # of which one changed (snapshot is the full pre-state of the
            # value's typed columns).
            columns.to_h { |col| [col.to_s, value.attribute_before_last_save(col.to_s)] }
          when :destroy
            # The Value record is destroyed but still in-memory at this
            # point (Phase 03 P04 live-validation confirmed value.id and
            # value attributes are readable in after_commit on: :destroy).
            # Snapshot the current values as the "before destroy" state.
            columns.to_h { |col| [col.to_s, value[col]] }
          end
        end

        def build_after_snapshot(value, change_type, columns)
          case change_type
          when :create, :update
            columns.to_h { |col| [col.to_s, value[col]] }
          when :destroy
            # No "after" exists — empty hash, mirror of :create's empty
            # before. Distinct from {col: nil}.
            {}
          end
        end

        def resolve_actor
          actor = TypedEAV.config.actor_resolver&.call
          return nil if actor.nil?

          # Same coercion as lib/typed_eav.rb:239-243 (normalize_one):
          # AR record → id.to_s; scalar → to_s.
          actor.respond_to?(:id) ? actor.id.to_s : actor.to_s
        end
      end
    end
  end
end
