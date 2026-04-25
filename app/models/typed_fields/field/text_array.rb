# frozen_string_literal: true

module TypedFields
  module Field
    class TextArray < Base
      value_column :json_value
      # :contains was declared here but QueryBuilder implements it with
      # Arel `matches` (SQL LIKE), which doesn't work against jsonb arrays.
      # Use :any_eq for element membership (it maps to JSONB @>).
      operators :any_eq, :all_eq, :is_null, :is_not_null

      store_accessor :options, :min_size, :max_size

      def array_field? = true

      def cast(raw)
        return [nil, false] if raw.nil?

        # Drop nil/blank/whitespace-only elements so required-check and size
        # validation compare against real content rather than HTML form stubs
        # (e.g. an empty row in a dynamic list posts as "" or "   ").
        elements = Array(raw).filter_map do |v|
          next nil if v.nil?

          s = v.to_s
          s.strip.empty? ? nil : s
        end
        [elements.presence, false]
      end

      def validate_typed_value(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
