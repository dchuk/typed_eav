---
phase: 4
plan_count: 3
status: complete
started: 2026-05-06
total_tests: 6
passed: 6
skipped: 0
issues: 0
completed: 2026-05-06
---

Phase 04 (Versioning) UAT — developer-judgment walkthrough of API ergonomics, naming, schema design, and documentation clarity.

## Tests

### P01-T1: Schema design — jsonb before/after vs typed columns

- **Plan:** 04-01 — Versioning schema, ValueVersion model, Config.versioning + Config.actor_resolver
- **Scenario:** Open `db/migrate/20260505000000_create_typed_eav_value_versions.rb`. The audit log stores `before_value` and `after_value` as jsonb columns, defaulting to `{}`. The plan-time decision (per `04-CONTEXT.md`) was to use jsonb for variable-shape values rather than mirroring the 17 typed value_columns from `typed_eav_values`. No GIN index on jsonb (deferred). The three indexes are `idx_te_vvs_value`, `idx_te_vvs_entity`, `idx_te_vvs_field`, all `(... , changed_at DESC)`.
- **Expected:** The schema design feels right for a developer who'd consume this gem — jsonb is appropriate for variable-shape audit data, the index choices cover the most common query paths (per-Value history, per-entity timeline, per-field timeline), and the no-GIN deferral is acceptable. If this feels wrong (e.g., you wanted typed mirror columns, or you wanted GIN-on-jsonb shipped now), describe the concern.
- **Result:** pass

### P01-T2: Config naming — `Config.versioning` and `Config.actor_resolver`

- **Plan:** 04-01 — Versioning schema, ValueVersion model, Config.versioning + Config.actor_resolver
- **Scenario:** Open `lib/typed_eav/config.rb`. The two new accessors are exposed as `TypedEAV.config.versioning` (boolean, default `false`) and `TypedEAV.config.actor_resolver` (callable or nil, default `nil`). Imagine a consumer of this gem reading these in their `config/initializers/typed_eav.rb`.
- **Expected:** The names + defaults are what you want consumers to see. Alternative names that were in scope: `versioning_enabled`, `audit_actor`, `current_actor_resolver`. The `defined?(@var)` idiom and false/nil defaults match the existing `Config.field_validation_strictness` style.
- **Result:** pass

### P02-T1: Opt-in API — `has_typed_eav versioned: true`

- **Plan:** 04-02 — Versioning subscriber, value_columns plural, Registry/has_typed_eav opt-in, engine wiring
- **Scenario:** Read README §"Versioning" → "Opt in per-model". The shipped opt-in is `has_typed_eav versioned: true` on the model declaration. The Registry stores the entity_type → versioned? lookup; the Versioned concern reopens after has_typed_eav so consumers can include it explicitly when they prefer.
- **Expected:** The opt-in API feels clean for typical usage. Alternatives in scope: a separate `has_typed_eav_versioning` macro, or a class-level `versioned_typed_eav!` declaration. If you'd rather see one of those (or the API still feels off), describe the concern.
- **Result:** pass

### P03-T1: Public API ergonomics — `Value#history` and `Value#revert_to`

- **Plan:** 04-03 — Value#history + Value#revert_to + README versioning + slot-0 regression spec
- **Scenario:** Read README §"Versioning" → "Reading and reverting". `value.history` returns versions ordered `changed_at DESC`. `value.revert_to(version)` is append-only — it writes a new version row representing the revert and updates the live Value's typed columns from `version.before_value`. It does NOT delete or mutate prior history rows.
- **Expected:** The names + return shapes match how you'd reach for this in a real Rails app. Alternative names that were in scope: `versions` (instead of `history`), `revert!` (instead of `revert_to`). Append-only semantics (vs destructive revert) matches your intent. If a destructive revert (delete intermediate rows) was what you wanted, describe the concern.
- **Result:** pass

### P03-T2: Post-destroy history — FK ON DELETE SET NULL on `value_id`

- **Plan:** 04-03 — Value#history + Value#revert_to + README versioning + slot-0 regression spec
- **Scenario:** Read README §"Versioning" → "Querying full audit history". When a `Value` is destroyed, the FK on `typed_eav_value_versions.value_id` is `ON DELETE SET NULL`. This means **all pre-existing version rows for that Value have `value_id` nullified** (not just the new `:destroy` row). Callers who want post-destroy history must use the entity-scoped query: `TypedEAV::ValueVersion.where(entity_type: ..., entity_id: ..., field_id: ...)`. `value.history` is no longer reachable because the `value` itself is gone.
- **Expected:** This is the design you want — history survives Value destruction (audit log durability) at the cost of `value_id` being nullified on prior rows. The README clearly explains the entity-scoped query as the correct post-destroy access path. If this feels like a footgun (e.g., you'd prefer `ON DELETE CASCADE` so history dies with the parent, or you want a denormalized `original_value_id` column to preserve linkage), describe the concern.
- **Result:** pass

### P03-T3: Zero-overhead-when-disabled guarantee

- **Plan:** 04-02 — Versioning subscriber, value_columns plural, Registry/has_typed_eav opt-in, engine wiring
- **Scenario:** When `Config.versioning = false` (the default), the engine boot does NOT register the `Versioning::Subscriber` callback into `EventDispatcher.value_change_internals`. The slot-0 regression spec at `spec/regressions/review_round_5_versioning_slot_zero_spec.rb` confirms `value_change_internals == []` under the default boot path, and idempotent registration when toggled on. No JSON snapshotting, no allocation, no DB write happens for non-versioning apps.
- **Expected:** The "zero overhead when disabled" guarantee is credible based on the README + regression spec narrative. Anything else you'd want to verify before deploying this in a high-traffic Rails app (e.g., concrete benchmark numbers, additional probe in the regression spec)?
- **Result:** pass

## Summary

- Passed: 6
- Skipped: 0
- Issues: 0
- Total: 6
