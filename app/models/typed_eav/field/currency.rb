# frozen_string_literal: true

module TypedEAV
  module Field
    # Two-cell field type: stores `{amount: BigDecimal, currency: String}`
    # across decimal_value (amount) + string_value (currency ISO 4217 code).
    #
    # Phase 05 contract:
    # - value_columns: [:decimal_value, :string_value] — propagates through
    #   versioning's snapshot loop (Phase 04) and the Value
    #   _dispatch_value_change_update filter so a change to either cell
    #   correctly fires the :update event.
    # - operator_column: :currency_eq → :string_value; everything else →
    #   :decimal_value. Routed via QueryBuilder.filter (plan 05-01).
    # - read_value / write_value / apply_default_to: paired overrides
    #   that compose / unpack the {amount, currency} hash across the two
    #   physical columns. Without all three, single-cell defaults would
    #   write a Hash to decimal_value and raise TypeMismatch.
    # - cast: Hash input only. Bare Numeric/String is invalid — explicit
    #   currency dimension is required at write time. Silently defaulting
    #   to default_currency would invite bugs where users forget the
    #   currency dimension entirely.
    #
    # Operators (explicit narrowing — does NOT inherit string-search ops
    # like :contains/:starts_with from decimal_value's default since those
    # don't apply to amount-numeric or currency-code searches):
    # - :eq, :gt, :lt, :gteq, :lteq, :between target the amount.
    # - :currency_eq targets the currency code (registered ONLY on this
    #   class — QueryBuilder's operator-validation gate rejects it on any
    #   non-Currency field).
    # - :is_null / :is_not_null target the amount column (a Currency value
    #   is considered null when its amount is null).
    #
    # Options:
    # - default_currency: String ISO 4217 code (e.g., "USD"). Used as the
    #   currency fallback when cast input has amount but no currency.
    #   Never applies as a global silent default — only when cast input
    #   already has an amount and no explicit currency.
    # - allowed_currencies: Array<String> of ISO codes. When set,
    #   validate_typed_value enforces inclusion.
    class Currency < Base
      value_column :decimal_value
      storage_contract_class TypedEAV::CurrencyStorageContract

      operators(*%i[eq gt lt gteq lteq between currency_eq is_null is_not_null])

      store_accessor :options, :default_currency, :allowed_currencies

      validates :default_currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
      validate :allowed_currencies_format

      def self.value_columns
        storage_contract_class.value_columns
      end

      def self.operator_column(operator)
        storage_contract_class.query_column(operator)
      end

      # Cast Hash input → [{amount: BigDecimal, currency: String}, false]
      # or [nil, false] for nil/blank, or [nil, true] for unparseable input.
      # Bare Numeric or String input is [nil, true] — users MUST pass a
      # hash to make the currency dimension explicit (locked plan-time
      # decision; preventing silent default_currency reliance in the
      # ergonomic-but-error-prone scalar-cast case).
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- one cast method with linear branches for nil/non-hash/amount-parse/currency-coercion/currency-shape; splitting hides the cast contract from a single read.
      def cast(raw)
        return [nil, false] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
        return [nil, true] unless raw.is_a?(Hash)

        amount_raw   = raw[:amount]   || raw["amount"]
        currency_raw = raw[:currency] || raw["currency"]

        amount_bd = nil
        if amount_raw.present?
          amount_bd = BigDecimal(amount_raw.to_s, exception: false)
          return [nil, true] if amount_bd.nil?
        end

        currency_str = currency_raw.is_a?(String) ? currency_raw.upcase : nil
        # default_currency fallback applies ONLY when the hash has an
        # amount but no currency. When the hash has neither, the result is
        # {amount: nil, currency: nil} — falsy enough that read_value
        # returns nil. When the hash has only a currency, the fallback
        # does NOT trigger (amount stays nil); validation will catch the
        # co-population requirement at save time.
        currency_str ||= default_currency if amount_bd && default_currency.present?
        # Reject non-3-letter currency codes (validation also catches this
        # on save; cast catches it earlier so :invalid is set on the cast
        # result and Value#validate_value surfaces :invalid promptly).
        return [nil, true] if currency_str && currency_str !~ /\A[A-Z]{3}\z/

        [{ amount: amount_bd, currency: currency_str }, false]
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Co-population validation + allowed_currencies inclusion.
      # When val is a Hash, requires both :amount and :currency populated.
      # When allowed_currencies is set, val[:currency] must be in the
      # list. Without the co-population check, a half-populated row
      # (amount-only or currency-only) would silently round-trip.
      def validate_typed_value(record, val)
        return if val.nil?

        unless val.is_a?(Hash) && val[:amount].present? && val[:currency].present?
          record.errors.add(:value, "must have both amount and currency")
          return
        end

        allowed = options_hash[:allowed_currencies]
        record.errors.add(:value, :inclusion) if allowed.present? && Array(allowed).exclude?(val[:currency])
      end

      private

      def allowed_currencies_format
        list = options_hash[:allowed_currencies]
        return if list.nil?
        return if list.is_a?(Array) && list.all? { |c| c.is_a?(String) && c =~ /\A[A-Z]{3}\z/ }

        errors.add(:allowed_currencies, "must be an Array of 3-letter uppercase ISO codes")
      end
    end
  end
end
