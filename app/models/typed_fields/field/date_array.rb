# frozen_string_literal: true

module TypedFields
  module Field
    class DateArray < Base
      value_column :json_value
      operators :any_eq, :is_null, :is_not_null

      store_accessor :options, :min_size, :max_size

      def array_field? = true

      def cast(raw)
        return [nil, false] if raw.nil?
        elements = Array(raw)
        result = elements.filter_map { |v| ::Date.parse(v.to_s) rescue nil }
        [result.presence, result.size < elements.size]
      end

      def validate_typed_value(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
