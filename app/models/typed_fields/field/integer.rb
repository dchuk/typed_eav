# frozen_string_literal: true

module TypedFields
  module Field
    class Integer < Base
      value_column :integer_value

      store_accessor :options, :min, :max

      validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

      def cast(raw)
        return [nil, false] if raw.nil?

        str = raw.to_s.strip
        return [nil, false] if str.empty?

        bd = BigDecimal(str, exception: false)
        return [nil, true] if bd.nil?
        return [nil, true] if bd.frac != 0

        [bd.to_i, false]
      end

      def validate_typed_value(record, val)
        validate_range(record, val)
      end
    end
  end
end
