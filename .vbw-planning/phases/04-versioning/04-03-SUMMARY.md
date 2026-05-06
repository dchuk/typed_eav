---
phase: 4
plan: 03
title: Value#history + Value#revert_to + README §"Versioning" + slot-0 regression spec
status: complete
completed: 2026-05-05
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - 586b8638442da83ce8560927306642fa70cf326e
  - f1cb83205502f30667faf54e460acf295026ce9f
  - fa513db700ed283ce3e51c178d8a0b9714702536
  - 3a6887a671873a009a9bf5467a6c5cb069676a05
deviations:
  - "DEVN-02 (Critical): plan-supplied value_history_spec post-destruction example asserted versions_for_value_id.pluck(:change_type) == [\"create\", \"update\"]; the actual schema has FK ON DELETE SET NULL on typed_eav_value_versions.value_id, so destroy! nullifies value_id on ALL pre-existing version rows (not just the new :destroy version). Restructured the example to assert pre-destroy via value.history (excludes :destroy because the destroy version hasn't been written yet) and post-destroy via the entity-scoped query (includes the full lifecycle with documented row shape). Added a schema-reality comment in the spec body. README §\"Querying full audit history\" updated to match the actual post-destroy shape (all value_id: nil)."
  - "DEVN-01 (Minor): Metrics/AbcSize on revert_to (25.57/25) — added paired rubocop:disable/enable with justification on the disable line per CONVENTIONS.md style. Three guard clauses with multi-line error messages plus the column-iteration loop genuinely belong together; splitting hurts readability of the locked check ordering."
  - "DEVN-01 (Minor): RSpec/AnyInstance offense in save-failure example — replaced allow_any_instance_of(described_class) with allow(value) on the specific instance (the only instance revert_to operates on)."
pre_existing_issues: []
ac_results:
  - criterion: "TypedEAV::Value#history returns versions.order(changed_at: :desc, id: :desc) — chainable relation, tie-breaks on id"
    verdict: pass
    evidence: "586b863 / app/models/typed_eav/value.rb:134-156 / spec/models/typed_eav/value_history_spec.rb (7 examples)"
  - criterion: "Value#history is an instance method (not has_many ... -> { order(...) }) so ordering is explicit at the call site"
    verdict: pass
    evidence: "586b863 / app/models/typed_eav/value.rb:155-157 — `def history; versions.order(...); end`"
  - criterion: "Value#revert_to(version) writes before_value back via self[col] = ... iterating field.class.value_columns; calls save!; fires after_commit chain"
    verdict: pass
    evidence: "f1cb832 / app/models/typed_eav/value.rb:223-229 / spec/models/typed_eav/value_revert_to_spec.rb#happy-path-revert-to-an-:update-version (3 examples)"
  - criterion: "Value#revert_to raises ArgumentError in three documented conditions in order: (1) value_id.nil? (2) before_value.empty? (3) value_id != self.id"
    verdict: pass
    evidence: "f1cb832 / app/models/typed_eav/value.rb:189-220 / spec/models/typed_eav/value_revert_to_spec.rb#error-cases (5 examples including check-ordering edge case)"
  - criterion: "Effective revertable version types: only :update (create fails check 2, destroy fails check 1)"
    verdict: pass
    evidence: "f1cb832 / value_revert_to_spec :create version raises before_value-empty + :destroy version raises source-Value-destroyed"
  - criterion: "Value#revert_to does NOT inject synthetic context — caller uses TypedEAV.with_context"
    verdict: pass
    evidence: "f1cb832 / spec/models/typed_eav/value_revert_to_spec.rb#context-capture (2 examples; one asserts {} when no with_context)"
  - criterion: "README has new §\"Versioning\" section AFTER §\"Event hooks\" and BEFORE §\"Database Support\""
    verdict: pass
    evidence: "3a6887a / README.md:705 (Versioning) sandwiched between :568 (Event hooks) and :981 (Database Support)"
  - criterion: "README §\"Validation Behavior\" gains one new bullet cross-referencing §\"Versioning\""
    verdict: pass
    evidence: "3a6887a / README.md:566 — `Versioning is opt-in: When enabled ... See §\"Versioning\" for the full contract.`"
  - criterion: "spec/regressions/review_round_5_versioning_slot_zero_spec.rb exercises register_if_enabled with 4 examples (default-off, slot-0, semantic equivalence, idempotency)"
    verdict: pass
    evidence: "fa513db / spec/regressions/review_round_5_versioning_slot_zero_spec.rb (4 examples; uses :event_callbacks)"
  - criterion: "Value#history spec covers empty, ordering, return type, tie-breaking, post-destruction (excludes :destroy pre-destroy + entity-scoped exposes full lifecycle), scoping isolation"
    verdict: pass
    evidence: "586b863 / spec/models/typed_eav/value_history_spec.rb (7 examples)"
  - criterion: "Value#revert_to spec covers happy path, append-only audit trail, user proc fires, context capture (with + without), error cases (3), check ordering, save failure rollback, multi-cell forward-compat"
    verdict: pass
    evidence: "f1cb832 / spec/models/typed_eav/value_revert_to_spec.rb (12 examples)"
  - criterion: "Existing review_round_*.rb files unchanged — only the new round 5 file added"
    verdict: pass
    evidence: "git log shows only review_round_5_versioning_slot_zero_spec.rb added; existing review_round_2/3/4 + known_bugs untouched (85 regression examples pass)"
  - criterion: "frozen_string_literal: true on every new .rb"
    verdict: pass
    evidence: "Line 1 of value_history_spec.rb, value_revert_to_spec.rb, review_round_5_versioning_slot_zero_spec.rb"
