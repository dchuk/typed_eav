# TypedEAV

[Documentation](https://dchuk.github.io/typed_eav/) · [Getting started](https://dchuk.github.io/typed_eav/getting-started.html) · [API reference](https://dchuk.github.io/typed_eav/reference/api.html)

Add runtime-defined custom fields to Active Record models, with typed values,
validation, and SQL filtering, sorting, and summaries.

Scalar values use native PostgreSQL columns such as `integer_value` and
`date_value`; collection and JSON fields use JSONB. Field definitions control
casting and validation, and can be shared globally or scoped to tenants.

TypedEAV is useful when users define fields at runtime and your application
needs to query them through a consistent typed interface. JSONB also works well
for many workloads; choose based on your query patterns and operational needs.
See [Storage and performance](docs/guides/performance.md) for the tradeoffs,
indexing guidance, and benchmark evidence.

## Compatibility

The canonical support contract lives in
[`.github/compatibility.json`](https://github.com/dchuk/typed_eav/blob/main/.github/compatibility.json). Typed EAV supports:

| Runtime | Supported versions |
|---|---|
| Ruby | 3.3 through 4.0 (`>= 3.3`, `< 4.1`) |
| Rails | 7.2 through 8.1 (`>= 7.2`, `< 8.2`) |
| PostgreSQL | 15 through 18 |

CI proves representative floor, middle, and ceiling combinations rather than
every Cartesian product. Versions outside these ranges and prerelease versions
are outside the support guarantee. PostgreSQL compatibility claims assume the
current minor release for each supported major version.

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

PostgreSQL is required; MySQL and SQLite are not supported. For existing
installations, see [Upgrading](docs/guides/upgrading.md) and the
[Changelog](CHANGELOG.md).

## Quick Start

Assuming your application already has a `Contact` model and table:

```ruby
class Contact < ApplicationRecord
  has_typed_eav
end

TypedEAV::Field::Integer.create!(
  name: "age",
  entity_type: Contact.polymorphic_name,
  options: { min: 0, max: 150 }
)

contact = Contact.new
contact.set_typed_eav_value("age", "40")
contact.save! # Supply any other attributes your Contact model requires.

contact.typed_eav_value("age") # => 40 (Integer)
contact.typed_eav_hash         # => { "age" => 40 }

Contact.with_field("age", :gteq, 21)
       .order_typed_eav("age", direction: :desc)
       .limit(25)
```

Fields cast and validate both assigned values and query operands. Queries
return Active Record relations, so you can combine them with ordinary host
filters. Use `Contact.polymorphic_name` when creating definitions to respect
Rails' STI and namespaced-polymorphism settings.

See [Reading, writing, and forms](docs/guides/usage.md) for bulk assignment,
nested attributes, form helpers, and the admin scaffold, or
[Querying typed fields](docs/guides/queries.md) for operators, multi-field
filters, sorting, distinct values, counts, and numeric aggregates.

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

See [Field types and validation](docs/guides/fields.md) for options, casting
rules, attachments, sections, and custom single- or multi-column field types.

## Essential Behavior

- **Scoping selects definitions, not host records.** Apply tenant and
  authorization filters to the host relation. Scoped models require scope by
  default; global definitions can be overridden by more specific partitions.
  See [Multi-tenant scoping](docs/guides/scoping.md).
- **Missing rows and explicit NULLs differ.** Filtering, sorting, summaries,
  and reads have documented rules for each. See
  [Queries](docs/guides/queries.md) and [Bulk reads](docs/guides/bulk-operations.md#bulk-reads-bulkread).
- **The admin scaffold requires authorization.** Its generated controller
  returns `404` until you implement `authorize_typed_eav_admin!` directly on
  that controller. See [Admin scaffold](docs/guides/usage.md#admin-scaffold).
- **Versioning is opt-in.** Audit rows share the value transaction; public
  change hooks run after commit. In-memory dirty tracking is separate from
  audit history. See [Events and versioning](docs/guides/events-and-versioning.md)
  and [Typed-value changes](docs/guides/usage.md#in-memory-typed-value-changes).
- **Bulk write APIs have different guarantees.** The regular writer saves
  hosts with callbacks and validations. Fast upsert requires explicit
  acknowledgment that host saves, persistence callbacks, and versioning are
  skipped. See [Bulk operations](docs/guides/bulk-operations.md).

## Documentation

Start at the [documentation home](docs/index.md), or browse the
[public API and configuration reference](docs/reference/index.md).

| Guide | Covers |
|---|---|
| [Reading, writing, and forms](docs/guides/usage.md) | Assignment by name or ID, nested forms, admin scaffold, pending and saved changes |
| [Querying typed fields](docs/guides/queries.md) | Operators, filter composition, sorting, distinct values, counts, aggregates |
| [Multi-tenant scoping](docs/guides/scoping.md) | Resolvers, two-level partitions, precedence, background jobs, administrative queries |
| [Field types and validation](docs/guides/fields.md) | Built-in types, options, sections, attachments, custom types, validation contracts |
| [Bulk operations](docs/guides/bulk-operations.md) | Selective and preloaded reads, semantic writes, fast upsert, transactions, default backfills |
| [Events and versioning](docs/guides/events-and-versioning.md) | Callbacks, context, actor resolution, audit history, reverting |
| [CSV mapping](docs/guides/csv-import.md) | Header/index mapping, typed casting, row errors, saving mapped values |
| [Database schema and portability](docs/guides/schema.md) | Tables, PostgreSQL requirements, read-only schema previews |
| [Storage and performance](docs/guides/performance.md) | JSONB tradeoffs, optional indexes and statistics, query strategy, evidence limits |

## Development and Upgrades

- [Architecture](docs/guides/architecture.md) and [design decisions](docs/adr/)
- [Development and test isolation](docs/guides/development.md)
- [Benchmark guide](bench/README.md)
- [Upgrading](docs/guides/upgrading.md) and [Changelog](CHANGELOG.md)
- [Release process](RELEASING.md)

## License

MIT
