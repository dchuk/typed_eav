---
title: "Field types and validation"
---

# Field types and validation

[Documentation home](../index.md)

## Field Types

| Type | Column | Ruby Type | Options |
|------|--------|-----------|---------|
| `Text` | `string_value` | String | `min_length`, `max_length`, `pattern` |
| `LongText` | `text_value` | String | `min_length`, `max_length` |
| `Integer` | `integer_value` | Integer | `min`, `max` |
| `Decimal` | `decimal_value` | BigDecimal | `min`, `max`, `precision_scale` |
| `Boolean` | `boolean_value` | Boolean | |
| `Date` | `date_value` | Date | `min_date`, `max_date` |
| `DateTime` | `datetime_value` | Time | `min_datetime`, `max_datetime` |
| `Select` | `string_value` | String | options via `TypedEAV::Option` |
| `MultiSelect` | `json_value` | Array | options via `TypedEAV::Option` |
| `IntegerArray` | `json_value` | Array | `min_size`, `max_size`, `min`, `max` |
| `DecimalArray` | `json_value` | Array | `min_size`, `max_size` |
| `TextArray` | `json_value` | Array | `min_size`, `max_size` |
| `DateArray` | `json_value` | Array | `min_size`, `max_size` |
| `Email` | `string_value` | String | auto-downcases, strips whitespace |
| `Url` | `string_value` | String | strips whitespace |
| `Color` | `string_value` | String | hex color values |
| `Json` | `json_value` | Hash/Array | arbitrary JSON |
| `Currency` | `decimal_value` + `string_value` | `{amount: BigDecimal, currency: String}` | `default_currency`, `allowed_currencies` |
| `Percentage` | `decimal_value` | BigDecimal (0..1 range) | `decimal_places`, `display_as: :fraction \| :percent` |
| `Image` | `string_value` (signed_id) + `:attachment` has_one_attached | String (Active Storage signed_id) | `allowed_content_types`, `max_size_bytes` |
| `File` | `string_value` (signed_id) + `:attachment` has_one_attached | String (Active Storage signed_id) | `allowed_content_types`, `max_size_bytes` |
| `Reference` | `integer_value` (FK) | Integer (target record ID) | `target_entity_type`, `target_scope` |

## Sections (Optional UI Grouping)

```ruby
general = TypedEAV::Section.create!(
  name: "General Info",
  code: "general",
  entity_type: "Contact",
  sort_order: 1
)

social = TypedEAV::Section.create!(
  name: "Social Media",
  code: "social",
  entity_type: "Contact",
  sort_order: 2
)

TypedEAV::Field::Text.create!(
  name: "twitter_handle",
  entity_type: "Contact",
  section: social
)
```

## Custom Field Types

Override `cast(raw)` to return a `[casted_value, invalid?]` tuple.
`invalid?` tells `Value#validate_value` whether to surface `:invalid`
(vs `:blank`) when raw input can't be coerced. For types that never
fail to coerce, always return `[value, false]`.

```ruby
# app/models/fields/phone.rb
module Fields
  class Phone < TypedEAV::Field::Base
    value_column :string_value
    operators :eq, :contains, :starts_with, :is_null, :is_not_null

    def cast(raw)
      # Strip everything but digits and +; never rejects as invalid
      [raw&.to_s&.gsub(/[^\d+]/, ""), false]
    end
  end
end

# Register it
TypedEAV.configure do |c|
  c.register_field_type :phone, "Fields::Phone"
end
```

### Family intermediate bases (extension points)

`Field::Base` is the universal parent, but three intermediate family
bases collapse the most common per-leaf duplication. Pick the right
parent and you inherit the family's validation surface for free.

