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
    def initialize(model:, name:, direction:, nulls:, scope:, parent_scope:)
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

    def value_subquery(value_table, host_table, column, field)
      predicate = value_table[:field_id].eq(field.id)
                                        .and(value_table[:entity_type].eq(@model.polymorphic_name))
                                        .and(value_table[:entity_id].eq(host_table[@model.primary_key]))

      value_table.project(value_table[column]).where(predicate)
    end
  end
end
