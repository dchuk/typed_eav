---
title: "Public API reference"
---

# Public API reference

This is an index of application-facing entry points. Linked guides explain
examples, supported types, validation, and transaction boundaries. Internal
query builders, dispatchers, caches, and callback methods are not extension APIs.

## Host models and records

Declare `has_typed_eav(scope_method: nil, parent_scope_method: nil, types: nil,
versioned: false)` on an Active Record model. Scope methods name record accessors;
`parent_scope_method` requires `scope_method`. `types: nil` allows registered
types; an array restricts them. Versioning additionally requires the global
boot-time switch. Use the host's `polymorphic_name` for `entity_type`.

| Record method | Contract |
| --- | --- |
| `typed_values` | Active Record association; normal saves validate and persist values with the host. |
| `typed_eav_definitions` | Visible definitions for this record's partition, including same-name candidates. |
| `typed_eav_scope`, `typed_eav_parent_scope` | Configured accessor values normalized to strings, or `nil`. |
| `initialize_typed_values` | Build missing effective fields with defaults in memory; returns `typed_values`. Save separately. |
| `typed_eav_value(name)` | Logical Ruby value, or `nil` when absent. |
| `set_typed_eav_value(name, value)` | Stage a value by effective field name; unknown names are ignored. Save separately. |
| `typed_eav_hash` | Hash of field names to logical values. |
| `typed_eav_attributes=` / `typed_eav=` | Named entries such as `[{name: "age", value: 30}]`; supports `_destroy`. |
| `typed_values_attributes=` | Rails nested attributes using `field_id`, optional Value `id`, `value`, and `_destroy`. |
| `typed_eav_changes` | Pending logical changes as `{name => [before, after]}`. |
| `saved_typed_eav_changes` | Logical changes from the latest successful host save; reload/rollback clears them. |

