# frozen_string_literal: true

module TypedEAV
  # Replaces the per-type Finder class hierarchy from active_fields.
  #
  # Because values live in native typed columns, ActiveRecord already knows
  # the column types from the schema. Arel predicates (eq, gt, lt, matches, etc.)
  # automatically go through the column's ActiveRecord::Type for casting.
  #
  # This means:
  #   where(integer_value: "42")  ->  Rails casts "42" to 42 automatically
  #   arel[:date_value].gt(value) ->  Rails casts string dates to Date objects
  #
  # No manual CAST() calls. No per-type caster classes for queries.
  # One module handles all field types.
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

        # Phase 05: route the operator to its physical column via field-side
        # dispatch. Single-cell types (every built-in as of Phase 04) return
        # `value_column` for every operator — BC-safe. Multi-cell types
        # (Phase 05 Currency) route operators like `:eq` (amount) and
        # `:currency_eq` (currency code) to different columns. See
        # ColumnMapping#operator_column.
        col = field.class.operator_column(operator)
        arel_col = values_table[col]

        base = value_scope(field)

        case operator
        when :eq
          eq_predicate(base, arel_col, col, value)
        when :not_eq
          not_eq_predicate(base, arel_col, col, value)
        when :gt
          base.where(arel_col.gt(value))
        when :gteq
          base.where(arel_col.gteq(value))
        when :lt
          base.where(arel_col.lt(value))
        when :lteq
          base.where(arel_col.lteq(value))
        when :between
          unless value.respond_to?(:first) && value.respond_to?(:last)
            raise ArgumentError,
                  ":between expects a Range or two-element Array"
          end

          base.where(arel_col.between(value.first..value.last))
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
          base.where("#{col} @> ?", [value].to_json)
        when :all_eq
          # For json_value arrays: contains all given elements
          base.where("#{col} @> ?", Array(value).to_json)
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
