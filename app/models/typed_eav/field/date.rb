# frozen_string_literal: true

module TypedEAV
  module Field
    # Date-typed field with optional min_date/max_date guards. Declares
    # its own `date_value` storage and `:min_date`/`:max_date`
    # `store_accessor`. `validate_date_range` is inherited from
    # `Field::RangeBounded`.
    #
    # Latent-bug fix (per ADR-0004): the
    # `validates :max_date, comparison: { greater_than_or_equal_to: :min_date }`
    # macro now applies here (previously only Integer/Decimal carried it).
    # A Date field configured with `max_date < min_date` fails at
    # field-save instead of saving silently.
    class Date < RangeBounded
      value_column :date_value

      store_accessor :options, :min_date, :max_date

      validates :max_date,
                comparison: { greater_than_or_equal_to: :min_date },
                allow_nil: true,
                if: :min_date

      def cast(raw)
        return [nil, false] if raw.nil?

        casted = raw.is_a?(::Date) ? raw : ::Date.parse(raw.to_s)
        [casted, false]
      rescue ::Date::Error
        [nil, true]
      end

      def validate_typed_value(record, val)
        validate_date_range(record, val)
      end
    end
  end
end
