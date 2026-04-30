---
phase: 2
plan: 04
title: Field#backfill_default! — partition-aware, find_in_batches with per-batch transactions
status: complete
completed: 2026-04-29
tasks_completed: 3
tasks_total: 3
commit_hashes:
  - 7b8077f
deviations: []
pre_existing_issues: []
ac_results:
  - criterion: "Field::Base instances expose a public backfill_default! method"
    verdict: "pass"
    evidence: "app/models/typed_eav/field/base.rb (commit 7b8077f); spec 'TypedEAV::Field::Base#backfill_default!' green"
  - criterion: "backfill_default! iterates field.entity_type.constantize.find_in_batches(batch_size: 1000) — iteration unit is the batch, not records"
    verdict: "pass"
    evidence: "app/models/typed_eav/field/base.rb backfill_default! body uses entity_class.find_in_batches(batch_size: 1000) do |batch| ... end"
  - criterion: "Each batch (whole 1000-record array) runs inside a single ActiveRecord::Base.transaction(requires_new: true)"
    verdict: "pass"
    evidence: "spec 'per-batch transaction atomicity rolls back the whole batch on failure and recovers cleanly on re-run' green"
  - criterion: "If a batch transaction raises, the whole batch rolls back atomically; prior batches stay committed; exception surfaces; idempotent on re-run"
    verdict: "pass"
    evidence: "spec 'per-batch transaction atomicity ...' verifies whole-batch rollback + recovery"
  - criterion: "Skip rule per-record (inside batch loop): skip when entity already has non-nil typed value"
    verdict: "pass"
    evidence: "spec 'skip rule for non-nil typed values does not overwrite entities that already have a non-nil typed value' green"
  - criterion: "Skip rule partition-scoped: scope/parent_scope match"
    verdict: "pass"
    evidence: "specs 'partition isolation by scope' and 'partition isolation by parent_scope' green"
  - criterion: "When field.scope is nil (global field): no scope filter; iterate all entities"
    verdict: "pass"
    evidence: "spec 'global field iterates all entities' green"
  - criterion: "No-op when field.default_value is nil"
    verdict: "pass"
    evidence: "spec 'no-op safety is a no-op when no default is configured' green"
  - criterion: "Re-running backfill_default! after success is idempotent"
    verdict: "pass"
    evidence: "spec 'idempotent re-run produces no new Value rows and no changes to existing rows' green"
  - criterion: "Synchronous by default; async dispatch documented as RDoc inline on backfill_default!; no built-in AJ"
    verdict: "pass"
    evidence: "RDoc-style comment block on backfill_default! in app/models/typed_eav/field/base.rb includes async recipe"
  - criterion: "Foundational principle: no hardcoded attribute references; uses self.class.value_column"
    verdict: "pass"
    evidence: "backfill_default! resolves column via `column = self.class.value_column`; spec 'value_column lookup works for non-integer types' verifies Text field uses string_value"
  - criterion: "Single atomic commit covering one source file plus one spec file"
    verdict: "pass"
    evidence: "commit 7b8077f changes exactly app/models/typed_eav/field/base.rb and spec/models/typed_eav/field_spec.rb (2 files, 320 insertions)"
  - criterion: "artifact: app/models/typed_eav/field/base.rb provides public Field#backfill_default!; contains 'def backfill_default!'"
    verdict: "pass"
    evidence: "app/models/typed_eav/field/base.rb defines public def backfill_default!"
  - criterion: "artifact: spec/models/typed_eav/field_spec.rb provides backfill_default! specs (skip non-nil, fill nil, idempotent re-run, partition isolation, no-op when no default)"
    verdict: "pass"
    evidence: "spec/models/typed_eav/field_spec.rb 'TypedEAV::Field::Base#backfill_default!' describe block covers all listed cases plus per-batch transaction atomicity"
  - criterion: "key_link: backfill relies on entities responding to typed_eav_scope and typed_eav_parent_scope (defined by has_typed_eav InstanceMethods)"
    verdict: "pass"
    evidence: "entity_partition_axis_matches? guards with respond_to?(reader_method); specs use Contact (scope_method) and Project (scope+parent_scope) hosts"
  - criterion: "key_link: backfill creates Value rows with explicit value: field.default_value (NOT via UNSET_VALUE sentinel)"
    verdict: "pass"
    evidence: "backfill_one passes value: default_value explicitly to Value.create!/update!; bypasses sentinel resolution path"
---

Adds `Field#backfill_default!` for partition-aware default-value backfill: iterates entities of `field.entity_type` in batches of 1000 via `find_in_batches`, with one transaction per WHOLE batch (not per record) for bounded overhead and recoverability.

## What Was Built

- Public `Field#backfill_default!` instance method on `TypedEAV::Field::Base` with comprehensive RDoc covering iteration model, skip rule, partition match, transaction boundary rationale, and inline async-dispatch recipe.
- Three private helpers: `partition_matches?`, `entity_partition_axis_matches?(entity, axis)`, `backfill_one(entity, column)` — appended to the existing `private` block after Plan 02-02's `normalize_partition_sort_order`.
- Per-batch transaction wrapping (`ActiveRecord::Base.transaction(requires_new: true)`) with the whole batch as the atomic unit; mid-batch raises roll back the whole batch while prior batches stay committed.
- Skip rule symmetric with the Value-side `validate_field_scope_matches_entity` validator: existing non-nil typed column → skip; existing nil → update to default; absent → create with explicit `value: default_value` (bypasses the UNSET_VALUE sentinel path).
- Foundational principle preserved: column resolved via `self.class.value_column`; no hardcoded attribute references.
- Spec coverage: 10 examples in a new `RSpec.describe "TypedEAV::Field::Base#backfill_default!"` block — no-op safety, fill missing rows, skip non-nil, update nil, idempotent re-run, partition isolation by scope, partition isolation by parent_scope, global field iteration, value_column lookup for non-integer types, per-batch transaction atomicity with recoverability.

## Files Modified

- `app/models/typed_eav/field/base.rb` -- modified: added `# ── Backfill ──` section with public `backfill_default!` between `clear_option_cache!` and `# ── Per-type value validation`; appended `partition_matches?`, `entity_partition_axis_matches?`, `backfill_one` to the `private` block; added paired `# rubocop:disable/enable Metrics/ClassLength` with rationale (class crosses 250-line cap due to legitimate cross-cutting partition contract).
- `spec/models/typed_eav/field_spec.rb` -- modified: appended `RSpec.describe "TypedEAV::Field::Base#backfill_default!"` block with 10 examples covering full plan coverage matrix.

## Deviations

None. All locked CONTEXT.md decisions honored: per-batch transactions (not per-record), find_in_batches (not find_each), `self.class.value_column` (no hardcoded refs), explicit `value: default_value` (no UNSET_VALUE coupling), synchronous by default (no built-in AJ dispatch), RDoc-only async recipe (no README modification).
