# frozen_string_literal: true

module TypedEAV
  # Storage contract for Field::Currency's two-cell value shape.
  class CurrencyStorageContract < FieldStorageContract
    VALUE_COLUMNS = %i[decimal_value string_value].freeze
    AMOUNT_COLUMN = :decimal_value
    CURRENCY_COLUMN = :string_value

    def self.value_columns
      VALUE_COLUMNS
    end

    def self.query_column(operator)
      operator == :currency_eq ? CURRENCY_COLUMN : AMOUNT_COLUMN
    end

    delegate :value_columns, :query_column, to: :class

    def read(value_record)
      amount = value_record[AMOUNT_COLUMN]
      currency = value_record[CURRENCY_COLUMN]
      return nil if amount.nil? && currency.nil?

      { amount: amount, currency: currency }
    end

    def write(value_record, casted)
      if casted.nil?
        value_record[AMOUNT_COLUMN] = nil
        value_record[CURRENCY_COLUMN] = nil
      else
        value_record[AMOUNT_COLUMN] = casted[:amount]
        value_record[CURRENCY_COLUMN] = casted[:currency]
      end
    end

    def apply_default(value_record)
      default = field.default_value
      return unless default.is_a?(Hash)

      value_record[AMOUNT_COLUMN] = default[:amount] || default["amount"]
      value_record[CURRENCY_COLUMN] = default[:currency] || default["currency"]
    end
  end
end
