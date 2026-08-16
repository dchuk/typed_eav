---
phase: 02
slug: 02-pipeline-completions
gathered: 2026-04-29
calibration: architect
---

# Phase 2: Phase-1 Pipeline Completions — Context

Gathered: 2026-04-29
Calibration: architect

## Phase Boundary

Complete the three "infrastructure already exists" pipeline items from the v0.1.0 enhancement plan: display ordering helpers, default-value auto-population + backfill, and configurable Field-destroy cascade behavior. All work is partitioned by the `(entity_type, scope, parent_scope)` tuple landed in Phase 1.

**Scope refinement vs. ROADMAP goal language.** The ROADMAP Phase 2 goal says "without adding new columns or breaking the v0.1.0 API." The cascade decision below (an explicit `field_dependent` column on `typed_eav_fields`, plus making `Value#field_id` nullable with FK `ON DELETE SET NULL`) is a **schema-additive change** that preserves API backwards-compatibility (defaults reproduce current behavior). The "no new columns" phrasing is hereby refined to "additive schema changes only, never removal or renaming, defaults preserve v0.1.0 behavior." API surface remains backwards-compatible.

## Decisions Made

### Display ordering — list helper implementation strategy

- **Decision:** In-house partition-aware module on `Field::Base` (and `Section`), keyed by `(entity_type, scope, parent_scope)`.
- **Helper surface:** `move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at(n)` — names match `acts_as_list` for muscle memory but the implementation is local.
- **Race semantics:** Each move wraps in `with_lock` against the partition (or the moving record + its neighbors) to serialize concurrent reorders.
- **Sort-order semantics:** Each move normalizes `sort_order` to consecutive integers within the partition (no gaps), preserving uniqueness within the partition. Boundary moves (`move_higher` on top item, `move_lower` on bottom) are no-ops, not errors.
- **Partition reuse:** Phase 1's `for_entity` partition pattern in `field/base.rb` and `section.rb` is the symmetric anchor — duplicate inline rather than extracting a shared concern (still under the deferred "extract Scopable" idea from Phase 1).
- **Why not `acts_as_list`:** Codebase contract documented in `PATTERNS.md` is "one hard dep, soft-detect everything else." Adopting `acts_as_list` as a runtime dep would contradict that and force every consumer to pull it in. ~150 LoC of in-house code is preferred.

### Default-value sentinel detection

- **Decision:** Add `UNSET_VALUE = Object.new.freeze` as a private constant on `TypedEAV::Value`.
- **Mechanics:** `Value#value=(val)` accepts `UNSET_VALUE` as the "kwarg not given" signal. `typed_values.create(field: f)` (no value kwarg) defaults to `UNSET_VALUE`, which triggers `field.default_value` population. `typed_values.create(field: f, value: nil)` passes explicit `nil`, which short-circuits the default and stores nil.
- **Pattern lineage:** Mirrors `UNSET_SCOPE` / `ALL_SCOPES` documented in `PATTERNS.md` §"Sentinel objects for distinguishing kwarg states." Identifiable via `.equal?`, self-documenting via the constant name.
- **Form path interaction:** Forms always submit explicit values (including empty strings), so `typed_values_attributes=` and `typed_eav_attributes=` paths bypass the sentinel — defaults only fire on the non-form construction path, matching the ROADMAP success-criterion phrasing.
- **Backfill interaction:** `Field#backfill_default!` operates over existing `Value` rows (or absent rows) — see backfill decision below.

### `Field#backfill_default!` execution model

- **Decision:** `find_each(batch_size: 1000)` with `transaction do … end` per batch, synchronous by default.
- **Skip rule:** Within each batch, skip records that already have a non-nil typed value for this field — the rule is "non-nil typed column," not "Value row exists." A Value row whose typed column is nil is still a candidate for backfill.
- **Recovery:** Per-batch transactions make backfill recoverable mid-run. Re-running is idempotent because the skip rule re-checks each batch.
- **Locking:** No table-level lock; per-batch transactions hold row locks only for the batch duration. Safe to run on a live table.
- **Async wrapping:** No built-in Active Job dispatch. README documents the recipe for users who want async (`MyApp::BackfillJob.perform_later(field_id)` calling `field.backfill_default!`). Consistent with the soft-detect philosophy — no AJ dependency.
- **Partition awareness:** Iteration is scoped to entities whose `entity_type` matches the field's `entity_type`, with `(scope, parent_scope)` filters applied via the `for_entity` partition helper from Phase 1.

