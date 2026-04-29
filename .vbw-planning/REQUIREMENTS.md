# Requirements

Defined: 2026-04-28

## Requirements

### REQ-01: Event system for field-change auditing
**Must-have**

`Config.on_value_change` and `Config.on_field_change` callbacks; `TypedEAV.with_context` thread-local context stack mirroring `with_scope`. Foundation for REQ-02 versioning and REQ-05 materialized index.

### REQ-02: Versioning of field values
**Must-have**

Opt-in `TypedEAV::Versioned` concern + `typed_eav_value_versions` table (event-log shape). `Value#history`, `Value#revert_to`. Hook ordering: versioning fires before user `on_value_change` so callbacks see the persisted version row.

### REQ-03: Field type expansion
**Should-have**

New STI subclasses: Image / File (Active Storage), Reference (cross-scope safe), Currency (two typed columns: decimal_value + string_value), Percentage (Decimal wrapper, 0–1 range). Calculated/computed fields are out of scope.

### REQ-04: Bulk operations & import/export
**Should-have**

`bulk_set_typed_eav_values`, `Field.export_schema` / `Field.import_schema` (idempotence keyed on `(name, entity_type, scope, parent_scope)`), CSV mapping helper, `typed_eav_hash_for(records)` batch read.

### REQ-05: Read-path optimization via materialized index
**Should-have**

Optional `typed_eav_value_index_<entity>` materialized view per `(entity_type, scope, parent_scope)`. DDL regeneration triggered by REQ-01 `on_field_change`. SQL-injection safety on column generation. Eager-load helpers and cache primitives.

### REQ-06: Two-level scope partitioning
**Must-have**

Extend canonical partition tuple from `(entity_type, scope)` to `(entity_type, scope, parent_scope)` for fields AND sections. Paired partial unique indexes mirroring the existing scope-NULL / scope-NOT-NULL split. Foundational — every later requirement keys off this tuple.

### REQ-07: Phase-1 pipeline completions
**Must-have**

Three "complete the pipeline" items, each over existing infrastructure (no new columns):
- Display-ordering API (`acts_as_list`-style helpers over existing `sort_order`).
- Default-value pipeline (`before_validation` auto-populate + sentinel for "unset" vs "explicit nil" + `Field#backfill_default!`).
- Configurable cascade behavior (`field_dependent: :destroy | :nullify | :restrict_with_error`; `:nullify` requires coordinated column-nullable + FK-on-delete migration).

## Out of Scope

- MySQL / SQLite support (Postgres-only is committed; partial unique indexes, GIN, `text_pattern_ops`, materialized views are PG-specific).
- Adapter portability — explicitly out of scope per ROADMAP cross-cutting requirements.
- Calculated / computed fields (deferred to a separate design doc — see REQ-03 notes).
- Branching / merging on versioning (REQ-02 ships the event-log shape only).
- Multi-shard / cross-database scoping — single Postgres database is assumed.
- Standalone documentation site — README is the canonical user docs.
- Per-type query caster classes — there is one `QueryBuilder` module; field types only declare `value_column` + `cast`.
