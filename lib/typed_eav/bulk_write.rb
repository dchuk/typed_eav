# frozen_string_literal: true

module TypedEAV
  # Internal executor for host-class bulk typed-value writes.
  #
  # Host models keep the public `bulk_set_typed_eav_values` (uniform
  # values-per-record) and `bulk_set_typed_eav_values_per_record`
  # (per-record-varying values) APIs; this module owns the transaction
  # shape, savepoint isolation, error aggregation, field name resolution
  # delegation, and version-group stamping.
  #
  # ## Internal shape (G1, issue #18)
  #
  # Both public executors (`execute` and `execute_per_record`) are thin
  # adapters: they validate their inputs, resolve the version grouping,
  # allocate field UUIDs, and then hand off to `execute_pairs(pairs,
  # effective_grouping, field_uuids)` — a single shared loop that takes
  # ordered `[record, vbn]` pairs and runs the outer-transaction-plus-
  # savepoint-per-record envelope.
  #
  # Pair-shaped (not Hash-shaped) so `execute`'s `[record, vbn]` list can
  # carry duplicate in-memory instances of the same persisted row without
  # silently collapsing them via Hash-key collision — preserving
  # `execute`'s byte-for-byte behavior contract.
  module BulkWrite
    class << self
      def execute(host_class:, records:, values_by_field_name:, version_grouping: :default)
        validate_inputs!(records, values_by_field_name, version_grouping)

        records = records.to_a
        return { successes: [], errors_by_record: {} } if records.empty?

        validate_record_classes!(host_class, records)

        effective_grouping = resolve_grouping(version_grouping)
        vbn = values_by_field_name.transform_keys(&:to_s)
        field_uuids = effective_grouping == :per_field ? vbn.keys.index_with { SecureRandom.uuid } : nil

        execute_pairs(records.map { |r| [r, vbn] }, effective_grouping, field_uuids)
      end

      # Per-record-varying sibling to `execute`. Accepts a `Hash<host_record,
      # Hash<field_name, value>>` and routes each record's value-set through
      # the same shared `execute_pairs` envelope.
      #
      # Empty `values_by_record` short-circuits to the empty result without
      # opening a transaction (matches `execute`'s empty-records contract).
      def execute_per_record(host_class:, values_by_record:, version_grouping: :default)
        validate_per_record_inputs!(values_by_record, version_grouping)

        return { successes: [], errors_by_record: {} } if values_by_record.empty?

        validate_record_classes!(host_class, values_by_record.keys, method: :bulk_set_typed_eav_values_per_record)

        effective_grouping = resolve_grouping(version_grouping)
        pairs = values_by_record.map { |record, vbn| [record, vbn.transform_keys(&:to_s)] }
        field_uuids = if effective_grouping == :per_field
                        pairs.flat_map { |(_record, vbn)| vbn.keys }.uniq.index_with { SecureRandom.uuid }
                      end

        execute_pairs(pairs, effective_grouping, field_uuids)
      end

      def apply_record_save(record:, vbn:, effective_grouping:, uuids:, accumulator:)
        push_uuid = case effective_grouping
                    when :per_record then uuids[:record]
                    when :per_field  then uuids[:field].values.first
                    end

        do_save = lambda do
          record.typed_eav_attributes = vbn.map { |name, value| typed_eav_entry_for(name, value) }
          stamp_pending_version_group_ids(record, effective_grouping, uuids)

          if record.save
            accumulator[:successes] << record
          else
            accumulator[:errors_by_record][record] = record.errors.messages.transform_keys(&:to_s)
            raise ActiveRecord::Rollback
          end
        end

        if push_uuid
          TypedEAV.with_context(version_group_id: push_uuid, &do_save)
        else
          do_save.call
        end
      end

      private

      # Shared loop over ordered `[record, vbn]` pairs. Holds the outer
      # transaction, the `ActiveRecord::Base.cache` block, the bulk-
      # definitions memo envelope, and the per-record `requires_new: true`
      # savepoint loop. Calls `apply_record_save` per iteration.
      #
      # Pair-shaped (not Hash-shaped) so duplicate in-memory instances of
      # the same persisted row iterate each instance separately — matters
      # for `execute`'s byte-for-byte behavior contract on
      # `[Entity.find(1), Entity.find(1)]`-shaped input.
      def execute_pairs(pairs, effective_grouping, field_uuids)
        successes = []
        errors_by_record = {}

        with_bulk_definitions_memo do
          ActiveRecord::Base.cache do
            ActiveRecord::Base.transaction do
              pairs.each do |(record, vbn)|
                record_uuid = effective_grouping == :per_record ? SecureRandom.uuid : nil
                record_field_uuids = record_scoped_field_uuids(field_uuids, vbn)

                with_record_scope(record) do
                  ActiveRecord::Base.transaction(requires_new: true) do
                    apply_record_save(
                      record: record,
                      vbn: vbn,
                      effective_grouping: effective_grouping,
                      uuids: { record: record_uuid, field: record_field_uuids },
                      accumulator: { successes: successes, errors_by_record: errors_by_record },
                    )
                  end
                end
              end
            end
          end
        end

        { successes: successes, errors_by_record: errors_by_record }
      end

      # For `:per_field`, the global `field_uuids` map covers the union of
      # field names across all records' value hashes. The per-record save
      # only needs the slice for the names actually being written on THIS
      # record so `apply_record_save`'s push_uuid lookup
      # (`uuids[:field].values.first`) stays well-defined.
      def record_scoped_field_uuids(field_uuids, vbn)
        return nil unless field_uuids

        vbn.keys.index_with { |name| field_uuids[name] }
      end

      # Honor the record's own `[scope, parent_scope]` when iterating a
      # potentially mixed-scope batch. Inside `TypedEAV.unscoped { ... }`,
      # `EntityQuery#resolve_scope` short-circuits to `ALL_SCOPES` and
      # ignores the explicit `scope:` kwarg — which would surface the
      # wrong field definitions for a record whose scope/parent_scope
      # differs from its siblings. We restore strict scoping per record by
      # temporarily clearing the `unscoped?` flag and pushing the record's
      # own tuple onto the `with_scope` stack. Records on hosts without
      # `scope_method:` (no `typed_eav_scope` to read) pass through
      # unchanged.
      def with_record_scope(record, &)
        scope_method = record.class.respond_to?(:typed_eav_scope_method) ? record.class.typed_eav_scope_method : nil
        return yield unless scope_method

        s  = record.typed_eav_scope
        ps = record.typed_eav_parent_scope

        # `:typed_eav_unscoped` is the same thread-local key used by
        # `TypedEAV.unscoped` / `TypedEAV.unscoped?` (the constant is
        # `private_constant` on `TypedEAV`; we use the literal symbol to
        # avoid reaching into private internals).
        prev_unscoped = Thread.current[:typed_eav_unscoped]
        Thread.current[:typed_eav_unscoped] = nil
        TypedEAV.with_scope([s, ps], &)
      ensure
        Thread.current[:typed_eav_unscoped] = prev_unscoped if scope_method
      end

      # Translates one `(name, value)` from a vbn hash into the nested-
      # attributes entry shape that `typed_eav_attributes=` expects.
      # `_destroy: true` shorthand (`{ "field" => { _destroy: true } }`)
      # is detected here and emitted as `{ name:, _destroy: true }` so
      # the value is removed rather than written as a literal Hash payload.
      def typed_eav_entry_for(name, value)
        return { name: name, _destroy: true } if destroy_marker?(value)

        { name: name, value: value }
      end

      def destroy_marker?(value)
        return false unless value.is_a?(Hash)

        flag = value[:_destroy] || value["_destroy"]
        ActiveRecord::Type::Boolean.new.cast(flag)
      end

      def validate_inputs!(records, values_by_field_name, version_grouping)
        if records.nil?
          raise ArgumentError,
                "bulk_set_typed_eav_values requires an Enumerable of records, got nil"
        end

        unless values_by_field_name.is_a?(Hash)
          raise ArgumentError,
                "bulk_set_typed_eav_values requires a Hash of values_by_field_name, " \
                "got #{values_by_field_name.class}"
        end

        validate_grouping!(version_grouping)
      end

      def validate_per_record_inputs!(values_by_record, version_grouping)
        unless values_by_record.is_a?(Hash)
          raise ArgumentError,
                "bulk_set_typed_eav_values_per_record requires a Hash of values_by_record, " \
                "got #{values_by_record.class}"
        end

        values_by_record.each do |record, vbn|
          next if vbn.is_a?(Hash)

          raise ArgumentError,
                "bulk_set_typed_eav_values_per_record: per-record value for #{record.inspect} " \
                "must be a Hash of field-name => value, got #{vbn.class}"
        end

        validate_grouping!(version_grouping)
      end

      def validate_grouping!(version_grouping)
        valid_grouping = %i[default per_record per_field none]
        unless valid_grouping.include?(version_grouping)
          raise ArgumentError,
                "version_grouping: #{version_grouping.inspect} is not supported. " \
                "Supported values: #{valid_grouping.map(&:inspect).join(", ")}."
        end

        return unless %i[per_record per_field].include?(version_grouping) && !TypedEAV.config.versioning

        raise ArgumentError,
              "version_grouping: #{version_grouping.inspect} was passed but versioning is disabled. " \
              "Set TypedEAV.config.versioning = true in your initializer, or pass " \
              "version_grouping: :none to opt out explicitly, or omit the kwarg to silently no-op."
      end

      def validate_record_classes!(host_class, records, method: :bulk_set_typed_eav_values)
        return if records.all?(host_class)

        classes = records.map { |record| record.class.name }.uniq
        raise ArgumentError,
              "#{method} expects records of class #{host_class.name} (or its subclasses); " \
              "got mixed classes: #{classes.join(", ")}"
      end

      def resolve_grouping(version_grouping)
        if version_grouping == :default
          TypedEAV.config.versioning ? :per_record : :none
        else
          version_grouping
        end
      end

      def with_bulk_definitions_memo
        prior_memo = Thread.current[:typed_eav_bulk_defs_memo]
        Thread.current[:typed_eav_bulk_defs_memo] = {}
        yield
      ensure
        Thread.current[:typed_eav_bulk_defs_memo] = prior_memo
      end

      def stamp_pending_version_group_ids(record, effective_grouping, uuids)
        return if effective_grouping == :none

        record.typed_values.each do |value|
          next unless value.new_record? || value.changed?

          uuid = case effective_grouping
                 when :per_record then uuids[:record]
                 when :per_field  then uuids[:field][value.field&.name]
                 end
          value.pending_version_group_id = uuid if uuid
        end
      end
    end
  end
end
