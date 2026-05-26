# frozen_string_literal: true

require "uri"

module TypedEAV
  module Field
    # URL-typed field. Inherits `string_value` storage shape, the
    # `min_length` / `max_length` / `pattern` `store_accessor`, the
    # `max_gte_min_length` guard, and the `validate_pattern_syntax` guard
    # from `Field::ValidatedString`. Adds the `URL_FORMAT` regex
    # (http/https only) and layers the format check onto
    # `validate_typed_value` via `super`.
    #
    # Latent-bug fix (per ADR-0004): `max_gte_min_length` (previously
    # only on Text) now applies here — a Url field configured with
    # `max_length < min_length` fails at field-save.
    class Url < ValidatedString
      # Re-declare value_column for Ruby class-ivar non-inheritance — see
      # comment on Field::Text. STI dispatch is unaffected.
      value_column :string_value

      URL_FORMAT = /\A#{URI::DEFAULT_PARSER.make_regexp(%w[http https])}\z/

      def cast(raw)
        [raw&.to_s&.strip, false]
      end

      def url_format_valid?(val)
        URL_FORMAT.match?(val)
      end

      def validate_typed_value(record, val)
        super
        record.errors.add(:value, "is not a valid URL") unless url_format_valid?(val)
      end
    end
  end
end
