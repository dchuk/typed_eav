# frozen_string_literal: true

module TypedFields
  # Maps field types to their native database column on the values table.
  #
  # This is the core concept borrowed from Relaticle's hybrid EAV:
  # instead of serializing everything into a jsonb blob, each value
  # type gets its own column so the database can natively index,
  # sort, and enforce constraints.
  #
  # Usage in field type classes:
  #
  #   class TypedFields::Field::Integer < TypedFields::Field::Base
  #     value_column :integer_value
  #   end
  #
  # The value model reads this to know which column to read/write.
  # The query builder reads this to know which column to filter on.
  # ActiveRecord handles all type casting automatically via the
  # column's registered ActiveRecord::Type.
  module ColumnMapping
    extend ActiveSupport::Concern

    DEFAULT_OPERATORS_BY_COLUMN = {
      boolean_value: %i[eq not_eq is_null is_not_null],
      string_value: %i[eq not_eq contains not_contains starts_with ends_with is_null is_not_null],
      text_value: %i[eq not_eq contains not_contains starts_with ends_with is_null is_not_null],
      integer_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
      decimal_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
      date_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
      datetime_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
      json_value: %i[contains is_null is_not_null],
    }.freeze
    FALLBACK_OPERATORS = %i[eq not_eq is_null is_not_null].freeze

    class_methods do
      # Declare which typed column this field type stores its value in.
      def value_column(column_name = nil)
        unless column_name
          return @value_column || raise(NotImplementedError,
                                        "#{name} must declare `value_column :column_name`")
        end

        @value_column = column_name.to_sym
      end

      # All operators this field type supports for querying.
      # Subclasses can override to restrict or extend.
      def supported_operators
        @supported_operators || default_operators_for(value_column)
      end

      def operators(*ops)
        @supported_operators = ops.map(&:to_sym)
      end

      private

      def default_operators_for(col)
        DEFAULT_OPERATORS_BY_COLUMN.fetch(col, FALLBACK_OPERATORS)
      end
    end
  end
end
