# TypedEAV

Add dynamic custom fields to ActiveRecord models at runtime, backed by **native database typed columns** instead of jsonb blobs.

TypedEAV uses a hybrid EAV (Entity-Attribute-Value) pattern where each value type gets its own column (`integer_value`, `date_value`, `string_value`, etc.) in the values table. This means the database can natively index, sort, and enforce constraints on your custom field data with zero runtime type casting.

## Why Typed Columns?

Most Rails custom field gems serialize everything into a single `jsonb` column. When you query, they generate SQL like:

```sql
CAST(value_meta->>'const' AS bigint) = 42
```

This works, but:

- **No B-tree indexes** on the actual values (only GIN for jsonb containment)
- **Runtime CAST overhead** on every query
- **No database-level type enforcement** (a "number" could be stored as a string)
- **The query planner can't optimize** range scans, sorts, or joins

TypedEAV stores values in native columns, so queries become:

```sql
WHERE integer_value = 42
```

Standard B-tree indexes work. Range scans work. The query planner is happy. ActiveRecord handles all type casting automatically through the column's registered type.

## Installation

Add to your Gemfile:

```ruby
gem "typed_eav"
```

Run the install migration:

```bash
bin/rails typed_eav:install:migrations
bin/rails db:migrate
```

## Quick Start

### 1. Include the concern

```ruby
class Contact < ApplicationRecord
  has_typed_eav
end

# With multi-tenant scoping:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
end

# With restricted field types:
class Contact < ApplicationRecord
  has_typed_eav types: [:text, :integer, :boolean, :select]
end
```

### 2. Create field definitions

```ruby
# Simple fields
TypedEAV::Field::Text.create!(
  name: "nickname",
  entity_type: "Contact"
)

TypedEAV::Field::Integer.create!(
  name: "age",
  entity_type: "Contact",
  required: true,
  options: { min: 0, max: 150 }
)

TypedEAV::Field::Date.create!(
  name: "birthday",
  entity_type: "Contact",
  options: { max_date: Date.today.to_s }
)

# Select field with options
status = TypedEAV::Field::Select.create!(
  name: "status",
  entity_type: "Contact",
  required: true
)
status.field_options.create!([
  { label: "Active",   value: "active",   sort_order: 1 },
  { label: "Inactive", value: "inactive", sort_order: 2 },
  { label: "Lead",     value: "lead",     sort_order: 3 },
])

# Multi-select (stored as json array)
tags = TypedEAV::Field::MultiSelect.create!(
  name: "tags",
  entity_type: "Contact"
)
tags.field_options.create!([
  { label: "VIP",      value: "vip" },
  { label: "Partner",  value: "partner" },
  { label: "Prospect", value: "prospect" },
])
```

### 3. Set values on records

```ruby
contact = Contact.new(name: "Darrin")

# Individual assignment
contact.set_typed_eav_value("age", 40)
contact.set_typed_eav_value("status", "active")

# Bulk assignment by field NAME (ergonomic for scripting / seeds)
contact.typed_eav_attributes = [
  { name: "age", value: 40 },
  { name: "status", value: "active" },
  { name: "tags", value: ["vip", "partner"] },
]

# Bulk assignment by field ID (standard Rails form contract).
# Your form templates emit this shape when you use fields_for :typed_values.
contact.typed_values_attributes = [
  { id: 12, field_id: 4, value: "40" },
  { field_id: 7, value: "active" },
]

contact.save!

# Reading
contact.typed_eav_value("age")    # => 40 (Ruby Integer)
contact.typed_eav_value("status") # => "active"
contact.typed_eav_hash              # => { "age" => 40, "status" => "active", ... }
```

### 4. Query with the DSL

This is where typed columns pay off. All queries go through native columns with proper indexes.

```ruby
# Short form - single field filter
Contact.with_field("age", :gt, 21)
Contact.with_field("status", "active")           # :eq is the default operator
Contact.with_field("nickname", :contains, "smith")

# Chain them
Contact.with_field("age", :gteq, 18)
       .with_field("status", "active")
       .with_field("tags", :any_eq, "vip")

# Multi-filter form (good for search UIs)
Contact.where_typed_eav(
  { name: "age",    op: :gt,       value: 21 },
  { name: "status", op: :eq,       value: "active" },
  { name: "city",   op: :contains, value: "port" },
)

# Compact keys (for URL params / form submissions)
Contact.where_typed_eav(
  { n: "age", op: :gt, v: 21 },
  { n: "status", v: "active" },
)

# With scoping
Contact.where_typed_eav(
  { name: "priority", op: :eq, value: "high" },
  scope: current_tenant.id
)

# Combine with standard ActiveRecord
Contact.where(company_id: 42)
       .with_field("status", "active")
       .with_field("age", :gteq, 21)
       .order(:name)
       .limit(25)
```

