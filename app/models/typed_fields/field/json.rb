# frozen_string_literal: true

module TypedFields
  module Field
    class Json < Base
      value_column :json_value
      operators :is_null, :is_not_null

      # Parse JSON strings into objects/arrays. The JSON input partial posts a
      # string from a textarea; without parsing it would land as a JSON-
      # encoded string in json_value instead of the intended object.
      def cast(raw)
        return [nil, false] if raw.nil?
        return [raw, false] if raw.is_a?(Hash) || raw.is_a?(Array) ||
                               raw.is_a?(Numeric) || raw == true || raw == false

        str = raw.to_s
        return [nil, false] if str.strip.empty?

        [::JSON.parse(str), false]
      rescue ::JSON::ParserError
        [nil, true]
      end
    end
  end
end
