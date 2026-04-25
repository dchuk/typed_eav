# frozen_string_literal: true

module TypedFields
  module Field
    class DecimalArray < Base
      value_column :json_value
      operators :any_eq, :all_eq, :is_null, :is_not_null

      store_accessor :options, :min_size, :max_size

      def array_field? = true

      # See IntegerArray#cast for the "invalid element → whole value invalid"
      # rationale. Same pattern: any unparseable element marks the cast
      # invalid and stores nil rather than a silently-pruned partial.
      def cast(raw)
        return [nil, false] if raw.nil?

        elements = Array(raw).reject { |v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        casted = elements.map { |v| BigDecimal(v.to_s, exception: false) }
        return [nil, true] if casted.any?(&:nil?) && elements.any?

        [casted.presence, false]
      end

      def validate_typed_value(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
