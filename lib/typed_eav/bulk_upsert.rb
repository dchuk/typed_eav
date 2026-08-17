# frozen_string_literal: true

module TypedEAV
  # Reduced-semantics, SQL-oriented bulk value writer.
  #
  # This API intentionally does not run host callbacks, host validations,
  # Value callbacks, versioning, or per-record error isolation. Callers must
  # acknowledge those semantics explicitly. It pre-casts and validates every
  # row in a transaction unit before issuing one upsert batch on the host
  # model's connection. Scope resolution and field casting remain authoritative.
  module BulkUpsert
    TYPE_COLUMNS = %i[
      string_value text_value boolean_value integer_value decimal_value date_value datetime_value json_value
    ].freeze

    class << self
      # rubocop:disable Metrics/ParameterLists -- transaction controls are explicit API contract.
      def execute(
        host_class:, records:, values_by_field_name:, acknowledge_reduced_semantics:, transaction: :all, chunk_size: nil
      )
        validate_options!(records, values_by_field_name, acknowledge_reduced_semantics, transaction, chunk_size)
        records = records.to_a
        return 0 if records.empty?

        validate_record_classes!(host_class, records)
        units = transaction == :all ? [records] : records.each_slice(chunk_size)
        units.sum { |unit| write_unit(host_class, unit, values_by_field_name) }
      end

      private

      def write_unit(host_class, records, values_by_field_name)
        rows = records.flat_map do |record|
          fields = TypedEAV::Partition.definitions_by_name(
            host_class.typed_eav_definitions(
              scope: record.typed_eav_scope,
              parent_scope: record.typed_eav_parent_scope,
            ),
          )
          values_by_field_name.filter_map do |name, raw|
            field = fields[name.to_s]
            raise ArgumentError, "bulk_upsert field is not visible for #{record.class.name}: #{name}" unless field

            build_row(host_class, record, field, raw)
          end
        end
        return 0 if rows.empty?

        host_class.transaction do
          TypedEAV::Value.upsert_all(rows, unique_by: :idx_te_values_entity_field) # rubocop:disable Rails/SkipsModelValidations -- reduced API explicitly prevalidates before SQL.
        end
        rows.length
      end

      def build_row(host_class, record, field, raw)
        value = TypedEAV::Value.new(entity: record, field: field)
        value.value = raw
        value.valid?
        errors = value.errors.to_hash.except(:field, "field")
        raise ArgumentError, "bulk_upsert validation failed for #{field.name}: #{errors.inspect}" if errors.any?

        now = Time.current
        row = {
          entity_type: host_class.polymorphic_name,
          entity_id: record.id,
          field_id: field.id,
          created_at: now,
          updated_at: now,
        }
        TYPE_COLUMNS.each { |column| row[column] = value[column] }
        row
      end

      def validate_options!(records, values, acknowledged, transaction, chunk_size)
        raise ArgumentError, "bulk_upsert requires an Enumerable of records" if records.nil?
        raise ArgumentError, "bulk_upsert requires a Hash of values_by_field_name" unless values.is_a?(Hash)
        raise ArgumentError, "bulk_upsert requires acknowledge_reduced_semantics: true" unless acknowledged == true
        return if transaction == :all
        return if transaction == :chunks && chunk_size.is_a?(Integer) && chunk_size.positive?

        raise ArgumentError, "transaction must be :all or :chunks with a positive chunk_size"
      end

      def validate_record_classes!(host_class, records)
        return if records.all?(host_class)

        raise ArgumentError, "bulk_upsert expects records of class #{host_class.name}"
      end
    end
    # rubocop:enable Metrics/ParameterLists
  end
end
