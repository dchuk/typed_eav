# frozen_string_literal: true

module TypedEAV
  # SQL-backed operations over one scalar typed field.
  #
  # Entity-level wrappers resolve ambient/explicit scope and preserve Rails'
  # current relation delegation. This object owns the field-definition lookup,
  # scalar support gate, and correlated value expression so no host or Value
  # records are hydrated merely to order a relation.
  class ScalarQuery
    SCALAR_COLUMNS = %i[
      boolean_value
      date_value
      datetime_value
      decimal_value
      integer_value
      string_value
      text_value
    ].freeze
    DIRECTIONS = %i[asc desc].freeze
    NULL_PLACEMENTS = %i[first last].freeze

    # rubocop:disable Metrics/ParameterLists -- the query object receives the resolved public API inputs explicitly.
    def initialize(model:, name:, scope:, parent_scope:, direction: :asc, nulls: :last)
      @model = model
      @name = normalize_name(name)
      @direction = normalize_option(direction, DIRECTIONS, "direction")
      @nulls = normalize_option(nulls, NULL_PLACEMENTS, "nulls")
      @scope = scope
      @parent_scope = parent_scope
    end
    # rubocop:enable Metrics/ParameterLists

    def order_relation
      raise_all_scopes!

      field = field_for_name
      column = scalar_column_for(field)
      relation = @model.all
      host_table = relation.arel_table
      value_table = TypedEAV::Value.arel_table
      value_query = value_subquery(value_table, host_table, column, field)

      relation.reorder(
        Arel.sql("(#{value_query.to_sql}) #{@direction.to_s.upcase} NULLS #{@nulls.to_s.upcase}"),
        host_table[@model.primary_key].asc,
      )
    end

    def distinct_values(limit:)
      raise_all_scopes!

      field = field_for_name
      column = scalar_column_for(field)
      relation = value_relation(field).select(column).distinct
      relation = relation.order(Arel.sql("#{quoted_value_column(column)} ASC NULLS LAST"))

      relation.limit(validate_limit(limit)).pluck(column)
    end

    def count_distinct_values
      raise_all_scopes!

      field = field_for_name
      column = scalar_column_for(field)
      distinct_relation = value_relation(field).select(column).distinct
      aliased_relation = TypedEAV::Value.from(
        "(#{distinct_relation.to_sql}) #{quoted_table_name("typed_eav_distinct_values")}",
      )

      aliased_relation.count
    end

    def value_counts(limit:)
      raise_all_scopes!

      field = field_for_name
      column = scalar_column_for(field)
      count_sql = Arel.sql("COUNT(DISTINCT #{quoted_value_column(:entity_id)})")

      value_relation(field)
        .group(column)
        .order(Arel.sql("#{quoted_value_column(column)} ASC NULLS LAST"))
        .limit(validate_limit(limit))
        .pluck(column, count_sql)
        .to_h
    end

    private

    def normalize_name(name)
      unless name.is_a?(String) || name.is_a?(Symbol)
        raise ArgumentError, "typed field name must be a non-empty String or Symbol"
      end

      normalized = name.to_s
      return normalized if normalized.present?

      raise ArgumentError, "typed field name must be a non-empty String or Symbol"
    end

    def normalize_option(value, allowed, label)
      normalized = value.to_sym if value.is_a?(String) || value.is_a?(Symbol)
      return normalized if allowed.include?(normalized)

      formatted = allowed.map { |option| ":#{option}" }.join(", ")
      raise ArgumentError, "typed field #{label} must be one of #{formatted}"
    end

    def raise_all_scopes!
      return unless @scope.equal?(TypedEAV::EntityQuery::ALL_SCOPES)

      raise ArgumentError,
            "typed field ordering across all partitions is ambiguous; pass an explicit scope"
    end

    def field_for_name
      fields = TypedEAV::Partition.visible_fields(
        entity_type: @model.polymorphic_name,
        scope: @scope,
        parent_scope: @parent_scope,
      )
      field = TypedEAV::Partition.definitions_by_name(fields)[@name]
      return field if field

      raise ArgumentError,
            "Unknown typed field '#{@name}' for #{@model.name}. " \
            "Available fields: #{TypedEAV::Partition.definitions_by_name(fields).keys.join(", ")}"
    end

    def scalar_column_for(field)
      columns = field.class.value_columns
      if columns.length != 1 || SCALAR_COLUMNS.exclude?(columns.first)
        raise ArgumentError,
              "Typed field '#{field.name}' (#{field.field_type_name}) is not a supported scalar field for ordering"
      end

      columns.first
    rescue NotImplementedError
      raise ArgumentError,
            "Typed field '#{field.name}' (#{field.field_type_name}) is not a supported scalar field for ordering"
    end

    def value_relation(field)
      TypedEAV::Value.where(
        field_id: field.id,
        entity_type: @model.polymorphic_name,
        entity_id: host_id_relation,
      )
    end

    def host_id_relation
      # `all` is intentional: EntityQuery's relation delegation exposes the
      # caller relation through the model's current scope at this boundary.
      # rubocop:disable Rails/RedundantActiveRecordAllMethod
      relation = @model.all.unscope(:select)
      # rubocop:enable Rails/RedundantActiveRecordAllMethod
      alias_name = "typed_eav_host_ids"
      qualified_primary_key = "#{quoted_table_name(alias_name)}.#{quoted_column_name(@model.primary_key)}"
      wrapped_sql = "(#{relation.to_sql}) #{quoted_table_name(alias_name)}"

      @model.base_class.unscoped.from(wrapped_sql).select(Arel.sql(qualified_primary_key))
    end

    def quoted_value_column(column)
      "#{quoted_table_name(TypedEAV::Value.table_name)}.#{quoted_column_name(column)}"
    end

    def quoted_table_name(table_name)
      TypedEAV::Value.connection.quote_table_name(table_name)
    end

    def quoted_column_name(column_name)
      TypedEAV::Value.connection.quote_column_name(column_name)
    end

    def validate_limit(limit)
      unless limit.is_a?(Integer) && limit.positive? && limit <= 1_000
        raise ArgumentError, "typed scalar query limit must be a positive Integer no greater than 1000"
      end

      limit
    end

    def value_subquery(value_table, host_table, column, field)
      predicate = value_table[:field_id].eq(field.id)
                                        .and(value_table[:entity_type].eq(@model.polymorphic_name))
                                        .and(value_table[:entity_id].eq(host_table[@model.primary_key]))

      value_table.project(value_table[column]).where(predicate)
    end
  end
end
