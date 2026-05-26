# frozen_string_literal: true

module TypedEAV
  module Field
    # DateTime-typed field with optional min_datetime/max_datetime
    # guards. Declares its own `datetime_value` storage and
    # `:min_datetime`/`:max_datetime` `store_accessor`.
    # `validate_datetime_range` is inherited from `Field::RangeBounded`.
    #
    # Latent-bug fix (per ADR-0004): the
    # `validates :max_datetime, comparison: { greater_than_or_equal_to: :min_datetime }`
    # macro now applies here (previously only Integer/Decimal carried
    # it). A DateTime field configured with `max_datetime < min_datetime`
    # fails at field-save instead of saving silently.
    class DateTime < RangeBounded
      value_column :datetime_value

      store_accessor :options, :min_datetime, :max_datetime

      validates :max_datetime,
                comparison: { greater_than_or_equal_to: :min_datetime },
                allow_nil: true,
                if: :min_datetime

      def cast(raw)
        return [nil, false] if raw.nil?
        return [raw, false] if raw.is_a?(::Time)

        result = ::Time.zone.parse(raw.to_s)
        if result.nil?
          [nil, !raw.to_s.strip.empty?]
        else
          [result, false]
        end
      rescue ArgumentError
        [nil, true]
      end

      def validate_typed_value(record, val)
        validate_datetime_range(record, val)
      end
    end
  end
end
