# frozen_string_literal: true

module TypedFields
  module Field
    class DateTime < Base
      value_column :datetime_value

      store_accessor :options, :min_datetime, :max_datetime

      def cast(raw)
        return [nil, false] if raw.nil?
        return [raw, false] if raw.is_a?(::Time)
        result = ::Time.zone.parse(raw.to_s)
        if result.nil?
          [nil, !raw.to_s.strip.empty?]
        else
          [result, false]
        end
      rescue ArgumentError
        [nil, true]
      end

      def validate_typed_value(record, val)
        validate_datetime_range(record, val)
      end
    end
  end
end
