---
phase: 5
title: "Field type expansion"
type: research
confidence: high
date: 2026-05-06
---

## Findings

### RQ-1 — STI hierarchy current shape

The codebase has **17 built-in field type subclasses** as of Phase 4. Each lives in its own file under `app/models/typed_eav/field/`. The complete map:

| Class | File | value_column | operator set (declared or default) |
|---|---|---|---|
| `Field::Text` | field/text.rb | `:string_value` | DEFAULT_OPERATORS_BY_COLUMN[:string_value] |
| `Field::LongText` | field/long_text.rb | `:text_value` | DEFAULT_OPERATORS_BY_COLUMN[:text_value] |
| `Field::Integer` | field/integer.rb | `:integer_value` | DEFAULT_OPERATORS_BY_COLUMN[:integer_value] |
| `Field::Decimal` | field/decimal.rb | `:decimal_value` | DEFAULT_OPERATORS_BY_COLUMN[:decimal_value] |
| `Field::Boolean` | field/boolean.rb | `:boolean_value` | explicit: `[:eq, :is_null, :is_not_null]` |
| `Field::Date` | field/date.rb | `:date_value` | DEFAULT_OPERATORS_BY_COLUMN[:date_value] |
| `Field::DateTime` | field/date_time.rb | `:datetime_value` | DEFAULT_OPERATORS_BY_COLUMN[:datetime_value] |
| `Field::Select` | field/select.rb | `:string_value` | explicit: `[:eq, :not_eq, :is_null, :is_not_null]` |
| `Field::MultiSelect` | field/multi_select.rb | `:json_value` | explicit: `[:any_eq, :all_eq, :is_null, :is_not_null]` |
| `Field::IntegerArray` | field/integer_array.rb | `:json_value` | explicit: `[:any_eq, :all_eq, :is_null, :is_not_null]` |
| `Field::DecimalArray` | field/decimal_array.rb | `:json_value` | explicit: `[:any_eq, :all_eq, :is_null, :is_not_null]` |
| `Field::TextArray` | field/text_array.rb | `:json_value` | explicit: `[:any_eq, :all_eq, :is_null, :is_not_null]` |
| `Field::DateArray` | field/date_array.rb | `:json_value` | explicit: `[:any_eq, :is_null, :is_not_null]` |
| `Field::Email` | field/email.rb | `:string_value` | DEFAULT_OPERATORS_BY_COLUMN[:string_value] |
| `Field::Url` | field/url.rb | `:string_value` | DEFAULT_OPERATORS_BY_COLUMN[:string_value] |
| `Field::Color` | field/color.rb | `:string_value` | explicit: `[:eq, :not_eq, :is_null, :is_not_null]` |
| `Field::Json` | field/json.rb | `:json_value` | explicit: `[:is_null, :is_not_null]` |

All 17 subclasses are registered in `Config::BUILTIN_FIELD_TYPES` (lib/typed_eav/config.rb lines 57–75) as `type_name: "TypedEAV::Field::ClassName"` pairs.

**The cast-tuple contract** is defined by `Field::Base#cast(raw)` (field/base.rb lines 243–245):

```
Returns [casted_value, invalid?]
  - casted_value: type-coerced value, or nil when raw is nil/blank
  - invalid?:     true when raw was non-empty but unparseable
```

Callers that only need the value use `cast(raw).first`. The `invalid?` boolean flows into `Value#validate_value` which translates it to `errors.add(:value, :invalid)`. Every subclass must implement `cast(raw)` returning this exact two-element array; `Base#cast` is the identity pass-through fallback (never marks invalid). Subclasses also optionally implement `validate_typed_value(record, val)` for post-cast validation, and may declare `array_field?` / `optionable?` predicate overrides (both default to `false` on Base).

**The operator-dispatch contract** lives in `ColumnMapping`:
- Class method `value_column(:col_name)` sets `@value_column`.
- Class method `operators(*ops)` sets `@supported_operators` (overrides the column default).
- Class method `supported_operators` reads `@supported_operators` or falls back to `DEFAULT_OPERATORS_BY_COLUMN[value_column]`.
- Class method `value_columns` returns `[value_column]` for single-cell types; Phase 5 Currency must override this to return `[:decimal_value, :string_value]`.

