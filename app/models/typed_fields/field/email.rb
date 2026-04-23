# frozen_string_literal: true

module TypedFields
  module Field
    class Email < Base
      value_column :string_value

      store_accessor :options, :min_length, :max_length, :pattern
      validate :validate_pattern_syntax

      EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      def cast(raw)
        [raw&.to_s&.strip&.downcase, false]
      end

      def email_format_valid?(val)
        EMAIL_FORMAT.match?(val)
      end

      def validate_typed_value(record, val)
        validate_length(record, val)
        validate_pattern(record, val) if pattern.present?
        record.errors.add(:value, "is not a valid email address") unless email_format_valid?(val)
      end

      private

      def validate_pattern_syntax
        return if pattern.blank?
        Regexp.new(pattern)
      rescue RegexpError => e
        errors.add(:pattern, "is invalid: #{e.message}")
      end
    end
  end
end
