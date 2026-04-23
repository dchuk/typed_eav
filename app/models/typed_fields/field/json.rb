# frozen_string_literal: true

module TypedFields
  module Field
    class Json < Base
      value_column :json_value
      operators :is_null, :is_not_null

      def cast(raw)
        [raw, false]
      end
    end
  end
end
