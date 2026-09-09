---
title: "Querying typed fields"
---

# Querying typed fields

[Documentation home](../index.md)

## Filtering

Queries use native typed columns and the indexes shipped for each type. The Field remains the owner of operand casting and validation; the query builder receives a field-normalized value rather than applying a generic Active Record cast.

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

## Missing values and explicit NULL

By default, `:is_null` finds existing Value rows whose typed value is NULL.
It does not find hosts with no Value row. For an "is empty" search that covers
both cases, opt into `include_missing:`:

```ruby
contacts = Contact.where(tenant_id: "t1")
contacts.with_field("age", :is_null, scope: "t1")
contacts.with_field("age", :is_null, scope: "t1", include_missing: true)

# The same option applies to every :is_null filter in a multi-filter query:
contacts.where_typed_eav(
  { name: "age", op: :is_null },
  { name: "status", value: "active" },
  scope: "t1", include_missing: true
)
```

`include_missing: true` means the host has **no non-NULL value** for the
selected definition. It has no effect on `:is_not_null` or any other operator;
it does not make an unknown field name valid. In administrative
`TypedEAV.unscoped` queries, no matching same-name definition may hold a
non-NULL value for that host. Other filters remain ANDed, and host authorization
still belongs on the caller relation.

## Sorting by a typed field

```ruby
Contact.where(tenant_id: "t1")
       .order_typed_eav("age", direction: :desc, nulls: :last, scope: "t1")
       .limit(25)
```

`order_typed_eav` returns an Active Record relation and orders in PostgreSQL,
without loading typed values into Ruby. It replaces prior ordering while
preserving host filters, STI restrictions, limits, and offsets. `direction:`
accepts `:asc` (default) or `:desc`; `nulls:` accepts `:first` or `:last`
(default in either direction). Missing rows and explicit NULLs share that
placement. Equal values use the host primary key ascending as a stable tie-break.

Scope arguments (or the ambient scope) select the winning field definition;
**they do not filter host records by tenant**. Keep authorization/tenant filters
on the caller relation. All-partitions `TypedEAV.unscoped` is rejected for this
API: choose one effective definition instead. Single native scalar cells are
supported, using their stored values (for example, reference IDs and attachment
signed IDs, not display labels). JSON/array and multi-cell fields such as
Currency are rejected rather than assigned an implicit ordering.

## Distinct values and grouped counts

```ruby
contacts = Contact.where(tenant_id: "t1")
contacts.distinct_typed_eav_values("status", scope: "t1", limit: 100)
# => ["active", "paused", nil]
contacts.typed_eav_value_counts("status", scope: "t1", limit: 100)
# => {"active" => 24, "paused" => 3, nil => 2}
contacts.count_distinct_typed_eav_values("status", scope: "t1")
# => 3
```

These scalar queries run in SQL without hydrating hosts or Values. Results
use native ascending value order, with explicit NULL (`nil`) last. Missing
value rows contribute nothing; `false` and empty strings remain real values.
Grouped counts count host identities, not duplicate rows introduced by joins.
The caller's filters, STI restrictions, distinctness, and pagination determine
the host set before summarization. Scope arguments choose field-definition
visibility, not host authorization, just as with typed sorting.

Lists and grouped-count hashes default to 100 values and accept a positive
Integer `limit:` up to 1,000. They are truncated in value order, not ranked by
frequency. Compare their length with `count_distinct_typed_eav_values` to
detect truncation; that exact SQL count includes one NULL category and returns
only an Integer, regardless of cardinality. It still requires database work
over the matching set. Collection/multi-cell fields and all-partitions mode
are unsupported, matching scalar sorting.

## Numeric aggregates

```ruby
Contact.where(tenant_id: "t1").aggregate_typed_eav(
  "score", operation: :sum, scope: "t1"
)
```

`aggregate_typed_eav` requires `operation: :min`, `:max`, or `:sum` and returns
one SQL-calculated scalar over the caller's host set. Integer fields return
Integers; Decimal and Percentage fields preserve `BigDecimal` precision, with
no Float conversion. Percentage values remain stored fractions, not formatted
percent strings. Missing rows and explicit NULLs are ignored. With no non-NULL
values, min/max return `nil` and sum returns the field's typed zero.

The same host filtering, partition visibility, STI, and pagination rules as
distinct queries apply. Only Integer/Decimal families (including Percentage)
with a single numeric cell are supported. Reference IDs, text, collections,
and multi-cell Currency are rejected; the gem does not silently sum identifiers
or combine currencies. No values or host records are loaded to compute the result.

## Available Operators

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

## How Type Inference Works

The owning Field casts and validates query operands before SQL generation;
Active Record supplies the SQL bind plumbing:

```ruby
# The Integer Field casts and validates the operand before SQL generation
Contact.with_field("age", :gt, "21")
# SQL: WHERE integer_value > 21  (not '21')

# The Date Field owns date parsing and validation
Contact.with_field("birthday", :lt, "2000-01-01")
# SQL: WHERE date_value < '2000-01-01'::date

# The Boolean Field owns truthy/falsy casting
Contact.with_field("active", "true")
# SQL: WHERE boolean_value = TRUE
```

Field-owned casting keeps query operands aligned with write semantics, including strict range/array shapes and specialized fields such as Currency and Reference. The resulting normalized operand is bound against the Field's typed column; Active Record supplies SQL bind plumbing, not the field's domain semantics.
