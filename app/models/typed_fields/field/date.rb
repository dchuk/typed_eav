# frozen_string_literal: true

module TypedFields
  module Field
    class Date < Base
      value_column :date_value

      store_accessor :options, :min_date, :max_date

      def cast_value(raw)
        return nil if raw.nil?
        reset_cast_state!
        raw.is_a?(::Date) ? raw : ::Date.parse(raw.to_s)
      rescue ::Date::Error
        mark_cast_invalid!
        nil
      end

      def validate_typed_value(record, val)
        validate_date_range(record, val)
      end
    end
  end
end
