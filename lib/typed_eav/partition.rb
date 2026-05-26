# frozen_string_literal: true

module TypedEAV
  # Partition-aware visibility for schema objects keyed by the canonical
  # `(entity_type, scope, parent_scope)` tuple.
  #
  # This module is deliberately explicit: callers pass already-resolved scope
  # values. Ambient resolution (`TypedEAV.current_scope`, `with_scope`,
  # `unscoped`) stays with the adapters that know their calling context.
  module Partition
    # Frozen orphan-parent ArgumentError message. Kept as a module constant
    # so both `visible_fields` and `visible_sections` raise the same string
    # without re-allocating per call. The string is the wire-stable BC error
    # message that `partition_spec` matches against; do not change it
    # without coordinating with downstream rescue clauses.
    ORPHAN_PARENT_MESSAGE = "parent_scope cannot be set when scope is blank"
    private_constant :ORPHAN_PARENT_MESSAGE

    class << self
      # All field definitions visible from a tuple: pure global rows,
      # scope-only rows, and full-tuple rows. Passing mode: :all_partitions is
      # the deliberate admin bypass; it is distinct from `scope: nil`, which
      # means the global partition only.
      def visible_fields(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        validate_mode!(mode)
        return TypedEAV::Field::Base.where(entity_type: entity_type) if mode == :all_partitions

        raise ArgumentError, ORPHAN_PARENT_MESSAGE unless ScopeTuple.invariant_satisfied?(scope, parent_scope)

        TypedEAV::Field::Base.for_entity(entity_type, scope: scope, parent_scope: parent_scope)
      end

      # One visible field per name after collision resolution. Most-specific
      # wins: full tuple beats scope-only, scope-only beats global.
      def effective_fields_by_name(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        fields = visible_fields(entity_type: entity_type, scope: scope, parent_scope: parent_scope, mode: mode)
        if mode == :all_partitions
          definitions_multimap_by_name(fields)
        else
          definitions_by_name(fields)
        end
      end

      # Indexes field definitions by name with deterministic three-way
      # collision resolution: when global (scope=NULL, parent_scope=NULL),
      # scope-only (scope set, parent_scope=NULL), and full-triple (both set)
      # fields share a name, the most-specific row wins.
      #
      # Sort key `[scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` orders rows:
      #   [0, 0] global              (least specific) -> comes first
      #   [1, 0] scope-only          (middle)
      #   [1, 1] full triple         (most specific)  -> comes last
      #
      # `index_by(&:name)` keeps the LAST entry on duplicate keys (Rails
      # convention via `Array#to_h`), so most-specific wins. The two-key sort
      # extends the prior "scoped beats global" rule into "two-key beats
      # one-key beats global" without changing the index_by-last-wins
      # mechanism. The `(scope=NULL, parent_scope=NOT NULL)` slot is
      # unreachable by construction (orphan-parent invariant in Field::Base),
      # so the ordering is exhaustive across the three valid shapes.
      #
      # Shared by the class-query path (FilterQuery / BulkRead / EntityQuery)
      # and the instance path (HasTypedEAV::InstanceMethods#typed_eav_defs_by_name)
      # so the two cannot drift. Lives on Partition because partition-tuple
      # precedence is a partition concept.
      def definitions_by_name(defs)
        defs.to_a
            .sort_by { |d| [d.scope.nil? ? 0 : 1, d.parent_scope.nil? ? 0 : 1] }
            .index_by(&:name)
      end

      # Indexes field definitions by name into a multi-map (one name ->
      # array of fields). Used by the class-query path under
      # `TypedEAV.unscoped { }`, where the same field name may legitimately
      # exist across multiple tenant partitions and we must OR-across all
      # matching field_ids per filter rather than collapse to a single row.
      def definitions_multimap_by_name(defs)
        defs.to_a.group_by(&:name)
      end

      # All sections visible from the same tuple as field definitions.
      def visible_sections(entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        validate_mode!(mode)
        return TypedEAV::Section.where(entity_type: entity_type) if mode == :all_partitions

        raise ArgumentError, ORPHAN_PARENT_MESSAGE unless ScopeTuple.invariant_satisfied?(scope, parent_scope)

        TypedEAV::Section.for_entity(entity_type, scope: scope, parent_scope: parent_scope)
      end

      # Looks up a single {TypedEAV::Section} by `id` constrained to the
      # caller's partition tuple. Documented-public surface: apps building
      # admin UIs that need to authorize a section lookup before editing,
      # rendering, or destroying it should call this rather than
      # `Section.find(id)`, which would happily return a section belonging
      # to another tenant's partition.
      #
      # Visibility merge matches {visible_sections}: rows whose
      # `(entity_type, scope, parent_scope)` is either the requested tuple
      # or the global `(scope: nil, parent_scope: nil)` partition are
      # eligible. The most-specific-wins precedence used for field
      # collision resolution does not apply here — section lookup is by
      # primary key, not by name.
      #
      # Sibling documented-public methods on this module that share the
      # same partition-visibility surface: {visible_fields},
      # {effective_fields_by_name}, {definitions_by_name},
      # {definitions_multimap_by_name}, {visible_sections}.
      #
      # @param id [Integer, String] the section's primary key. Blank input
      #   is the caller's responsibility to guard upstream; this method
      #   does not silently swallow `nil` / `""` — it forwards to
      #   `ActiveRecord::Relation#find`, which raises
      #   `ActiveRecord::RecordNotFound` on blank.
      # @param entity_type [String] the host AR class name the section
      #   belongs to (matches `Section#entity_type`).
      # @param scope [Object, nil] the resolved scope value from the
      #   caller's partition. `nil` means the global partition only.
      # @param parent_scope [Object, nil] the resolved parent_scope value.
      #   Must be `nil` when `scope` is blank (the orphan-parent invariant
      #   shared with {visible_sections}).
      # @param mode [Symbol] `:partition` (default) restricts to the
      #   caller's tuple plus the global tuple. `:all_partitions` is the
      #   deliberate admin bypass that ignores the tuple entirely —
      #   distinct from `scope: nil`, which means "global partition only."
      # @return [TypedEAV::Section] the section record when it belongs to
      #   the caller's partition or the global tuple.
      # @raise [ActiveRecord::RecordNotFound] when the section's
      #   `(scope, parent_scope)` falls outside the visibility merge for
      #   the requested tuple, or when no section with `id` exists.
      # @raise [ArgumentError] when `parent_scope` is present and `scope`
      #   is blank (orphan-parent), or when `mode` is neither
      #   `:partition` nor `:all_partitions`.
      def find_visible_section!(id, entity_type:, scope: nil, parent_scope: nil, mode: :partition)
        visible_sections(entity_type: entity_type, scope: scope, parent_scope: parent_scope, mode: mode).find(id)
      end

      private

      def validate_mode!(mode)
        return if %i[partition all_partitions].include?(mode)

        raise ArgumentError, "Unknown partition mode: #{mode.inspect}. Expected :partition or :all_partitions."
      end
    end
  end
end