All of this infrastructure is already Phase-5-aware. The `value_columns` plural override path, the versioning subscriber's loop over `value_columns`, and the `_dispatch_value_change_update` filter (`value_columns.any?`) all exist today, explicitly forward-compat'd for Currency (see column_mapping.rb lines 46–68, value.rb lines 462–476, versioning/subscriber.rb lines 84–88).

### RQ-2 — Value model write/read pipeline

**Write path:**

1. `Value#initialize` — if `value:` kwarg absent, substitutes `UNSET_VALUE` sentinel (value.rb lines 253–268).
2. `Value#value=(val)` — three branches (value.rb lines 79–103):
   - UNSET_VALUE + field assigned → `apply_field_default` → writes `field.default_value` to `self[value_column]`
   - UNSET_VALUE + field not yet assigned → stash `@pending_value = UNSET_VALUE`
   - explicit value + field assigned → `casted, invalid = field.cast(val)` → `self[value_column] = casted`, `@cast_was_invalid = invalid`
   - explicit value + field not yet assigned → stash `@pending_value = val`
3. `after_initialize :apply_pending_value` — resolves the stash once field is set (value.rb lines 292–307).
4. `apply_field_default` — writes `field.default_value` directly to `self[value_column]` (bypasses `value=` to avoid re-casting an already-cast default).

**Read path:**

`Value#value` (value.rb lines 73–77):
```ruby
def value
  return nil unless field
  self[value_column]
end
```

`value_column` is `field.class.value_column` (the single-cell column name, a Symbol). AR reads from the native typed column. No custom deserialization; the database column type IS the deserializer.

**Currency's two-column shape must slot in here.** `value_column` returns a single Symbol — that API cannot serve Currency's `{amount, currency}` composite. Two options:

1. Override `Value#value` for Currency via the field class (e.g., `field.class.read_value(self)` dispatch). Requires a new method on Base (with a default delegating to `self[value_column]`).
2. Keep `Value#value` and override `value_column` to return `:decimal_value` (the primary column), while adding a separate `Value#currency_code` accessor — but this breaks the uniform `{amount, currency}` shape the ROADMAP specifies.

Option 1 is the correct design. A new `Field::Base` instance method (e.g., `read_value(value_record)`) returning the field-type-specific logical value allows Currency to compose `{amount: record[:decimal_value], currency: record[:string_value]}` without touching the core `Value#value` API. Single-cell types keep their default:

```ruby
# Field::Base
def read_value(value_record)
  value_record[self.class.value_column]
end

# Value#value becomes:
def value
  return nil unless field
  field.read_value(self)
end
```

The `apply_field_default` method also needs adjustment: it currently writes `self[value_column] = default`. Currency defaults need both columns populated. A parallel `apply_default_to(value_record)` dispatch on the field handles this cleanly without changing the single-cell path.

**Column selection today:** only `value_column` (singular) is used in the write path. The plural `value_columns` is used in versioning snapshot logic and event-dispatch filtering — both already work for Currency if the class overrides `value_columns`.

### RQ-3 — Operator dispatch

**Registration:** `ColumnMapping#operators(*ops)` (column_mapping.rb lines 76–78) sets `@supported_operators` on the field class. `DEFAULT_OPERATORS_BY_COLUMN` (lines 24–33) maps column names to default operator lists. `supported_operators` merges them (line 73–74).

**Dispatch:** `QueryBuilder.filter(field, operator, value)` (query_builder.rb lines 32–88) validates the operator against `field.class.supported_operators`, then selects from a `case` statement on the operator symbol. `col = field.class.value_column` is fetched once; all predicates use `values_table[col]` (Arel table column reference).

**New operators needed for Phase 5:**

| Operator | Type | Current status |
|---|---|---|
| `:references` | Reference | Not in any field; new |
| `:between` | Currency (amount) | Already implemented (query_builder.rb line 62–67) |
| `:eq` / `:gt` / `:lt` / `:gteq` / `:lteq` | Currency (amount) | Already implemented |
| `:eq` | Currency (currency code) | Already implemented |

**`:references` operator:** This is the most novel. It needs a `WHERE integer_value = ? AND entity_type = ?` (or equivalent for string FK) scoped to the field's `typed_eav_values` rows. It can be added as a new `when :references` branch in `QueryBuilder.filter` that:
1. Casts `value` through `field.cast(value)` to get the FK.
2. Emits `base.where(integer_value: fk)` (or `string_value: fk`).