### Cascade behavior wiring + schema delivery

- **Decision:** Single in-phase migration delivering both schema changes; `field_dependent` lives as a string column on `typed_eav_fields`.
- **Schema changes (one migration):**
  1. Add `field_dependent` string column on `typed_eav_fields`, `null: false, default: "destroy"`. Allowed values: `"destroy"`, `"nullify"`, `"restrict_with_error"` (string, not enum, for forward-compat).
  2. Change `typed_eav_values.field_id` from `NOT NULL` to nullable.
  3. Drop and recreate the FK from `ON DELETE CASCADE` to `ON DELETE SET NULL` (Postgres requires drop-and-recreate for `ON DELETE` change).
- **Distribution:** Greenfield installs pick up the migration automatically. Existing v0.1.0 deployments run `bin/rails generate typed_eav:install` again — the install generator pulls all engine migrations, so the new one is applied alongside any prior ones not yet copied.
- **`:destroy` (default):** Existing AR `dependent: :destroy` on the `Field has_many :values` association continues to fire; behavior unchanged for v0.1.0 callers.
- **`:nullify`:** When a Field is destroyed, its Value rows have `field_id` set to NULL by the FK. The existing read-path orphan guard (`v.field` nil → skip) already handles this — `typed_eav_value` and `typed_eav_hash` continue to silently skip orphans. Documented in CONCERNS.md as fail-soft, intentional.
- **`:restrict_with_error`:** Implemented via `before_destroy` on `Field::Base` that queries `values.exists?` and, if true, calls `errors.add(:base, "...")` and `throw(:abort)`. Mirrors AR's `dependent: :restrict_with_error` semantics exactly. Error message: "Cannot delete field that has values. Use field_dependent: :nullify or destroy values first."
- **Validation:** New validation on `Field::Base` ensures `field_dependent` is one of the three allowed values.
- **Test coverage:** `spec/regressions/known_bugs_spec.rb` no longer pends the orphan/cascade items; new spec `spec/lib/typed_eav/field_cascade_spec.rb` covers all three policies × partition variations.

### Open (Claude's discretion)

- **Default value population from `accepts_nested_attributes_for` flow.** The ROADMAP says non-form `create(field: f)` populates defaults; forms always submit explicit values. The `initialize_typed_values` path in `has_typed_eav.rb` is form-adjacent (it pre-populates Value rows for unsaved entities so forms have something to render). Whether `initialize_typed_values` invokes default-population or leaves it to the explicit `create` path is a small implementation detail that does not affect the success criteria — Lead's plan can choose the cleanest wiring.
- **Boundary error vs no-op for `insert_at(n)` with out-of-range `n`.** ROADMAP says boundary moves are no-ops; for `insert_at(0)` or `insert_at(999)` on a 5-item partition, clamp to `[1, count]` (no error). Lead's call.
- **Migration filename / timestamp.** Standard rails convention (`db/migrate/YYYYMMDDHHMMSS_*.rb`); engine migrations follow the existing `20260330000000_*` / `20260430000000_*` pattern.

## Deferred Ideas

- **Active Job auto-dispatch for `backfill_default!`.** Considered and rejected for this phase (would introduce soft-detect complexity for an explicitly-invoked method). Revisit if multiple users report needing async backfill out of the box.
- **`acts_as_list` as a soft-detected backend.** Considered the hybrid "use `acts_as_list` if defined, fall back to in-house" pattern; rejected as double-maintenance with no real win. Do not reintroduce without a deliberate reversal.
- **Configurable per-app default for `field_dependent`** (i.e., a `Config.default_field_dependent = :nullify` setting). Out of scope for Phase 02 — the schema-level default of `"destroy"` is enforced. Add later only if a real consumer asks.
- **Cascade behavior on Section destroy.** This phase is explicitly about Field destroy. Section cascade may surface as a separate concern in a later phase.
