# frozen_string_literal: true

module TypedEAV
  module Field
    # Intermediate STI base for field families that constrain a single
    # comparable value by `min`/`max` bounds.
    #
    # Leaves: `Field::Integer`, `Field::Decimal`, `Field::Date`,
    # `Field::DateTime`. `Field::Percentage` keeps its `< Decimal` chain
    # (so the new full chain is
    # `Percentage < Decimal < RangeBounded < Base`).
    #
    # Does NOT declare a `value_column` — each leaf still owns its typed
    # column (`integer_value`, `decimal_value`, `date_value`,
    # `datetime_value`). The family is identified by "has min/max bounds",
    # not by storage shape.
    #
    # Hoists the protected `validate_range` / `validate_date_range` /
    # `validate_datetime_range` helpers previously kept on `Field::Base`.
    # Each leaf declares its own `store_accessor` (`:min`/`:max` for
    # Integer/Decimal; `:min_date`/`:max_date` for Date;
    # `:min_datetime`/`:max_datetime` for DateTime) and its own
    # `validates :max, comparison: { greater_than_or_equal_to: :min }`
    # macro using the appropriate key names. Adding the macro to
    # Date/DateTime in-slice closes a latent-bug gap previously only
    # caught on Integer/Decimal.
    #
    # Public extension point: external authors can subclass this directly
    # if they want a typed numeric/temporal column with min/max guards
    # (see README §"Custom field types"). STI dispatch is unaffected.
    class RangeBounded < Base
      protected

      def validate_range(record, val)
        opts = options_hash
        record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min]) if opts[:min] && val < opts[:min].to_d
        return unless opts[:max] && val > opts[:max].to_d

        record.errors.add(:value, :less_than_or_equal_to, count: opts[:max])
      end

      def validate_date_range(record, val)
        opts = options_hash
        if opts[:min_date]
          min = ::Date.parse(opts[:min_date])
          record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min_date]) if val < min
        end
        if opts[:max_date]
          max = ::Date.parse(opts[:max_date])
          record.errors.add(:value, :less_than_or_equal_to, count: opts[:max_date]) if val > max
        end
      rescue ::Date::Error
        record.errors.add(:base, "field has invalid date configuration")
      end

      def validate_datetime_range(record, val)
        opts = options_hash
        if opts[:min_datetime]
          min = ::Time.zone.parse(opts[:min_datetime])
          record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min_datetime]) if val < min
        end
        if opts[:max_datetime]
          max = ::Time.zone.parse(opts[:max_datetime])
          record.errors.add(:value, :less_than_or_equal_to, count: opts[:max_datetime]) if val > max
        end
      rescue ArgumentError
        record.errors.add(:base, "field has invalid datetime configuration")
      end
    end
  end
end
