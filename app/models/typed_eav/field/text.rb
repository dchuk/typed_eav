# frozen_string_literal: true

module TypedEAV
  module Field
    # String-typed field with optional length / pattern guards. Storage,
    # `store_accessor`, numericality validators, `max_gte_min_length`,
    # `validate_pattern_syntax`, and the default `validate_typed_value`
    # (length + pattern) all come from `Field::ValidatedString`. Text adds
    # only `cast` (raw → String).
    class Text < ValidatedString
      # Re-declare value_column to populate Text's own @value_columns class
      # instance variable — Ruby class ivars are NOT inherited through
      # subclass lookup (the same workaround `Field::Percentage` uses
      # against `Field::Decimal`). BC-safe and explicit; STI dispatch is
      # unaffected (the `type` column still stores "TypedEAV::Field::Text").
      value_column :string_value

      def cast(raw)
        [raw&.to_s, false]
      end
    end
  end
end
