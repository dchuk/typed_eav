# Phase 6: Bulk operations & import/export — Context

Gathered: 2026-05-06
Calibration: architect

## Phase Boundary

Bulk write, schema export/import, CSV mapping, and bulk read APIs that compose with versioning (Phase 4) and respect the (entity_type, scope, parent_scope) partition tuple (Phase 1).

In scope:
- `Entity.bulk_set_typed_eav_values(records, values_by_field_name, **opts)`
- `Field.export_schema(entity_type:, scope:, parent_scope:)` / `Field.import_schema(hash, **opts)`
- `TypedEAV::CSVMapper.row_to_attributes(row, mapping)`
- `Entity.typed_eav_hash_for(records)`

Out of scope:
- Bulk delete API (not in roadmap)
- Library-side multi-file orchestration / job queue integration
- Schema migration tooling for incompatible type changes
- Transform overrides in CSV mapping
- An `on_error:` knob on bulk_set_typed_eav_values (deferrable; default semantics covers v0.6.0)

## Decisions Made

### Bulk write failure isolation
- Decision: **Savepoints per record inside an outer transaction.** Standard Rails idiom (`ActiveRecord::Base.transaction(requires_new: true)` for nested savepoints).
- Behavior: bad records roll back to their own savepoint and surface in `errors_by_record`; good records commit when the outer transaction commits. Cross-record atomicity is preserved for outer-level failures (deadlock, connection drop).
- Result shape: `{ successes: [record_or_id, ...], errors_by_record: { record_or_id => errors_hash } }`. Symmetric with the CSV mapper's per-row Result so users learn one mental model.
- Default: `on_error: :continue` semantics implied by partial success; no explicit `on_error:` keyword in v0.6.0. Add later if requested.
- Rationale: "single transaction" + "errors_by_record" in the roadmap is only consistent with savepoint-per-record; strict all-or-nothing makes the result shape pointless, and per-record transactions break Phase 3 hook semantics.

### Schema-import conflict policy
- Decision: **`Field.import_schema(hash, on_conflict: :error)` keyword argument.** Values: `:error` (default), `:skip`, `:overwrite`.
- Type changes (incompatible STI subclass swap, e.g., `Field::String` → `Field::Decimal`) **always raise** regardless of `on_conflict:` — data-loss guard, since the gem cannot infer a safe migration of existing typed values across `*_value` columns.
- Idempotence key remains `(name, entity_type, scope, parent_scope)` per the roadmap. Existing key with identical attributes is a no-op under any flag.
- Rationale: explicit `on_conflict:` mirrors Rails `upsert_all`'s `on_duplicate:` idiom; default `:error` surfaces drift loudly so a stale CI hash never silently reverts production; `:skip` covers "ensure schema present" deploys; `:overwrite` covers admin force-sync.

### CSV mapping format & result shape
- Decision (bundled):
  - **Mapping shape**: a single hash. String keys map CSV headers (`{"Email Address" => :email}`); integer keys map column indexes for headerless files (`{0 => :email}`). No transform overrides in v0.6.0 — callers preprocess `CSV::Row` before calling `row_to_attributes`.
  - **Per-row return**: `TypedEAV::CSVMapper.row_to_attributes(row, mapping)` always returns a `TypedEAV::CSVMapper::Result` value with `.attributes`, `.errors`, `.success?`. Never raises on row-level errors. Type coercion goes through existing `Field#cast`; cast failures land in `errors`, not exceptions.
  - **Streaming**: per-row API, no file-level orchestration in the library. Callers use `CSV.foreach(path, headers: true) { |row| … }`. Large files stay O(1) memory.
- Rationale: structural "never fail-whole-import" promise (caller loops with `next unless result.success?`); symmetric with `bulk_set_typed_eav_values`'s `successes/errors_by_record`; minimal API surface for v0.6.0.

### version_grouping default & disabled-versioning behavior
- Decision (mechanism + default):
  - Add a nullable, indexed `version_group_id uuid` column to `typed_eav_value_versions` (additive migration on top of Phase 4's table; uses `disable_ddl_transaction!` + `algorithm: :concurrently` per the production-safety pattern in `.vbw-planning/codebase/PATTERNS.md:263`).
  - Bulk operations populate `version_group_id`; non-bulk writes leave it NULL (backward-compatible).
  - **Default `version_grouping: :per_record`** when versioning is enabled — one uuid per record touched; all field changes for record X share that uuid. Aligns with the savepoint-per-record boundary from "Bulk write failure isolation".
  - `:per_field` also supported (one uuid per field touched across the bulk set), for "what entities had field Y bulk-updated together?" queries.
- Decision (disabled versioning): **raise `ArgumentError` when `version_grouping:` is explicitly passed but `Config.versioning = false`.** Omitting the option works in either env, so env-conditional callers don't need branching. Loud failure prevents the silent no-op footgun of "caller assumes grouping happened when it didn't".
- Rationale: per-Value version row schema (Phase 4) shouldn't be reshaped; tagging via `version_group_id` is additive and enables grouped retrieval (`value.history.where(version_group_id: x)`) without changing existing rows or hooks. Default `:per_record` matches the typical "track what changed for this entity" mental model.

### Open (Claude's discretion)
- Exact `errors_hash` shape inside `errors_by_record` and `Result#errors` (likely AR-style `{attribute => [messages]}`, but settling at plan time is fine).
- Whether `version_group_id` is a Postgres `uuid` column or a `bigint` sequence (uuid is more portable across replicas; decide at plan time).
- Whether `Field.export_schema` carries an explicit `schema_version` field for forward-compat — recommend yes (always include it, default `1`), can be settled in planning without user input.
- Whether `Entity.typed_eav_hash_for(records)` integrates with Phase 7 cache primitives or stays preload-only (Phase 7 will revisit; safe to ship preload-only here).

## Deferred Ideas

- `on_error:` keyword on `bulk_set_typed_eav_values` (`:continue` / `:raise` / `:rollback_all`) — re-evaluate after v0.6.0 if real callers ask for it.
- Transform overrides in CSV mapping (`{header => {field:, transform:}}`).
- Library-side whole-file CSV orchestration helper (caller-orchestrated streaming covers the use case in v0.6.0).
- Bulk delete API.
- Schema migration tooling for incompatible field-type changes (currently always raises in `import_schema`).
