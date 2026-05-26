# frozen_string_literal: true

module TypedEAV
  module Field
    # Long-text-typed field stored in the `text_value` column. Kept as a
    # direct child of `Field::Base` (per ADR-0004 — array types,
    # LongText, File, Image, Reference all stay direct children; only
    # Text/Email/Url moved into the new `Field::ValidatedString` family).
    # Inlines its own min_length / max_length check rather than joining
    # the ValidatedString family because LongText does NOT carry the
    # `:pattern` option, the `max_gte_min_length` guard, or the
    # `validate_pattern_syntax` guard — the family base would attach
    # validation surface LongText doesn't want.
    class LongText < Base
      value_column :text_value

      store_accessor :options, :min_length, :max_length

      def cast(raw)
        [raw&.to_s, false]
      end

      def validate_typed_value(record, val)
        opts = options_hash
        str = val.to_s
        if opts[:min_length] && str.length < opts[:min_length].to_i
          record.errors.add(:value, :too_short, count: opts[:min_length])
        end
        return unless opts[:max_length] && str.length > opts[:max_length].to_i

        record.errors.add(:value, :too_long, count: opts[:max_length])
      end
    end
  end
end
