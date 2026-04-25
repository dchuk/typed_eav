# frozen_string_literal: true

module TypedFields
  module Field
    class IntegerArray < Base
      value_column :json_value
      operators :any_eq, :all_eq, :is_null, :is_not_null

      store_accessor :options, :min_size, :max_size, :min, :max

      def array_field? = true

      # Cast each element using the scalar-integer parsing rules: strings
      # must look like integers (`/\A-?\d+\z/`). Fractional input like
      # "1.9" is rejected instead of silently truncated to 1.
      #
      # If ANY element fails to cast, mark the whole value invalid and store
      # nil — don't keep a "partially cast" array around, because a failed
      # form re-render would drop the bad elements and confuse the user
      # (they'd see only the good ones and not know why validation fired).
      # This mirrors scalar `Integer#cast` which returns `[nil, true]` on
      # invalid input.
      def cast(raw)
        return [nil, false] if raw.nil?

        elements = Array(raw).reject { |v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        casted = elements.map { |v| cast_integer(v) }
        return [nil, true] if casted.any?(&:nil?) && elements.any?

        [casted.presence, false]
      end

      def validate_typed_value(record, val)
        validate_array_size(record, val)
        validate_element_range(record, val)
      end

      private

      def cast_integer(val)
        return val if val.is_a?(Integer)

        str = val.to_s
        return nil unless str.match?(/\A-?\d+\z/)

        str.to_i
      end

      def validate_element_range(record, val)
        opts = options_hash
        min_val = opts[:min]&.to_d
        max_val = opts[:max]&.to_d
        return unless min_val || max_val

        Array(val).each do |el|
          if min_val && el < min_val
            record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min])
            break
          end
          if max_val && el > max_val
            record.errors.add(:value, :less_than_or_equal_to, count: opts[:max])
            break
          end
        end
      end
    end
  end
end
