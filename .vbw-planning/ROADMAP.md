# typed_eav Roadmap

Execution order for the items in `typed_eav-enhancement-plan.md`, reconciled against the codebase mapping at `.vbw-planning/codebase/` and externally reviewed via Codex Plan Reviewer (Apr 2026).

The milestone ordering below differs from the plan's section order. The plan groups items by category (foundational, field types, bulk, perf, events). The roadmap orders them by dependency: scope partitioning first (it changes the partition key everything else uses); then the "complete the pipeline" Phase-1 items; then events (versioning depends on the event/context contract); then versioning; then field types; then bulk; then read-perf last (materialized index depends on field-change events).

The plan's foundational principle — no hardcoded attribute references; everything runtime-defined and accessed through generic accessors — is binding for every milestone below. Cross-cutting requirements from the plan §"Cross-cutting requirements" apply to every item.

---

## M1 — Two-level scope partitioning  *(Phase 1)*

Status: not started — **start here**
Maps to: plan §"Phase 1 — Two-level scope partitioning"
Why first: this changes the partition key tuple `(entity_type, scope) → (entity_type, scope, parent_scope)`. Every later milestone — field uniqueness, sections, schema import, references, ordering, materialized index — keys off this tuple. Doing it later means re-doing them.

### Pre-implementation gating (must land before code)
1. **Canonical partition tuple**: `(entity_type, scope, parent_scope)` is the identity for fields AND sections.
2. **Composite resolution semantics**: `parent_scope` narrows further within `scope`. `nil parent_scope` = "all parents within scope." When `scope` is nil (global), `parent_scope` must also be nil — no orphan-parent rows.
3. **Sentinel/kwarg semantics**: extend the existing `UNSET_SCOPE` / `ALL_SCOPES` pattern (`lib/typed_eav/has_typed_eav.rb` lines 99–104) to a parent-scope sentinel. The `unscoped { }` block continues to bypass both scope keys atomically.
4. **Migration & index strategy** for both `typed_eav_fields` AND `typed_eav_sections`:
   - Add nullable `parent_scope` column to both tables.
   - Add new paired partial unique indexes for `(name, entity_type, scope, parent_scope)` on fields and `(entity_type, code, scope, parent_scope)` on sections, mirroring the existing scope-NULL / scope-NOT-NULL split (migration line 57).

### Build
- `lib/typed_eav.rb` — extend `current_scope` to a tuple, add `with_parent_scope`, integrate with `unscoped`.
- `lib/typed_eav/has_typed_eav.rb` — extend macro (`parent_scope_method:`); extend `resolve_scope` (lines 246–279); extend predicate construction in `where_typed_eav` (single-scope and `unscoped` multimap branches); extend the `for_entity` Field scope.
- `app/models/typed_eav/value.rb` — extend `validate_field_scope_matches_entity` (line 138) to verify both keys.
- `app/models/typed_eav/section.rb` — symmetric `parent_scope` integration; update `for_entity` (line 20).
- Migration: add `parent_scope` to `typed_eav_fields` AND `typed_eav_sections` with paired partial unique indexes.

### Acceptance
- Single-scope users (no `parent_scope_method:`) see no API change.
- New `parent_scope` column is nullable; existing data migrates cleanly.
- `Contact.where_typed_eav(...)` resolves both scope keys via the resolver chain.
- `validate_field_scope_matches_entity` rejects cross-(scope, parent_scope) writes.
- Sections honor the same partition tuple.
- All `spec/regressions/review_round_*_scope*` and `spec/lib/typed_eav/scoping_spec.rb` pass with new parent-scope coverage.

---

## M2 — Phase 1 completions  *(Phase 1)*

Status: not started (after M1)
Maps to: plan §"Phase 1 — Display ordering on Field", §"Default values on Field", §"Configurable cascade behavior on Field destroy"
Why this slot: each of these has partial infrastructure already in place. They're "complete the pipeline," not "add a feature." Smaller change-surface than M1, parallelizable internally.

### M2.1 Display ordering API
Existing: `sort_order` integer column (migration line 45) used by `Field.sorted` (`field/base.rb` line 49), the `idx_te_fields_lookup` covering index (line 66), the scaffold form (`_common_fields.html.erb` line 55), and `render_typed_value_inputs` (`typed_eav_helper.rb` line 24). **Don't add a parallel `position` column.**

