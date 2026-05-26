# frozen_string_literal: true

module TypedEAV
  module Field
    # Email-typed field. Inherits `string_value` storage shape, the
    # `min_length` / `max_length` / `pattern` `store_accessor`, the
    # `max_gte_min_length` guard, and the `validate_pattern_syntax` guard
    # from `Field::ValidatedString`. Adds the `EMAIL_FORMAT` regex and
    # layers the format check onto `validate_typed_value` via `super`.
    #
    # Latent-bug fix (per ADR-0004): `max_gte_min_length` (previously
    # only on Text) now applies here — an Email field configured with
    # `max_length < min_length` fails at field-save.
    class Email < ValidatedString
      # Re-declare value_column for Ruby class-ivar non-inheritance — see
      # comment on Field::Text. STI dispatch is unaffected.
      value_column :string_value

      EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      def cast(raw)
        return [nil, false] if raw.nil?

        [raw.to_s.strip.downcase, false]
      end

      def email_format_valid?(val)
        EMAIL_FORMAT.match?(val)
      end

      def validate_typed_value(record, val)
        super
        record.errors.add(:value, "is not a valid email address") unless email_format_valid?(val)
      end
    end
  end
end
