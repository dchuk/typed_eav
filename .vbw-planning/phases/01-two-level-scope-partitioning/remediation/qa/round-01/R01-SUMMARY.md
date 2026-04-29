---
phase: 01
round: 01
title: "QA remediation: plan-amendment for tracked deviations"
type: remediation
status: in-progress
completed:
tasks_completed: 1
tasks_total: 5
commit_hashes:
  - a1c01e3
files_modified:
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
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
