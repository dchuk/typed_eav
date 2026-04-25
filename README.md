# TypedFields

Add dynamic custom fields to ActiveRecord models at runtime, backed by **native database typed columns** instead of jsonb blobs.

TypedFields uses a hybrid EAV (Entity-Attribute-Value) pattern where each value type gets its own column (`integer_value`, `date_value`, `string_value`, etc.) in the values table. This means the database can natively index, sort, and enforce constraints on your custom field data with zero runtime type casting.

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

TypedFields stores values in native columns, so queries become:

```sql
WHERE integer_value = 42
```

Standard B-tree indexes work. Range scans work. The query planner is happy. ActiveRecord handles all type casting automatically through the column's registered type.

## Installation

Add to your Gemfile:

```ruby
gem "typed_fields"
```

Run the install migration:

```bash
bin/rails typed_fields:install:migrations
bin/rails db:migrate
```

## Quick Start

### 1. Include the concern

```ruby
class Contact < ApplicationRecord
  has_typed_fields
end

# With multi-tenant scoping:
class Contact < ApplicationRecord
  has_typed_fields scope_method: :tenant_id
end

# With restricted field types:
class Contact < ApplicationRecord
  has_typed_fields types: [:text, :integer, :boolean, :select]
end
```

### 2. Create field definitions

```ruby
# Simple fields
TypedFields::Field::Text.create!(
  name: "nickname",
  entity_type: "Contact"
)

TypedFields::Field::Integer.create!(
  name: "age",
  entity_type: "Contact",
  required: true,
  options: { min: 0, max: 150 }
)

TypedFields::Field::Date.create!(
  name: "birthday",
  entity_type: "Contact",
  options: { max_date: Date.today.to_s }
)

# Select field with options
status = TypedFields::Field::Select.create!(
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
tags = TypedFields::Field::MultiSelect.create!(
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
contact.set_typed_field_value("age", 40)
contact.set_typed_field_value("status", "active")

# Bulk assignment by field NAME (ergonomic for scripting / seeds)
contact.typed_fields_attributes = [
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
contact.typed_field_value("age")    # => 40 (Ruby Integer)
contact.typed_field_value("status") # => "active"
contact.typed_fields_hash           # => { "age" => 40, "status" => "active", ... }
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
Contact.where_typed_fields(
  { name: "age",    op: :gt,       value: 21 },
  { name: "status", op: :eq,       value: "active" },
  { name: "city",   op: :contains, value: "port" },
)

# Compact keys (for URL params / form submissions)
Contact.where_typed_fields(
  { n: "age", op: :gt, v: 21 },
  { n: "status", v: "active" },
)

# With scoping
Contact.where_typed_fields(
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
bin/rails g typed_fields:scaffold
bin/rails db:migrate
```

This copies a controller, views, helper, Stimulus controllers, and an initializer into your app, and adds routes mounted at `/typed_fields`.

**Security**: the generated controller ships with `authorize_typed_fields_admin!` returning `head :not_found` by default — fail-closed. Edit the method directly in `app/controllers/typed_fields_controller.rb` to wire it to your auth system:

```ruby
def authorize_typed_fields_admin!
  return if current_user&.admin?
  head :not_found
end
```

Defining `authorize_typed_fields_admin!` in `ApplicationController` does **not** override it — the scaffold sets it on its own controller.

## Multi-Tenant Scoping

Field definitions are partitioned by a `scope` column so multiple tenants (or accounts, workspaces, orgs — any partition key your app uses) can each define their own fields without collisions. Fields with `scope = NULL` are global, visible to every partition.

### Declaring a scoped model

```ruby
class Contact < ApplicationRecord
  has_typed_fields scope_method: :tenant_id
end
```

`scope_method:` names an instance method on your model. When the record reads its own field definitions (e.g., in a form), that method tells TypedFields which partition the record belongs to.

### Class-level queries resolve scope automatically

Queries like `Contact.where_typed_fields(...)` consult an **ambient scope resolver** — no need to pass `scope:` on every call:

```ruby
# The resolver tells TypedFields which partition is active.
Contact.where_typed_fields({ name: "age", op: :gt, value: 21 })
```

The resolver chain (highest priority first):

1. Explicit `scope:` keyword argument on the query
2. Active `TypedFields.with_scope(value) { ... }` block
3. Configured `TypedFields.config.scope_resolver` callable
4. `nil`

If every step returns `nil` and the model declared `scope_method:`, queries raise `TypedFields::ScopeRequired` — the **fail-closed default**. This is the whole point: forgetting to set scope can't silently leak other partitions' data.

### Wiring the resolver

Pick the pattern that matches your app and set it once in `config/initializers/typed_fields.rb`:

```ruby
TypedFields.configure do |c|
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

The resolver can return a raw value (`"t1"`, `42`) or an AR record — TypedFields calls `.id.to_s` when the return value responds to `#id`.

### Block APIs

```ruby
# Run a block with a specific ambient scope (background jobs, console, rake tasks):
TypedFields.with_scope(tenant_id) do
  Contact.where_typed_fields({ name: "status", op: :eq, value: "active" })
end

# Escape hatch for admin tools, migrations, or cross-tenant audits:
TypedFields.unscoped do
  Contact.where_typed_fields({ name: "status", op: :eq, value: "active" })
  # returns matches across ALL partitions
end
```

