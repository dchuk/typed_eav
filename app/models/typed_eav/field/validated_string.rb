# frozen_string_literal: true

require "timeout"

module TypedEAV
  module Field
    # Intermediate STI base for string-valued field families that share a
    # `min_length` / `max_length` / `pattern` validation surface.
    #
    # Leaves: `Field::Text`, `Field::Email`, `Field::Url`.
    #
    # Hoists the `string_value` storage declaration, the
    # `store_accessor :options, :min_length, :max_length, :pattern` line,
    # the `min_length` / `max_length` numericality validators, the
    # `max_gte_min_length` guard, the `validate_pattern_syntax` guard, and
    # the protected `validate_length` / `validate_pattern` helpers — all
    # previously duplicated across Text/Email/Url with one drift gap
    # (`max_gte_min_length` was only on Text).
    #
    # Default `validate_typed_value` runs `validate_length` plus
    # `validate_pattern if pattern.present?`. Leaves override and call
    # `super` to layer on their format-specific check (Email's
    # `EMAIL_FORMAT`, Url's `URL_FORMAT`).
    #
    # Public extension point: external authors can subclass this directly
    # to inherit the full min/max/pattern surface (see README §"Custom field
    # types"). STI dispatch is unaffected — leaves still store their own
    # class names in the `type` column.
    class ValidatedString < Base
      value_column :string_value

      store_accessor :options, :min_length, :max_length, :pattern

      validates :min_length, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
      validates :max_length, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
      validate :max_gte_min_length
      validate :validate_pattern_syntax

      def validate_typed_value(record, val)
        validate_length(record, val)
        validate_pattern(record, val) if pattern.present?
      end

      protected

      def validate_length(record, val)
        opts = options_hash
        str = val.to_s
        if opts[:min_length] && str.length < opts[:min_length].to_i
          record.errors.add(:value, :too_short, count: opts[:min_length])
        end
        return unless opts[:max_length] && str.length > opts[:max_length].to_i

        record.errors.add(:value, :too_long, count: opts[:max_length])
      end

      def validate_pattern(record, val)
        opts = options_hash
        pattern = opts[:pattern]
        return if pattern.blank?

        matched = Timeout.timeout(1) { Regexp.new(pattern).match?(val.to_s) }
        record.errors.add(:value, :invalid) unless matched
      rescue RegexpError
        record.errors.add(:value, "has an invalid pattern configured")
      rescue Timeout::Error
        record.errors.add(:value, "pattern validation timed out")
      end

      private

      def max_gte_min_length
        return unless min_length && max_length

        errors.add(:max_length, "must be >= min_length") if max_length < min_length
      end

      def validate_pattern_syntax
        return if pattern.blank?

        Regexp.new(pattern)
      rescue RegexpError => e
        errors.add(:pattern, "is invalid: #{e.message}")
      end
    end
  end
end
