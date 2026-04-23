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
