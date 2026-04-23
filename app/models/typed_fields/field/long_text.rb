# frozen_string_literal: true

module TypedFields
  module Field
    class LongText < Base
      value_column :text_value

      store_accessor :options, :min_length, :max_length

      def cast(raw)
        [raw&.to_s, false]
      end

      def validate_typed_value(record, val)
        validate_length(record, val)
      end
    end
  end
end
