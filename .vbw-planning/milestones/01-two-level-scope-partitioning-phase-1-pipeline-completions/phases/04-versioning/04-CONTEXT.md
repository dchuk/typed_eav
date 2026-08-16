# Phase 4: Versioning — Context

Gathered: 2026-05-04
Calibration: architect

## Phase Boundary

Opt-in versioning of `TypedEAV::Value` mutations via a new `typed_eav_value_versions` table. Hook ordering is locked relative to Phase 3's `on_value_change` (versioning runs first, on `EventDispatcher.value_change_internals` slot 0; user proc fires last). Default off. Branching/merging are explicitly out of scope. Default storage is event log; snapshot extension pattern is documented for high-volume apps. Must precede Phase 6 because bulk's `version_grouping:` option is undefinable without versioning.

Reqs: REQ-02. Deps: Phase 3 (`after_commit` ordering, `EventDispatcher`, `with_context` / `current_context`, `:update` filter on `saved_change_to_attribute?(field.class.value_column)`).

## Decisions Made

### Opt-in granularity (master switch + per-entity)

- `TypedEAV.config.versioning` is the master kill-switch. Default `false`. When `false`, Phase 4's internal subscriber is NOT registered with `EventDispatcher.register_internal_value_change` at engine boot — zero overhead for apps that don't use versioning.
- When `true`, the subscriber registers but only writes a version row when `value.entity_type` belongs to a host model that opted in. Per-entity opt-in flows through the existing `Registry` (host calls `has_typed_eav versioned: true` or `include TypedEAV::Versioned`; macro records the flag on the Registry entry). Non-opted entity types pay a Registry lookup per write and nothing more.
- This decouples the master switch from the per-entity decision. Disabling for all is one toggle; enabling for some is a per-host decision; no Field column is added.
- Rejected: gem-global on/off only (forces all-or-nothing — Phase 5 will introduce field types apps may want versioned only on specific hosts). Rejected: per-Field column on `typed_eav_fields` (granularity most apps don't need; requires migration for everyone).

### Version row jsonb shape (column-named)

- `before_value` and `after_value` are jsonb hashes keyed by typed-column name: `{"<column_name>": <casted value>}`. For all 17 current field types, one key (e.g., `{"integer_value": 42}`, `{"string_value": "alice"}`). For Phase 5 Currency, two keys (`{"decimal_value": 99.99, "string_value": "USD"}`). NULL value is `{"<column>": null}` (distinct from empty `{}` which means no recorded value).
- The Versioning subscriber reads `field.class.value_columns` (a list, defaulting to `[value_column]` for single-cell field types). Phase 5 Currency overrides `value_columns` to return `[:decimal_value, :string_value]`. The subscriber snapshots only those keys — no full-row snapshot, no scalar wrapping.
- Forward-compatible with Phase 5 Currency at zero schema cost. Queryable: `WHERE before_value->>'integer_value' = '42'` works against jsonb GIN/B-tree-on-expression indexes.
- Rejected: flat scalar `{"v": <value>}` (Currency forces a one-off branch and loses native column-key queryability). Rejected: full-row snapshot of all 7 typed columns (~6 redundant nulls per row, storage waste at scale).

### `Value#revert_to(version)` semantics (append-only, fires hooks)

- `revert_to` writes the targeted version's `before_value` columns back via `self.value = …` (or per-column `self[col] = …` for multi-cell types like Currency) and `save!`. The existing Value `after_commit :_dispatch_value_change_update` chain fires; EventDispatcher routes through Versioning's internal subscriber (slot 0); a NEW version row is written where `after_value` reflects the targeted version's `before_value`. The user's `Config.on_value_change` user proc also fires — they see the revert as a normal `:update`.
- Audit trail is append-only: every revert is itself audited. Matches PaperTrail / Audited industry conventions.
- Implication: if `with_context` is active during the revert (e.g., `TypedEAV.with_context(reverted_from_version_id: v.id) { value.revert_to(v) }`), the new version row's persisted context records that intent. Versioning does NOT inject a synthetic `reverted_from_version_id` automatically; that's the caller's choice via `with_context`.
- Rejected: silent revert via `update_columns` (skips callbacks → no version row for the revert → audit log loses the revert event). Rejected: hybrid `Versioning.silent { value.revert_to(v) }` API (special-cases revert with a parallel execution path; complexity for marginal gain).

### `actor_resolver` returning nil (allow nil `changed_by`)

- `Config.actor_resolver` mirrors the `scope_resolver` shape but with permissive nil semantics. When the resolver returns nil (system writes, migrations, console, jobs without an actor in scope), the version row is written with `changed_by: nil`. The `typed_eav_value_versions.changed_by` column is nullable.
- Apps that need stricter "every write must have an actor" policy enforce it in their own `actor_resolver` (`->{ Current.user || raise SomeAppError }`) or via a downstream model validation on the version row.
- Reasoning vs scope_resolver: missing scope is a tenant-isolation hazard (catastrophic, fail-closed). Missing actor is a degraded audit log (recoverable, sometimes legitimate — system writes are real). Forcing every Versioned write to have an actor is an app-policy choice, not a gem-policy choice. Strict-mode would reject every console save, every migration backfill, every job that didn't set `with_context(actor: ...)` — hostile defaults for a gem.
- Rejected: reject the write (`raise TypedEAV::ActorRequired`). Rejected: configurable sentinel actor (`Config.system_actor`) — kicks the policy decision down the road.
- Open shape question (Claude's discretion at plan time): `changed_by` column type. Options are `string` (mirrors how `scope` is `string`-coerced in Phase 1) or polymorphic (`changed_by_type` + `changed_by_id`) for AR-record actors. Plan should pick based on cost/value at design time; the discussion locked the nil-allowance contract, not the column type.

## Open (Claude's discretion)

- `changed_by` column shape (string vs polymorphic). Above.
- Indexing strategy on `typed_eav_value_versions`. Reasonable defaults at plan time: `(value_id, changed_at DESC)` for `Value#history`, `(entity_type, entity_id, changed_at DESC)` for entity-scoped history, possibly `(field_id, changed_at DESC)` for field-history queries. GIN on `before_value`/`after_value` deferred unless a real querying use case surfaces.
- Foreign-key behavior of `typed_eav_value_versions.value_id` when the source Value row is destroyed. Phase 2 cascade work made `field_id` `ON DELETE SET NULL`. For version rows, the choices are: (a) FK with `ON DELETE SET NULL` on `value_id` so version history survives Value destruction (matches event-log semantics), (b) FK with `ON DELETE CASCADE` (simpler but loses history when Value is destroyed). Recommend (a) at plan time — preserves the audit log even when the live Value disappears. Same pattern for `field_id` reference if one is added.
- Migration delivery model. Greenfield gets the migration automatically; existing v0.1.x deployments run `bin/rails generate typed_eav:install` (matches Phase 2 cascade migration delivery).
- `entity` reference: polymorphic on `(entity_type, entity_id)` per the roadmap is straightforward. No discussion topic.

## Deferred Ideas

- Snapshot-storage extension pattern (alternative to event-log default for high-volume apps). Roadmap explicitly mentions it as documented but out of scope for this phase. Document the extension shape in README; do not implement.
- Branching/merging across version chains. Explicitly out of scope per roadmap.
- `Versioning.silent { … }` API for opt-out callbacks during specific writes. Rejected for `revert_to` above; could resurface for bulk-import scenarios in Phase 6. Revisit only if Phase 6 surfaces a real requirement.
- Strict-mode actor resolution (`Config.require_actor = true`) raising `TypedEAV::ActorRequired` on nil. Out of scope for Phase 4. Apps enforce in their own resolver. Revisit only if a regulated-industry consumer reports needing it built-in.
- Per-Field versioning toggle (`typed_eav_fields.versioned:boolean`). Rejected for Phase 4. Revisit if per-field granularity becomes a real need (e.g., one entity has 50 fields and only 3 should be versioned).
- jsonb GIN indexes on `before_value` / `after_value` for content queries. Out of scope for Phase 4. Add later only if a real querying use case surfaces.
- Auto-injection of `reverted_from_version_id` in version row context during `revert_to`. Caller uses `with_context` instead. Revisit if the manual pattern proves error-prone.
