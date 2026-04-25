# frozen_string_literal: true

module TypedFields
  module Field
    class MultiSelect < Base
      value_column :json_value
      operators :any_eq, :all_eq, :is_null, :is_not_null

      def optionable? = true
      def array_field? = true

      def allowed_values
        if field_options.loaded?
          field_options.sort_by { |o| [o.sort_order || 0, o.label.to_s] }.map(&:value)
        else
          field_options.sorted.pluck(:value)
        end
      end

      def cast(raw)
        return [nil, false] if raw.nil?

        # Rails emits a hidden "" sentinel for `select multiple: true` so an
        # empty submission still round-trips. Drop nil/blank elements here so
        # the inclusion check doesn't reject the form's own placeholder.
        elements = Array(raw).filter_map do |v|
          next nil if v.nil?

          s = v.to_s
          s.strip.empty? ? nil : s
        end
        [elements.presence, false]
      end

      def validate_typed_value(record, val)
        validate_multi_option_inclusion(record, val)
        validate_array_size(record, val)
      end
    end
  end
end
