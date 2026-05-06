# frozen_string_literal: true

module TypedEAV
  module Field
    # Decimal subclass storing fractions in 0..1 (inclusive). The "percent"
    # representation (e.g., "75.0%") is a format-time concern via
    # `display_as: :percent` — the underlying decimal_value column always
    # stores the fraction.
    #
    # STI: extends Field::Decimal (subclass-of-subclass). Rails AR resolves
    # the `type` column to "TypedEAV::Field::Percentage" correctly because
    # default STI behavior uses the leaf class name.
    #
    # Storage: decimal_value (inherited from Decimal — does NOT re-declare).
    # Operators: inherits Decimal's default operator set
    # (DEFAULT_OPERATORS_BY_COLUMN[:decimal_value]).
    # Range: hard-coded 0..1; min/max options are NOT exposed via
    # store_accessor (they would conflict with the 0-1 invariant).
    # Decimal's `precision_scale` option is inherited but not exposed
    # here either — it would govern storage rounding only.
    #
    # Options (all read-side only — do NOT change what gets stored):
    # - decimal_places: Integer >= 0 (default 2). Format-time precision.
    # - display_as: :fraction | :percent (default :fraction).
    class Percentage < Decimal
      # Re-declare value_column :decimal_value. ColumnMapping's value_column
      # stores the column on `@value_column` (a class instance variable on
      # the declaring class) — Ruby class instance variables are NOT
      # inherited through subclass lookup, so `Percentage.value_column`
      # would raise NotImplementedError without this re-declaration.
      # Re-declaring with the same column is BC-safe and explicit; STI
      # behavior (the `type` column stores "TypedEAV::Field::Percentage")
      # is unaffected.
      value_column :decimal_value

      store_accessor :options, :decimal_places, :display_as

      validate :decimal_places_format
      validate :display_as_inclusion

      # Inherits supported_operators (DEFAULT_OPERATORS_BY_COLUMN
      # [:decimal_value]) and cast (BigDecimal parse) from Decimal.
      # Inherits read_value / write_value / apply_default_to defaults from
      # Field::Base via Decimal's chain.

      def validate_typed_value(record, val)
        # Inherits Decimal's range check (min/max — typically nil for
        # Percentage since options are not exposed). Without `super`, a
        # future addition of min/max to Percentage's options would
        # silently bypass the range guard.
        super
        return if val.nil?

        return if val.between?(0, 1)

        record.errors.add(:value, "must be between 0.0 and 1.0")
      end

      # Format helper. Read-side only; does NOT alter what's stored in
      # decimal_value.
      #
      # - display_as: :percent → returns "<val*100>%" rounded to
      #   decimal_places (e.g., 0.75 with decimal_places: 1 → "75.0%").
      # - display_as: :fraction (default) → returns val.to_s
      #   (e.g., 0.75 → "0.75").
      # - nil val → returns nil.
      def format(val)
        return nil if val.nil?

        places = (decimal_places || 2).to_i
        case display_as&.to_sym
        when :percent
          "#{(val * 100).round(places)}%"
        else # :fraction or unset
          val.to_s
        end
      end

      private

      def decimal_places_format
        d = options_hash[:decimal_places]
        return if d.nil?

        d_int = Integer(d.to_s, exception: false)
        return if d_int && d_int >= 0

        errors.add(:decimal_places, "must be a non-negative integer")
      end

      def display_as_inclusion
        d = options_hash[:display_as]
        return if d.nil?
        return if %w[fraction percent].include?(d.to_s)

        errors.add(:display_as, "must be :fraction or :percent")
      end
    end
  end
end
