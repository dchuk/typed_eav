# frozen_string_literal: true

module TypedEAV
  class Value < ApplicationRecord
    self.table_name = "typed_eav_values"

    # Sentinel for distinguishing "no value: kwarg given" from "value: nil
    # given explicitly". Used by Value#initialize (substitutes UNSET_VALUE
    # when the :value kwarg is missing) and Value#value= (treats the
    # sentinel as the trigger to populate field.default_value):
    #
    #   typed_values.create(field: f)             # → triggers default population
    #   typed_values.create(field: f, value: nil) # → stores nil (no default)
    #   typed_values.create(field: f, value: 42)  # → stores 42
    #
    # Mirrors the UNSET_SCOPE / ALL_SCOPES public-sentinel pattern in
    # lib/typed_eav/has_typed_eav.rb (intentionally NOT private_constant —
    # advanced callers may want `val.equal?(TypedEAV::Value::UNSET_VALUE)`
    # checks in their own code). The freeze prevents accidental mutation
    # that would break `.equal?` identity for any caller holding a reference.
    UNSET_VALUE = Object.new.freeze

    # ── Associations ──

    belongs_to :entity, polymorphic: true, inverse_of: :typed_values

    # `field` is optional because the Phase 02 cascade migration changed the
    # FK to ON DELETE SET NULL — orphaned Value rows (`field_id IS NULL`)
    # are an expected outcome when `field_dependent: :nullify` is used.
    # Read-path guards in `InstanceMethods#typed_eav_value` and
    # `#typed_eav_hash` silently skip them; the write-path validators below
    # (`validate_value`, `validate_entity_matches_field`,
    # `validate_field_scope_matches_entity`) all `return unless field`
    # already, so optional belongs_to does not weaken any write-path
    # invariant — see RESEARCH §Area 3 orphan-safety audit.
    belongs_to :field,
               class_name: "TypedEAV::Field::Base",
               inverse_of: :values,
               optional: true

    # Append-only audit log of mutations to this Value. Written by
    # TypedEAV::Versioning::Subscriber (plan 04-02) when the host entity
    # opted into versioning AND `config.versioning = true`. Read via
    # `value.versions.order(changed_at: :desc)` (or the convenience
    # `value.history` alias added in plan 04-03).
    #
    # `dependent: nil` (the implicit AR default) — version rows are
    # preserved when the Value is destroyed (the FK is ON DELETE SET NULL,
    # nulling value_id; the row remains queryable by (entity_type,
    # entity_id, field_id)).
    has_many :versions,
             class_name: "TypedEAV::ValueVersion",
             inverse_of: :value

    # ── Validations ──

    validates :field, uniqueness: { scope: %i[entity_type entity_id] }
    validate :validate_value
    validate :validate_entity_matches_field
    validate :validate_field_scope_matches_entity
    validate :validate_json_size

    # ── Value access ──
    #
    # The magic here is that we delegate to the correct typed column
    # based on what the field type declares. ActiveRecord handles all
    # casting through the column's type (schema-inferred).
    #
    # So `value = "42"` on an integer field writes 42 to integer_value,
    # and `value` reads it back as a Ruby Integer. No custom caster needed
    # for storage - the database column type IS the caster.

    def value
      return nil unless field

      self[value_column]
    end

    def value=(val)
      if val.equal?(UNSET_VALUE)
        # Sentinel branch: caller did NOT pass an explicit `value:` kwarg.
        # Apply the field's configured default if field is already assigned;
        # otherwise stash the sentinel in @pending_value to be resolved later
        # by apply_pending_value (parallel to the explicit-value pending path
        # below). Without this branch, `typed_values.create(field: f)` would
        # silently leave the typed column nil even when the field declares a
        # default — losing the configuration the caller already paid to set.
        if field
          apply_field_default
        else
          @pending_value = UNSET_VALUE
        end
      elsif field
        # Cast through the field type, then write to the native column.
        # Rails will further cast via the column type on save.
        casted, invalid = field.cast(val)
        self[value_column] = casted
        @cast_was_invalid = invalid
      else
        # Field not yet assigned - stash for later
        @pending_value = val
      end
    end

    # Which column this value lives in
    def value_column
      field.class.value_column
    end

    # Append-only audit log of mutations to this Value, ordered most-
    # recent-first. Returns a relation that can be chained (`.where`,
    # `.limit`, `.pluck`).
    #
    # Implemented as an instance method (not `has_many ... -> { order(...) }`)
    # so the ordering is explicit at the call site for documentation
    # purposes — readers see `value.history.first` and know they're getting
    # the most-recent version. Hidden default-scope ordering is harder to
    # discover and easier to accidentally override.
    #
    # Tie-breaks on id when multiple versions share a changed_at (rare —
    # requires same-second writes from concurrent threads or a backfill
    # script that pinned a single timestamp). Without the secondary id
    # ordering, callers iterating `history` after a same-second batch
    # would see non-deterministic order across DB executions.
    #
    # Survives Value destruction: even after `value.destroy!` and the FK
    # nulls value_id on the version rows, the version rows are still
    # queryable via the entity reference. `history` returns nothing in
    # that case (the `versions` association is keyed on value_id and
    # returns no rows when value_id is NULL on all rows). Use
    # `TypedEAV::ValueVersion.where(entity: contact, field_id: field.id).order(changed_at: :desc)`
    # to query orphaned audit history (the README §"Versioning" §"Querying
    # full audit history" subsection documents this fallback).
    def history
      versions.order(changed_at: :desc, id: :desc)
    end

    # Revert this Value's typed columns to the state recorded in
    # `version.before_value`, then save!. The save fires the existing
    # `after_commit :_dispatch_value_change_update` chain; EventDispatcher
    # routes through TypedEAV::Versioning::Subscriber (slot 0); a NEW
    # version row is written where after_value reflects the targeted
    # version's before_value.
    #
    # This is the locked CONTEXT contract (04-CONTEXT.md §`Value#revert_to`
    # semantics): revert is itself versioned. Append-only audit trail
    # preserved. Matches PaperTrail / Audited industry conventions.
    #
    # ## What revert_to does NOT do
    #
    # - Does NOT use `update_columns` to skip callbacks. That would write
    #   the columns silently and produce NO new version row — the audit
    #   log would lose the revert event entirely. The locked CONTEXT
    #   decision is explicit about this.
    # - Does NOT inject a synthetic `reverted_from_version_id` into the
    #   new version row's context. If the caller wants to record the
    #   intent, they wrap the call in `TypedEAV.with_context(
    #   reverted_from_version_id: v.id) { value.revert_to(v) }`. The
    #   subscriber captures the active context as-is.
    # - Does NOT fire if the targeted version's source Value was destroyed
    #   (`version.value_id` is nil per plan 04-02's destroy-event handling).
    #   Raises ArgumentError. Cannot save! a destroyed AR record back into
    #   existence — caller must create a new Value manually using
    #   `version.before_value` as the seed state.
    # - Does NOT fire if the targeted version is a :create (before_value
    #   is `{}` — empty — and there's nothing to revert to). Raises
    #   ArgumentError.
    # - Does NOT cross-Value: raises ArgumentError if `version.value_id !=
    #   self.id`. Cross-Value reverts are a misuse pattern (the caller
    #   passed the wrong record), not a feature.
    #
    # ## Revertable version types
    #
    # Only :update versions are revertable in practice:
    #   - :create → fails empty-before_value check.
    #   - :destroy → fails value_id-nil check (source Value gone).
    #   - :update → succeeds (assuming same-Value).
    # Documented in §Plan-time decisions §A.
    #
    # ## Multi-cell forward-compat
    #
    # Iterates `field.class.value_columns` (plural) to handle Phase 05
    # Currency (and any future multi-cell type). For all 17 current
    # single-cell types, value_columns returns [value_column] and the
    # loop runs once.
    # rubocop:disable Metrics/AbcSize -- three guard clauses (each with a multi-line error message including ids) plus the column-iteration body genuinely belong together; splitting them would obscure the locked check ordering documented above. The ABC complexity is just over the 25 threshold and reflects the explicit error-message construction (not control-flow density).
    def revert_to(version)
      # Check 1: source Value must still exist. plan 04-02's subscriber writes
      # value_id: nil for :destroy events (because the parent typed_eav_values
      # row is gone by after_commit on :destroy time and FK ON DELETE SET NULL
      # would FK-fail at INSERT otherwise). A destroy version cannot be
      # reverted because we can't save! a destroyed AR record back into
      # existence. This check covers all destroy versions.
      if version.value_id.nil?
        raise ArgumentError,
              "Cannot revert version##{version.id}: source Value was destroyed " \
              "(version.value_id is nil). To restore a destroyed entity's typed " \
              "values, create a new Value record manually using version.before_value " \
              "as the seed state."
      end

      # Check 2: version must have a before-state to revert TO. :create
      # versions have empty before_value (`{}` — locked semantic per
      # 04-CONTEXT.md §"Version row jsonb shape"). There is nothing to
      # revert to — the create represents the first state of the Value.
      # Apps that want "revert to initial creation state" semantically want
      # to reset to the field's default value, which is a different operation.
      if version.before_value.empty?
        raise ArgumentError,
              "Cannot revert to version##{version.id}: before_value is empty (this " \
              "version represents a :create event with no before-state). Choose a " \
              "later :update version to revert from."
      end

      # Check 3: cross-Value guard. Caller must pass a version belonging to
      # this Value. Naming both ids in the error message helps inline debug.
      unless version.value_id == id
        raise ArgumentError,
              "Cannot revert Value##{id} to a version belonging to Value##{version.value_id} " \
              "(value_id mismatch). Pass a version returned by #{self.class.name.demodulize}#history."
      end

      # Restore each typed column from the version's before_value snapshot.
      # value_columns (plural) handles multi-cell types like Phase 05 Currency.
      # We use `self[col] = …` (raw column write) instead of `self.value = …`
      # (cast through the field type) because:
      #   1. value.before_value already stores cast values (the subscriber
      #      writes `value[col]` which is the cast value AR returned).
      #   2. self.value = expects the field's "logical" value shape (a single
      #      scalar for single-cell types, a {amount, currency} hash for
      #      Currency in Phase 05). Reconstructing that shape from
      #      before_value's per-column hash adds complexity for zero benefit
      #      since the per-column values are exactly what we need.
      field.class.value_columns.each do |col|
        self[col] = version.before_value[col.to_s]
      end

      save!
    end
    # rubocop:enable Metrics/AbcSize

    # Override AR's initialize so missing `:value` kwarg → UNSET_VALUE
    # substitution. This is the only mechanism that lets us distinguish
    # "no value given" from "value: nil given" (both leave the typed column
    # nil; the difference can only be observed at construction time). The
    # sentinel then flows through `value=` and (if field is unset) into
    # `@pending_value`, where `apply_pending_value` resolves it to the
    # field's configured default once field becomes available.
    #
    # `accepts_nested_attributes_for` paths and `set_typed_eav_value` always
    # pass an explicit `value:` (never missing the key), so they bypass this
    # substitution and continue to behave as before.
    def initialize(attributes = nil, &)
      if attributes.is_a?(Hash)
        attrs = attributes.dup
        attrs[:value] = UNSET_VALUE unless attrs.key?(:value) || attrs.key?("value")
        super(attrs, &)
      elsif defined?(ActionController::Parameters) && attributes.is_a?(ActionController::Parameters)
        # Permitted params hash-like: convert to a plain hash for the key check,
        # then re-pass. Same UNSET_VALUE substitution rule.
        attrs = attributes.to_h
        attrs[:value] = UNSET_VALUE unless attrs.key?(:value) || attrs.key?("value")
        super(attrs, &)
      else
        # nil, scalar, or any other shape AR's initialize accepts unchanged.
        super
      end
    end

    # ── Callbacks ──

    after_initialize :apply_pending_value

    # Phase 03 event dispatch. THREE explicit `after_commit ..., on: :X`
    # declarations rather than the after_create_commit/after_update_commit/
    # after_destroy_commit alias trio: Rails 8.1 has a documented alias
    # collision where reusing the same method name across the alias forms
    # causes only the LAST registration to win (each alias points at
    # `after_commit` internally and the second declaration overwrites the
    # first). The explicit `on:` form sidesteps the bug entirely.
    #
    # Each callback forwards to a private `_dispatch_value_change_*` method
    # that delegates to TypedEAV::EventDispatcher. Models stay thin — all
    # dispatch policy (internal-vs-user proc ordering, error rescue, context
    # injection) lives in EventDispatcher and is unit-testable without AR.
    after_commit :_dispatch_value_change_create,  on: :create
    after_commit :_dispatch_value_change_update,  on: :update
    after_commit :_dispatch_value_change_destroy, on: :destroy

    private

    def apply_pending_value
      return unless @pending_value && field

      if @pending_value.equal?(UNSET_VALUE)
        # Sentinel-pending branch: dispatch directly to apply_field_default.
        # We deliberately do NOT route through `self.value =` here because
        # value= would re-trigger the sentinel branch with field present,
        # giving the same outcome but obscuring the dispatch — keeping the
        # call explicit makes the parallel between value= and this branch
        # easy to follow.
        apply_field_default
      else
        self.value = @pending_value
      end
      @pending_value = nil
    end

    # Writes field.default_value (already cast or nil) directly to the typed
    # column. Does NOT route through value= because field.default_value is
    # already cast via cast(default_value_meta["v"]).first — re-casting
    # would be redundant. Field-side validate_default_value (field/base.rb)
    # catches invalid raw defaults at field save time, so what we read here
    # is always either a castable value or nil.
    def apply_field_default
      default = field.default_value
      self[value_column] = default
    end

    def validate_value
      return unless field

      if @cast_was_invalid
        errors.add(:value, :invalid)
        @cast_was_invalid = false
        return
      end

      val = value

      # Required check. Treat blank strings and empty arrays as missing so
      # required fields can't be saved as effectively empty.
      if field.required? && blank_typed_value?(val)
        errors.add(:value, :blank)
        return
      end

      return if val.nil?

      # Delegate to the field type's own validation (polymorphic dispatch).
      # Each Field::* class implements validate_typed_value(record, val)
      # with its type-specific constraints; shared helpers live on Field::Base.
      field.validate_typed_value(self, val)
    end

    def blank_typed_value?(val)
      return true if val.nil?
      # Whitespace-only strings count as blank even inside arrays so a
      # required TextArray can't slip through with `[" "]` or `["", nil]`.
      return val.all? { |e| blank_array_element?(e) } if val.is_a?(Array)
      return val.strip.empty? if val.is_a?(String)

      false
    end

    def blank_array_element?(element)
      return true if element.nil?
      return element.strip.empty? if element.is_a?(String)

      element.respond_to?(:empty?) && element.empty?
    end

    MAX_JSON_BYTES = 1_000_000 # 1MB
    private_constant :MAX_JSON_BYTES

    def validate_json_size
      return unless field && value_column == :json_value

      val = self[:json_value]
      return if val.nil?

      return unless val.to_json.bytesize > MAX_JSON_BYTES

      errors.add(:value, "is too large (maximum 1MB)")
    end

    def validate_entity_matches_field
      return unless field && entity_type
      return if entity_type == field.entity_type

      errors.add(:entity, :invalid)
    end

    # Cross-tenant guard: when nested attributes let a client submit a raw
    # field_id, the entity_type match above is not enough — another tenant's
    # field with the same entity_type but a different scope would still
    # attach. Reject unless the field's scope matches the entity's
    # typed_eav_scope (globals, scope=NULL, remain shared).
    #
    # Two-axis check: when `field.parent_scope` is set, also enforce that
    # `entity.typed_eav_parent_scope` matches. The Field-level orphan-parent
    # invariant (`Field::Base#validate_parent_scope_invariant`) guarantees
    # `field.parent_scope.present?` implies `field.scope.present?`, so the
    # scope-axis check above has already validated the scope half by the
    # time we reach the parent_scope branch. Same `errors.add(:field, :invalid)`
    # error key/value as today — no new symbol introduced.
    # rubocop:disable Metrics/AbcSize -- two axis-checks (scope + parent_scope) with respond_to? + match guards belong in one validator; splitting would obscure that they share a single error symbol and that the parent_scope branch trusts the Field-level orphan-parent invariant.
    def validate_field_scope_matches_entity
      return unless field && entity

      # Scope axis: skip when the field is global (scope nil). Otherwise the
      # entity must declare typed_eav_scope (host opted into has_typed_eav)
      # and its scope must match the field's.
      if field.scope.present?
        return errors.add(:field, :invalid) unless entity.respond_to?(:typed_eav_scope)

        entity_scope = entity.typed_eav_scope
        return errors.add(:field, :invalid) unless entity_scope && field.scope == entity_scope.to_s
      end

      # Parent-scope axis: only fires when field.parent_scope is set. The
      # `respond_to?(:typed_eav_parent_scope)` check is redundant for hosts
      # that went through `has_typed_eav` (the InstanceMethods mixin defines
      # the method unconditionally now), but kept for the rare path where
      # external code instantiates Value records bypassing has_typed_eav —
      # the same pattern as the scope-axis check above.
      return if field.parent_scope.blank?

      return errors.add(:field, :invalid) unless entity.respond_to?(:typed_eav_parent_scope)

      entity_parent_scope = entity.typed_eav_parent_scope
      return if entity_parent_scope && field.parent_scope == entity_parent_scope.to_s

      errors.add(:field, :invalid)
    end
    # rubocop:enable Metrics/AbcSize

    # ── Phase 03 event dispatch ──
    #
    # All three forwarders short-circuit when `field.nil?` (orphan Value:
    # field_id NULLed by the Phase 02 ON DELETE SET NULL FK when a Field
    # with field_dependent: :nullify was destroyed). The event contract
    # is `(value, change_type, context)` and consumers expect
    # `value.field` to be readable; an orphan would confuse Phase 04
    # versioning and Phase 07 matview consumers, so we drop the event
    # at the model boundary rather than push the nil-guard downstream.
    #
    # Update filter (Phase 04 fix): only fire :update when ANY of the typed
    # columns the field uses changed (value_columns plural — added in
    # plan 04-02). For all 17 single-cell field types as of Phase 04,
    # value_columns returns [value_column], so this is behaviorally
    # identical to the singular form Phase 03 shipped. For Phase 05
    # Currency (two-cell), a change to either column correctly fires the
    # event. Without this fix, Phase 05 Currency would have a latent bug
    # where changes to the second cell alone are silently dropped at the
    # dispatch gate (Scout §3 / Discrepancy D3 from plan 04-01).
    #
    # A Value row's only meaningful change for downstream consumers is
    # its typed columns — field_id repointing or other bookkeeping shifts
    # are out-of-spec for the event contract. Without this filter, Phase 04
    # versioning would pile up no-op version rows (every audit-trail
    # commit) and Phase 07 matview would refresh on bookkeeping-only writes.

    def _dispatch_value_change_create
      return unless field

      TypedEAV::EventDispatcher.dispatch_value_change(self, :create)
    end

    def _dispatch_value_change_update
      return unless field
      # Forward-compat with Phase 05 Currency (and any future multi-cell
      # field type): check if ANY of the typed columns the field uses
      # changed in the just-committed save. Phase 04 plan 02 introduces
      # `value_columns` plural in lib/typed_eav/column_mapping.rb; for
      # all 17 current single-cell types, value_columns returns
      # [value_column], so this filter is behaviorally identical to the
      # prior singular form. For Phase 05 Currency
      # (value_columns → [:decimal_value, :string_value]), a change to
      # either cell now correctly fires the :update event — without this
      # plural fix, a Currency change to only the string_value (currency
      # code) cell would silently be missed by the dispatch gate, and
      # Phase 04 versioning would never see it (Scout §3 / Discrepancy D3
      # from plan 04-01).
      return unless field.class.value_columns.any? { |col| saved_change_to_attribute?(col) }

      TypedEAV::EventDispatcher.dispatch_value_change(self, :update)
    end

    def _dispatch_value_change_destroy
      return unless field

      TypedEAV::EventDispatcher.dispatch_value_change(self, :destroy)
    end
  end
end
