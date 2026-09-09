---
title: "Database schema and portability"
---

# Database schema and portability

[Documentation home](../index.md)

## Database Support

Requires PostgreSQL. The `text_pattern_ops` index on `string_value` and the jsonb `@>` containment operator are Postgres-specific. MySQL/SQLite support would require removing those index types and changing the array query operators.

As of v0.2.0, the paired partial unique indexes cover the three-key partition tuple `(entity_type, scope, parent_scope)`. The orphan-parent invariant means the `WHERE scope IS NULL` partials don't include `parent_scope` — a global row always has `parent_scope` NULL too.

## Schema

The gem creates five tables:

- `typed_eav_fields` - field definitions (STI, one row per field per entity type)
- `typed_eav_values` - values (one row per entity per field, with typed columns)
- `typed_eav_options` - allowed values for select/multi-select fields
- `typed_eav_sections` - optional UI grouping
- `typed_eav_value_versions` - opt-in, append-only audit history for Value
  create, update, and destroy events; it retains durable entity identity even
  when the live Value row is later removed

## Exporting and importing definitions

Use the portable export to copy field and section definitions between databases:

```ruby
schema = TypedEAV::SchemaPortability.export_schema(
  entity_type: Contact.polymorphic_name, scope: "t1", parent_scope: nil
)
File.write("contact-schema.json", JSON.pretty_generate(schema))

# In the destination application, after installing the gem's migrations:
schema = JSON.parse(File.read("contact-schema.json"))
result = TypedEAV::SchemaPortability.import_schema(schema, on_conflict: :error)
result # => {"created" => 3, "updated" => 0, "skipped" => 0,
       #     "unchanged" => 0, "errors" => []} (example counts)
```

The string-keyed envelope has `schema_version: 1`, `entity_type`, `scope`,
`parent_scope`, `fields`, and `sections`. Export selects the **exact tuple**;
it does not merge inherited global definitions. Export each required partition
separately. It includes field types, raw labels, defaults, options, option rows,
and section properties. It excludes host records, Value rows, audit history,
database IDs, and field-to-section associations. It is not a database backup.
Custom field classes used by an export must also exist in the receiving app.

Import matches fields by name and partition, and sections by code and partition.
Identical entries increment `unchanged`. Divergent entries raise `ArgumentError`
under the default `:error` policy; `:skip` increments `skipped`, and `:overwrite`
updates the definition and increments `updated`. New entries increment `created`.
Counts combine fields and sections. Overwriting an optionable field replaces
its option rows; omitted definitions are retained. Existing values are neither
converted nor backfilled when defaults or constraints change.

Import runs in one transaction. Unsupported schema versions or conflict policies,
divergent definitions under `:error`, and all field type swaps raise
`ArgumentError`; model validation failures raise Active Record exceptions.
Failures roll back the import and propagate: `errors` is currently an empty
compatibility slot, **not** a collected failure report.

The importer uses each entry's partition identity. To deliberately copy to a
different tenant, update `entity_type`, `scope`, and `parent_scope` in both the
envelope and **every** field and section entry before previewing/importing.
Changing only the envelope does not retarget the imported rows. Preview first
when importing into an existing partition.

## Snapshot schema for application exports

```ruby
snapshot = TypedEAV::SchemaPortability.export_snapshot_schema(
  entity_type: Contact.polymorphic_name, scope: "t1"
)
snapshot["snapshot_schema_version"] # => 1
snapshot["fields"].map { |field| [field["name"], field["display_name"]] }
```

This read-only Hash is a smaller projection for applications packaging typed
values with enough field metadata to render or interpret them later. Each field
contains `name`, `field_type_name`, resolved `display_name`, `required`,
`sort_order`, and `options`; optionable fields also contain `options_data`.
Non-optionable fields omit that key. Fields are ordered by `sort_order`.

Unlike the portable export, the snapshot omits sections, partition identity,
STI class names, defaults, and `field_dependent`. Capture the owning partition
and values separately if your application needs them. Consumers should check
`snapshot_schema_version`; `field_type_name` survives namespace moves but changes
if a field's leaf class is renamed. There is no matching snapshot-import API:
use `export_schema` / `import_schema` for definition round trips.

## Read-only schema previews

```ruby
schema = TypedEAV::SchemaPortability.export_schema(
  entity_type: "Contact", scope: "t1"
)
schema["fields"].first["required"] = true
preview = TypedEAV::SchemaPortability.preview_schema(schema, on_conflict: :overwrite)
preview["fields"].first["changes"]
# => {"required" => {"from" => false, "to" => true}}
preview["risks"] # => ["required_false_to_true"]
```

The preview compares a version-1 portable export with the database's exact
target partition. It requires the envelope's `entity_type`, `scope`, and
`parent_scope` to match every entry; mixed-target payloads and duplicate
identities are rejected. This intentionally stricter preview input does not
change `import_schema` or silently retarget definitions.

The plain Hash result contains envelope metadata, `summary`, `fields`,
`sections`, `risks`, and `importable`. Each entry includes its exact `identity`,
`status` (`unchanged`, `added`, `changed`, or `conflict`), conditional `action`,
and attribute `changes` with `from`/`to` values. Field entries also contain
option-row `added`, `removed`, and `changed` lists, matched by option value.
Raw option ordering and key-presence differences remain visible because the
importer compares the complete exported payload, not just equivalent settings.

`on_conflict: :error` blocks divergent definitions; `:skip` leaves them alone;
`:overwrite` predicts an update. Type swaps always produce an error action,
even under skip/overwrite. Risks flag type changes, removed options, newly
required fields, and changes to options, defaults, or field dependencies.
Omitted target definitions are **not deletions** and are not listed as such.

`importable: true` means no known conflict-policy/type-swap blocker was found,
not that validation or a later import is guaranteed to succeed. Actions are
conditional predictions: a blocking error aborts the existing transactional
import, including otherwise acceptable additions. Previewing does not save
definitions, run mutation/validation callbacks, enqueue jobs, execute DDL, or
convert values. It is an advisory snapshot, not a lock or reservation; model
validations and concurrent changes still apply to the actual import.