### Available Operators

| Operator | Works On | Description |
|----------|----------|-------------|
| `:eq` | all | Equal (default) |
| `:not_eq` | all | Not equal (NULL-safe) |
| `:gt` | numeric, date, datetime | Greater than |
| `:gteq` | numeric, date, datetime | Greater than or equal |
| `:lt` | numeric, date, datetime | Less than |
| `:lteq` | numeric, date, datetime | Less than or equal |
| `:between` | numeric, date, datetime | Between (pass Range or Array) |
| `:contains` | text, long_text | ILIKE %value% |
| `:not_contains` | text, long_text | NOT ILIKE %value% |
| `:starts_with` | text, long_text | ILIKE value% |
| `:ends_with` | text, long_text | ILIKE %value |
| `:any_eq` | json arrays | Array contains element |
| `:all_eq` | json arrays | Array contains all elements |
| `:is_null` | all | Value is NULL |
| `:is_not_null` | all | Value is not NULL |

### How Type Inference Works

You don't need to think about types when querying. Rails handles it:

```ruby
# You pass a string, Rails casts to integer via the column type
Contact.with_field("age", :gt, "21")
# SQL: WHERE integer_value > 21  (not '21')

# You pass a string, Rails casts to date
Contact.with_field("birthday", :lt, "2000-01-01")
# SQL: WHERE date_value < '2000-01-01'::date

# Boolean columns handle truthy/falsy casting
Contact.with_field("active", "true")
# SQL: WHERE boolean_value = TRUE
```

This works because `ActiveRecord::Base.columns_hash` knows every column's type from the schema, and `where()` / Arel predicates automatically cast values through the column's registered `ActiveRecord::Type`.

## Forms

Wire typed fields into Rails forms via nested attributes:

```erb
<%= form_with model: @contact do |f| %>
  <%= f.text_field :name %>

  <%= render_typed_value_inputs(form: f, record: @contact) %>

  <%= f.submit %>
<% end %>
```

The helper emits one input per available field, including the hidden `id` / `field_id` markers required by `accepts_nested_attributes_for`. Permit the nested shape in your controller — the `value: []` form is required for array/multi-select types:

```ruby
def contact_params
  params.require(:contact).permit(
    :name,
    typed_values_attributes: [
      :id, :field_id, :_destroy, :value, { value: [] }
    ]
  )
end
```

For list pages, preload the field association to avoid N+1:

```ruby
@contacts = Contact.includes(typed_values: :field).all
```

## Admin Scaffold

To manage field definitions through a UI, run the scaffold generator:

```bash
bin/rails g typed_eav:scaffold
bin/rails db:migrate
```

This copies a controller, views, helper, Stimulus controllers, and an initializer into your app, and adds routes mounted at `/typed_eav_fields`.

**Security**: the generated controller ships with `authorize_typed_eav_admin!` returning `head :not_found` by default — fail-closed. Edit the method directly in `app/controllers/typed_eav_controller.rb` to wire it to your auth system:

```ruby
def authorize_typed_eav_admin!
  return if current_user&.admin?
  head :not_found
end
```

Defining `authorize_typed_eav_admin!` in `ApplicationController` does **not** override it — the scaffold sets it on its own controller.

## Multi-Tenant Scoping

Field definitions are partitioned by a `scope` column so multiple tenants (or accounts, workspaces, orgs — any partition key your app uses) can each define their own fields without collisions. Fields with `scope = NULL` are global, visible to every partition.

### Declaring a scoped model

```ruby
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
end
```

`scope_method:` names an instance method on your model. When the record reads its own field definitions (e.g., in a form), that method tells TypedEAV which partition the record belongs to.

### Class-level queries resolve scope automatically

Queries like `Contact.where_typed_eav(...)` consult an **ambient scope resolver** — no need to pass `scope:` on every call:

```ruby
# The resolver tells TypedEAV which partition is active.
Contact.where_typed_eav({ name: "age", op: :gt, value: 21 })
```

The resolver chain (highest priority first):

