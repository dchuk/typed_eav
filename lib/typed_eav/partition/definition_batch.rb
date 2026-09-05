# frozen_string_literal: true

module TypedEAV
  module Partition
    # Internal batched resolver for field definitions visible to many exact
    # partition tuples. It performs one definition SELECT, then applies the
    # same global -> scope -> full-tuple precedence as `definitions_by_name`
    # independently for every requested tuple.
    class DefinitionBatch
      class << self
        def resolve(entity_type:, tuples:)
          new(entity_type: entity_type, tuples: tuples).resolve
        end
      end

      def initialize(entity_type:, tuples:)
        @entity_type = entity_type
        @tuples = tuples.uniq
      end

      def resolve
        tuples.each { |scope, parent_scope| validate_tuple!(scope, parent_scope) }
        return {} if tuples.empty?

        definitions_by_tuple = load_definitions.group_by do |definition|
          [definition.scope, definition.parent_scope]
        end

        tuples.to_h do |tuple|
          visible = candidate_tuples(tuple).flat_map { |candidate| definitions_by_tuple.fetch(candidate, []) }
          [tuple, TypedEAV::Partition.definitions_by_name(visible)]
        end
      end

      private

      attr_reader :entity_type, :tuples

      def load_definitions
        requested = tuples.map { |scope, parent_scope| { "scope" => scope, "parent_scope" => parent_scope } }
        TypedEAV::Field::Base.where(entity_type: entity_type).where(<<~SQL.squish, requested.to_json).to_a
          typed_eav_fields.scope IS NULL AND typed_eav_fields.parent_scope IS NULL
          OR EXISTS (
            SELECT 1
            FROM jsonb_to_recordset(?::jsonb) AS requested(scope text, parent_scope text)
            WHERE (
              typed_eav_fields.scope IS NOT DISTINCT FROM requested.scope
              AND typed_eav_fields.parent_scope IS NOT DISTINCT FROM requested.parent_scope
            )
            OR (
              typed_eav_fields.scope IS NOT DISTINCT FROM requested.scope
              AND typed_eav_fields.parent_scope IS NULL
            )
          )
        SQL
      end

      def candidate_tuples(tuple)
        scope, parent_scope = tuple
        [[nil, nil], [scope, nil], [scope, parent_scope]].uniq
      end

      def validate_tuple!(scope, parent_scope)
        return if TypedEAV::ScopeTuple.invariant_satisfied?(scope, parent_scope)

        raise ArgumentError, "parent_scope cannot be set when scope is blank"
      end
    end
  end
end
