# frozen_string_literal: true

module TypedFields
  class Value < ApplicationRecord
    self.table_name = "typed_field_values"

    # ── Associations ──

    belongs_to :entity, polymorphic: true, inverse_of: :typed_values
    belongs_to :field,
               class_name: "TypedFields::Field::Base",
               inverse_of: :values

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
      if field
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

    # ── Callbacks ──

    after_initialize :apply_pending_value

    private

    def apply_pending_value
      return unless @pending_value && field

      self.value = @pending_value
      @pending_value = nil
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
    # typed_fields_scope (globals, scope=NULL, remain shared).
    def validate_field_scope_matches_entity
      return unless field && entity
      return if field.scope.nil?
      return unless entity.respond_to?(:typed_fields_scope)

      entity_scope = entity.typed_fields_scope
      return if entity_scope && field.scope == entity_scope.to_s

      errors.add(:field, :invalid)
    end
  end
end
