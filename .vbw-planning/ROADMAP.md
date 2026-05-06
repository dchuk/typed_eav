# typed_eav Roadmap

Execution order for the items in `typed_eav-enhancement-plan.md`, reconciled against the codebase mapping at `.vbw-planning/codebase/` and externally reviewed via Codex Plan Reviewer (Apr 2026).

This roadmap is dependency-ordered, not category-grouped. The plan organizes items by category (foundational, field types, bulk, perf, events). The roadmap orders them by what unblocks what: scope partitioning first (it changes the partition key everything else uses); then "complete the pipeline" Phase-1 items; events before versioning (versioning depends on the event/context contract); versioning before bulk (bulk's `version_grouping:` option is undefinable without versioning); field types in parallel; bulk after versioning; read-perf last (materialized index depends on field-change events).

The plan's foundational principle — no hardcoded attribute references; everything runtime-defined and accessed through generic accessors — is binding for every phase below. Cross-cutting requirements from the plan §"Cross-cutting requirements" apply to every item.

## Phases

- [x] Phase 1: Two-level scope partitioning
- [x] Phase 2: Phase-1 pipeline completions
- [x] Phase 3: Event system
- [x] Phase 4: Versioning
- [ ] Phase 5: Field type expansion
- [ ] Phase 6: Bulk operations & import/export
- [ ] Phase 7: Read optimization

### Phase 1: Two-level scope partitioning
**Goal:** Extend the canonical partition tuple from `(entity_type, scope)` to `(entity_type, scope, parent_scope)` for fields AND sections, so every later phase keys off the same identity.
**Deps:** none — start here.
**Reqs:** REQ-06
**Success:**
- Single-scope users (no `parent_scope_method:`) see no API change.
- New `parent_scope` column is nullable; existing data migrates cleanly.
- `Contact.where_typed_eav(...)` resolves both scope keys via the resolver chain.
- `Value#validate_field_scope_matches_entity` rejects cross-`(scope, parent_scope)` writes.
- Sections honor the same partition tuple.
- All `spec/regressions/review_round_*_scope*` and `spec/lib/typed_eav/scoping_spec.rb` pass with new parent-scope coverage.

### Phase 2: Phase-1 pipeline completions
**Goal:** Complete three "infrastructure already exists" items (display ordering, default values, cascade behavior). Schema changes are additive only (cascade policy adds a `field_dependent` column and changes the values FK to `ON DELETE SET NULL`); v0.1.0 API surface and default behavior are preserved.
**Deps:** Phase 1 (partition-tuple changes apply to ordering and default-value helpers).
**Reqs:** REQ-07
**Success:**
- Display ordering: `Field.sorted` keeps working; `acts_as_list`-style helpers (`move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at(n)`) operate over the existing `sort_order` column, partitioned by `(entity_type, scope, parent_scope)`. Boundary moves are no-ops; reordering preserves uniqueness within partition.
- Default values: non-form `typed_values.create(field: f)` populates from `field.default_value`; explicit `value = nil` does NOT re-apply default; `Field#backfill_default!` skips records with non-nil typed values; existing `validate_default_value` keeps catching invalid defaults at field save.
- Cascade behavior: default behavior unchanged (`:destroy`); `field_dependent: :nullify` leaves orphans for existing read-path guards (requires coordinated column-nullable + FK-on-delete migration); `:restrict_with_error` blocks destroy when any value rows reference the field.

### Phase 3: Event system
**Goal:** Define the event/context contract that Phase 4 versioning and Phase 7 materialized index both depend on. Defining it before its consumers is cheaper than refactoring it twice.
**Deps:** Phase 2.
**Reqs:** REQ-01
**Success:**
- `Config.on_value_change = ->(value, change_type, context) { ... }` fires from `after_commit` on Value with `change_type ∈ [:create, :update, :destroy]`.
- `Config.on_field_change = ->(field, change_type) { ... }` companion hook.
- `TypedEAV.with_context(source: :user) { ... }` thread-local stack mirrors existing `with_scope`; nests cleanly; outer context is restored on exception (ensure-pop).
- Hooks fire in the correct order relative to `Value#apply_pending_value` lifecycle.
- Hooks receive Value/Field as parameters; never assume specific attribute names (foundational principle).

### Phase 4: Versioning
**Goal:** Opt-in versioning of Value mutations via a new `typed_eav_value_versions` table, with hook ordering specified relative to Phase 3's `on_value_change`. Must precede Phase 6 because bulk's `version_grouping:` option is undefinable without it.
**Deps:** Phase 3 (versioning fires from `after_commit` like `on_value_change`; ordering must be locked).
**Reqs:** REQ-02
**Success:**
- New `typed_eav_value_versions` table: `value_id`, `field_id`, polymorphic `entity` reference, `changed_by`, `before_value` (jsonb), `after_value` (jsonb), `changed_at`, `change_type`.
- `TypedEAV::Versioned` concern, opt-in via `TypedEAV.configure { |c| c.versioning = true }`.
- `Value#history` association; `Value#revert_to(version)`.
- `Config.actor_resolver` mirrors `Config.scope_resolver`.
- Hook ordering documented: versioning runs first; user callbacks see the persisted version row.
- Default off keeps current behavior. Branching/merging are explicitly out of scope. Default storage is event log; snapshot extension pattern documented for high-volume apps.

### Phase 5: Field type expansion
**Goal:** Ship four new field types over the existing STI hierarchy. Each preserves the cast-tuple contract, the operator-dispatch model, and the foundational "no hardcoded attribute references" principle.
**Deps:** Phase 1 (partition tuple). Benefits from Phase 4 (versioning of new types).
**Reqs:** REQ-03
**Success:**
- **Image / File:** `Field::Image`, `Field::File`, `has_one_attached`, `on_image_attached` hook. Active Storage dependency: lazy-load via `defined?(::ActiveStorage::Blob)` (preferred, mirrors `acts_as_tenant` soft-detect) — alternative is hard-depend with fail-fast install message; decide at phase start.
- **Reference:** `Field::Reference`, FK in `integer_value` or `string_value`, `target_entity_type` / `target_scope` options, `:references` operator. Cross-scope safety: when a Reference Value is set, validate referenced entity's `typed_eav_scope` matches field's `target_scope`. Behavior for unscoped target entity types specified at phase start.
- **Currency:** Only field type that uses two typed columns per Value row — `decimal_value` (amount) + `string_value` (currency). Custom `Value#value` shape: `{amount, currency}`. Operators: `:eq, :gt, :lt, :gteq, :lteq, :between` on amount; `:eq` on currency code. Validation: both cells co-populated; currency in `allowed_currencies`. Options: `default_currency`, `allowed_currencies`. Rejected alternative: `json_value` storage (loses native amount indexing).
- **Percentage:** Thin `Field::Decimal` wrapper, 0–1 range, `decimal_places`, `display_as: :fraction|:percent` options, formatting helper.
- Calculated / computed fields explicitly **out of scope** — separate design doc.

### Phase 6: Bulk operations & import/export
**Goal:** Bulk write, schema export/import, CSV mapping, and bulk read APIs that compose with versioning.
**Deps:** Phase 4 (`version_grouping:` option requires versioning to exist).
**Reqs:** REQ-04
**Success:**
- **Bulk attribute assignment:** `Entity.bulk_set_typed_eav_values(records, values_by_field_name)` in single transaction; `version_grouping: :per_record | :per_field` when versioning is enabled; result object with `successes:` and `errors_by_record:`.
- **Schema export / import:** `Field.export_schema(entity_type:, scope:, parent_scope:)` → serializable hash (options jsonb, default_value_meta, sections, select/multi_select option rows; **excludes data values**). `Field.import_schema(hash, …)` is idempotent. Idempotence key: `(name, entity_type, scope, parent_scope)` — using field name alone collapses two tenants' identically-named fields.
- **CSV mapping helper:** `TypedEAV::CSVMapper.row_to_attributes(row, mapping)` → params for `typed_eav_attributes=`. Type coercion through existing `Field#cast`. Per-row error reporting; never fail-whole-import.
- **Bulk read API:** `Entity.typed_eav_hash_for(records)` → `{ entity_id => { name => value } }`. Internally: one preload of `typed_values: :field`, group by entity, apply `definitions_by_name` collision precedence.

### Phase 7: Read optimization
**Goal:** Eager-load helpers, cache primitives, materialized-view index, and query-plan helpers. Last because the materialized view depends on Phase 3's `on_field_change`.
**Deps:** Phase 3 (`on_field_change` for DDL regeneration timing); benefits from Phase 4 (versioning) for cache invalidation primitives.
**Reqs:** REQ-05
**Success:**
- **Eager-load helpers:** `Entity.with_all_typed_values` scope wrapping `includes(typed_values: :field)`; optional `typed_eav_hash_cached` public alias. (Reframe from plan: `loaded_typed_values_with_fields` and `typed_eav_hash` / `typed_eav_value` are already preload-aware — this phase ships ergonomic API, not new caching logic.)
- **Materialized value index:** Optional `typed_eav_value_index_<entity>` materialized view per `(entity_type, scope, parent_scope)`. Opt-in via `TypedEAV.config.materialize_index = true`. DDL regeneration triggered by `on_field_change` (`:create` / `:destroy` / `:rename`); via Active Job by default with sync fallback when AJ unavailable. Data refresh: `REFRESH MATERIALIZED VIEW CONCURRENTLY` on configurable schedule (default 5 min) or on demand. **SQL-injection safety:** restrict field name to `[A-Za-z0-9_]`, reject reserved SQL identifiers, always quote with `format("%I", name)`, reject names that collide with synthetic columns.
- **Query result caching primitives:** `Field#cache_version` → `"#{id}-#{updated_at.to_i}"`; `Value#cache_version` same shape; `TypedEAV.cache_key_for(entity, field_names)` composite key threading entity → values → fields.
- **Query plan helpers:** `.explain` already works on AR relations — keep the plan item only if a TypedEAV-specific interpretation layer adds value (highlight `idx_te_values_field_*` index hits, summarize scope hits); otherwise drop. `TypedEAV.benchmark(name) { block }` wrapping `Benchmark.realtime` with EAV-aware structured output.

## Progress

| Phase | Done | Status | Date |
|-------|------|--------|------|
| 1 - Two-level scope partitioning | 7/7 | complete | 2026-04-29 |
| 2 - Phase-1 pipeline completions | 4/4 | complete | 2026-04-29 |
| 3 - Event system | 2/2 | complete | 2026-05-01 |
| 4 - Versioning | 3/3 | complete | 2026-05-06 |
| 5 - Field type expansion | 0/4 | planned | - |
| 6 - Bulk operations & import/export | 0/0 | pending | — |
| 7 - Read optimization | 0/0 | pending | — |

---

## Cross-cutting requirements (status)

- ✓ **No hardcoded attribute references** — verified across the codebase mapping; every accessor takes name/id parameter.
- ✓ **Backwards compatibility** — every phase preserves current API surface. Phase 2 must alias rather than rename `Field.sorted`. Phase 2 must keep direct `default_value=` callers working. Phase 2 cascade default unchanged. Phase 1 `parent_scope` is nullable.
- ✓ **Postgres-only** committed. Phase 1 (paired partial indexes) and Phase 7.2 (materialized views) deepen the dependency. Adapter portability is explicitly out of scope.
- ✓ **Testing discipline** — `spec/regressions/` pattern keeps an audit trail of analysis-round bugs.
- ✓ **Documentation discipline** — README §"Validation Behavior" is the existing model for "non-obvious contracts." Each phase lands a new bullet there.

## Pre-implementation gating summary

Plan-level decisions that must land in `typed_eav-enhancement-plan.md` before any code (these are now reflected in the plan after the Apr 2026 reconciliation):

- Phase 1 partition tuple, semantics, sentinel pattern, migration / index strategy for fields AND sections.
- Phase 2 default-auto-populate sentinel (unset vs. explicit nil).
- Phase 2 cascade migration two-step amendment (column nullable + FK change for `:nullify`).
- Phase 3 → Phase 4 → Phase 7 hook ordering (versioning's `after_commit` ordering relative to user callbacks; materialized-view DDL regeneration triggered by `on_field_change`).
- Postgres-only commitment.

Decisions deferrable to phase start (still required before that phase's code, but not blocking the plan):

- Phase 5 Active Storage hard-vs-lazy dependency.
- Phase 5 Reference target validation for unscoped target types.
- Phase 5 Currency Value-shape and operator narrowing.
- Phase 6 schema-import conflict behavior on idempotence-key collision.
- Phase 6 CSV result-object shape.
- Phase 7 DDL regeneration job vs sync fallback configuration.

## Housekeeping (independent of phases)

- `typed_eav-0.1.0.gem` (built artifact) is committed at repo root. Remove from version control; rebuilt by `.github/workflows/release.yml`.
- `TEST_PLAN.md` "Current State" lists 6 spec files but the suite now has 22. Update or mark dated.
