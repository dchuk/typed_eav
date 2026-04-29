---
phase: 1
plan: "04"
title: "Section — parent_scope partition + uniqueness + invariant"
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - 9c7e916
deviations:
  - "DEVN-01 (minor): tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) implemented as a single coordinated edit per the plan's explicit `Single commit, one file` directive in task 4. Each task's done criterion was independently verified before commit. No content was merged or omitted."
pre_existing_issues: []
ac_results:
  - criterion: "Section.for_entity accepts both scope: and parent_scope: kwargs (both default nil)"
    verdict: pass
    evidence: "app/models/typed_eav/section.rb:25 — `scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil| ... }`"
  - criterion: "for_entity scope expands to where(entity_type:, scope: [scope, nil].uniq, parent_scope: [parent_scope, nil].uniq)"
    verdict: pass
    evidence: "Live SQL via rspec harness — three forms emitted: (1) `scope IS NULL AND parent_scope IS NULL`; (2) `(scope = 't1' OR scope IS NULL) AND parent_scope IS NULL`; (3) `(scope = 't1' OR scope IS NULL) AND (parent_scope = 'p1' OR parent_scope IS NULL)`"
  - criterion: "AR uniqueness validator on :code uses scope: %i[entity_type scope parent_scope] (was %i[entity_type scope])"
    verdict: pass
    evidence: "app/models/typed_eav/section.rb:13. Live REPL via rspec: `(entity_type=Contact, code=x, scope=t1, parent_scope=p1)` rejects a duplicate; same triple with `parent_scope=p2` is valid."
  - criterion: "New validate :validate_parent_scope_invariant rejects parent_scope.present? && scope.nil? — symmetric to Field::Base"
    verdict: pass
    evidence: "app/models/typed_eav/section.rb:15 declares the validator; lines 40-45 implement it byte-for-byte identical to Field::Base#validate_parent_scope_invariant. Live REPL: `Section.new(scope: nil, parent_scope: 'p1').valid? # => false; errors[:parent_scope]` populated."
  - criterion: "Existing API surface preserved: Section.for_entity(et, scope: s) still works for callers that don't pass parent_scope"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:297-312 (Section#for_entity describe block) passes unchanged: `result = TypedEAV::Section.for_entity('Contact', scope: 't1')` includes scoped + global rows, excludes other-tenant rows."
  - criterion: "No new dependencies; mirrors plan 03's Field::Base changes inline-duplicated per CONTEXT.md"
    verdict: pass
    evidence: "Diff is 26 insertions / 4 deletions on a single file. No new requires, no shared concern, no library bumps. Validator method body matches Field::Base's structure exactly (only differing context around the class)."
  - criterion: "Single commit: feat(section): partition by (entity_type, scope, parent_scope) and reject orphan parents"
    verdict: pass
    evidence: "Commit 9c7e916. `git show --stat 9c7e916` shows exactly 1 file changed (`app/models/typed_eav/section.rb`)."
  - criterion: "Artifact app/models/typed_eav/section.rb provides three-key partition support"
    verdict: pass
    evidence: "Line 25-31: for_entity lambda accepts and applies parent_scope kwarg with `[parent_scope, nil].uniq` expansion."
  - criterion: "Artifact app/models/typed_eav/section.rb provides orphan-parent invariant validator"
    verdict: pass
    evidence: "Line 15 declares validate; line 40-45 implements validate_parent_scope_invariant under a `private` section."
  - criterion: "Symmetric link to Field::Base: inline-duplicated logic, lockstep with plan 03"
    verdict: pass
    evidence: "validate_parent_scope_invariant body is identical to plan 03's Field::Base equivalent. Difference between the two implementations is limited to the uniqueness key (`:code` vs `:name`) and the file path, as required."
  - criterion: "AR uniqueness validator scope key matches the new idx_te_sections_uniq_scoped index columns"
    verdict: pass
    evidence: "Validator scope `%i[entity_type scope parent_scope]` matches `idx_te_sections_uniq_scoped_full` (entity_type, code, scope, parent_scope) and `idx_te_sections_uniq_scoped_only` (entity_type, code, scope) created by 5ff7c30."
  - criterion: "spec/models/typed_eav/section_and_option_spec.rb passes"
    verdict: pass
    evidence: "12 examples, 0 failures."
  - criterion: "Full spec suite passes (no regressions)"
    verdict: pass
    evidence: "`bundle exec rspec spec/` — 388 examples, 0 failures."
  - criterion: "rubocop clean on app/models/typed_eav/section.rb"
    verdict: pass
    evidence: "`bundle exec rubocop app/models/typed_eav/section.rb` — 1 file inspected, no offenses."
  - criterion: "No spec files modified by this plan"
    verdict: pass
    evidence: "git show --stat 9c7e916 lists only app/models/typed_eav/section.rb. Spec updates are deferred to plan 06."
  - criterion: "No version bump or CHANGELOG edit"
    verdict: pass
    evidence: "git show 9c7e916 -- lib/typed_eav/version.rb CHANGELOG.md returns no diff."
---

Section gains the symmetric `parent_scope` partition treatment that Field::Base receives in plan 03 (running concurrently in wave 1). The three-key partition tuple `(entity_type, scope, parent_scope)` is now enforced consistently at the AR validator layer, the `for_entity` query helper, and the orphan-parent invariant. Inline-duplicated with Field::Base per CONTEXT.md — no `Scopable` concern this phase.

## What Was Built

- `Section.for_entity` accepts a `parent_scope:` kwarg (default nil) and applies the `[parent_scope, nil].uniq` expansion identical to Field::Base. Single-scope callers (`Section.for_entity(et, scope: s)`) are unaffected.
- AR uniqueness validator on `:code` extends from `%i[entity_type scope]` to `%i[entity_type scope parent_scope]`, aligning with the triple-aware paired-partial unique indexes (`idx_te_sections_uniq_scoped_full`, `_scoped_only`, `_global`) added by wave 0 (commit `5ff7c30`).
- `validate_parent_scope_invariant` rejects orphan-parent rows (`parent_scope.present? && scope.blank?`). Implementation is byte-for-byte symmetric to `Field::Base#validate_parent_scope_invariant` so the future extraction (when rule-of-three triggers) is mechanical.
- Verified via the rspec harness: SQL expands as designed for all three call shapes; uniqueness rejection / acceptance behaves correctly across `parent_scope` differences; orphan-parent constructions fail validation. Full suite (388 examples) and rubocop are clean.

## Files Modified

- `app/models/typed_eav/section.rb` — extended `for_entity` to accept `parent_scope:`, broadened `:code` uniqueness scope to include `parent_scope`, and added `validate_parent_scope_invariant` in a new `private` section. 26 insertions, 4 deletions.

## Anticipated Test Breakage (Plan 06)

No anticipated breakage was triggered by this plan. The existing Section unit specs (`spec/models/typed_eav/section_and_option_spec.rb`) and the `Section#for_entity` describe block in `spec/lib/typed_eav/scoping_spec.rb:297-312` continue to pass unmodified because:

1. Existing fixtures default `parent_scope` to nil, and `[nil, nil].uniq == [nil]` preserves single-scope partition semantics.
2. The broadened uniqueness scope is strictly a superset — rows that were unique under `(entity_type, scope)` remain unique under `(entity_type, scope, parent_scope)` when `parent_scope` is uniformly nil.
3. The orphan-parent invariant only rejects new shapes (parent_scope set with scope blank) that no existing fixture creates.

Plan 06 owns the new positive coverage for `parent_scope` (e.g., asserting two sections with the same `(entity_type, code, scope)` but differing `parent_scope` coexist; asserting `Section.for_entity` returns the parent-scope-globals union; asserting orphan-parent rejection at the model layer). No spec files were modified by this plan.

## Deviations

- DEVN-01 (minor): tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) were applied in a single coordinated edit. The plan's task 4 explicitly directs `Single commit, one file`, and tasks 1-3 each modify the same small file in adjacent regions; splitting them would require three sequential commits to the same hunk neighborhood. Each task's done criterion was independently verified (live SQL inspection, REPL uniqueness checks, REPL invariant checks) before commit. No content was merged or omitted.