See [reading, writing, and forms](../guides/usage.md),
[defaults](../guides/usage.md#defaults-for-new-and-existing-records), and [scoping](../guides/scoping.md).

## Host queries

These methods are available on the host class and through Active Record relations.
The query methods below (including `typed_eav_definitions`) accept `scope:` and
`parent_scope:`. Omitted keywords use ambient resolution; explicit `nil` selects
the global axis. These select **field definitions**, not authorized host rows:
start with an appropriately filtered host relation.

| Method | Result and defaults |
| --- | --- |
| `where_typed_eav(*filters, include_missing: false)` | Active Record relation; filters use `name`, `op` (default `:eq`), and `value`. |
| `with_field(name, operator_or_value = nil, value = nil, include_missing: false)` | Single-filter relation; two-argument non-Symbol value implies equality. |
| `order_typed_eav(name, direction: :asc, nulls: :last)` | Relation ordered by a supported scalar field, then host primary key. Replaces prior ordering. |
| `distinct_typed_eav_values(name, limit: 100)` | Array of distinct scalar values in database order. |
| `count_distinct_typed_eav_values(name)` | Integer distinct count, including an explicit NULL category. |
| `typed_eav_value_counts(name, limit: 100)` | Hash of scalar values to counts. |
| `aggregate_typed_eav(name, operation:)` | `:min`, `:max`, or `:sum` for Integer/Decimal/Percentage; typed number or `nil` for empty min/max. |
| `typed_eav_definitions` | Relation of visible field definitions; does not collapse names. |

Missing rows differ from explicit NULL rows. `include_missing: true` broadens
`:is_null` and is ignored by other operators. Scalar APIs reject unsupported
field families and all-partition ambiguity with `ArgumentError`. See
[queries](../guides/queries.md) for operators, NULL behavior, limits, and errors.

## Bulk operations

| Host class method | Result and defaults |
| --- | --- |
| `typed_eav_hash_for(records, fields: nil, source: :database)` | `{record.id => {field_name => value}}`; optional selected field names; `source: :preloaded` reads loaded associations. |
| `bulk_set_typed_eav_values(records, values_by_field_name, version_grouping: :default, transaction: :all, chunk_size: nil)` | Normal host saves; returns `{successes: [...], errors_by_record: {record => errors_hash}}`. |
| `bulk_set_typed_eav_values_per_record(values_by_record, version_grouping: :default, transaction: :all, chunk_size: nil)` | Same result, with `{record => {field_name => value}}` input. |
| `bulk_upsert_typed_eav_values(records, values_by_field_name, acknowledge_reduced_semantics: false, transaction: :all, chunk_size: nil)` | Written row count; requires explicit acknowledgement, skips persistence callbacks and audit versions. |

Normal bulk writes collect validation failures per record; an unexpected exception
can roll back the active transaction. `transaction: :chunks` requires a positive
`chunk_size`; prior chunks remain committed on later failure. See
[bulk operations](../guides/bulk-operations.md) before choosing either write path.

## Field definitions and values

Use `TypedEAV::Field::<Type>.create!` and ordinary Active Record updates for field
metadata; `field_options` holds Select/MultiSelect choices. The
[fields guide](../guides/fields.md) covers every built-in type and its options.

| API | Purpose |
| --- | --- |
| `field.default_value` / `default_value=` | Read/set the logical default. Explicit value assignment can override it with `nil`. |
| `field.backfill_default!(relation: nil)` | Synchronously apply a configured default to eligible existing hosts in batches; no count/result contract. |
| `field.destroy!` | Apply the field's `field_dependent` policy. |
| `field.destroy_with_values_in_batches!(batch_size: 1_000)` | Resumable deletion for persisted `field_dependent: :destroy` fields; requires no open transaction. |
| `field.move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at(position)` | Reorder within the field's partition. |
| `field.field_type_name`, `display_name`, `array_field?`, `optionable?`, `allowed_option_values` | Metadata for rendering and field-management interfaces. |
| `field.cast(raw)` | Custom-type protocol returning `[cast_value, invalid]`; casting alone does not establish validity. |
| `value.value` / `value=` | Read/write the field's logical value, including multi-cell types. |
| `value.history` | Versions ordered newest first by timestamp and ID. |
| `value.revert_to(version)` | Save the version's **before** state and write a new version; rejects another Value's version, create versions, and destroyed source Values. |

See [default initialization and backfill](../guides/usage.md#defaults-for-new-and-existing-records),
[field deletion](../guides/events-and-versioning.md#public-callback-slots), and
[custom types](../guides/fields.md#custom-field-types) for their contracts. Full history after Value deletion requires querying
`TypedEAV::ValueVersion` by entity and field identity; see
[events and versioning](../guides/events-and-versioning.md).

## Schema and CSV

| API | Result |
| --- | --- |
| `TypedEAV::SchemaPortability.export_schema(entity_type:, scope: nil, parent_scope: nil)` | String-keyed versioned schema Hash for an exact partition, including fields and sections; excludes values. |
| `TypedEAV::SchemaPortability.preview_schema(hash, on_conflict: :error)` | Read-only JSON-safe comparison and predicted actions; advisory, not a reservation or validation guarantee. |
| `TypedEAV::SchemaPortability.import_schema(hash, on_conflict: :error)` | Counts under `"created"`, `"updated"`, `"skipped"`, `"unchanged"`, plus `"errors"`; import runs in a transaction and failures can raise. |
| `TypedEAV::SchemaPortability.export_snapshot_schema(entity_type:, scope: nil, parent_scope: nil)` | Lean versioned field projection; not a full import payload or a value backup. |
| `TypedEAV::CSVMapper.row_to_attributes(row, mapping, fields_by_name: nil)` | Result with frozen `attributes`/`errors` Hashes and `success?`/`failure?`. Does not save records. |

`Field::Base.export_schema` and `.import_schema` remain compatible delegators.
Conflict policies are `:error`, `:skip`, and `:overwrite`; type swaps are refused.
CSV mapping uses uniformly String header keys or Integer index keys, with field
names as values. Typed mode casts via supplied definitions, reports cast errors,
and skips unknown fields. Normal model validation must still run.
See [schema portability](../guides/schema.md) and [CSV imports](../guides/csv-import.md).

## Partition helpers

`TypedEAV::Partition` expects explicitly resolved scope values; it does not consult
ambient scope. Visibility methods accept `scope: nil`, `parent_scope: nil`, and
`mode: :partition`. Use `mode: :all_partitions` only for an authorized admin bypass.
Invalid modes and orphan parent scopes raise `ArgumentError` in partition mode.

| Method | Result |
| --- | --- |
| `visible_fields(entity_type: nil, ...)` | Field relation, including global, scope-only, and full-tuple candidates. |
| `effective_fields_by_name(entity_type:, ...)` | `{name => field}` with most-specific precedence; all-partitions mode instead returns `{name => [fields]}`. |
| `definitions_by_name(defs)` | Collapse supplied definitions by name, most-specific winning. Supply only the intended visible set. |
| `definitions_multimap_by_name(defs)` | Group supplied definitions as `{name => [fields]}` without collapsing. |
| `visible_sections(entity_type:, ...)` | Relation of sections visible to the tuple. |
| `find_visible_section!(id, entity_type:, ...)` | Visible Section, or `ActiveRecord::RecordNotFound`. |

These helpers constrain definition visibility; application authorization still
belongs to the caller. See [scoping](../guides/scoping.md).
