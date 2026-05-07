# frozen_string_literal: true

module TypedEAV
  # Internal executor for host-class bulk typed-value writes.
  #
  # Host models keep the public `bulk_set_typed_eav_values` API; this module
  # owns the transaction shape, savepoint isolation, error aggregation, field
  # name resolution delegation, and version-group stamping.
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

        execute_records(records, vbn, effective_grouping, field_uuids)
      end

      def apply_record_save(record:, vbn:, effective_grouping:, uuids:, accumulator:)
        push_uuid = case effective_grouping
                    when :per_record then uuids[:record]
                    when :per_field  then uuids[:field].values.first
                    end

        do_save = lambda do
          record.typed_eav_attributes = vbn.map { |name, value| { name: name, value: value } }
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

      def execute_records(records, vbn, effective_grouping, field_uuids)
        successes = []
        errors_by_record = {}

        with_bulk_definitions_memo do
          ActiveRecord::Base.cache do
            ActiveRecord::Base.transaction do
              records.each do |record|
                record_uuid = effective_grouping == :per_record ? SecureRandom.uuid : nil

                ActiveRecord::Base.transaction(requires_new: true) do
                  apply_record_save(
                    record: record,
                    vbn: vbn,
                    effective_grouping: effective_grouping,
                    uuids: { record: record_uuid, field: field_uuids },
                    accumulator: { successes: successes, errors_by_record: errors_by_record },
                  )
                end
              end
            end
          end
        end

        { successes: successes, errors_by_record: errors_by_record }
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

      def validate_record_classes!(host_class, records)
        return if records.all?(host_class)

        classes = records.map { |record| record.class.name }.uniq
        raise ArgumentError,
              "bulk_set_typed_eav_values expects records of class #{host_class.name} (or its subclasses); " \
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
