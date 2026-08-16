---
phase: 1
plan: "03"
title: "Field::Base — parent_scope partition + uniqueness + invariant"
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - 6c3afb5
deviations:
  - "DEVN-01 (minor): tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) implemented as a single coordinated edit per the plan's explicit `Single commit, one file` directive in task 4. Each task's done criterion was independently verified before commit. No content was merged or omitted."
pre_existing_issues: []
ac_results:
  - criterion: "Field::Base.for_entity accepts both scope: and parent_scope: kwargs (both default nil)"
    verdict: pass
    evidence: "app/models/typed_eav/field/base.rb:62 — `scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil| ... }`"
  - criterion: "for_entity scope expands to where(entity_type:, scope: [scope, nil].uniq, parent_scope: [parent_scope, nil].uniq)"
    verdict: pass
    evidence: "Live SQL emitted via Rails runner against the test database — three forms verified: (1) `entity_type = 'Contact' AND scope IS NULL AND parent_scope IS NULL`; (2) `(scope = 't1' OR scope IS NULL) AND parent_scope IS NULL`; (3) `(scope = 't1' OR scope IS NULL) AND (parent_scope = 'p1' OR parent_scope IS NULL)`"
  - criterion: "AR uniqueness validator on :name uses scope: %i[entity_type scope parent_scope] (was %i[entity_type scope])"
    verdict: pass
    evidence: "app/models/typed_eav/field/base.rb:35 — `validates :name, presence: true, uniqueness: { scope: %i[entity_type scope parent_scope] }`"
  - criterion: "New validate :validate_parent_scope_invariant rejects parent_scope.present? && scope.nil? with errors[:parent_scope]"
    verdict: pass
    evidence: "app/models/typed_eav/field/base.rb:41 declares the validator; lines 272-277 implement it. Live REPL: Field::Text.new(scope: nil, parent_scope: 'p1').valid? is false with errors[:parent_scope] = ['cannot be set when scope is blank']."
  - criterion: "When parent_scope is nil, the invariant validator is silent (passes); when scope is also nil, parent_scope must be nil (single-direction guard)"
    verdict: pass
    evidence: "Live REPL exercised four canonical states — (scope=nil, parent_scope=nil) passes; (scope='t1', parent_scope=nil) passes; (scope='t1', parent_scope='p1') passes; (scope=nil, parent_scope='p1') fails. The empty-string scope edge case ('', 'p1') also fails as designed by the `blank?` guard."
  - criterion: "When scope.present? and parent_scope.present?, validator passes; when both present is the canonical two-level shape"
    verdict: pass
    evidence: "Live REPL: Field::Text.new(scope: 't1', parent_scope: 'p1').valid? — errors[:parent_scope] is empty."
  - criterion: "Existing API surface preserved: Field::Base.for_entity(et, scope: s) still works (parent_scope defaults to nil → only globals-on-parent matched)"
    verdict: pass
    evidence: "for_entity('Contact', scope: 't1') emits `parent_scope IS NULL` predicate (the [nil, nil].uniq == [nil] expansion). Existing single-scope callers unchanged. Full spec suite (388 examples, 0 failures) confirms no caller-side breakage."
  - criterion: "No new dependencies; no rubocop disable comments added without justification"
    verdict: pass
    evidence: "Diff is 50 insertions / 4 deletions on a single file. No new requires, no shared concern, no library bumps. `bundle exec rubocop app/models/typed_eav/field/base.rb` — 1 file, no offenses; no `rubocop:disable` comments introduced."
  - criterion: "Single commit: feat(field): partition by (entity_type, scope, parent_scope) and reject orphan parents"
    verdict: pass
    evidence: "Commit 6c3afb5. `git show --stat 6c3afb5` shows exactly 1 file changed (app/models/typed_eav/field/base.rb), 50 insertions, 4 deletions."
  - criterion: "Artifact app/models/typed_eav/field/base.rb provides three-key partition support"
    verdict: pass
    evidence: "Lines 62-68: for_entity lambda accepts and applies `parent_scope:` kwarg with `[parent_scope, nil].uniq` expansion; comment block lines 45-61 documents the orphan-parent invariant rationale."
  - criterion: "Artifact app/models/typed_eav/field/base.rb provides orphan-parent invariant validator"
    verdict: pass
    evidence: "Line 41 declares `validate :validate_parent_scope_invariant`; lines 272-277 implement it under the existing `private` section, with rationale comment lines 253-271."
  - criterion: "AR uniqueness validator scope key matches the new idx_te_fields_uniq_scoped index columns"
    verdict: pass
    evidence: "Validator scope `%i[entity_type scope parent_scope]` aligns with `idx_te_fields_uniq_scoped_full` (name, entity_type, scope, parent_scope) and `idx_te_fields_uniq_scoped_only` (name, entity_type, scope) created by 5ff7c30."
  - criterion: "Inline-duplicated symmetric logic — plan 04 mirrors these changes on Section"
    verdict: pass
    evidence: "Plan 04 (commit 9c7e916) ships symmetric Section changes; the validator method body is byte-for-byte identical between Field::Base and Section, and for_entity's lambda body matches structurally. Future Scopable extraction is mechanical."
  - criterion: "spec/models/typed_eav/field_spec.rb passes"
    verdict: pass
    evidence: "115 examples, 0 failures."
  - criterion: "spec/models/typed_eav/has_typed_eav_spec.rb and spec/regressions/review_round_2_scope_leak_spec.rb pass"
    verdict: pass
    evidence: "Combined run: 44 examples, 0 failures."
  - criterion: "Full spec suite passes (no regressions)"
    verdict: pass
    evidence: "`bundle exec rspec` — 388 examples, 0 failures."
  - criterion: "rubocop clean on app/models/typed_eav/field/base.rb"
    verdict: pass
    evidence: "`bundle exec rubocop app/models/typed_eav/field/base.rb` — 1 file inspected, no offenses."
  - criterion: "No spec files modified by this plan"
    verdict: pass
    evidence: "git show --stat 6c3afb5 lists only app/models/typed_eav/field/base.rb. Spec updates are deferred to plan 06."
  - criterion: "No version bump or CHANGELOG edit"
    verdict: pass
    evidence: "git show 6c3afb5 -- lib/typed_eav/version.rb CHANGELOG.md returns no diff."
