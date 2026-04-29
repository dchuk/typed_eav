---
phase: 01
round: 01
title: "QA remediation: plan-amendment for tracked deviations"
type: remediation
status: in-progress
completed:
tasks_completed: 3
tasks_total: 5
commit_hashes:
  - a1c01e3
  - 67dcdf1
files_modified:
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/remediation/qa/round-01/R01-SUMMARY.md
deviations: []
known_issue_outcomes: []
---

QA round 01 — appending "Plan amendment (R01)" rationale blocks to phase 01 PLAN.md files so the documented plan reflects what actually shipped, without modifying any production code or specs.

## Task 1: Amend 01-01-PLAN.md with class name and commit type rationale

### What Was Built
- Appended a `## Plan amendment (R01) — class name + commit type` block to the end of `01-01-PLAN.md` (after the closing `<output>` tag).
- Captured DEVIATION-01-01-A (class name `AddParentScopeToTypedEAVPartitions` vs plan's `AddParentScopeToTypedEavPartitions`) with rationale citing the `EAV` inflector acronym registered in `lib/typed_eav.rb` and the `String#constantize` failure mode.
- Captured DEVIATION-01-01-B (commit type `feat(migration)` vs plan's `db(migration)`) with rationale citing the project commit-format hook's allowed tokens (`feat|fix|test|refactor|perf|docs|style|chore`).

### Files Modified
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md` -- amended: appended R01 amendment block documenting both DEVIATION-01-01-A and DEVIATION-01-01-B; original frontmatter, `<objective>`, `<tasks>`, `<verification>`, `<success_criteria>`, and `<output>` content unchanged.

### Known Issue Outcomes
- None for this task; known issue outcomes are aggregated at round close.

### Deviations
- No deviations.

## Task 2: Amend 01-02-PLAN.md with anticipated-handoff clarification

### What Was Built
- Appended a `## Plan amendment (R01) — anticipated cross-plan handoff to 01-06` block to the end of `01-02-PLAN.md` (after the closing `</output>` tag).
- Captured DEVIATION-01-02 with rationale: the 8 scoping_spec failures after commit `52014a3` (5 assertion-shape mismatches + 3 `ArgumentError` raises from the strict resolver-callable contract) were anticipated by the plan's task 4 verify gate ("those failures get fixed in plan 06") and resolved by plan 06's commit `e5e78a4`.
- Clarified that the SUMMARY's `deviations:` DEVN-05 entry and 8 `pre_existing_issues` entries were over-conservative reporting — the strict QA gate flagged them because they appeared in `deviations:` frontmatter, but the plan body already declared the breakage as expected. They are anticipated cross-plan handoffs to 01-06, not plan violations.

### Files Modified
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md` -- amended: appended R01 amendment block documenting DEVIATION-01-02; original frontmatter, `<objective>`, `<context>`, `<tasks>`, `<verification>`, `<success_criteria>`, and `<output>` content unchanged (git numstat confirms 6 insertions, 0 deletions).

### Known Issue Outcomes
- None for this task; known issue outcomes are aggregated at round close.

### Deviations
- No deviations.

## Task 3: Amend 01-03 + 01-04 + 01-05 + 01-06 PLAN.md with single-commit + DEVN-05 + plan-vs-production correction notes

### What Was Built
- Appended `## Plan amendment (R01) — single-commit consolidation is prescribed` block to `01-03-PLAN.md` (after the closing `</output>` tag), capturing DEVIATION-01-03. Rationale: task 4 explicitly directs "Single commit. One file changed." Tasks 1-3 modify the same validations/scopes block in `app/models/typed_eav/field/base.rb`; splitting them would force three sequential commits to the same hunk neighborhood. Cited shipped commit `6c3afb5`.
- Appended `## Plan amendment (R01) — single-commit consolidation is prescribed` block to `01-04-PLAN.md` (after the closing `</output>` tag), capturing DEVIATION-01-04. Same shape as 01-03 — Section's symmetric mirror plan also directs "Single commit, one file" in task 4. Cited shipped commit `9c7e916`.
- Appended `## Plan amendment (R01) — single-commit consolidation + anticipated DEVN-05 leftover` block to `01-05-PLAN.md` (after the closing `</output>` tag), capturing TWO sub-amendments. (A) DEVIATION-01-05-A: task 5 directs "Single commit"; tasks 1-4 (macro extension, `resolve_scope` rewrite, query path forwarding, Value cross-axis guard) ship as a single integration commit `c628372` covering 4 files. (B) DEVIATION-01-05-B: 8 `scoping_spec` failures persisting after `c628372` are the same anticipated cross-plan handoff documented in 01-02's amendment, resolved by 01-06's commit `e5e78a4` — task 5's verify gate explicitly stated the expected counts.
- Appended `## Plan amendment (R01) — single-commit consolidation + corrected task 3 assertion` block to `01-06-PLAN.md` (after the closing `</output>` tag), capturing TWO sub-amendments. (A) DEVIATION-01-06-A: task 5 directs "Single commit. Seven files modified"; tasks 1-4 spread across 7 spec files but ship as a single commit `e5e78a4` after per-file rspec verification of each task's done criteria. (B) DEVIATION-01-06-B: task 3 prescribed `expect(fields).to contain_exactly(project_scope_only, project_global)` for `Project.typed_eav_definitions(parent_scope: nil)` inside a `with_scope(["tenant_a", "w1"])` block. This contradicted production semantics — `resolve_scope` (`lib/typed_eav/has_typed_eav.rb:340`) gates ambient resolution off whenever EITHER kwarg is passed explicitly, so passing `parent_scope: nil` collapses the resolver to `(scope: nil, parent_scope: nil)` and `for_entity` returns globals only. Dev caught the planning error and rewrote the test to assert actual behavior (`contain_exactly(project_global)`) with an explanatory inline comment, parallel to the existing `scope: nil` test. Documented the any-explicit-disables-ambient rule for future planners.
- All four files received only additions (no deletions); `git diff --stat` shows 4/4/6/6 lines added respectively (20 insertions total). Original frontmatter, `<objective>`, `<context>`, `<tasks>`, `<verification>`, `<success_criteria>`, and `<output>` content unchanged across all four files.
- `grep -l "Plan amendment (R01)"` confirms all four files now carry the canonical amendment marker, joining 01-01-PLAN.md and 01-02-PLAN.md from prior tasks (6/7 phase-01 PLANs amended; 01-07 amendment lands in task 4).

### Files Modified
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md` -- amended: appended R01 amendment block documenting DEVIATION-01-03 (single-commit consolidation rationale citing task 4's "Single commit. One file changed." directive and commit `6c3afb5`).
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md` -- amended: appended R01 amendment block documenting DEVIATION-01-04 (single-commit consolidation rationale citing task 4's "Single commit, one file." directive and commit `9c7e916`).
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md` -- amended: appended R01 amendment block documenting DEVIATION-01-05-A (single-commit consolidation, commit `c628372`) and DEVIATION-01-05-B (anticipated 8-failure carryover from 01-02 resolved by 01-06's commit `e5e78a4`).
- `.vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md` -- amended: appended R01 amendment block documenting DEVIATION-01-06-A (single-commit consolidation, commit `e5e78a4`) and DEVIATION-01-06-B (corrected task 3 assertion `contain_exactly(project_global)` with the any-explicit-disables-ambient `resolve_scope` rationale citing `lib/typed_eav/has_typed_eav.rb:340`).
- `.vbw-planning/phases/01-two-level-scope-partitioning/remediation/qa/round-01/R01-SUMMARY.md` -- frontmatter advanced (`tasks_completed: 3`, four new PLAN.md paths added to `files_modified`); Task 3 narrative appended to body. Commit hash for this combined commit will be appended at round close per the established two-step recording pattern (Task 1+2 hashes were recorded in separate `chore(vbw)` commits, e.g., `2e5f76f`).

### Known Issue Outcomes
- None for this task; known issue outcomes are aggregated at round close.

### Deviations
- No deviations.
