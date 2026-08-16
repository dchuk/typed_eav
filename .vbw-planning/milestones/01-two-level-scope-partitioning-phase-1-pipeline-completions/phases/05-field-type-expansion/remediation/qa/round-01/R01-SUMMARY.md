---
phase: 5
round: 01
title: "Plan-amendment for DEVN-02 (QueryBuilder :currency_eq case entry)"
type: remediation
status: complete
started: 2026-05-06
completed: 2026-05-06
tasks_completed: 1
tasks_total: 1
commit_hashes:
  - b170484085ef20f3bb7ad3294f732a97837c9175
files_modified:
  - .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md
deviations: []
known_issue_outcomes: []
---

Closed DEVN-02 by appending a dated Plan Amendments section to 05-02-PLAN.md correcting the false truth that "NO QueryBuilder changes are needed in this plan" — no source code change required because the dev's `when :eq, :currency_eq` branch is correct as-shipped at the verified commit.

## Task 1: P01 — Append Plan Amendments section to 05-02-PLAN.md documenting DEVN-02 plan-truth correction

### What Was Built
- Appended a `## Plan Amendments` heading and a `### 2026-05-06 — R01 plan-amendment for DEVN-02 (QueryBuilder ':currency_eq' case-statement entry)` subsection at the end of `05-02-PLAN.md` (after the closing `<output>` tag) documenting the plan-truth correction.
- Amendment text quotes the original false truth verbatim and disambiguates the two `QueryBuilder.filter` dispatch layers: (1) **column resolution** via `field.class.operator_column(operator)` — correct as planned, Currency's override correctly maps `:currency_eq` → `:string_value`; (2) **predicate emitter resolution** via the `case operator` statement inside `QueryBuilder.filter` — required the addition of `when :eq, :currency_eq` so `:currency_eq` reuses `eq_predicate`. The original truths block conflated these two layers.
- Amendment names the exact required code change: extend the `:eq` branch in `lib/typed_eav/query_builder.rb#filter` from `when :eq` to `when :eq, :currency_eq` so `:currency_eq` reuses `eq_predicate`. Column dispatch via `operator_column` already routes `arel_col` to `:string_value`, so no further changes are needed inside the predicate body.
- Amendment confirms the operator-validation gate from plan 05-01 still narrows `:currency_eq` to `Field::Currency` only (verified by `spec/lib/typed_eav/query_builder_spec.rb` operator-gate exclusivity example) — no other field type accepts the operator.
- Amendment records the file-contract correction: `lib/typed_eav/query_builder.rb` should have appeared in this plan's `files_modified:` frontmatter list. The authoritative post-execution record lives in `05-02-SUMMARY.md`'s `files_modified:` (which correctly includes `lib/typed_eav/query_builder.rb`).
- Amendment confirms NO source code is modified — the existing `when :eq, :currency_eq` branch at `lib/typed_eav/query_builder.rb` line 59, verified at commit `6bd087dedc62550754b97a0e8a749771dbe3b11f`, is correct as-shipped.
- Append-only edit: original truths block preserved verbatim (line 27 still contains the false statement as historical record); diff is purely additive (21 insertions, 0 deletions).

### Files Modified
- `.vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` -- append: added `## Plan Amendments` section with dated R01 entry resolving DEVN-02 as a plan-truth correction.

### Matching FAIL ID
- **DEVN-02** — flagged in `.vbw-planning/phases/05-field-type-expansion/05-VERIFICATION.md` (verification row 12) for `lib/typed_eav/query_builder.rb` modification despite plan stating "NO QueryBuilder changes are needed." Classified as `plan-amendment` in `R01-PLAN.md#fail_classifications` (not `code-fix`) because the code is correct at commit `6bd087d` (verification line 33 evidence) and the dev's change was unavoidable. Closed by this round's plan-metadata correction.

### Source Plan Reference
- `source_plan: 05-02-PLAN.md` (per `R01-PLAN.md#fail_classifications[0].source_plan`)

### Deviations
None.
