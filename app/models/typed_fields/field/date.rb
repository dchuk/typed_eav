# frozen_string_literal: true

module TypedFields
  module Field
    class Date < Base
      value_column :date_value

      store_accessor :options, :min_date, :max_date

      def cast(raw)
        return [nil, false] if raw.nil?

        casted = raw.is_a?(::Date) ? raw : ::Date.parse(raw.to_s)
        [casted, false]
      rescue ::Date::Error
        [nil, true]
      end

      def validate_typed_value(record, val)
        validate_date_range(record, val)
      end
    end
  end
end
