# frozen_string_literal: true

module TypedFields
  module Field
    class Decimal < Base
      value_column :decimal_value

      store_accessor :options, :min, :max, :precision_scale

      validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

      def cast(raw)
        return [nil, false] if raw.nil?
        result = BigDecimal(raw.to_s, exception: false)
        if result.nil?
          return [nil, !raw.to_s.strip.empty?]
        end
        return [result, false] unless precision_scale.present?
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
