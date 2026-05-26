# frozen_string_literal: true

module TypedEAV
  module Field
    # Multi-choice option-set field. Stores the chosen values as a JSON
    # array in `json_value`. Inherits `optionable? = true`, the
    # public-facing sorted `allowed_values` helper, and the protected
    # `validate_multi_option_inclusion` helper from `Field::Optionable`.
    # Stays a direct child of `Field::Base` — Optionable is a concern
    # (mixin), not an intermediate STI class, because Select and
    # MultiSelect don't share a `value_column`.
    #
    # `validate_array_size` is called directly from `Field::Base`
    # (cross-family outlier; also used by `Field::IntegerArray`).
    class MultiSelect < Base
      include Optionable

      value_column :json_value
      operators :any_eq, :all_eq, :is_null, :is_not_null

      def array_field? = true

      def cast(raw)
        return [nil, false] if raw.nil?

        # Rails emits a hidden "" sentinel for `select multiple: true` so an
        # empty submission still round-trips. Drop nil/blank elements here so
        # the inclusion check doesn't reject the form's own placeholder.
        elements = Array(raw).filter_map do |v|
          next nil if v.nil?

          s = v.to_s
          s.strip.empty? ? nil : s
        end
        [elements.presence, false]
      end

      def validate_typed_value(record, val)
        validate_multi_option_inclusion(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
