# frozen_string_literal: true

module TypedEAV
  # Bulk-read query object. Returns `{ record_id => { field_name => value } }`
  # for an Enumerable of host records — the class-method bulk variant of
  # `HasTypedEAV::InstanceMethods#typed_eav_hash`. N+1-free regardless of
  # record count or field count.
  #
  # `fields:` is an optional projection of field names. A nil selection keeps
  # the all-fields behavior; a non-nil selection is normalized to unique
  # strings, and only the selected winning definitions' values are loaded.
  # Unknown names are ignored, as are names that are not defined for a
  # particular record's partition tuple. An empty selection returns one empty
  # inner hash per record without querying definitions or values.
  #
  # `source: :database` (the default) always reads a fresh Value graph. The
  # explicit `source: :preloaded` mode projects only the already-loaded
  # `typed_values` targets and their loaded `field` associations; it never
  # falls back to an association query. Incomplete preload requirements raise
  # `ArgumentError` before projection. The preloaded mode is therefore a
  # snapshot of caller-owned in-memory records and can include unsaved Value
  # assignments; it never saves or mutates those records.
  #
  # ## Pipeline
  #
  #   1. validate_records!    — nil -> ArgumentError; single-class invariant
  #   2. group_by_tuple       — `[typed_eav_scope, typed_eav_parent_scope]`
  #   3. winning_ids_by_tuple — one `Partition::DefinitionBatch` query, then
  #                             extract the winning field ids per tuple
  #   4. load_values          — fresh `:database` SELECT across ALL records,
  #                             restricted to selected field IDs when
  #                             `fields:` is used; or `:preloaded` association
  #                             targets after a strict loaded-state check
  #   5. build_result_hash    — per-record inner hash; orphan-skip + winning-id
  #                             precedence mirrored from the instance path.
  #
  # ## Query bound
  #
  # Database mode performs up to three SELECTs — one bulk Value query, one
  # field-association query for those values, and one definition query for the
  # union of requested partitions. The preloaded mode performs one fresh
  # definition SELECT and reads Value/field association targets in memory;
  # `fields: []` bypasses even that definition query. Both bounds are
  # independent of record count and partition cardinality.
  #
  # ## Single-class invariant
  #
  # The polymorphic value query targets the host's canonical Rails
  # `polymorphic_name`, so an STI subclass reads rows stored for its base
  # class. Mixed, unrelated input would still be invalid; STI subclasses pass
  # via `records.all?(host_class)`.
  class BulkRead
    def initialize(host_class:, records:, fields: nil, source: :database)
      @host_class = host_class
      @records    = records
      @fields     = fields
      @source     = source
    end

    def to_hash
      validate_source!

      records = coerce_records
      return {} if records.empty?

      validate_record_classes!(records)

      selected_names = normalize_fields
      return empty_results(records) if selected_names == []

      tuples_by_record = group_by_tuple(records)
      winning_ids_by_tuple = winning_ids_by_tuple(tuples_by_record.values.uniq, selected_names)
      values_by_record_id = if @source == :preloaded
                              preloaded_values(records, tuples_by_record, winning_ids_by_tuple, selected_names)
                            else
                              preload_values(records, winning_ids_by_tuple, selected_names)
                            end

      build_result(records, tuples_by_record, winning_ids_by_tuple, values_by_record_id, selected_names)
    end

    private

    attr_reader :host_class

    def validate_source!
      return if %i[database preloaded].include?(@source)

      raise ArgumentError, "typed_eav_hash_for source must be :database or :preloaded"
    end

    def normalize_fields
      return nil if @fields.nil?

      names = if @fields.is_a?(String) || @fields.is_a?(Symbol)
                [@fields]
              elsif @fields.respond_to?(:to_a)
                @fields.to_a
              else
                raise ArgumentError, "typed_eav_hash_for fields must be an Enumerable of String/Symbol names"
              end

      names.map do |name|
        next name if name.is_a?(String)
        next name.to_s if name.is_a?(Symbol)

        raise ArgumentError,
              "typed_eav_hash_for fields must contain only String or Symbol names; got #{name.inspect}"
      end.uniq
    end

    def coerce_records
      raise ArgumentError, "typed_eav_hash_for requires an Enumerable of records, got nil" if @records.nil?

      @records.to_a
    end

    def empty_results(records)
      records.to_h { |record| [record.id, {}] }
    end

    def validate_record_classes!(records)
      return if records.all?(host_class)

      classes = records.map { |r| r.class.name }.uniq
      raise ArgumentError,
            "typed_eav_hash_for expects records of class #{host_class.name} (or its subclasses); " \
            "got mixed classes: #{classes.join(", ")}"
    end

    def group_by_tuple(records)
      # Memo of record -> tuple key so each record only computes its tuple once.
      records.index_with { |r| [r.typed_eav_scope, r.typed_eav_parent_scope] }
    end

    def winning_ids_by_tuple(tuples, selected_names)
      TypedEAV::Partition::DefinitionBatch
        .resolve(entity_type: host_class.polymorphic_name, tuples: tuples)
        .transform_values do |fields_by_name|
          fields_by_name.each_with_object({}) do |(name, field), winners|
            next if selected_names&.exclude?(name)

            winners[name] = field.id
          end
        end
    end

    def preload_values(records, winning_ids_by_tuple, selected_names)
      relation = TypedEAV::Value
                 .includes(:field)
                 .where(entity_type: host_class.polymorphic_name, entity_id: records.map(&:id))

      if selected_names
        field_ids = winning_ids_by_tuple.values.flat_map(&:values).uniq
        return {} if field_ids.empty?

        relation = relation.where(field_id: field_ids)
      end

      rows = relation.to_a
      rows.group_by(&:entity_id)
    end

    # Reuse a caller's fully-preloaded association graph without allowing an
    # accidental association reader to issue an N+1 query. `target` is used
    # deliberately: unlike `record.typed_values`, it never loads an unloaded
    # association. For a selected projection, filter each target by the
    # winning field IDs before checking field associations; unselected Values
    # therefore need not have their `field` association loaded. The all-fields
    # path retains the stricter check over every Value, including orphan rows
    # whose loaded field target is nil.
    def preloaded_values(records, tuples_by_record, winning_ids_by_tuple, selected_names)
      unloaded_records = records.reject { |record| record.association(:typed_values).loaded? }
      if unloaded_records.any?
        raise ArgumentError,
              "typed_eav_hash_for source: :preloaded requires the typed_values association " \
              "to be preloaded for every record"
      end

      records.to_h do |record|
        values = record.association(:typed_values).target
        if selected_names
          tuple = tuples_by_record.fetch(record)
          selected_ids = winning_ids_by_tuple.fetch(tuple, {}).values
          values = values.select { |value| selected_ids.include?(effective_field_id(value)) }
        end

        unloaded_values = values.reject { |value| value.association(:field).loaded? }
        if unloaded_values.any?
          raise ArgumentError,
                "typed_eav_hash_for source: :preloaded requires the field association " \
                "to be preloaded for every typed value"
        end

        [record.id, values]
      end
    end

    def effective_field_id(value)
      return value.field_id if value.field_id

      association = value.association(:field)
      association.loaded? ? association.target&.id : nil
    end

    def build_result(records, tuples_by_record, winning_ids_by_tuple, values_by_record_id, selected_names)
      records.each_with_object({}) do |record, result|
        tuple_key            = tuples_by_record[record]
        winning_ids_by_name  = winning_ids_by_tuple.fetch(tuple_key, {})
        rows                 = values_by_record_id.fetch(record.id, [])
        result[record.id]    = inner_hash_for(rows, winning_ids_by_name, selected_names)
      end
    end

    # Builds the inner `{ field_name => value }` hash for a single record.
    #
    # Skips orphans (`tv.field` nil — definition deleted via raw SQL or a
    # Phase 02 `:nullify` cascade). When a winning field_id is registered
    # for the name, only its row may surface (scoped-beats-global collision
    # precedence). When no winner is registered (definition deleted while
    # values remain), fall back to first-wins so the hash isn't lossy.
    def inner_hash_for(value_rows, winning_ids_by_name, selected_names)
      value_rows.each_with_object({}) do |tv, inner|
        next unless tv.field

        name = tv.field.name
        winning_id = winning_ids_by_name[name]
        # A selected field ID may be visible for another record's partition
        # tuple because the value preload spans all requested records. In a
        # projection, a name without a winner for this tuple is absent rather
        # than eligible for the all-fields stale-row fallback below.
        next if selected_names && !winning_id
        next assign_with_precedence(inner, name, tv, winning_id) if winning_id

        inner[name] = tv.value unless inner.key?(name)
      end
    end

    def assign_with_precedence(inner, name, value_row, winning_id)
      effective_id = value_row.field_id || value_row.field&.id
      inner[name] = value_row.value if effective_id == winning_id
    end
  end
end