No hardcoded type check is needed — `field.class.value_column` already routes to the right column. The operator symbol registration on `Field::Reference` is sufficient to gate access.

**Currency two-column filtering:** The `:eq` / numeric operators on Currency amount route to `decimal_value` (via `value_column`), and the `:eq` on currency code routes to `string_value`. These are logically different columns on the same row. `QueryBuilder.filter` today takes a single `col`. For Currency, two operators targeting different columns requires either:
1. A `field.class.operator_column(operator)` method so QueryBuilder can ask "which column does this operator act on?" (preferred — zero hardcoding).
2. Two separate `Field::Currency::AmountProxy` / `Field::Currency::CurrencyProxy` virtual field types for query purposes (over-engineered).

Option 1 is clean: `Field::Base#operator_column(operator)` defaults to `value_column` (BC-safe for all 17 existing types), and `Field::Currency` overrides it to return `:string_value` when `operator == :eq` (currency-code filter) and `:decimal_value` otherwise. `QueryBuilder` calls `field.class.operator_column(operator)` instead of `field.class.value_column`.

### RQ-4 — Active Storage soft-detect precedent

**Direct precedent in this codebase:** `Config::DEFAULT_SCOPE_RESOLVER` (config.rb lines 49–53):

```ruby
DEFAULT_SCOPE_RESOLVER = lambda {
  next nil unless defined?(::ActsAsTenant)
  [::ActsAsTenant.current_tenant, nil]
}
```

This is the exact soft-detect pattern: `defined?(::ConstantName)` as a guard before using the constant. No `require`, no `rescue LoadError`. The gem does NOT hard-depend on `acts_as_tenant`.

**For Active Storage:** `defined?(::ActiveStorage::Blob)` is the idiomatic parallel. The key difference from the `acts_as_tenant` pattern is that `acts_as_tenant` is purely a scope-resolution concern (config-time), while Active Storage requires attaching behavior to Value model instances at runtime (calling `has_one_attached` on a class). The soft-detect guard needs to live at class-definition time:

```ruby
# In Field::Image and Field::File — called from an engine initializer or
# the field class body itself:
if defined?(::ActiveStorage::Blob)
  TypedEAV::Value.has_one_attached :attachment
end
```

**Critical subtlety:** `has_one_attached` must be called on `TypedEAV::Value` (or a subclass), not on `Field::Image`. The blob record belongs to the Value (the entity that holds the attachment), not the field definition. Every Value whose field is a `Field::Image` shares the same `TypedEAV::Value` model — so the attachment is declared once on `Value`, gated by the field type at read time.

**Alternative (hard-depend):** Add `spec.add_dependency "activestorage"` to the gemspec. Every consumer is forced to install Active Storage even if they never use Image/File fields. This is hostile for existing users. The soft-detect path is clearly preferred.

