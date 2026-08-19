# frozen_string_literal: true

module TypedEAV
  # Replaces the per-type Finder class hierarchy from active_fields.
  #
  # Field owns operand casting and operator validation before this layer builds
  # Arel. Active Record supplies bind plumbing for the already-normalized
  # typed value; no manual SQL CAST() calls or per-type query caster classes
  # are needed here.
  #
  # Usage:
  #   QueryBuilder.filter(field, :gt, 42)
  #   # => ActiveRecord::Relation scoped to matching values
  #
  #   QueryBuilder.filter(field, :contains, "hello")
  #   # => ILIKE query against the field's string_value column
  #
  class QueryBuilder
    class << self
      # Returns an ActiveRecord::Relation of TypedEAV::Value records
      # matching the given field, operator, and comparison value.
      #
      # The relation is suitable for subquery use:
      #   Model.where(id: QueryBuilder.filter(field, :gt, 5).select(:entity_id))
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength -- one operator-dispatch case statement; flattening keeps the supported-operators list scannable in one place.
      def filter(field, operator, value)
        operator = operator.to_sym

        # Validate operator is supported by this field type. The gate runs
        # BEFORE column resolution so an unsupported operator raises a
        # descriptive ArgumentError instead of silently dispatching to
        # `operator_column`'s default (which would point at the wrong
        # column for multi-cell types).
        supported = field.class.supported_operators
        unless supported.include?(operator)
          raise ArgumentError,
                "Operator :#{operator} is not supported for #{field.class.name}. " \
                "Supported operators: #{supported.map { |o| ":#{o}" }.join(", ")}"
        end

        # Route the operator to its physical column via the field-class
        # dispatch. Single-cell types return `value_columns.first` for every
        # operator — BC-safe. Multi-cell types (Currency) route operators
        # like `:eq` (amount) and `:currency_eq` (currency code) to
        # different columns. See `Field::TypedStorage.operator_column`.
        col = field.class.operator_column(operator)
        arel_col = values_table[col]

        base = value_scope(field)
        excluded = %i[is_null is_not_null contains not_contains starts_with ends_with]
        operand = field.cast_query_operand(operator, value) unless excluded.include?(operator)

        case operator
        when :eq, :currency_eq
          # :currency_eq (Phase 5 Currency) is semantically equality on the
          # routed column — Currency's operator_column override has already
          # routed `col` to :string_value, so reusing the eq_predicate is
          # the canonical implementation. Without this branch, the case
          # falls through to the `else` raise even though the column
          # dispatch resolved correctly. The operator-validation gate at
          # the top of #filter still narrows :currency_eq to Field::Currency
          # only — no other field type accepts it.
          eq_predicate(base, arel_col, col, operand)
        when :not_eq
          not_eq_predicate(base, arel_col, col, operand)
        when :references
          # Phase 5 Reference field. `value` may be an Integer FK OR an
          # AR record instance — `field.cast` normalizes both to an
          # integer FK (a class-mismatched record marks the cast invalid
          # via the second tuple element). Empty-relation semantics on
          # invalid cast: returning `base.where(col => nil)` would
          # collapse to :is_null which has different semantics ("rows
          # without an FK at all" rather than "rows referencing this
          # missing target"); `base.none` is the unambiguous "no match".
          # The :references operator is registered ONLY on Field::Reference
          # (the operator-validation gate above keeps it from leaking to
          # other types).
          if operand.nil?
            base.none
          else
            base.where(arel_col.eq(operand))
          end
        when :gt
          base.where(arel_col.gt(operand))
        when :gteq
          base.where(arel_col.gteq(operand))
        when :lt
          base.where(arel_col.lt(operand))
        when :lteq
          base.where(arel_col.lteq(operand))
        when :between
          base.where(arel_col.between(operand))
        when :contains
          base.where(arel_col.matches("%#{sanitize_like(value)}%"))
        when :not_contains
          base.where(arel_col.does_not_match("%#{sanitize_like(value)}%"))
        when :starts_with
          base.where(arel_col.matches("#{sanitize_like(value)}%"))
        when :ends_with
          base.where(arel_col.matches("%#{sanitize_like(value)}"))
        when :is_null
          base.where(col => nil)
        when :is_not_null
          base.where.not(col => nil)
        when :any_eq
          # For json_value arrays: contains the given element
          base.where("#{col} @> ?", [operand].to_json)
        when :all_eq
          # For json_value arrays: contains all given elements
          base.where("#{col} @> ?", operand.to_json)
        else
          raise ArgumentError, "Unhandled operator: #{operator}"
        end
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

      # Convenience: returns entity IDs matching the filter.
      # Useful for subqueries: Model.where(id: QueryBuilder.entity_ids(field, :gt, 5))
      def entity_ids(field, operator, value)
        filter(field, operator, value).distinct.select(:entity_id)
      end

      private

      def values_table
        TypedEAV::Value.arel_table
      end

      # Base scope: values for this specific field
      def value_scope(field)
        TypedEAV::Value.where(field: field)
      end

      # NULL-safe equality: AR `where(col => nil)` already emits IS NULL, and
      # `where(col => true/false)` already emits IS TRUE/FALSE on PG, so the
      # same `base.where(col => value)` covers booleans and other types.
      def eq_predicate(base, _arel_col, col, value)
        base.where(col => value)
      end

      # NULL-safe inequality: includes NULL rows (they're "not equal" to any value)
      def not_eq_predicate(base, arel_col, col, value)
        if value.nil?
          base.where.not(col => nil)
        else
          # NOT col = value OR col IS NULL
          # Without the OR, NULLs are excluded (SQL tri-valued logic)
          base.where(arel_col.not_eq(value).or(arel_col.eq(nil)))
        end
      end

      def sanitize_like(value)
        value.to_s.gsub(/[%_\\]/) { |m| "\\#{m}" }
      end
    end
  end
end