1. Explicit `scope:` keyword argument on the query
2. Active `TypedEAV.with_scope(value) { ... }` block
3. Configured `TypedEAV.config.scope_resolver` callable
4. `nil`

If every step returns `nil` and the model declared `scope_method:`, queries raise `TypedEAV::ScopeRequired` — the **fail-closed default**. This is the whole point: forgetting to set scope can't silently leak other partitions' data.

### Wiring the resolver

Pick the pattern that matches your app and set it once in `config/initializers/typed_eav.rb`:

```ruby
TypedEAV.configure do |c|
  # acts_as_tenant (auto-detected — no config needed if loaded)
  # c.scope_resolver = -> { ActsAsTenant.current_tenant&.id }

  # Rails CurrentAttributes
  # c.scope_resolver = -> { Current.account&.id }

  # Custom class
  # c.scope_resolver = -> { MyApp::Tenancy.current_workspace_id }

  # Subdomain / session / thread-local
  # c.scope_resolver = -> { Thread.current[:org_id] }

  # Disable ambient resolution entirely
  # c.scope_resolver = nil

  c.require_scope = true  # fail-closed (default). Set false for gradual adoption.
end
```

The resolver MUST return a 2-element Array `[scope, parent_scope]`. Each slot
accepts a raw value (`"t1"`, `42`), an AR record (TypedEAV calls `.id.to_s`
on anything that responds to `#id`), or `nil`. If you don't use parent_scope,
return `[scope, nil]`. A bare scalar return raises `ArgumentError` at the
next ambient query — see [Migrating from v0.1.x](#migrating-from-v01x) for
the upgrade path.

### Block APIs

```ruby
# Run a block with a specific ambient scope (background jobs, console, rake tasks):
TypedEAV.with_scope(tenant_id) do
  Contact.where_typed_eav({ name: "status", op: :eq, value: "active" })
end

# Escape hatch for admin tools, migrations, or cross-tenant audits:
TypedEAV.unscoped do
  Contact.where_typed_eav({ name: "status", op: :eq, value: "active" })
  # returns matches across ALL partitions
end
```

Both are exception-safe via `ensure` and nest cleanly.

### Explicit `scope:` override

Any query method accepts `scope:` as an override for admin tools and tests:

```ruby
Contact.where_typed_eav({ name: "status", value: "active" }, scope: "t1")
Contact.with_field("age", :gt, 21, scope: "t1")
```

Explicit wins over ambient. Passing `scope: nil` explicitly (as opposed to omitting the kwarg) means "filter to global fields only" — useful for admin UIs that want to see unscoped field definitions without activating `unscoped` mode.

### Background jobs

ActiveJob (including Sidekiq via the ActiveJob adapter) wraps every `perform` in Rails' executor, which already clears `ActiveSupport::CurrentAttributes` between jobs — so if your resolver reads from `Current.account`, each job starts clean. For raw `Sidekiq::Job` (no ActiveJob), wrap the job body manually:

```ruby
class ExportJob
  include Sidekiq::Job

  def perform(tenant_id, ...)
    TypedEAV.with_scope(tenant_id) do
      Contact.where_typed_eav(...)
    end
  end
end
```

### Disabling enforcement for gradual adoption

If your app has existing typed-eav queries that don't yet pass scope, flip `require_scope` to `false` in the initializer. When no scope resolves, queries fall back to **global fields only** (definitions stored with `scope: nil`) instead of raising — they do **not** return all partitions' fields. Audit and fix callers, then flip back to `true`.

To intentionally query across every partition (admin tools, migrations, cross-tenant audits), use the explicit escape hatch `TypedEAV.unscoped { ... }` rather than relying on `require_scope = false`.

### Two-level scoping (`parent_scope`)

When a single tenant axis isn't enough — say, `tenant_id` for the customer AND
`workspace_id` for an in-tenant partition — declare both:

```ruby
class Project < ApplicationRecord
  has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id
end
```

Field (and section) definitions partition on the tuple `(entity_type, scope,
parent_scope)`. A `Project` record reads field definitions in three precedence
layers: a full-triple `(scope, parent_scope)` match wins, then `(scope, nil)`
(tenant-wide), then `(nil, nil)` (truly global). The same precedence applies
to the class-level query path.

`parent_scope_method:` requires `scope_method:` — declaring it without a scope
method raises at macro-expansion time (no host can have a parent partition
without a scope partition).

Both `with_scope` and the configured `scope_resolver` carry the tuple now:

```ruby
TypedEAV.with_scope(["t1", "w1"]) do
  Project.where_typed_eav({ name: "status", value: "active" })
end

# Single-axis call still works (parent_scope = nil):
TypedEAV.with_scope("t1") do
  Contact.where_typed_eav({ name: "age", op: :gt, value: 21 })
end

# Custom resolver — MUST return [scope, parent_scope]:
TypedEAV.configure do |c|
  c.scope_resolver = -> { [Current.tenant&.id, Current.workspace&.id] }
end
```

Per-query overrides accept `parent_scope:` alongside `scope:` on
`where_typed_eav`, `with_field`, and `typed_eav_definitions`:

```ruby
Project.where_typed_eav(
  { name: "priority", value: "high" },
  scope: "t1",
  parent_scope: "w1",
)
```

When `acts_as_tenant` is loaded, the auto-detected `DEFAULT_SCOPE_RESOLVER`
returns `[ActsAsTenant.current_tenant, nil]` — the parent_scope slot is `nil`
because the tenant gem has no parent-scope analog. Configure your own resolver
when you need both axes.

### Migrating from v0.1.x

The resolver-callable contract is a **breaking change**: any custom
`Config.scope_resolver` lambda must now return `[scope, parent_scope]` (a
2-element Array) instead of a bare scalar. A scalar return raises
`ArgumentError` at the next ambient query so the failure is loud, not silent.
If you don't use parent_scope, return `[scope, nil]`.

Run `bin/rails typed_eav:install:migrations` to copy the new
`AddParentScopeToTypedEavPartitions` migration into your app, then
`bin/rails db:migrate`. The migration is safe on production: it adds a
nullable `parent_scope` column (catalog-only, instantaneous) and uses
`CREATE INDEX CONCURRENTLY` for all index changes, so existing rows aren't
rewritten. Existing fields end up with `parent_scope = NULL` (the
global-parent shape) and continue to work for every single-scope caller.

See the [CHANGELOG](CHANGELOG.md) for the full upgrade checklist.

### Orphan-parent invariant

A `Field` or `Section` row with `parent_scope` set and `scope` blank is
invalid — model-level validation rejects it on save. Reason: a "global field
within one workspace" has no semantic resolution path; the row would never
match any record's resolver. The paired partial unique indexes rely on this
invariant.

### Name collisions across scopes

When both a global field (`scope: nil`) and a scoped field share a name, the **scoped definition wins** for the partition that owns it: forms render exactly one input (the scoped one), reads return the scoped value, and writes target the scoped row.

`TypedEAV.unscoped { Contact.where_typed_eav(...) }` OR-across every partition's matching `field_id` per filter (still AND-ing across filters), so cross-tenant audit queries see every partition's matches — they don't collapse to a single tenant.

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

### Multi-cell field types (Phase 5)

External field types may store their logical value across multiple typed
columns. To support this, override three methods on your custom field
class:

- `read_value(value_record)` (instance method) — return the composite
  value from the multi-cell shape (e.g.,
  `{amount: BigDecimal, currency: String}`).
- `apply_default_to(value_record)` (instance method) — write the
  configured default across all relevant columns.
- `self.operator_column(operator)` (class method) — return which physical
  column a given operator acts on (e.g., `:eq` → `:decimal_value` for
  amount, `:currency_eq` → `:string_value` for currency code).

Defaults delegate to `value_column` for all three, so existing single-
cell types are unchanged. The built-in `Field::Currency` (Phase 5) is
the canonical multi-cell consumer of these extension points.

### Built-in Phase-5 field types

- **`Currency` (Phase 5):** Stores `{amount: BigDecimal, currency: String}` across two typed columns (`decimal_value` for the amount; `string_value` for the ISO 4217 currency code). Operators: `:eq`, `:gt`, `:lt`, `:gteq`, `:lteq`, `:between` target the amount; `:currency_eq` targets the currency code; `:is_null` / `:is_not_null` target the amount column (a Currency value is null when its amount is null). Cast input MUST be a hash with `:amount` and/or `:currency` keys — bare numeric/string values are rejected with `:invalid` to enforce explicit currency dimension at write time. Options: `default_currency` (String ISO code, applied as fallback only when an amount is given without an explicit currency), `allowed_currencies` (Array of ISO codes; `validate_typed_value` enforces inclusion). Versioning snapshots automatically capture both columns under `value_columns` iteration (no Phase 4 subscriber changes required). The `:currency_eq` operator is registered ONLY on `Field::Currency`; the QueryBuilder operator-validation gate rejects it with a clear `ArgumentError` if invoked on any other field type.

  ```ruby
  Contact.where_typed_eav(name: "price", op: :currency_eq, value: "USD")
  Contact.where_typed_eav(name: "price", op: :between,     value: [50, 150])
  ```

- **`Percentage` (Phase 5):** A `Field::Decimal` subclass storing the underlying fraction in 0..1 (inclusive). The `:percent` representation is a format-time concern — call `field.format(value)` with `display_as: :percent` to render `0.75` as `"75.0%"`. Options: `decimal_places` (Integer >= 0, default 2; format-time precision only — does NOT alter what's stored in `decimal_value`), `display_as` (`:fraction` default, or `:percent`). Validation: out-of-range values (e.g., `1.5`) fail with the message `"must be between 0.0 and 1.0"`. Storage and operator semantics inherit from `Field::Decimal`.

  ```ruby
  pf = TypedEAV::Field::Percentage.create!(
    name: "discount", entity_type: "Order", scope: tenant_id,
    options: { display_as: :percent, decimal_places: 1 },
  )
  pf.format(BigDecimal("0.755")) # => "75.5%"
  ```

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
- **Event hooks fire from `after_commit`**: the `on_value_change` and `on_field_change` callbacks fire after the database write is durable; their exceptions never break a save. See §"Event hooks" for the full contract.
- **Versioning is opt-in**: When enabled (`TypedEAV.config.versioning = true` on the gem; `versioned: true` per host), every `:create` / `:update` / `:destroy` event on a Value writes an append-only audit row in `typed_eav_value_versions`. See §"Versioning" for the full contract.

## Event hooks

`typed_eav` fires `after_commit` events for value and field changes. Use them
for audit logs, search-index synchronization, cache invalidation, or any
out-of-band reaction that must wait until the database write is durable.

### Public callback slots

```ruby
TypedEAV.configure do |c|
  c.on_value_change = ->(value, change_type, context) {
    # change_type ∈ [:create, :update, :destroy]
    # context is a frozen Hash (see `with_context` below) — read-only
  }

  c.on_field_change = ->(field, change_type) {
    # change_type ∈ [:create, :update, :destroy, :rename]
    # NOTE: no context arg — field changes are CRUD-on-config, not
    # per-entity user actions
  }
end
```

The `:rename` change_type fires whenever the field's `name` column changed
in the just-committed save, even when bundled with other attribute changes
(options, sort_order, default_value, etc.). The detection is intentionally
escalating — Phase 7's materialized index needs to regenerate column DDL on
every rename.

`:update` on Value fires only when the typed value column changed. Saving
a Value record without modifying its typed column (e.g., touching only
bookkeeping columns) is a no-op for event dispatch.

`field_dependent: :nullify` cascades produce **no** Value `:destroy`
events. The FK `ON DELETE SET NULL` runs at the database level and
bypasses AR callbacks. Only the Field `:destroy` event fires. Use
`field_dependent: :destroy` if your consumer needs per-Value events on
field deletion.

### Thread-local context with `with_context`

```ruby
TypedEAV.with_context(request_id: request.uuid, actor_id: current_user.id) do
  contact.update!(typed_eav: { phone: "555-1234" })
  # on_value_change receives { request_id: "...", actor_id: 42 } as context
end
```

`with_context` is a thread-local stack with shallow per-key merge:

```ruby
TypedEAV.with_context(request_id: "abc") do
  TypedEAV.with_context(source: :bulk) do
    # current context: { request_id: "abc", source: :bulk }
  end
  # current context: { request_id: "abc" }
end
# current context: {}
```

The current-context hash is frozen — callbacks cannot mutate it. Outer
context is restored on exit even if the inner block raises.

`TypedEAV.current_context` returns the current frozen Hash (or a shared
frozen `{}` when no `with_context` block is active). It's safe to call
from any code path; it never returns nil.

### Error policy

User callbacks (`Config.on_value_change`, `Config.on_field_change`) are
rescued — exceptions are logged via `Rails.logger.error` and **do not
propagate** to the user's save call. The save row is already committed
when `after_commit` fires; re-raising would surface a misleading
"save failed" error.

This is the deliberate split with first-party features. Internal
subscribers used by `typed_eav` itself (Phase 4 versioning, Phase 7
materialized index) follow a different rule: their exceptions
**propagate**. Versioning corruption must be loud.

### Ordering guarantee

When multiple subscribers are registered, they fire in this order:

1. First-party internal subscribers (versioning, matview, etc.), in
   registration order. Errors propagate.
2. The user proc on `Config.on_value_change` / `Config.on_field_change`,
   last. Errors are rescued and logged.

Reassigning `Config.on_value_change` after gem initialization does **not**
disable internal subscribers — they live on a separate dispatcher list
and survive `Config.reset!`.

### Test isolation

Test files that exercise event hooks should opt in to the `:event_callbacks`
metadata:

```ruby
RSpec.describe "my feature", :event_callbacks do
  it "fires the hook" do
    captured = []
    TypedEAV::Config.on_value_change = ->(v, t, _ctx) { captured << [v.id, t] }
    contact.update!(typed_eav: { phone: "555-1234" })
    expect(captured).to include([be_a(Integer), :update])
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshots and
restores Config user procs and the internal-subscriber lists around each
example, so test mutations don't leak across examples and engine-load
registrations from later phases stay intact.

Integration specs that create real AR records and need `after_commit` to
fire durably should additionally opt in to `:real_commits`:

```ruby
RSpec.describe "my model", :event_callbacks, :real_commits do
  # ...
end
```

`:real_commits` disables transactional fixtures for the example and
manually deletes typed_eav rows in FK order after.

### Reset semantics

| Method | What it resets |
|---|---|
| `TypedEAV::Config.reset!` | User procs (`on_value_change`, `on_field_change`) plus `field_types`, `scope_resolver`, `require_scope`. Does **not** clear internal subscribers. |
| `TypedEAV::EventDispatcher.reset!` | Internal subscribers only. Does **not** touch Config. |

Production code rarely calls either — they exist for test isolation and
for the rare case where a host app wants to fully unwire the gem in a
specific request lifecycle.

## Versioning

`typed_eav` ships an opt-in append-only audit log for changes to typed
values. When enabled, each `:create` / `:update` / `:destroy` event on
a Value writes a row to `typed_eav_value_versions` capturing the
before-state, after-state, actor, context, and timestamp.

Default off. Apps that don't enable it pay zero overhead — the Phase 04
internal subscriber is not registered with `EventDispatcher.value_change_internals`
at all when `Config.versioning = false`. Zero callable in the dispatcher
chain, zero per-write method dispatch, zero per-write config read.

### Enabling versioning

Two steps:

```ruby
# 1. Set the gem-level master switch in an initializer.
#    config/initializers/typed_eav.rb
TypedEAV.configure do |c|
  c.versioning = true
  c.actor_resolver = -> { Current.user }   # optional; nil is permissive
end

# 2. Opt the host model in. Either via the kwarg form:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id, versioned: true
end

# Or via the concern (equivalent — pick whichever fits your conventions):
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
  include TypedEAV::Versioned
end
```

The two opt-in forms produce identical Registry state. The kwarg form is
preferred for new code; the concern form fits codebases with established
mixin-based feature wiring.

### Querying history

```ruby
contact.typed_eav_attributes = [{ name: "age", value: 41 }]
contact.save!
contact.typed_eav_attributes = [{ name: "age", value: 42 }]
contact.save!

value = contact.typed_values.find_by(field: age_field)
value.history          # most-recent-first relation
# => [<ValueVersion change_type: "update" before: {"integer_value" => 41} after: {"integer_value" => 42}>,
#     <ValueVersion change_type: "create" before: {} after: {"integer_value" => 41}>]

value.history.first.changed_by   # => "42" (User#42 — coerced to id.to_s)
value.history.first.context      # => { "request_id" => "abc-123" } if with_context was active
```

`value.history` is a chainable relation. Filter, paginate, pluck:

```ruby
value.history.where(change_type: "update").pluck(:changed_at, :changed_by)
value.history.limit(5).each { |v| ... }
```

### Querying full audit history (including destroy events)

`Value#history` returns versions where `value_id` matches the live Value
record. After the live Value is destroyed, the FK `ON DELETE SET NULL`
nullifies `value_id` on the existing version rows, and the new `:destroy`
version is also written with `value_id: nil` (the parent
`typed_eav_values` row is gone by `after_commit on: :destroy` time —
writing a non-nil `value_id` would FK-fail at INSERT). So `Value#history`
cannot surface destroy versions, and after Value destruction it can no
longer be called at all.

To query the FULL audit history for a given (entity, field), including
destroy events and post-destruction lookup, use the entity-scoped query
directly:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.name, entity_id: contact.id, field_id: age_field.id)
  .order(changed_at: :desc, id: :desc)
# => [<ValueVersion change_type: "destroy" before: {"integer_value" => 42} after: {} value_id: nil>,
#     <ValueVersion change_type: "update"  before: {"integer_value" => 41} after: {"integer_value" => 42} value_id: nil>,
#     <ValueVersion change_type: "create"  before: {} after: {"integer_value" => 41} value_id: nil>]
```

This pattern is the canonical way to surface "what happened to this
field on this entity" across the full lifecycle, including post-destroy.
The `entity_type` + `entity_id` columns remain the durable identity even
after the parent Value row is gone, and `field_id` survives because
destroying a Value does not destroy its Field.

For broader audit views — "show all version history across all fields
for a given entity" (e.g., admin entity-history pages, compliance
exports) — drop the `field_id` filter:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.name, entity_id: contact.id)
  .order(changed_at: :desc, id: :desc)
# => all version rows for every typed field on this contact, most-recent-first.
# Includes :create, :update, and :destroy events across every field the
# entity has ever had a typed value for.
```

The field-scoped query (with `field_id:`) is the common case for
"history of a single field"; the entity-scoped query (without `field_id:`)
is the broad-audit case for "all version history across all fields for
this entity".

### Version row jsonb shape

`before_value` and `after_value` are jsonb hashes keyed by typed-column
name:

| Field type | Snapshot shape (single key) |
|---|---|
| `text`, `email`, `url`, `color` | `{"string_value": "..."}` |
| `long_text` | `{"text_value": "..."}` |
| `integer` | `{"integer_value": 42}` |
| `decimal` | `{"decimal_value": "10.5"}` |
| `boolean` | `{"boolean_value": true}` |
| `date` | `{"date_value": "2026-05-05"}` |
| `date_time` | `{"datetime_value": "2026-05-05T12:00:00Z"}` |
| `select` | `{"string_value": "..."}` |
| `multi_select`, `*_array`, `json` | `{"json_value": [...]}` |

Multi-cell field types (Phase 5 Currency, when it lands) produce
two-key snapshots: `{"decimal_value": "99.99", "string_value": "USD"}`.
The version row's snapshot iterates `Field.value_columns` (plural), so
new field types get the right shape automatically.

`{}` (empty hash) and `{"<col>": null}` are distinct semantics:

- `{}` means **no recorded value** — typical of `before_value` on a
  `:create` event, or `after_value` on a `:destroy` event.
- `{"<col>": null}` means **recorded nil** — the user explicitly
  cleared the cell.

### Reverting

```ruby
target = value.history.find_by(change_type: "update")
value.revert_to(target)
# value's typed columns now match target.before_value.
# A NEW version row is written capturing the revert (append-only).
```

`revert_to` writes the targeted version's `before_value` columns back
via `self[col] = …` and `save!`. The existing `after_commit` chain
fires; the versioning subscriber writes a NEW version row whose
`after_value` reflects the targeted version's `before_value`. The
audit log is append-only — every revert is itself versioned.

To record the intent of the revert, wrap the call in `with_context`:

```ruby
TypedEAV.with_context(reverted_from_version_id: target.id, actor: current_user) do
  value.revert_to(target)
end
# The new version row's `context` column captures both keys.
```

`revert_to` raises `ArgumentError` in three documented conditions, checked in order:

- when `version.value_id` is nil (the source Value was destroyed — destroy
  versions have `value_id: nil` per the locked subscriber contract; you
  can't restore a destroyed AR record by `save!`);
- when the version's `before_value` is empty (the version represents a
  `:create` event with no before-state to revert to);
- when the version belongs to a different Value (`value_id` mismatch).

In practice only `:update` versions are revertable. To restore a
destroyed entity's typed values, create a new `TypedEAV::Value` record
manually using `version.before_value` as the seed state.

### Hook ordering guarantee

Versioning is registered as an internal subscriber on
`TypedEAV::EventDispatcher`. It runs **first** (slot 0) for every Value
event. Your `Config.on_value_change` user proc fires **last**, after
the version row is persisted:

```
Value#save! → after_commit → EventDispatcher.dispatch_value_change:
  1. TypedEAV::Versioning::Subscriber.call  # writes version row
  2. ... any other internal subscribers (Phase 7 matview, etc.) ...
  3. Config.on_value_change user proc        # sees the persisted version
```

Internal subscriber errors propagate (versioning corruption is loud).
User proc errors are rescued and logged via `Rails.logger.error` —
the save itself already committed.

### Actor resolution

`Config.actor_resolver` mirrors `Config.scope_resolver`'s callable shape
but returns whatever the app chooses (an AR record, a string, an integer,
nil). The subscriber coerces non-nil returns via `id.to_s` (for AR
records) or `to_s` (for scalars) before storing in the `changed_by`
column (string, nullable).

`nil` is the documented permissive sentinel: system writes, migrations,
console-without-actor, and background jobs without a `with_context(actor:
...)` wrap all flow through with `changed_by: nil`. This is intentional —
forcing every Versioned write to have an actor would reject every console
save and every migration backfill, which is hostile-by-default for a gem.

Apps that need stricter enforcement do it inside the resolver:

```ruby
c.actor_resolver = -> { Current.user || raise(MyApp::ActorRequired) }
```

`Config.reset!` (documented in §"Event hooks") also resets `Config.versioning`
to `false` and `Config.actor_resolver` to `nil`.

### What versioning does not do

- **No branching/merging across version chains.** Phase 4 ships event-log
  shape only. Roadmap explicitly defers branching to a future design.
- **No snapshot storage by default.** `typed_eav_value_versions` is an
  event log — one row per change, not a full-row snapshot. For
  high-volume apps that want snapshot storage, extend `ValueVersion` in
  your own code (the gem keeps the event-log shape canonical so future
  upgrades don't break your extension).
- **No automatic `reverted_from_version_id` injection.** Use
  `with_context` to record revert intent; the gem captures whatever
  context the caller set.
- **No per-Field versioning toggle.** Opt-in is per-entity (host model)
  in Phase 4. Per-field granularity may land later if a real need
  surfaces.
- **No GIN indexes on `before_value` / `after_value` content.** Apps
  that need to query inside the snapshot jsonb add their own indexes.
  Phase 4 ships only the temporal indexes (`changed_at DESC` keyed on
  `value_id`, `(entity_type, entity_id)`, and `field_id`).

### Test isolation

Specs that exercise versioning should opt into the `:event_callbacks`
and `:real_commits` metadata flags (see §"Event hooks" — same pattern):

```ruby
RSpec.describe "my versioning behavior", :event_callbacks, :real_commits do
  before do
    TypedEAV.registry.register("Contact", versioned: true)
    TypedEAV::Config.versioning = true
    # CRITICAL: the :event_callbacks hook clears
    # EventDispatcher.value_change_internals at example entry, so the
    # engine-boot-registered subscriber is gone for the duration of
    # the example. Re-register explicitly inside the before block.
    # The hook's ensure block restores the snapshot — no leak.
    TypedEAV::EventDispatcher.register_internal_value_change(
      TypedEAV::Versioning::Subscriber.method(:call),
    )
  end
  after { TypedEAV.registry.register("Contact", versioned: false) }

  it "writes a version row" do
    # ...
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshot/
restores `Config.versioning`, `Config.actor_resolver`, and the
EventDispatcher subscriber lists around each example, so your changes
don't leak to subsequent tests. The snapshot/restore CLEARS the
internals list at example entry — that's why the re-registration
above is required for any spec that needs the subscriber to fire. The
`:real_commits` hook disables transactional fixtures (so `after_commit`
fires durably) and cleans up `TypedEAV::ValueVersion` rows in
FK-respecting order between examples.

## Database Support

Requires PostgreSQL. The `text_pattern_ops` index on `string_value` and the jsonb `@>` containment operator are Postgres-specific. MySQL/SQLite support would require removing those index types and changing the array query operators.

As of v0.2.0, the paired partial unique indexes cover the three-key partition tuple `(entity_type, scope, parent_scope)`. The orphan-parent invariant means the `WHERE scope IS NULL` partials don't include `parent_scope` — a global row always has `parent_scope` NULL too.

## Schema

The gem creates four tables:

- `typed_eav_fields` - field definitions (STI, one row per field per entity type)
- `typed_eav_values` - values (one row per entity per field, with typed columns)
- `typed_eav_options` - allowed values for select/multi-select fields
- `typed_eav_sections` - optional UI grouping

## License

MIT
