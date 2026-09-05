# frozen_string_literal: true

module TypedEAV
  # Bulk-read query object. Returns `{ record_id => { field_name => value } }`
  # for an Enumerable of host records — the class-method bulk variant of
  # `HasTypedEAV::InstanceMethods#typed_eav_hash`. N+1-free regardless of
  # record count or field count.
  #
  # ## Pipeline (one batched definition query + one bulk value preload)
  #
  #   1. validate_records!    — nil -> ArgumentError; single-class invariant
  #   2. group_by_tuple       — `[typed_eav_scope, typed_eav_parent_scope]`
  #   3. winning_ids_by_tuple — one `Partition::DefinitionBatch` query, then
  #                             extract the winning field ids per tuple
  #   4. preload_values       — single SELECT across ALL records
  #   5. build_result_hash    — per-record inner hash; orphan-skip + winning-id
  #                             precedence mirrored from the instance path.
  #
  # ## Query bound
  #
  #   - 1 SELECT typed_eav_values WHERE entity_type=? AND entity_id IN (?)
  #   - 1 SELECT typed_eav_fields WHERE id IN (?)           (via includes)
  #   - 1 SELECT typed_eav_fields for the union of requested partitions
  #
  # Total: 3 queries — independent of record count and partition cardinality.
  #
  # ## Single-class invariant
  #
  # The polymorphic value query targets the host's canonical Rails
  # `polymorphic_name`, so an STI subclass reads rows stored for its base
  # class. Mixed, unrelated input would still be invalid; STI subclasses pass
  # via `records.all?(host_class)`.
  class BulkRead
    def initialize(host_class:, records:)
      @host_class = host_class
      @records    = records
    end

    def to_hash
      records = coerce_records
      return {} if records.empty?

      validate_record_classes!(records)

      tuples_by_record = group_by_tuple(records)
      winning_ids_by_tuple = winning_ids_by_tuple(tuples_by_record.values.uniq)
      values_by_record_id = preload_values(records)

      build_result(records, tuples_by_record, winning_ids_by_tuple, values_by_record_id)
    end

    private

    attr_reader :host_class

    def coerce_records
      raise ArgumentError, "typed_eav_hash_for requires an Enumerable of records, got nil" if @records.nil?

      @records.to_a
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

    def winning_ids_by_tuple(tuples)
      TypedEAV::Partition::DefinitionBatch
        .resolve(entity_type: host_class.polymorphic_name, tuples: tuples)
        .transform_values { |fields_by_name| fields_by_name.transform_values(&:id) }
    end

    def preload_values(records)
      rows = TypedEAV::Value
             .includes(:field)
             .where(entity_type: host_class.polymorphic_name, entity_id: records.map(&:id))
             .to_a
      rows.group_by(&:entity_id)
    end

    def build_result(records, tuples_by_record, winning_ids_by_tuple, values_by_record_id)
      records.each_with_object({}) do |record, result|
        tuple_key            = tuples_by_record[record]
        winning_ids_by_name  = winning_ids_by_tuple.fetch(tuple_key, {})
        rows                 = values_by_record_id.fetch(record.id, [])
        result[record.id]    = inner_hash_for(rows, winning_ids_by_name)
      end
    end

    # Builds the inner `{ field_name => value }` hash for a single record.
    #
    # Skips orphans (`tv.field` nil — definition deleted via raw SQL or a
    # Phase 02 `:nullify` cascade). When a winning field_id is registered
    # for the name, only its row may surface (scoped-beats-global collision
    # precedence). When no winner is registered (definition deleted while
    # values remain), fall back to first-wins so the hash isn't lossy.
    def inner_hash_for(value_rows, winning_ids_by_name)
      value_rows.each_with_object({}) do |tv, inner|
        next unless tv.field

        name = tv.field.name
        winning_id = winning_ids_by_name[name]
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
