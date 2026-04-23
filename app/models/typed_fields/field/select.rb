# frozen_string_literal: true

module TypedFields
  module Field
    class Select < Base
      value_column :string_value
      operators :eq, :not_eq, :is_null, :is_not_null

      def optionable? = true

      def allowed_values
        field_options.sorted.pluck(:value)
      end

      def cast(raw)
        [raw&.to_s, false]
      end

      def validate_typed_value(record, val)
        validate_option_inclusion(record, val)
      end
    end
  end
end