- **`TypedEAV::Field::ValidatedString`** — subclass when your custom
  type stores in `string_value` and wants a min/max-length + regex-pattern
  validation surface. Inherits `value_column :string_value`,
  `store_accessor :options, :min_length, :max_length, :pattern`,
  numericality validators on `min_length` / `max_length`, a
  `max_gte_min_length` guard that rejects inverted bounds at field-save,
  and a `validate_pattern_syntax` guard that rejects bad regexes at
  field-save. The default `validate_typed_value(record, val)` runs
  `validate_length` plus `validate_pattern if pattern.present?`. Override
  it and call `super` to layer on a format-specific check (the built-in
  `Field::Email` / `Field::Url` are the canonical pattern).

  ```ruby
  class Fields::Slug < TypedEAV::Field::ValidatedString
    SLUG_FORMAT = /\A[a-z0-9-]+\z/

    def cast(raw)
      [raw&.to_s&.strip&.downcase, false]
    end

    def validate_typed_value(record, val)
      super  # length + pattern from the family base
      record.errors.add(:value, "is not a valid slug") unless SLUG_FORMAT.match?(val.to_s)
    end
  end
  ```

- **`TypedEAV::Field::RangeBounded`** — subclass when your custom type
  stores a single comparable value (numeric or temporal) constrained by
  a min/max bound. Each leaf still declares its own `value_column` and
  its own `store_accessor` (key names vary by family member: `:min`/`:max`
  for numeric; `:min_date`/`:max_date` for date;
  `:min_datetime`/`:max_datetime` for datetime). The family base
  provides protected `validate_range` / `validate_date_range` /
  `validate_datetime_range` helpers. Each leaf should pair its
  `store_accessor` with the macro
  `validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min`
  (or the analogous form for the leaf's key names) so inverted bounds
  fail at field-save.

  ```ruby
  class Fields::Score < TypedEAV::Field::RangeBounded
    value_column :integer_value

    store_accessor :options, :min, :max
    validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

    def cast(raw)
      raw.nil? ? [nil, false] : [Integer(raw.to_s, exception: false), raw.to_s.empty? ? false : true]
    end

    def validate_typed_value(record, val)
      validate_range(record, val)
    end
  end
  ```

- **`TypedEAV::Field::Optionable`** — `include` this concern when your
  custom type's valid values are drawn from a `Field::Option` set.
  Provides `optionable? = true`, a public-facing sorted
  `allowed_values` helper, and protected
  `validate_option_inclusion` / `validate_multi_option_inclusion`
  helpers. Mixin (not inheritance) because option-set field types may
  use different `value_column`s — the built-in `Field::Select` stores in
  `string_value` while `Field::MultiSelect` stores in `json_value`, and
  both stay as direct children of `Field::Base`.

  ```ruby
  class Fields::Tag < TypedEAV::Field::Base
    include TypedEAV::Field::Optionable

    value_column :string_value
    operators :eq, :not_eq, :is_null, :is_not_null

    def cast(raw)
      [raw&.to_s, false]
    end

    def validate_typed_value(record, val)
      validate_option_inclusion(record, val)
    end
  end
  ```

The rule of thumb: subclass an intermediate family base when the new
field type shares its storage and validation surface with the family;
include `Optionable` when it draws values from an option set; subclass
`Field::Base` directly (as the `Phone` example above does) when none of
the family surfaces fit. `validate_array_size` lives on `Field::Base`
itself — its callers span unrelated families.

### Multi-cell field types

External field types may store their logical value across multiple typed
columns. The entire storage surface lives directly on `Field::Base` via
the `Field::TypedStorage` concern, so a custom multi-cell type is just a
`Field::Base` subclass that overrides three instance methods.

**Class-level DSL** (declared at class load time):

- `value_column :col` – single-cell sugar; declares the primary cell.
- `value_columns :a, :b, ...` – plural form for multi-cell types. The
  primary cell is `value_columns.first`. Both forms share storage;
  `value_column` and `value_columns` are interchangeable getters/setters.
- `operators :eq, :gt, ...` – restrict the supported operator set.
- `self.operator_column(op)` – override to route different operators to
  different cells. Defaults to `value_columns.first`.

**Override-point instance methods** (the entire extension surface for
multi-cell types):

- `read_value(record)` – compose the logical value from the cells.
- `write_value(record, casted)` – unpack the casted value across cells.
- `apply_default(record)` – populate cells from `default_value`.

The defaults target `value_columns.first`, so single-cell field types
keep working without overrides. The three methods are paired – override
all three or your reads will see a multi-cell shape that writes / defaults
cannot produce.

**Concrete snapshot helpers** (NOT overridable; derived from
`value_columns`):

- `value_changed?(record)` – true iff any cell saw a saved change.
- `before_snapshot(record, change_type)` / `after_snapshot(record, change_type)`
  – per-cell hashes keyed by string column names; powers the versioning
  jsonb shape.

Custom multi-cell type example (matches the built-in `Field::Currency`):

```ruby
class Fields::Money < TypedEAV::Field::Base
  AMOUNT_COLUMN = :decimal_value
  CURRENCY_COLUMN = :string_value

  value_columns AMOUNT_COLUMN, CURRENCY_COLUMN
  operators :eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq, :is_null, :is_not_null

  def self.operator_column(operator)
    operator == :currency_eq ? CURRENCY_COLUMN : AMOUNT_COLUMN
  end

  def read_value(value_record)
    amount = value_record[AMOUNT_COLUMN]
    currency = value_record[CURRENCY_COLUMN]
    return nil if amount.nil? && currency.nil?

    { amount: amount, currency: currency }
  end

  def write_value(value_record, casted)
    if casted.nil?
      value_record[AMOUNT_COLUMN] = nil
      value_record[CURRENCY_COLUMN] = nil
    else
      value_record[AMOUNT_COLUMN] = casted[:amount]
      value_record[CURRENCY_COLUMN] = casted[:currency]
    end
  end

  def apply_default(value_record)
    default = default_value
    return unless default.is_a?(Hash)

    value_record[AMOUNT_COLUMN] = default[:amount] || default["amount"]
    value_record[CURRENCY_COLUMN] = default[:currency] || default["currency"]
  end
end
```

The built-in `Field::Currency` is the canonical multi-cell consumer of
these extension points and reads as a normal `Field::Base` subclass with
exactly three method overrides.

### Built-in field types

- **`Currency`:** Stores `{amount: BigDecimal, currency: String}` across two typed columns (`decimal_value` for the amount; `string_value` for the ISO 4217 currency code). Multi-cell storage is declared via `value_columns :decimal_value, :string_value`; reads, writes, and default application override `read_value`, `write_value`, and `apply_default` directly on `Field::Currency`. Operators: `:eq`, `:gt`, `:lt`, `:gteq`, `:lteq`, `:between` target the amount; `:currency_eq` targets the currency code; `:is_null` / `:is_not_null` target the amount column (a Currency value is null when its amount is null). Cast input MUST be a hash with `:amount` and/or `:currency` keys — bare numeric/string values are rejected with `:invalid` to enforce explicit currency dimension at write time. Options: `default_currency` (String ISO code, applied as fallback only when an amount is given without an explicit currency), `allowed_currencies` (Array of ISO codes; `validate_typed_value` enforces inclusion). Versioning snapshots automatically capture both columns because the snapshot helpers iterate `value_columns`. The `:currency_eq` operator is registered ONLY on `Field::Currency`; the QueryBuilder operator-validation gate rejects it with a clear `ArgumentError` if invoked on any other field type.

  ```ruby
  Contact.where_typed_eav(name: "price", op: :currency_eq, value: "USD")
  Contact.where_typed_eav(name: "price", op: :between,     value: [50, 150])
  ```

- **`Percentage`:** A `Field::Decimal` subclass storing the underlying fraction in 0..1 (inclusive). The `:percent` representation is a format-time concern — call `field.format(value)` with `display_as: :percent` to render `0.75` as `"75.0%"`. Options: `decimal_places` (Integer >= 0, default 2; format-time precision only — does NOT alter what's stored in `decimal_value`), `display_as` (`:fraction` default, or `:percent`). Validation: out-of-range values (e.g., `1.5`) fail with the message `"must be between 0.0 and 1.0"`. Storage and operator semantics inherit from `Field::Decimal`.

  ```ruby
  pf = TypedEAV::Field::Percentage.create!(
    name: "discount", entity_type: "Order", scope: tenant_id,
    options: { display_as: :percent, decimal_places: 1 },
  )
  pf.format(BigDecimal("0.755")) # => "75.5%"
  ```

- **`Image`:** Active Storage-backed field type. Stores the attached blob's `signed_id` (a String) in `string_value`. Operators: `:eq`, `:is_null`, `:is_not_null`. Options: `allowed_content_types` (Array of strings; supports exact matches like `"image/png"` and `image/*` family wildcards), `max_size_bytes` (Integer; nil disables the cap). The single `:attachment` has_one_attached association is declared on `TypedEAV::Value` at engine boot when Active Storage is loaded; otherwise `Field::Image#cast` raises `NotImplementedError` with an actionable install message. The `:attachment` association is shared with `Field::File` — Image vs File is a class-identity distinction (used by the `on_image_attached` hook), not a separate association.

  ```ruby
  field = TypedEAV::Field::Image.create!(
    name: "avatar", entity_type: "Contact",
    options: { allowed_content_types: %w[image/png image/jpeg image/webp], max_size_bytes: 5_000_000 },
  )
  value = TypedEAV::Value.create!(entity: contact, field: field)
  value.attachment.attach(io: file_io, filename: "avatar.png", content_type: "image/png")
  value.update!(string_value: value.attachment.blob.signed_id)
  value.value # => the signed_id String
  ```

- **`File`:** Same shape as `Field::Image` but without image-specific semantics. Stores `signed_id` in `string_value`; same operator set; same options (`allowed_content_types`, `max_size_bytes`). The Image vs File distinction is by `value.field.class` at runtime — apps that want strict image-only validation set `allowed_content_types: ["image/*"]` on `Field::Image`; `Field::File` is a general-purpose attachment slot.

- **Active Storage dependency:** Lazy soft-detect via `defined?(::ActiveStorage::Blob)`. The gem does NOT add Active Storage as a hard dependency — apps that never use Image/File never need to install it. To use Image or File fields, add `gem "activestorage"` to your Gemfile (included in supported Rails versions via the `rails` meta-gem) and run `bin/rails active_storage:install` to create the `active_storage_blobs` / `active_storage_attachments` / `active_storage_variant_records` tables. The mirror precedent is `acts_as_tenant`, which is also soft-detected (see `Config::DEFAULT_SCOPE_RESOLVER`).

- **`on_image_attached` hook:** Fires from `after_commit` on `TypedEAV::Value` when a `Field::Image`-typed Value's attachment is added or replaced. Receives `(value, blob)`. Configure via `TypedEAV.configure { |c| c.on_image_attached = ->(v, b) { ... } }`. Hook ordering: runs AFTER versioning (Phase 4) and AFTER `on_value_change` (Phase 3) so it sees the persisted version row and the user-callback context. File attachments do NOT fire this hook — the name is image-specific by design. Use `on_value_change` for a generic value-mutation signal that covers File-typed Values too.

  ```ruby
  TypedEAV.configure do |c|
    c.on_image_attached = ->(value, blob) {
      ProcessImageJob.perform_later(value.id, blob.id)
    }
  end
  ```

- **`Reference`:** Foreign-key field type. Stores the target record's integer ID in `integer_value`. Operators: `:eq`, `:is_null`, `:is_not_null`, `:references` (explicit narrowing — does NOT inherit `:integer_value`'s `:gt`/`:lt`/`:between` defaults; arithmetic comparisons on FKs don't carry useful semantics). The `:references` operator accepts AR record instances OR Integer IDs at query time, normalizing via `field.cast` (a class-mismatched record routes to `base.none` rather than `:is_null`). Options: `target_entity_type` (REQUIRED — String class name of the target model, validated to constantize at field save), `target_scope` (OPTIONAL — when set, the field is REJECTED at save time if `target_entity_type` is not registered with `has_typed_eav scope_method:` (Gating Decision 2); when set with a scoped target, value-time validation rejects writes whose target's `typed_eav_scope` does not match `target_scope` via a `target_partition_matches?` helper structurally parallel to Phase 1's `entity_partition_axis_matches?` but on the target axis). Cross-scope safety mirrors the existing `Value#validate_field_scope_matches_entity` guard pattern applied to the target rather than the source.

  ```ruby
  rf = TypedEAV::Field::Reference.create!(
    name: "manager", entity_type: "Contact", scope: tenant_id,
    options: { target_entity_type: "Contact", target_scope: tenant_id },
  )
  TypedEAV::Value.create!(entity: alice, field: rf, value: bob)         # accepts AR record
  TypedEAV::Value.create!(entity: alice, field: rf, value: bob.id)      # accepts Integer FK
  Contact.where_typed_eav(name: "manager", op: :references, value: bob) # filter by record
  Contact.where_typed_eav(name: "manager", op: :references, value: 42)  # filter by FK
  ```

- **Summary:** The built-in field types **Image, File, Reference, Currency, Percentage** all preserve the cast-tuple contract (`[casted, invalid?]`), the operator-dispatch model (`supported_operators` + `operator_column` for multi-cell types), and the no-hardcoded-attribute-references foundational principle. The multi-cell extension surface (`read_value`, `write_value`, `apply_default`, and `operator_column`) is the canonical way to build any future external multi-cell field type.

## Validation Behavior

A few non-obvious contracts worth knowing about up front:

- **Required + blank**: `required: true` fields reject empty strings, whitespace-only strings, and arrays whose every element is nil/blank/whitespace.
- **Array all-or-nothing cast**: integer/decimal/date arrays mark the **whole** value invalid (stored as `nil`) when any element fails to cast. There is no silent partial — a failed form re-renders with the original input intact so the user can correct the bad element.
- **`Integer` array rejects fractional input**: `"1.9"` is rejected rather than truncated to `1`. Same rules as the scalar `Integer` field.
- **`Json` parses string input**: a JSON string posted from a form is parsed; parse failures surface as `:invalid` rather than being stored as the literal string.
- **`TextArray` does not support `:contains`**: it backs a jsonb column where SQL `LIKE` doesn't apply. Use `:any_eq` for "array contains element".
- **Orphaned values are skipped**: if a field row is deleted while values remain, `typed_eav_value` and `typed_eav_hash` silently skip the orphans rather than raising.
- **Cross-scope writes are rejected**: assigning a `Value` to a record whose `typed_eav_scope` doesn't match the field's `scope` adds a validation error on `:field`. The same guard covers the `parent_scope` axis.
- **Orphan-parent rows rejected**: a `Field` or `Section` row with `parent_scope` set but `scope` blank is invalid. The `Value`-side guard rejects cross-`(scope, parent_scope)` writes too.
- **Event hooks fire from `after_commit`**: the `on_value_change` and `on_field_change` callbacks fire after the database write is durable; their exceptions never break a save. See [Event hooks](events-and-versioning.md#event-hooks) for the full contract.
- **Versioning is opt-in**: When enabled (`TypedEAV.config.versioning = true` on the gem; `versioned: true` per host), every `:create` / `:update` / `:destroy` event on a Value writes an append-only audit row in `typed_eav_value_versions`. See [Versioning](events-and-versioning.md#versioning) for the full contract.
- **`label` is cosmetic, `name` is the machine key**: A field's optional `label` is free-text human display, independent of the slug `name`. Render via `display_name`, which returns `label` when present else `name.humanize`. `label` has no uniqueness or format constraints (only a 255-char max) and never affects ordering, lookup, partitioning, or rename detection — editing only `label` fires `on_field_change` with `:update`, never `:rename`. Existing rows (`label` NULL) render unchanged. Schema export round-trips the raw `label` (legacy payloads without a `label` key import as NULL); snapshot export carries the resolved `display_name`.
