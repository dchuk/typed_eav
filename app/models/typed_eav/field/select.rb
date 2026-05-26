# frozen_string_literal: true

module TypedEAV
  module Field
    # Single-choice option-set field. Stores the chosen value in
    # `string_value`. Inherits `optionable? = true`, the public-facing
    # sorted `allowed_values` helper, and the protected
    # `validate_option_inclusion` helper from `Field::Optionable`. Stays a
    # direct child of `Field::Base` — Optionable is a concern (mixin), not
    # an intermediate STI class, because Select and MultiSelect don't
    # share a `value_column`.
    class Select < Base
      include Optionable

      value_column :string_value
      operators :eq, :not_eq, :is_null, :is_not_null

      def cast(raw)
        [raw&.to_s, false]
      end

      def validate_typed_value(record, val)
        validate_option_inclusion(record, val)
      end
    end
  end
end