---

Phase 04 versioning ships its public Value-side API: Value#history (chainable
relation), Value#revert_to(version) (append-only revert), README §"Versioning"
documentation covering the full opt-in contract, and a slot-0 registration
regression spec guarding the locked hook-ordering invariant.

## What Was Built

- Value#history instance method returning versions.order(changed_at: :desc, id: :desc) — chainable relation with id tie-break for same-second writes
- Value#revert_to(version) — writes before_value back via field.class.value_columns iteration + save! to fire the after_commit chain (append-only audit trail)
- Three ArgumentError guards on revert_to in locked order: nil value_id, empty before_value, cross-Value mismatch
- README §"Versioning" section (276 lines) covering enabling, history queries (including orphaned-destroy via entity-scoped lookup), jsonb shape table, reverting semantics, hook-ordering guarantee, actor resolution, out-of-scope items, and test-isolation pattern
- spec/regressions/review_round_5_versioning_slot_zero_spec.rb — four examples exercising TypedEAV::Versioning.register_if_enabled (default-off zero overhead, slot-0 placement, helper-vs-manual semantic equivalence, idempotency)

## Files Modified

- `app/models/typed_eav/value.rb` -- added: Value#history (lines 134-156), Value#revert_to (lines 162-231) with paired rubocop:disable/enable for Metrics/AbcSize
- `README.md` -- added: §"Versioning" between Event hooks and Database Support; cross-reference bullet in §"Validation Behavior"
- `spec/models/typed_eav/value_history_spec.rb` -- created: 7 examples (empty, ordering, tie-break, return type, post-destruction lifecycle, scoping)
- `spec/models/typed_eav/value_revert_to_spec.rb` -- created: 12 examples (happy path, audit trail, user proc, context capture, 3+1 error cases, check ordering, save failure, multi-cell forward-compat)
- `spec/regressions/review_round_5_versioning_slot_zero_spec.rb` -- created: 4 examples guarding the slot-0 invariant

## Deviations

- **DEVN-02 (Critical):** plan-supplied value_history_spec post-destruction example asserted `versions_for_value_id.pluck(:change_type) == ["create", "update"]`. Actual schema has `ON DELETE SET NULL` on `typed_eav_value_versions.value_id`, so `destroy!` nullifies value_id on ALL pre-existing version rows (verified via direct DB query). Restructured the example to assert pre-destroy via `value.history` (excludes `:destroy` because the destroy version hasn't been written yet) and post-destroy via the entity-scoped query (includes the full lifecycle with documented row shape `value_id: nil`). Added schema-reality comment in the spec body. README §"Querying full audit history" updated to show the actual post-destroy state (all `value_id: nil`).
- **DEVN-01 (Minor):** `Metrics/AbcSize` on `revert_to` (25.57/25) — added paired `# rubocop:disable Metrics/AbcSize -- ...` / `# rubocop:enable` per CONVENTIONS.md "disable rubocop with a justification, not silently".
- **DEVN-01 (Minor):** `RSpec/AnyInstance` cop — replaced `allow_any_instance_of(described_class).to receive(:validate_value)` with `allow(value).to receive(:validate_value)` on the specific instance.
