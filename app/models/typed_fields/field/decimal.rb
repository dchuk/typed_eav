# frozen_string_literal: true

module TypedFields
  module Field
    class Decimal < Base
      value_column :decimal_value

      store_accessor :options, :min, :max, :precision_scale

      validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

      def cast_value(raw)
        return nil if raw.nil?
        reset_cast_state!
        result = BigDecimal(raw.to_s, exception: false)
        if result.nil? && !raw.to_s.strip.empty?
          mark_cast_invalid!
          return nil
        end
        return result unless result && precision_scale.present?
        scale = Kernel.Integer(precision_scale, exception: false)
        return result unless scale && scale >= 0
        result.round(scale)
      end

      def validate_typed_value(record, val)
        validate_range(record, val)
      end
    end
  end
end
