# frozen_string_literal: true

module TypedEAV
  # Partition-aware visibility for schema objects keyed by the canonical
  # `(entity_type, scope, parent_scope)` tuple.
  #
  # This module is deliberately explicit: callers pass already-resolved scope
  # values. Ambient resolution (`TypedEAV.current_scope`, `with_scope`,
  # `unscoped`) stays with the adapters that know their calling context.
  module Partition
    class << self
      # All field definitions visible from a tuple: pure global rows,
      # scope-only rows, and full-tuple rows. Passing mode: :all_partitions is
      # the deliberate admin bypass; it is distinct from `scope: nil`, which
      # means the global partition only.
      def visible_fields(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        validate_mode!(mode)
        return TypedEAV::Field::Base.where(entity_type: entity_type) if mode == :all_partitions

        validate_tuple!(scope, parent_scope)
        TypedEAV::Field::Base.for_entity(entity_type, scope: scope, parent_scope: parent_scope)
      end

      # One visible field per name after collision resolution. Most-specific
      # wins: full tuple beats scope-only, scope-only beats global.
      def effective_fields_by_name(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        fields = visible_fields(entity_type: entity_type, scope: scope, parent_scope: parent_scope, mode: mode)
        if mode == :all_partitions
          TypedEAV::HasTypedEAV.definitions_multimap_by_name(fields)
        else
          TypedEAV::HasTypedEAV.definitions_by_name(fields)
        end
      end

      # All sections visible from the same tuple as field definitions.
      def visible_sections(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        validate_mode!(mode)
        return TypedEAV::Section.where(entity_type: entity_type) if mode == :all_partitions

        validate_tuple!(scope, parent_scope)
        TypedEAV::Section.for_entity(entity_type, scope: scope, parent_scope: parent_scope)
      end

      def find_visible_section!(id, entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        visible_sections(entity_type: entity_type, scope: scope, parent_scope: parent_scope, mode: mode).find(id)
      end

      private

      def validate_mode!(mode)
        return if %i[partition all_partitions].include?(mode)

        raise ArgumentError, "Unknown partition mode: #{mode.inspect}. Expected :partition or :all_partitions."
      end

      def validate_tuple!(scope, parent_scope)
        return if parent_scope.blank?
        return if scope.present?

        raise ArgumentError, "parent_scope cannot be set when scope is blank"
      end
    end
  end
end
