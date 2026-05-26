# typed_eav — domain language

Glossary of canonical terms used in the codebase. Definitions live here; implementation lives in the code.

## Partition tuple

The `(entity_type, scope, parent_scope)` triple that scopes every field, section, and value lookup. Most-specific wins on name collision: full triple > scope-only > global. See [[ADR-0002]] for orchestration split and `TypedEAV::Partition#definitions_by_name` for the precedence rule.

`TypedEAV::Partition` is the public partition primitive. Documented-public methods: `visible_fields`, `effective_fields_by_name`, `definitions_by_name`, `definitions_multimap_by_name`, `visible_sections`, `find_visible_section!`. The module is not a fortress — it's the seam apps build admin UIs against.

## Two query altitudes

- **`QueryBuilder`** — per-field SQL primitive. Given `(field, operator, value)`, returns an `ActiveRecord::Relation` rooted at `TypedEAV::Value`. Knows nothing about scope, collision, multi-filter composition, or the host model.
- **`FilterQuery`** — multi-filter orchestrator. Given a host model, a list of filter specs, and a resolved scope tuple, composes the result via **subquery** (`host.where(id: <value-row entity_ids>)`) — not via JOIN. Per ADR-0002, future query-shape additions must pick the matching altitude.

## `:is_null` semantics — strict vs missing-row

- **strict `:is_null`** (current default) — matches `typed_eav_values` rows that **exist** for the field with a NULL value column. SQL-literal "the column is null."
- **`:is_null` with `include_missing: true`** (target for G3) — matches entities that **either** have a NULL value-column row **or** have no `typed_eav_values` row at all for the field at the requested partition tuple. The user-intuitive "is empty" semantic; implemented as a **set complement against `:is_not_null`** at the `FilterQuery` altitude, not via JOIN-shape change (the gem composes by subquery, not JOIN).

## Bulk-write failure isolation

The contract `BulkWrite.execute` ships: outer transaction wraps the run; each record runs in an inner `requires_new: true` savepoint so a per-record failure rolls back just that record's writes while leaving prior successes intact. Return shape: `{ successes: [...], errors_by_record: { record => errors_hash } }`.

## Bulk-write definitions memo

The `Thread.current[:typed_eav_bulk_defs_memo]` Hash that the bulk loop sets before iterating records. Per-instance `typed_eav_defs_by_name` consults the memo so each record in the loop doesn't re-issue a fresh `typed_eav_definitions` SELECT. Keyed by `[host_class, scope, parent_scope]`; one memo entry per partition tuple touched by the bulk call. Cleared on bulk-call exit.

## Snapshot vs portable schema

- **Portable schema** (`SchemaPortability.export_schema`) — full field-config wire format, used for cross-environment schema migration. Includes `entity_type`, `scope`, `parent_scope`, `type` (class name), `field_dependent`, `default_value_meta`, plus a wrapper hash with `schema_version`.
- **Snapshot schema** (target for G4: `export_snapshot_schema`) — lean, restore-oriented projection of the *same fields* without the partition keys (snapshot lives inside a known tuple), without the field-config knobs, identified by stable `field_type_name` string instead of class name. Wrapped in a versioned envelope `{ snapshot_schema_version: N, fields: [...] }` mirroring `export_schema`'s `schema_version` pattern — gem bumps `N` on shape changes; consumers detect-and-migrate.
