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
    # Update filter: only fire :update when `saved_change_to_attribute?(
    # field.class.value_column)` is true. A Value row's only meaningful
    # change for downstream consumers is the typed column for its field;
    # field_id repointing or other bookkeeping shifts are out-of-spec for
    # the event contract. Without this filter, Phase 04 versioning would
    # pile up no-op version rows (every audit-trail commit) and Phase 07
    # matview would refresh on bookkeeping-only writes.

    def _dispatch_value_change_create
      return unless field

      TypedEAV::EventDispatcher.dispatch_value_change(self, :create)
    end

    def _dispatch_value_change_update
      return unless field
      return unless saved_change_to_attribute?(field.class.value_column)

      TypedEAV::EventDispatcher.dispatch_value_change(self, :update)
    end

    def _dispatch_value_change_destroy
      return unless field

      TypedEAV::EventDispatcher.dispatch_value_change(self, :destroy)
    end
  end
end