---

Field::Base joins the three-key partition tuple `(entity_type, scope, parent_scope)`. The `for_entity` query helper, the AR uniqueness validator on `:name`, and a new orphan-parent invariant validator are all updated in lockstep. Inline-duplicated with Section (plan 04, commit `9c7e916`) per CONTEXT.md — no `Scopable` concern this phase.

## What Was Built

- `Field::Base.for_entity` accepts a `parent_scope:` kwarg (default nil) and applies the `[parent_scope, nil].uniq` expansion symmetrically with `scope`. Single-scope callers `Field::Base.for_entity(et, scope: s)` are unaffected because the default-nil expansion produces a `parent_scope IS NULL` predicate. A multi-line rationale comment explains why the orphan-parent invariant lets us write the expansion unconditionally.
- AR uniqueness validator on `:name` extends from `%i[entity_type scope]` to `%i[entity_type scope parent_scope]`, aligning with the triple-aware paired-partial unique indexes (`idx_te_fields_uniq_scoped_full`, `_scoped_only`, `_global`) added by wave 0 (commit `5ff7c30`). The DB index is the fail-safe; the validator is the friendly error path.
- New `validate_parent_scope_invariant` rejects `parent_scope.present? && scope.blank?` with `errors[:parent_scope] = ['cannot be set when scope is blank']`. Implementation is byte-for-byte symmetric to `Section#validate_parent_scope_invariant` (plan 04) so the future Scopable extraction (when rule-of-three triggers) is mechanical. `blank?` (not `nil?`) closes the empty-string-scope edge case.
- Verified via Rails runner SQL inspection (all three for_entity call shapes match the plan's expected predicate trees) and a four-state REPL invariant exercise (orphan rejected; global, scope-only, full-triple all pass). Full suite (388 examples, 0 failures) and `rubocop` are clean.

## Files Modified

- `app/models/typed_eav/field/base.rb` — broadened `:name` uniqueness scope; added `validate :validate_parent_scope_invariant`; expanded `for_entity` to accept and apply `parent_scope:`; added private `validate_parent_scope_invariant` method with rationale comment. 50 insertions, 4 deletions.

## Anticipated Test Breakage (Plan 06)

No anticipated breakage was triggered by this plan. The existing field unit specs (`spec/models/typed_eav/field_spec.rb`), the `has_typed_eav` integration specs, and the round-2 scope-leak regression specs all continue to pass unmodified because:

1. Existing factory fixtures default `parent_scope` to nil, and `[nil, nil].uniq == [nil]` preserves single-scope partition semantics in `for_entity`.
2. The broadened uniqueness scope is strictly a superset — rows that were unique under `(entity_type, scope)` remain unique under `(entity_type, scope, parent_scope)` when `parent_scope` is uniformly nil.
3. The orphan-parent invariant only rejects new shapes (parent_scope set with scope blank) that no existing fixture creates.

Plan 06 owns the new positive coverage for `parent_scope` on Field::Base — including the triple-uniqueness regression spec called out in `01-RESEARCH.md` §8 (`field_spec.rb` line 19-30 needs companion coverage for `(name, entity_type, scope, parent_scope)` tuple uniqueness) and the orphan-parent rejection assertion. No spec files were modified by this plan.

## Deviations

- DEVN-01 (minor): tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) were applied in a single coordinated edit. The plan's task 4 explicitly directs `Single commit. One file changed.`, and tasks 1-3 each modify the same small validations/scopes block in `app/models/typed_eav/field/base.rb`; splitting them would require three sequential commits to the same hunk neighborhood, contradicting the plan's stated commit shape. Each task's done criterion was independently verified (SQL inspection for for_entity, REPL uniqueness check for the validator scope, four-state REPL exercise for the invariant) before commit. No content was merged or omitted.
