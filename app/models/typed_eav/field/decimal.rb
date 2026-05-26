# frozen_string_literal: true

module TypedEAV
  module Field
    # Decimal-typed field with optional min/max guards and optional
    # `precision_scale` rounding. Declares its own `decimal_value`
    # storage and `:min`/`:max`/`:precision_scale` `store_accessor`; the
    # `validate :max, comparison:` macro guards against inverted bounds
    # at field-save. `validate_range` is inherited from
    # `Field::RangeBounded`. `Field::Percentage` extends this class to
    # add the 0..1 invariant (chain depth becomes
    # `Percentage < Decimal < RangeBounded < Base`).
    class Decimal < RangeBounded
      value_column :decimal_value

      store_accessor :options, :min, :max, :precision_scale

      validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

      def cast(raw)
        return [nil, false] if raw.nil?

        result = BigDecimal(raw.to_s, exception: false)
        return [nil, !raw.to_s.strip.empty?] if result.nil?
        return [result, false] if precision_scale.blank?

        scale = Kernel.Integer(precision_scale, exception: false)
        return [result, false] unless scale && scale >= 0

        [result.round(scale), false]
      end

      def validate_typed_value(record, val)
        validate_range(record, val)
      end
    end
  end
end