Build:
- `acts_as_list`-style helpers on `Field::Base` over the existing `sort_order`: `move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at(n)`. Per `(entity_type, scope, parent_scope)` partition.
- Add `Field.ordered` as alias of `Field.sorted` (don't rename — preserve back-compat).

Acceptance: reordering preserves uniqueness within partition; boundary moves are no-ops; `Field.sorted` keeps working.

### M2.2 Default values pipeline
Existing: `default_value_meta` jsonb column (migration line 51), `Field#default_value`/`=` accessors (`field/base.rb` lines 56–62), `validate_default_value` (line 211), and form-path auto-populate via `initialize_typed_values` (`has_typed_eav.rb` line 307). **Don't add a column.**

Build:
- `before_validation` on `Value` that fills the typed column from `field.default_value` when (a) record is new, (b) typed column is unset, (c) caller did not explicitly assign a value.
- **Sentinel** distinguishing "value never assigned" from "value explicitly set to nil." Mirror `UNSET_SCOPE` pattern.
- `Field#backfill_default!` for retroactive backfill, idempotent.

Acceptance: non-form `typed_values.create(field: f)` populates from default; explicit `value = nil` does NOT re-apply default; `backfill_default!` skips records with non-nil typed values; existing `validate_default_value` keeps catching invalid defaults at field save.

### M2.3 Configurable cascade behavior
Current state (corrected from plan): cascade IS `:destroy` today at both Rails (`Field::Base has_many :values, dependent: :destroy` — `field/base.rb` line 19) and DB (`foreign_key: on_delete: :cascade` — migration line 88) levels. Spec at `spec/models/typed_eav/has_typed_eav_spec.rb` line 340.

Build:
- `has_typed_eav field_dependent: :destroy | :nullify | :restrict_with_error` (default `:destroy`).
- `:nullify` requires **two coordinated migration changes**, not one:
  1. Make `typed_eav_values.field_id` nullable (currently `null: false`).
  2. Change FK from `on_delete: :cascade` to `on_delete: :nullify`.
- `:restrict_with_error` blocks destroy with `errors[:base]` populated.
- Document migration path for existing installs explicitly.

Acceptance: default behavior unchanged (`:destroy`); `:nullify` leaves orphans for existing read-path guards; `:restrict_with_error` blocks destroy when any value rows reference the field.

---

## M3 — Event system  *(Phase 5)*

Status: not started (after M2)
Maps to: plan §"Phase 5: Event system"
Why moved earlier: M4 versioning needs the event/context contract defined first (versioning fires from the same `after_commit` site as `on_value_change`; `with_context` is required for `changed_by` resolution). M7 materialized index also depends on `on_field_change` for DDL regeneration. Defining the events contract before its consumers is cheaper than refactoring it twice.

### Build
- `Config.on_value_change = ->(value, change_type, context) { ... }` — `after_commit` hook on Value.
- `change_type ∈ [:create, :update, :destroy]`.
- `Config.on_field_change = ->(field, change_type) { ... }` — companion hook.
- `TypedEAV.with_context(source: :user) { ... }` — thread-local context stack mirroring existing `with_scope` (`lib/typed_eav.rb` lines 55–61). Exception-safe via ensure-pop.

### Acceptance
- Hooks fire in the correct order relative to the existing `Value#apply_pending_value` lifecycle.
- `with_context` nests cleanly; outer context is restored on exception.
- Hooks receive Value/Field as parameters; never assume specific attribute names (foundational principle).

---

## M4 — Versioning  *(Phase 1)*

Status: not started (after M3)
Maps to: plan §"Phase 1 — Built-in versioning at the Value level"
Why this slot (Codex re-ordering): versioning is the largest substantively new feature in Phase 1. It must coordinate with M3's `on_value_change` hook (versioning runs `after_commit`; ordering with the user callback must be specified). It must ALSO precede M6 bulk APIs because Phase 3's bulk write specifies a `version_grouping:` option — that contract is impossible to define before versioning exists.

### Build
- New `typed_eav_value_versions` table: `value_id`, `field_id`, polymorphic `entity` reference, `changed_by`, `before_value` (jsonb), `after_value` (jsonb), `changed_at`, `change_type` (`:create | :update | :destroy`).
- `TypedEAV::Versioned` concern, opt-in via `TypedEAV.configure { |c| c.versioning = true }`.
- `Value#history` association; `Value#revert_to(version)`.
- `Config.actor_resolver` mirroring `Config.scope_resolver` pattern.
- Document hook ordering vs M3's `on_value_change` (versioning fires first; user callbacks see the persisted version row).

### Acceptance
- Versioning is opt-in; default off keeps current behavior.
- Branching/merging are explicitly out of scope (per plan).
- Default storage is event log; document snapshot extension pattern for high-volume apps.

---

## M5 — Field type expansion  *(Phase 2)*

Status: not started (after M1; benefits from M4 for versioning of new types)
Maps to: plan §"Phase 2"

### M5.1 Image / File field type
Pre-implementation decision: **lazy-load via `defined?(::ActiveStorage::Blob)`** (Recommend, mirroring `acts_as_tenant` soft-detect at `Config::DEFAULT_SCOPE_RESOLVER`), or hard-depend with fail-fast install message. Decide at milestone start.

Build per plan: `Field::Image`, `Field::File`, `has_one_attached`, `on_image_attached` hook.

### M5.2 Reference field type
Pre-implementation decision: cross-scope safety. Mirror `Value#validate_field_scope_matches_entity` (`value.rb` line 138). When a Reference Value is set, validate referenced entity's `typed_eav_scope` matches field's `target_scope`. Specify behavior for unscoped target entity types.

Build: `Field::Reference`, FK in `integer_value` or `string_value`, `target_entity_type`/`target_scope` options, `:references` operator.

### M5.3 Currency field type
**This is the only field type that uses two typed columns per Value row.** Plan revision: pick `decimal_value` (amount) + `string_value` (currency). Rejected: `json_value` storage (loses native amount indexing).

Build:
- Custom `Value#value` shape: structured `{amount, currency}`.
- Operators: `:eq, :gt, :lt, :gteq, :lteq, :between` on amount; `:eq` on currency code.
- Validation: both cells co-populated; currency in `allowed_currencies`.
- `default_currency`, `allowed_currencies` field options.

### M5.4 Percentage field type
Build: thin `Field::Decimal` wrapper, 0–1 range, `decimal_places`, `display_as: :fraction|:percent` options, formatting helper.

### Out of scope here
Calculated/computed fields (plan note line 94) — separate design doc.

---

## M6 — Bulk operations & import/export  *(Phase 3)*

Status: not started (after M4)
Maps to: plan §"Phase 3"

### M6.1 Bulk attribute assignment
- `Entity.bulk_set_typed_eav_values(records, values_by_field_name)` in single transaction.
- `version_grouping: :per_record | :per_field` when M4 versioning is enabled.
- Result object with `successes:` and `errors_by_record:`.

### M6.2 Schema export / import
- `Field.export_schema(entity_type:, scope:, parent_scope:)` → serializable hash (options jsonb, default_value_meta, sections, select/multi_select option rows; excludes data values).
- `Field.import_schema(hash, ...)` idempotent.
- **Idempotence key:** `(name, entity_type, scope, parent_scope)`. Using field name alone collapses two tenants' identically-named fields.

### M6.3 CSV mapping helper
`TypedEAV::CSVMapper.row_to_attributes(row, mapping)` → params for `typed_eav_attributes=`. Type coercion through existing `Field#cast`. Per-row error reporting; never fail-whole-import.

### M6.4 Bulk read API
`Entity.typed_eav_hash_for(records)` → `{ entity_id => { name => value } }`. Internally: one preload of `typed_values: :field`, group by entity, apply `definitions_by_name` collision precedence.

---

## M7 — Read optimization  *(Phase 4)*

Status: not started (last)
Maps to: plan §"Phase 4"
Why last (Codex re-ordering): the materialized index depends on M3's `on_field_change` event for DDL regeneration timing. Eager-load helpers and cache primitives are cheap and could be done earlier, but they don't unblock other milestones — there's no cost to grouping them with M7.

### M7.1 Eager-load helpers — reframe
Reframe from plan: `loaded_typed_values_with_fields` (`has_typed_eav.rb` lines 464–473) and `typed_eav_hash`/`typed_eav_value` already preload-aware. README §line 251 already documents `includes(typed_values: :field)`. This phase ships ergonomic API, not new caching logic.

Build: `Entity.with_all_typed_values` scope wrapping `includes(typed_values: :field)`; optionally surface `typed_eav_hash_cached` as a public alias.

### M7.2 Materialized value index (Postgres-only)
Pre-implementation: lock `on_field_change` ordering (must come from M3) and DDL refresh strategy.

Build:
- Optional `typed_eav_value_index_<entity>` materialized view per `(entity_type, scope, parent_scope)`.
- Opt-in via `TypedEAV.config.materialize_index = true`.
- DDL regeneration triggered by M3's `on_field_change` (`:create`/`:destroy`/`:rename`); via Active Job by default with sync fallback when AJ unavailable.
- Data refresh: `REFRESH MATERIALIZED VIEW CONCURRENTLY` on configurable schedule (default 5 min) or on demand.
- **SQL-injection safety on column generation:** field names are runtime user data with minimal constraints today (`Field::Base::RESERVED_NAMES` only excludes `id, type, class, created_at, updated_at`). For materialized fields: restrict name to `[A-Za-z0-9_]`, reject reserved SQL identifiers, always quote with `format("%I", name)`, reject names that collide with synthetic columns.

### M7.3 Query result caching primitives
- `Field#cache_version` → `"#{id}-#{updated_at.to_i}"`.
- `Value#cache_version` → same shape.
- `TypedEAV.cache_key_for(entity, field_names)` — composite key threading entity → values → fields.

### M7.4 Query plan helpers
- `.explain` already works on AR relations (`with_field`/`where_typed_eav` return relations — `has_typed_eav.rb` line 215). Keep this plan item only if a TypedEAV-specific interpretation layer is added (highlight `idx_te_values_field_*` index hits; summarize scope hits). Otherwise drop.
- `TypedEAV.benchmark(name) { block }` wrapping `Benchmark.realtime` with EAV-aware structured output.

---

## Cross-cutting requirements (status)

- ✓ **No hardcoded attribute references** — verified across the codebase mapping; every accessor takes name/id parameter.
- ✓ **Backwards compatibility** — every milestone preserves current API surface. M2.1 must alias rather than rename `Field.sorted`. M2.2 must keep direct `default_value=` callers working. M2.3 default behavior is unchanged. M1's `parent_scope` is nullable.
- ✓ **Postgres-only** committed. M1 (paired partial indexes) and M7.2 (materialized views) deepen the dependency. Adapter portability is explicitly out of scope.
- ✓ **Testing discipline** — `spec/regressions/` pattern keeps an audit trail of analysis-round bugs.
- ✓ **Documentation discipline** — README §"Validation Behavior" is the existing model for "non-obvious contracts." Each milestone lands a new bullet there.

---

## Pre-implementation gating summary

Plan-level decisions that **must** land in `typed_eav-enhancement-plan.md` before any code (these are now reflected in the plan after the Apr 2026 reconciliation):

- M1 partition tuple, semantics, sentinel pattern, migration/index strategy for fields AND sections.
- M2.2 default-auto-populate sentinel (unset vs. explicit nil).
- M2.3 cascade migration two-step amendment (column nullable + FK change for `:nullify`).
- M3 → M4 → M7.2 hook ordering (versioning's `after_commit` ordering relative to user callbacks; materialized-view DDL regeneration triggered by `on_field_change`).
- Postgres-only commitment.

Decisions deferrable to **milestone start** (still required before that milestone's code, but not blocking the plan):

- M5.1 Active Storage hard-vs-lazy dependency.
- M5.2 Reference target validation for unscoped target types.
- M5.3 Currency Value-shape and operator narrowing.
- M6.2 Schema-import conflict behavior on idempotence-key collision.
- M6.3 CSV result-object shape.
- M7.2 DDL regeneration job vs sync fallback configuration.

---

## Housekeeping (independent of milestones)

- `typed_eav-0.1.0.gem` (built artifact) is committed at repo root. Remove from version control; rebuilt by `.github/workflows/release.yml`.
- `TEST_PLAN.md` "Current State" lists 6 spec files but the suite now has 22. Update or mark dated.