Both are exception-safe via `ensure` and nest cleanly.

### Explicit `scope:` override

Any query method accepts `scope:` as an override for admin tools and tests:

```ruby
Contact.where_typed_fields({ name: "status", value: "active" }, scope: "t1")
Contact.with_field("age", :gt, 21, scope: "t1")
```

Explicit wins over ambient. Passing `scope: nil` explicitly (as opposed to omitting the kwarg) means "filter to global fields only" — useful for admin UIs that want to see unscoped field definitions without activating `unscoped` mode.

### Background jobs

ActiveJob (including Sidekiq via the ActiveJob adapter) wraps every `perform` in Rails' executor, which already clears `ActiveSupport::CurrentAttributes` between jobs — so if your resolver reads from `Current.account`, each job starts clean. For raw `Sidekiq::Job` (no ActiveJob), wrap the job body manually:

```ruby
class ExportJob
  include Sidekiq::Job

  def perform(tenant_id, ...)
    TypedFields.with_scope(tenant_id) do
      Contact.where_typed_fields(...)
    end
  end
end
```

### Disabling enforcement for gradual adoption

If your app has existing typed-field queries that don't yet pass scope, flip `require_scope` to `false` in the initializer. When no scope resolves, queries fall back to **global fields only** (definitions stored with `scope: nil`) instead of raising — they do **not** return all partitions' fields. Audit and fix callers, then flip back to `true`.

To intentionally query across every partition (admin tools, migrations, cross-tenant audits), use the explicit escape hatch `TypedFields.unscoped { ... }` rather than relying on `require_scope = false`.

### Name collisions across scopes

When both a global field (`scope: nil`) and a scoped field share a name, the **scoped definition wins** for the partition that owns it: forms render exactly one input (the scoped one), reads return the scoped value, and writes target the scoped row.

`TypedFields.unscoped { Contact.where_typed_fields(...) }` OR-across every partition's matching `field_id` per filter (still AND-ing across filters), so cross-tenant audit queries see every partition's matches — they don't collapse to a single tenant.

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
| `Select` | `string_value` | String | options via `TypedFields::Option` |
| `MultiSelect` | `json_value` | Array | options via `TypedFields::Option` |
| `IntegerArray` | `json_value` | Array | `min_size`, `max_size`, `min`, `max` |
| `DecimalArray` | `json_value` | Array | `min_size`, `max_size` |
| `TextArray` | `json_value` | Array | `min_size`, `max_size` |
| `DateArray` | `json_value` | Array | `min_size`, `max_size` |
| `Email` | `string_value` | String | auto-downcases, strips whitespace |
| `Url` | `string_value` | String | strips whitespace |
| `Color` | `string_value` | String | hex color values |
| `Json` | `json_value` | Hash/Array | arbitrary JSON |

## Sections (Optional UI Grouping)

```ruby
general = TypedFields::Section.create!(
  name: "General Info",
  code: "general",
  entity_type: "Contact",
  sort_order: 1
)

social = TypedFields::Section.create!(
  name: "Social Media",
  code: "social",
  entity_type: "Contact",
  sort_order: 2
)

TypedFields::Field::Text.create!(
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
  class Phone < TypedFields::Field::Base
    value_column :string_value
    operators :eq, :contains, :starts_with, :is_null, :is_not_null

    def cast(raw)
      # Strip everything but digits and +; never rejects as invalid
      [raw&.to_s&.gsub(/[^\d+]/, ""), false]
    end
  end
end

# Register it
TypedFields.configure do |c|
  c.register_field_type :phone, "Fields::Phone"
end
```

## Validation Behavior

A few non-obvious contracts worth knowing about up front:

- **Required + blank**: `required: true` fields reject empty strings, whitespace-only strings, and arrays whose every element is nil/blank/whitespace.
- **Array all-or-nothing cast**: integer/decimal/date arrays mark the **whole** value invalid (stored as `nil`) when any element fails to cast. There is no silent partial — a failed form re-renders with the original input intact so the user can correct the bad element.
- **`Integer` array rejects fractional input**: `"1.9"` is rejected rather than truncated to `1`. Same rules as the scalar `Integer` field.
- **`Json` parses string input**: a JSON string posted from a form is parsed; parse failures surface as `:invalid` rather than being stored as the literal string.
- **`TextArray` does not support `:contains`**: it backs a jsonb column where SQL `LIKE` doesn't apply. Use `:any_eq` for "array contains element".
- **Orphaned values are skipped**: if a field row is deleted while values remain, `typed_field_value` and `typed_fields_hash` silently skip the orphans rather than raising.
- **Cross-scope writes are rejected**: assigning a `Value` to a record whose `typed_fields_scope` doesn't match the field's `scope` adds a validation error on `:field`.

## Database Support

Requires PostgreSQL. The `text_pattern_ops` index on `string_value` and the jsonb `@>` containment operator are Postgres-specific. MySQL/SQLite support would require removing those index types and changing the array query operators.

## Schema

The gem creates four tables:

- `typed_fields` - field definitions (STI, one row per field per entity type)
- `typed_field_values` - values (one row per entity per field, with typed columns)
- `typed_field_options` - allowed values for select/multi-select fields
- `typed_field_sections` - optional UI grouping

## License

MIT
