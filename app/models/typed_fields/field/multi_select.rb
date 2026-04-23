# frozen_string_literal: true

module TypedFields
  module Field
    class MultiSelect < Base
      value_column :json_value
      operators :any_eq, :all_eq, :is_null, :is_not_null

      def optionable? = true
      def array_field? = true

      def allowed_values
        field_options.sorted.pluck(:value)
      end

      def cast_value(raw)
        return nil if raw.nil?
        Array(raw).map(&:to_s).presence
      end

      def validate_typed_value(record, val)
        validate_multi_option_inclusion(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