**Context7 note:** Active Storage documentation was not indexed in context7. The `has_one_attached` macro is well-established Rails (7.1+, the gem's floor) and does not require lookup. The `defined?(::ActiveStorage::Blob)` pattern is the canonical soft-detect idiom used throughout the Rails ecosystem.

### RQ-5 — Scope partitioning interaction for Reference

**Reference's `target_scope` validation:** When a Reference Value is set, the validator must confirm the referenced entity's `typed_eav_scope` matches the field's `target_scope` option (or that the target entity type is unscoped).

**The existing API a Reference validator would call:**

The `entity_partition_axis_matches?` private method on `Field::Base` (field/base.rb lines 590–601) shows exactly this pattern:

```ruby
def entity_partition_axis_matches?(entity, axis)
  field_axis_value = public_send(axis)
  return true if field_axis_value.blank?  # global: any entity matches
  reader_method = :"typed_eav_#{axis}"
  return false unless entity.respond_to?(reader_method)
  entity_value = entity.public_send(reader_method)
  return false if entity_value.nil?
  field_axis_value.to_s == entity_value.to_s
end
```

For Reference target-scope validation, the analogous check is:
1. Fetch the target entity by FK from `integer_value` (or `string_value`).
2. Check `target_entity_type.constantize.respond_to?(:typed_eav_scope_method)` — if not registered with `has_typed_eav`, treat as unscoped.
3. If registered, check `target_entity.typed_eav_scope` against `options_hash[:target_scope]`.

**Tuple exposure:** `field.scope`, `field.parent_scope`, and `entity.typed_eav_scope` / `entity.typed_eav_parent_scope` are all public methods. `TypedEAV::HasTypedEAV::InstanceMethods#typed_eav_scope` (has_typed_eav.rb lines 429–432) reads from `typed_eav_scope_method`. The `has_typed_eav.rb` class method `typed_eav_scope_method` is a `class_attribute`. So a Reference validator can check:

```ruby
target_class = field.options_hash[:target_entity_type].constantize
if target_class.respond_to?(:typed_eav_scope_method) && target_class.typed_eav_scope_method
  target_entity = target_class.find_by(id: value[:integer_value])
  target_scope = target_entity&.typed_eav_scope
  # compare target_scope against field's target_scope option
end
```

**Gating decision 2 (unscoped target)** lives here: if `target_class` did NOT call `has_typed_eav`, or called it without `scope_method:`, there is no scope to validate. The plan must specify whether this is (a) always allowed, (b) allowed only if the field's `target_scope` is nil, or (c) rejected.

### RQ-6 — Versioning interaction (Phase 4)

**Current versioning snapshot shape** (versioning/subscriber.rb lines 124–158):

```ruby
columns = value.field.class.value_columns
before_value = columns.to_h { |col| [col.to_s, value.attribute_before_last_save(col.to_s)] }
after_value  = columns.to_h { |col| [col.to_s, value[col]] }
```

**Currency ({amount, currency}) accommodation:** Already handled. When `Field::Currency` overrides `value_columns` to return `[:decimal_value, :string_value]`, the subscriber automatically produces:

```json
{
  "before_value": {"decimal_value": "99.99", "string_value": "USD"},
  "after_value":  {"decimal_value": "109.99", "string_value": "EUR"}
}
```

No subscriber changes needed. The iteration already loops over `value_columns`.

**Reference FK + class accommodation:** Reference stores its value in `integer_value` (FK) or `string_value`. `value_columns` returns `[:integer_value]` (or `[:string_value]`). The snapshot stores the FK integer/string only — the target entity's class name is in the field's `options_hash[:target_entity_type]`, not in the Value row. This is correct: the snapshot records the raw stored value (the FK), not the resolved entity. Consumers reading history reconstruct the entity from the FK + field metadata.

**Image/File accommodation:** The attachment relationship is on `ActiveStorage::Attachment` / `ActiveStorage::Blob`, not in a typed column. The Value row's typed column would hold the blob ID (stored in `integer_value` or a purpose-specific column TBD). The versioning snapshot would capture the blob ID. Blob-content diffs are not versioned by typed_eav — only the reference.

**`Value#revert_to` multi-cell compatibility:** Already forward-compat'd (value.rb lines 234–238):

```ruby
field.class.value_columns.each do |col|
  self[col] = version.before_value[col.to_s]
end
```

Currency revert would restore both `decimal_value` and `string_value` from the jsonb snapshot. No changes needed.

**Gap identified:** `Value#apply_field_default` (value.rb lines 315–318) currently writes only to `self[value_column]` (singular). If `Field::Currency` declares a `default_currency` option, the default needs both `decimal_value` (nil / some default amount) and `string_value` (the default currency code) populated. This is the same issue as RQ-2's `apply_field_default` path: needs the `apply_default_to(value_record)` dispatch or Currency must override it.

### RQ-7 — Spec patterns

From `spec/models/typed_eav/field_spec.rb`, the established patterns are:

**Column mapping block** (lines 85–109): A hash of `{FieldClass => :column_sym}` pairs iterated with `each` to assert `klass.value_column`. New types must appear here.

**Supported operators block** (lines 111–136): Explicit operator assertions per field type. New types must add a named `it` block describing their operator set.

**Casting block** (lines 138–235): Each subtype gets a `describe TypedEAV::Field::SomeType` block covering:
- Valid input casts correctly.
- Boundary/nil returns `[nil, false]`.
- Invalid input returns `[nil, true]` (marks invalid).

**Nil safety exhaustive test** (lines 474–484): Every factory name is listed; `cast(nil).first` must return `nil`. New types must add their factory to this list.

**Operators exhaustive test** (lines 486–531): Each type's operator set explicitly tested.

**Validation and option tests**: Dedicated `RSpec.describe` blocks for type-specific validations (e.g., `TextFieldOptionValidations`, `IntegerFieldOptionValidations`).

**Value spec column assertions** (spec/models/typed_eav/value_spec.rb lines 15–179): Each field type gets a `context "with a <type> field"` block asserting which physical column the value lands in.

**Factory pattern**: Each field type has a factory in `spec/factories/typed_eav.rb` named `:<type>_field` (except `email_typed_eav` to avoid collision with a Rails-reserved name). After-create hooks add field_options for Select/MultiSelect. New types must add factories here.

**Currency-specific spec requirements**: The two-column shape needs dedicated tests:
- `value = {amount: 99.99, currency: "USD"}` round-trips correctly.
- `value.decimal_value` and `value.string_value` contain the right data.
- Co-population validation: missing one cell is rejected.
- `cast(nil)` returns `[nil, false]`.
- Version snapshot for a Currency update captures both columns.

**Reference-specific spec requirements**:
- FK stored in `integer_value` round-trips.
- Cross-scope rejection fires when target entity's scope mismatches `target_scope`.
- Unscoped target behavior (per gating decision 2).
- `:references` operator query returns matching entities.

**Percentage-specific spec requirements**:
- Input `0.75` round-trips as `BigDecimal("0.75")`.
- Values outside 0–1 are rejected.
- `display_as: :percent` formatting helper returns `"75.0%"`.

---

## Relevant Patterns

### Pattern 1: `value_columns` override for multi-cell types

The entire Phase 4 infrastructure was built with multi-cell types in mind. The override path is:

```ruby
class Field::Currency < Base
  def self.value_columns
    [:decimal_value, :string_value]
  end
end
```

This single override propagates through: versioning snapshots, event-dispatch update filter, `Value#revert_to` column iteration, and any future Phase 6 bulk serialization that respects `value_columns`.

### Pattern 2: `operators(...)` declaration

Simple override on the class body:

```ruby
class Field::Currency < Base
  operators :eq, :gt, :lt, :gteq, :lteq, :between, :is_null, :is_not_null
  # currency-code :eq handled via operator_column dispatch (RQ-3)
end
```

Boolean used `operators :eq, :is_null, :is_not_null` to narrow from the boolean_value default. Reference and Currency follow the same explicit-declaration pattern.

### Pattern 3: `store_accessor :options` for field configuration

All type-specific options use `store_accessor :options, :key1, :key2`. The `options` column is jsonb. `options_hash` (Base#options_hash, field/base.rb lines 358–360) returns a `HashWithIndifferentAccess` for validation helpers.

```ruby
class Field::Currency < Base
  store_accessor :options, :default_currency, :allowed_currencies
end

class Field::Reference < Base
  store_accessor :options, :target_entity_type, :target_scope
end

class Field::Percentage < Base
  store_accessor :options, :decimal_places, :display_as
end
```

### Pattern 4: Soft-detect via `defined?(::Const)`

The `ActsAsTenant` soft-detect in `Config::DEFAULT_SCOPE_RESOLVER` (config.rb line 51) is the precedent. For Active Storage:

```ruby
# engine.rb initializer or field class body guard
if defined?(::ActiveStorage::Blob)
  TypedEAV::Value.has_one_attached :image_attachment
  TypedEAV::Value.has_one_attached :file_attachment
end
```

This must be evaluated at engine load time (in a `config.after_initialize` block, after Rails loads Active Storage), not at class parse time.

### Pattern 5: Partition-matching for cross-entity validators

`Field::Base#partition_matches?` (field/base.rb lines 574–578) and `#entity_partition_axis_matches?` are the established pattern for checking whether an entity belongs to a field's partition. The Reference validator for target_scope follows the same pattern applied to the target entity rather than the source entity.

### Pattern 6: `validate_typed_value` for field-owned validation

```ruby
# Field::Currency
def validate_typed_value(record, val)
  # val is the {amount: ..., currency: ...} hash
  unless val.is_a?(Hash) && val[:amount].present? && val[:currency].present?
    record.errors.add(:value, "must have both amount and currency")
    return
  end
  allowed = options_hash[:allowed_currencies]
  if allowed.present? && !Array(allowed).include?(val[:currency])
    record.errors.add(:value, :inclusion)
  end
  validate_range(record, val[:amount])
end
```

---

## Risks

### Risk 1: Currency read_value dispatch adds method to Field::Base

Adding `read_value(value_record)` and `apply_default_to(value_record)` on `Field::Base` extends the public interface consumed by `Value`. Any future external field type (via `Config.register_field_type`) that doesn't implement these methods falls back to the default — no breaking change. Low blast radius, but must be tested explicitly.

### Risk 2: `Value#value=` pending-value path for Currency

The pending-value path (`@pending_value`) stores the user's raw input as a single object. For Currency, the raw input is `{amount: "99.99", currency: "USD"}` — a Hash. The `apply_pending_value` call resolves via `self.value = @pending_value`, which routes back to `value=`. The cast must handle a Hash input correctly. Current `field.cast(raw)` signature accepts any raw value, so this is the same contract — Currency's `cast` must handle both Hash and nil input.

### Risk 3: Active Storage `has_one_attached` on a shared model

`TypedEAV::Value` is a monolithic table — every value for every field type shares the same AR class. Declaring `has_one_attached :image_attachment` on `Value` means every Value record gains an Active Storage association, even ones for Text or Integer fields. This is standard Rails pattern for polymorphic attachments, but:
- Eager-loading `typed_values: :image_attachment_blob` on non-Image values wastes queries.
- The association must be declared conditionally (inside the soft-detect block) so apps without Active Storage don't have stale association methods.
- For the `on_image_attached` hook: Phase 5 must wire this into the `on_value_change` event (or a dedicated config slot). The event fires from `Value`'s after_commit; the hook can check `value.field.is_a?(Field::Image)`.

### Risk 4: Reference FK column collision with Select

Both `Field::Select` and `Field::Reference` would use `:string_value` (if Reference stores string FKs) or `:integer_value` (if integer FKs). Since values are scoped to a single `(entity_id, field_id)` pair, there is no actual column collision — both write to their respective physical column, selected by `value_column`. No risk of data collision, but spec assertions for Reference must be explicit about which column is used.

### Risk 5: ROADMAP "four" vs "five" field types

The ROADMAP Phase 5 success criteria explicitly names five types: Image, File, Reference, Currency, Percentage. The phase goal says "four new field types." This is an acknowledged discrepancy in the ROADMAP text. The success criteria section is the authoritative specification; all five must be delivered. The plan must explicitly state this resolution.

### Risk 6: Currency QueryBuilder dispatch for dual-column operators

The `QueryBuilder.filter` method fetches `col = field.class.value_column` once and uses it for all operators. Currency needs `:eq` on `string_value` (currency code) and numeric operators on `decimal_value`. Without the `operator_column` dispatch (RQ-3), the `col` variable would always be `:decimal_value`, and `where_typed_eav(name: "price", op: :eq, value: "USD")` would query `decimal_value = 'USD'` — wrong. The plan must add `operator_column` dispatch before shipping Currency query support.

### Risk 7: Percentage as `Field::Decimal` subclass vs independent class

If `Field::Percentage < Field::Decimal` (STI subclass of a subclass), the `type` column stores `"TypedEAV::Field::Percentage"` and AR resolves it correctly. But `Field::Decimal.value_column` is already `:decimal_value`, so `Field::Percentage.value_column` inherits it without re-declaration. The risk is that `Field::Decimal` validations (range check on `min`/`max` options) would also fire for Percentage unless the subclass overrides `validate_typed_value`. Percentage's 0–1 range check IS a range check, so calling `super` from `Percentage#validate_typed_value` then adding the 0–1 constraint would be clean. The `display_as` formatter is a pure read-side concern (no write-path logic needed).

---

## Recommendations

### 1. Resolve the five-vs-four discrepancy now

The plan must open with explicit wording: "Phase 5 ships five field types: Image, File, Reference, Currency, Percentage. The roadmap goal section says 'four' but the success criteria enumerate five; five is the authoritative count."

### 2. Add `read_value` and `apply_default_to` dispatches on `Field::Base`

Before implementing Currency, add these two methods to `Field::Base` with single-cell defaults:

```ruby
# Returns the logical value for this field from a Value record.
# Override in multi-cell field types (e.g., Field::Currency).
def read_value(value_record)
  value_record[self.class.value_column]
end

# Applies the field's configured default to a Value record.
# Override in multi-cell field types.
def apply_default_to(value_record)
  value_record[self.class.value_column] = default_value
end
```

Update `Value#value` to call `field.read_value(self)` and `apply_field_default` to call `field.apply_default_to(self)`. This is the smallest API surface that makes Currency work without breaking any of the 17 existing types.

### 3. Add `operator_column` dispatch on `Field::Base`

```ruby
# Which column this operator acts on. Defaults to value_column.
# Field::Currency overrides: :eq on currency-code maps to :string_value;
# numeric operators map to :decimal_value.
def self.operator_column(operator)
  value_column
end
```

Update `QueryBuilder.filter` line 33 to use `field.class.operator_column(operator)` instead of `field.class.value_column`. All 17 existing types return the same result either way (BC safe).

### 4. Ship field types in dependency order within Phase 5

**Wave 1 (no special dependencies):** Percentage (thin Decimal wrapper, no new infrastructure).

**Wave 2 (operator_column + value_columns):** Currency (needs both `value_columns` override and `operator_column` dispatch).

**Wave 3 (read_value + apply_default_to):** Actually needed by Currency; ship in Wave 2.

**Wave 4 (Active Storage soft-detect):** Image and File (need the soft-detect engine initializer, `has_one_attached`, and the `on_image_attached` hook contract).

**Wave 5 (target-scope validation):** Reference (needs gating decision 2 resolved, target entity lookup, `:references` operator).

### 5. Register new types in `Config::BUILTIN_FIELD_TYPES`

Five new entries:

```ruby
image:      "TypedEAV::Field::Image",
file:       "TypedEAV::Field::File",
reference:  "TypedEAV::Field::Reference",
currency:   "TypedEAV::Field::Currency",
percentage: "TypedEAV::Field::Percentage",
```

---

## Gating Decisions

### Gating Decision 1: Active Storage hard-vs-lazy dependency

**What is being decided:** Whether the gem requires Active Storage to be installed (hard dependency via gemspec `add_dependency "activestorage"`) or silently omits Image/File field functionality when Active Storage is not present (soft-detect via `defined?(::ActiveStorage::Blob)`).

**Options and tradeoffs:**

| | Hard dependency | Lazy soft-detect |
|---|---|---|
| **Model** | `spec.add_dependency "activestorage"` | `defined?(::ActiveStorage::Blob)` guard |
| **DX when Active Storage absent** | Bundler fails with clear message | Image/File fields silently unconfigured; calling `value.image_attachment` raises `NoMethodError` |
| **DX for existing users** | Forced to pull in Active Storage even if never using Image/File | Existing users unaffected |
| **Precedent** | None in this codebase | `ActsAsTenant` soft-detect in `Config::DEFAULT_SCOPE_RESOLVER` |
| **Implementation complexity** | Low | Medium — need a fallback error when calling Image/File features without Active Storage |

**Recommendation: Lazy soft-detect**, mirroring the `acts_as_tenant` precedent. The ROADMAP explicitly states this is preferred. To avoid the silent-unconfigured problem, add a guard in `Field::Image#cast` and `Field::File#cast`:

```ruby
def cast(raw)
  unless defined?(::ActiveStorage::Blob)
    raise NotImplementedError,
          "TypedEAV::Field::Image requires Active Storage. Add `gem 'activestorage'` to your Gemfile."
  end
  # ...
end
```

This gives a clear error at first use, not at gem load time. Engine initializer registers the `has_one_attached` only when Active Storage is present.

**What the plan must call out:** "Phase-start decision: lazy soft-detect is the chosen approach. The `has_one_attached` declarations on `TypedEAV::Value` are wrapped in `if defined?(::ActiveStorage::Blob)` in a `config.after_initialize` block in the engine. `Field::Image#cast` and `Field::File#cast` raise `NotImplementedError` with an actionable message if called without Active Storage loaded."

---

### Gating Decision 2: Reference target validation for unscoped target entity types

**What is being decided:** When a `Field::Reference` has `target_entity_type: "Contact"` but `Contact` was registered with `has_typed_eav` without a `scope_method:` (or not registered at all), should a reference value be (a) always allowed, (b) allowed only if the field's `target_scope` option is nil, or (c) rejected with an error?

**Options and tradeoffs:**

| | Always allow unscoped | Allow only when target_scope is nil | Reject unscoped targets |
|---|---|---|---|
| **Cross-scope safety** | Weak — a scoped field referencing an unscoped target may leak data across tenants | Moderate — forces the field author to acknowledge no scope filtering is possible | Strong — prevents ambiguous configurations |
| **Ergonomics** | Best for simple apps without tenancy | Reasonable compromise | Breaks common use cases (e.g., referencing a global lookup table) |
| **Analogy in codebase** | `field.scope == nil` → global field, no scope check needed (Value#validate_field_scope_matches_entity) | — | — |

**Recommendation: Allow when the field's `target_scope` is nil, reject when `target_scope` is set but the target entity type is unscoped.** This mirrors the existing `field.scope.present?` guard in `Value#validate_field_scope_matches_entity` (value.rb lines 403–408). When `target_scope` is nil, the field author is declaring "this reference is to a global/unscoped entity" — no scope validation applies. When `target_scope` is set but the target entity isn't scope-aware, the configuration is self-contradictory and should fail at Field validation time (not silently at Value time).

**What the plan must call out:** "Phase-start decision: Reference field validation applies when `target_scope` is set; if the target entity type is not registered with `has_typed_eav scope_method:`, creating a Field::Reference with a non-nil `target_scope` is invalid and rejected at field save time with an error message. When `target_scope` is nil, references to any entity type (scoped or unscoped) are accepted with no cross-scope check at value write time."

---

### Gating Decision 3: Currency Value-shape and operator narrowing

**What is being decided:** (a) The logical value shape returned by `Value#value` for a Currency field (`{amount:, currency:}` hash vs other shapes), and (b) which operators target the amount column, which target the currency-code column, and how `QueryBuilder` dispatches between them.

**Options for value shape:**

| | Hash `{amount:, currency:}` | Struct or Value Object | Two separate accessors |
|---|---|---|---|
| **BC with existing `value=` / `value` pattern** | Minor extension — `cast` accepts and returns Hash | Requires AR serialization or custom deserializer | Breaks uniform `value` accessor |
| **Serialization** | jsonb-serializable; human-readable in `typed_eav_value_versions` | Not directly jsonb-serializable | N/A |
| **`typed_eav_attributes=` ergonomics** | `record.typed_eav_attributes = [{name: "price", value: {amount: 99, currency: "USD"}}]` | Same | Awkward |

**Recommendation: Hash `{amount: BigDecimal, currency: String}` as the logical value shape.** This is the ROADMAP's stated shape. The `cast` method accepts either a Hash (from code) or some application-defined serialized form, and returns `[{amount: bd, currency: str}, false]`. The `read_value(value_record)` dispatch (RQ-2) composes the hash from `value_record[:decimal_value]` + `value_record[:string_value]`.

**For operator dispatch:** Use the `operator_column` class method pattern (RQ-3). `Field::Currency` overrides:

```ruby
def self.operator_column(operator)
  operator == :eq && ... ? :string_value : :decimal_value
end
```

However, simple `operator == :eq` is ambiguous (`:eq` on amount vs `:eq` on currency code). The plan must define a currency-specific API for this. **Best approach:** define two separate operator namespaces via documented filter syntax:

```ruby
Contact.where_typed_eav(name: "price", op: :amount_eq, value: 99.99)
Contact.where_typed_eav(name: "price", op: :currency_eq, value: "USD")
# Plain :eq defaults to amount equality for BC ergonomics
```

This makes the operator unambiguous without breaking the generic interface. `operator_column` maps `:currency_eq` to `:string_value` and all others to `:decimal_value`. The operators declaration on `Field::Currency`:

```ruby
operators :eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq, :is_null, :is_not_null
```

This avoids any query path ambiguity at the cost of two new operator symbols.

**For validation:** `validate_typed_value` requires both cells co-populated. The `allowed_currencies` option (Array of ISO codes) validates `currency` membership. `default_currency` option auto-fills `string_value` when only `amount` is given.

**What the plan must call out:** "Phase-start decision: Currency logical value shape is `{amount: BigDecimal, currency: String}`. Operator `:eq` targets the amount column. A new operator `:currency_eq` targets the currency-code column. These two operators are the only ones where Currency differs from Decimal in query dispatch. The `operator_column` class method is introduced on `Field::Base` with a Decimal-equivalent default, overridden on `Field::Currency` to route `:currency_eq` to `:string_value`."
