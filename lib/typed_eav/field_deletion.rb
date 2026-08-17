# frozen_string_literal: true

module TypedEAV
  # Explicit, resumable deletion for large Field value populations.
  module FieldDeletion
    module_function

    def destroy!(field, batch_size: 1_000)
      validate!(field, batch_size)
      last_id = 0

      loop do
        deleted = delete_batch!(field, last_id, batch_size)
        break if deleted.empty?

        last_id = deleted.last
      end

      finalize!(field, batch_size)
    end

    def validate!(field, batch_size)
      raise ArgumentError, "field must be persisted" unless field.persisted?
      raise ArgumentError, "field_dependent must be destroy" unless field.field_dependent == "destroy"
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, "batch_size must be a positive Integer"
      end
      if field.class.connection.transaction_open?
        raise ArgumentError, "destroy_with_values_in_batches! cannot run inside an open transaction"
      end

      pools = [field.class.connection_pool, TypedEAV::Value.connection_pool, TypedEAV::ValueVersion.connection_pool]
      return if pools.uniq.size == 1

      raise ArgumentError, "field deletion requires Field, Value, and ValueVersion to share a connection pool"
    end
    private_class_method :validate!

    def delete_batch!(field, last_id, batch_size)
      field.class.transaction do
        values = locked_values(field.id, last_id, batch_size).to_a
        values.each(&:destroy!)
        values.map(&:id)
      end
    end
    private_class_method :delete_batch!

    def locked_values(field_id, last_id, limit)
      TypedEAV::Value
        .where(field_id: field_id)
        .where("id > ?", last_id)
        .order(:id)
        .limit(limit)
        .lock
    end
    private_class_method :locked_values

    def finalize!(field, batch_size)
      field.class.transaction do
        field.lock!
        values = locked_values(field.id, 0, batch_size + 1).to_a
        raise "field deletion residual drain exceeded batch_size" if values.size > batch_size

        values.each(&:destroy!)
        raise "field deletion residual proof failed" if TypedEAV::Value.exists?(field_id: field.id)

        field.destroy!
      end
    end
    private_class_method :finalize!
  end
end
