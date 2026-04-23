# frozen_string_literal: true

module TypedFields
  module Field
    class Integer < Base
      value_column :integer_value

      store_accessor :options, :min, :max

      validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

      def cast_value(raw)
        return nil if raw.nil?
        reset_cast_state!
        str = raw.to_s.strip
        bd = BigDecimal(str, exception: false)
        if bd.nil?
          mark_cast_invalid! unless str.empty?
          return nil
        end
        if bd.frac != 0
          mark_cast_invalid!
          return nil
        end
        bd.to_i
      end

      def validate_typed_value(record, val)
        validate_range(record, val)
      end
    end
  end
end
