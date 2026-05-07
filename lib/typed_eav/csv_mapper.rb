# frozen_string_literal: true

require "csv"

module TypedEAV
  # Pure stateless CSV-to-attributes transform.
  #
  # `TypedEAV::CSVMapper.row_to_attributes(row, mapping, fields_by_name: nil)`
  # turns a single CSV row (`CSV::Row` for header-mapped files, or a plain
  # `Array` for index-mapped headerless files) into a `Result` value object
  # with `.attributes`, `.errors`, and `.success?` / `.failure?` predicates.
  # Never raises on per-row content errors — cast failures land in `errors`,
  # NOT in exceptions. The only ArgumentError path is mapping-shape
  # validation, which fires before any row processing.
  #
  # ## Operating modes
  #
  # The 2-arg public form `row_to_attributes(row, mapping)` is the
  # **passthrough mode**: raw cell values flow through unchanged keyed by
  # the mapped field name. No coercion is attempted, no errors are possible.
  # This honors the public 2-arg surface in CONTEXT line 13 + ROADMAP §Phase
  # 6 success criterion exactly. Use this when the caller only needs CSV
  # mapping (header → field-name) without typed coercion — e.g., when
  # building a preview before the host record's partition is known.
  #
  # The 3-arg form `row_to_attributes(row, mapping, fields_by_name:
  # defs_by_name)` is the **typed mode**: per-cell coercion runs through
  # `field.cast(raw)` (the existing tuple contract documented on
  # `TypedEAV::Field::Base#cast`). Cast failures (`invalid? == true`) land
  # in `Result#errors` keyed by the field name, with the AR-symmetric
  # message `"is invalid"`. Empty cells (nil / empty string) cast to nil
  # per the `field.cast` contract and produce `attributes[name] = nil` with
  # NO error. The caller is expected to pass the result of
  # `record.class.typed_eav_definitions(scope:, parent_scope:).index_by(&:name)`
  # (or equivalent) — the mapper has no record context and does not resolve
  # fields itself.
  #
  # ## Mapping shape
  #
  # Single Hash. Keys are EITHER all `String` (CSV header names) OR all
  # `Integer` (column indexes for headerless files). Mixed-key mappings
  # raise `ArgumentError` immediately, before any row is touched, with a
  # remediation message that tells the caller how to fix it.
  #
  # Mapping VALUES are field names — accepted as Symbol or String; the
  # mapper coerces to String before lookup in `fields_by_name`. This
  # matches the codebase convention where `field.name` is always a String.
  #
  # ## Unknown field in mapping (typed mode)
  #
  # When a mapping value (e.g. `:foo`) does NOT appear in `fields_by_name`,
  # the cell is silently SKIPPED — it does NOT produce an error and does
  # NOT appear in `Result#attributes`. Rationale: the mapper is a pure
  # transform and has no record context. Mapping misconfiguration is a
  # caller concern; callers that want to detect it can compare
  # `result.attributes.keys` against the expected set. In passthrough mode
  # there is no `fields_by_name` to look up against, so every mapped cell
  # flows through unconditionally.
  #
  # ## Foundational principle
  #
  # NO HARDCODED ATTRIBUTE REFERENCES. The mapper resolves field metadata
  # via the `fields_by_name:` keyword argument supplied by the caller —
  # the mapper itself never inspects record attributes or partition state.
  # Every field touch goes through `field.cast(raw)` which dispatches via
  # the existing per-type cast contract.
  module CSVMapper
    # Plain value object — NOT an ActiveRecord model. No callbacks, no
    # validations, no DB interaction. Two frozen Hashes; `success?` is just
    # `errors.empty?`. Callers that need to combine multiple row Results
    # into a batch view do so by composing the immutable Hashes in their
    # own code (e.g., `results.flat_map(&:errors).reduce({}, :merge)`); the
    # mapper does not provide a "merge" helper in v0.6.0.
    class Result
      attr_reader :attributes, :errors

      def initialize(attributes:, errors:)
        @attributes = attributes.freeze
        @errors = errors.freeze
      end

      def success?
        @errors.empty?
      end

      def failure?
        !success?
      end
    end

    class << self
      # Transform a single row into a `Result`. See module-level docs for
      # the full contract. Returns a `Result`; only raises on mapping-shape
      # errors (mixed String + Integer keys).
      def row_to_attributes(row, mapping, fields_by_name: nil)
        validate_mapping_keys!(mapping)

        attributes = {}
        errors = {}

        mapping.each do |source_key, raw_field_name|
          # Unified cell read: both `CSV::Row#[String]` and `Array#[Integer]`
          # work via `[]` — homogeneous key validation above ensures
          # `source_key` matches the row representation (header name vs
          # index).
          raw_cell = row[source_key]

          # Codebase convention: field names are always Strings on the AR
          # side. Mapping values may be Symbol or String — coerce here so
          # the lookup against `fields_by_name` and the keys in
          # `attributes` / `errors` are consistent regardless of caller
          # input style.
          name = raw_field_name.to_s

          if fields_by_name.nil?
            # Passthrough mode — no coercion, no errors possible. Honors
            # the 2-arg public surface in CONTEXT line 13 + ROADMAP §Phase
            # 6. Cell flows through unchanged.
            attributes[name] = raw_cell
          else
            # Typed mode — silently skip unknown fields (see module docs).
            field = fields_by_name[name]
            next if field.nil?

            casted, invalid = field.cast(raw_cell)
            if invalid
              # AR-symmetric message; matches `errors_by_record` in the
              # bulk-write surface and `errors.add(:value, :invalid)` in
              # `Value#validate_value`. Plain Hash with String keys per
              # RESEARCH §Open-Question Resolutions §errors_hash shape.
              (errors[name] ||= []) << "is invalid"
            else
              attributes[name] = casted
            end
          end
        end

        Result.new(attributes: attributes, errors: errors)
      end

      private

      # Mapping-shape validation: keys must be all-String OR all-Integer.
      # Mixed keys raise immediately, BEFORE any row processing — fail
      # fast on configuration errors so the caller catches them on the
      # first invocation rather than silently producing partial Results.
      def validate_mapping_keys!(mapping)
        key_classes = mapping.keys.map(&:class).uniq
        return if key_classes == [String] || key_classes == [Integer] || key_classes.empty?

        raise ArgumentError,
              "CSVMapper mapping must use either all String keys (CSV headers) " \
              "or all Integer keys (column indexes), not both. " \
              "Got: #{mapping.inspect}"
      end
    end
  end
end
