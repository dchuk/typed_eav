# frozen_string_literal: true

module TypedEAV
  # One field-owned seam for native typed-column storage behavior.
  #
  # The contract intentionally delegates to the existing field type hooks so
  # custom field authors keep the same public extension points while callers
  # stop knowing which pieces belong together.
  class FieldStorageContract
    def initialize(field)
      @field = field
    end

    def value_columns
      field.class.value_columns
    end

    def query_column(operator)
      field.class.operator_column(operator)
    end

    def read(value_record)
      field.read_value(value_record)
    end

    def write(value_record, casted)
      field.write_value(value_record, casted)
    end

    def apply_default(value_record)
      field.apply_default_to(value_record)
    end

    def changed?(value_record)
      value_columns.any? { |column| value_record.saved_change_to_attribute?(column) }
    end

    def before_snapshot(value_record, change_type)
      case change_type.to_sym
      when :create
        {}
      when :update
        value_columns.to_h do |column|
          [column.to_s, value_record.attribute_before_last_save(column.to_s)]
        end
      when :destroy
        value_columns.to_h { |column| [column.to_s, value_record[column]] }
      else
        raise ArgumentError, "Unsupported change_type: #{change_type.inspect}"
      end
    end

    def after_snapshot(value_record, change_type)
      case change_type.to_sym
      when :create, :update
        value_columns.to_h { |column| [column.to_s, value_record[column]] }
      when :destroy
        {}
      else
        raise ArgumentError, "Unsupported change_type: #{change_type.inspect}"
      end
    end

    private

    attr_reader :field
  end
end
