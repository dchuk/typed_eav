---
phase: 5
round: 01
plan: R01
title: "Plan-amendment for DEVN-02 (QueryBuilder :currency_eq case entry)"
type: remediation
input_mode: verification
autonomous: true
effort_override: fast
skills_used: []
files_modified:
  - .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md
forbidden_commands: []
fail_classifications:
  - id: "DEVN-02"
    type: "plan-amendment"
    rationale: "Plan 05-02 truths block stated 'NO QueryBuilder changes are needed in this plan' but :currency_eq is a new operator name not present in QueryBuilder.filter's case statement. The case statement dispatches by operator name (in addition to operator_column resolving the column), so :currency_eq required a 'when :eq, :currency_eq' branch reusing eq_predicate. Dev correctly added the branch. Code is correct; plan truth is wrong. Resolution is to amend the original plan to document the required QueryBuilder change."
    source_plan: "05-02-PLAN.md"
must_haves:
  truths:
    - "The single FAIL (DEVN-02) is classified as plan-amendment in fail_classifications. The original 05-02-PLAN.md truth that said 'NO QueryBuilder changes are needed in this plan' is amended via a date-stamped Plan Amendments section appended to 05-02-PLAN.md acknowledging that :currency_eq required a case-statement entry in lib/typed_eav/query_builder.rb#filter (when :eq, :currency_eq reusing eq_predicate). The amendment preserves the original plan's history and explicitly resolves DEVN-02 as plan-truth-correction, not code-correction."
    - "No source code is modified. lib/typed_eav/query_builder.rb already contains the correct 'when :eq, :currency_eq' branch (verified at commit 6bd087dedc62550754b97a0e8a749771dbe3b11f via verification line 33 evidence). The dev's deviation was unavoidable and correct; the only artifact change is a metadata correction to the plan."
    - "The amendment text in 05-02-PLAN.md explicitly notes: (a) the operator-validation gate from plan 05-01 still narrows :currency_eq to Field::Currency only — no other field type accepts it; (b) operator_column resolves the column to :string_value, but the case statement also dispatches by operator NAME, so :currency_eq required its own case entry; (c) implementation is to extend the :eq branch to 'when :eq, :currency_eq' reusing eq_predicate."
  artifacts:
    - path: ".vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md"
      provides: "Original plan with appended ## Plan Amendments section dated 2026-05-06 documenting the DEVN-02 plan-truth correction"
      contains: "## Plan Amendments"
  key_links:
    - from: ".vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md#plan-amendments"
      to: ".vbw-planning/phases/05-field-type-expansion/05-02-SUMMARY.md#deviations"
      via: "DEVN-02 deviation entry → plan-amendment resolution; both reference lib/typed_eav/query_builder.rb#filter ':currency_eq' case-statement branch"
    - from: ".vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md#plan-amendments"
      to: ".vbw-planning/phases/05-field-type-expansion/05-VERIFICATION.md"
      via: "verification row 12 (DEVN-02 FAIL) is closed by this plan-amendment; no code change is required because verification evidence (query_builder.rb line 59) already shows the correct branch present at the verified commit"
---
<objective>
Amend `05-02-PLAN.md` to correct the plan-truth that incorrectly stated "NO QueryBuilder changes are needed in this plan" — this is a plan-truth correction, not a code fix. The dev's required change to `lib/typed_eav/query_builder.rb` (adding `when :eq, :currency_eq` reusing `eq_predicate`) was unavoidable: the QueryBuilder case statement in `#filter` dispatches by operator NAME (in addition to using `operator_column` for column resolution), so a new operator name like `:currency_eq` must have a case-statement entry or it falls through to the `else => raise` branch.

Source code is already correct at the verified commit (6bd087d) — verification line 33 confirms `query_builder.rb line 59: 'when :eq, :currency_eq' present`. The single FAIL (DEVN-02) closes via plan-metadata correction with no source-code edits.

This round writes ONE atomic commit appending a `## Plan Amendments` section to `05-02-PLAN.md` with a date-stamped entry describing the truth correction. The amendment preserves the original plan's contents (no rewriting of historical truths in-place) and creates an explicit audit trail linking 05-VERIFICATION.md → 05-02-PLAN.md amendment → 05-02-SUMMARY.md DEVN-02 deviation entry.
</objective>
<context>
@.vbw-planning/phases/05-field-type-expansion/05-VERIFICATION.md
@.vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md
@.vbw-planning/phases/05-field-type-expansion/05-02-SUMMARY.md

Locked decisions binding on this round:

- **Classification: `plan-amendment`** (not `code-fix`, not `process-exception`). The code is already correct at the verified commit; the plan's truth statement is wrong. Resolution is to amend the plan, not the code.
- **No source code modifications.** `lib/typed_eav/query_builder.rb` is correct as-shipped; touching it would be churn.
- **Append-only amendment style.** Add a new `## Plan Amendments` section at the very bottom of `05-02-PLAN.md` (after the closing `<output>` tag). Do NOT rewrite the original truths block in-place — that would destroy the historical record of what the plan originally said and why the deviation was flagged.
- **Single atomic commit.** One file, one commit, one task — minimum surface for a plan-metadata fix.

Pattern conformance:
- Plan amendments follow append-only audit-trail pattern (matches general VBW convention that planning artifacts are immutable except via dated amendment sections — preserves blame/history for QA review).
- The amendment text mirrors the truth-statement style of the original plan (declarative, file-and-line-specific, references the exact case-statement branch).
- Dating: use `2026-05-06` (today's date, matching the verification artifact's `date:` frontmatter).

Discrepancy awareness:
1. The original 05-02-PLAN.md truths block contains the false statement: "NO QueryBuilder changes are needed in this plan — the dispatch is field-defined and the existing `:eq`/`:not_eq`/etc. branches in query_builder.rb work unchanged." This statement conflated TWO separate dispatch concerns: (a) operator → column resolution (field-defined via `operator_column` — correct), and (b) operator → predicate-emitter resolution (case statement in `QueryBuilder.filter` — requires a name match). The amendment must explicitly disambiguate these two layers so future planners don't make the same mistake.
2. The amendment must NOT change the plan's `files_modified:` frontmatter list. That list reflects what was originally planned; the actual modified files (including `lib/typed_eav/query_builder.rb`) live in `05-02-SUMMARY.md`'s `files_modified:` list, which is the authoritative post-execution record. The amendment is a SECTION at the bottom of the body, not a frontmatter rewrite.
</context>
<tasks>
<task type="auto">
  <name>P01 — Append Plan Amendments section to 05-02-PLAN.md documenting DEVN-02 plan-truth correction</name>
  <files>
    .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md
  </files>
  <action>
1. Read `.vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` and confirm the file ends with the `<output>05-02-SUMMARY.md</output>` closing tag (currently around line 836). Do NOT modify any existing line.

2. Append the following `## Plan Amendments` section at the end of the file (after a blank line following `<output>05-02-SUMMARY.md</output>`):

```markdown

## Plan Amendments

### 2026-05-06 — R01 plan-amendment for DEVN-02 (QueryBuilder `:currency_eq` case-statement entry)

**Source:** Phase 5 verification (`.vbw-planning/phases/05-field-type-expansion/05-VERIFICATION.md`) flagged DEVN-02 as FAIL because `lib/typed_eav/query_builder.rb` was modified during execution despite this plan's truths block stating "NO QueryBuilder changes are needed in this plan." Remediation round 01 classifies the FAIL as `plan-amendment` rather than `code-fix`: the dev's change was unavoidable and correct; the plan-truth was wrong.

**Truth correction:** The original truths block (Phase-start Gating Decision 3 RESOLVED entry) stated:

> "Currency's `operator_column` override returns `:string_value` for `:currency_eq` and `:decimal_value` otherwise. NO QueryBuilder changes are needed in this plan — the dispatch is field-defined and the existing `:eq`/`:not_eq`/etc. branches in query_builder.rb work unchanged."

This conflated two separate dispatch layers in `QueryBuilder.filter`:

1. **Column resolution** — `field.class.operator_column(operator)` returns the physical column name. Currency's override correctly maps `:currency_eq` → `:string_value`. THIS layer needs no QueryBuilder change.
2. **Predicate emitter resolution** — the `case operator` statement inside `QueryBuilder.filter` dispatches to a predicate builder by operator NAME (e.g., `when :eq` → `eq_predicate(arel_col, casted)`). A NEW operator name not present in any `when` branch falls through to `else => raise ArgumentError`. THIS layer required the addition of `when :eq, :currency_eq` so `:currency_eq` reuses `eq_predicate`.

**Required QueryBuilder change (now documented):** Extend the `:eq` branch in `lib/typed_eav/query_builder.rb#filter`'s case statement from `when :eq` to `when :eq, :currency_eq` so the `:currency_eq` operator reuses `eq_predicate`. The column dispatch via `operator_column` already routes the predicate's `arel_col` to `:string_value` — no further changes are needed inside the predicate body. The operator-validation gate from plan 05-01 still narrows `:currency_eq` to `Field::Currency` only — no other field type accepts it (verified by `spec/lib/typed_eav/query_builder_spec.rb` operator-gate exclusivity example).

**File contract amendment:** `lib/typed_eav/query_builder.rb` should have been included in this plan's `files_modified:` frontmatter list. The post-execution authoritative record lives in `05-02-SUMMARY.md`'s `files_modified:` (which correctly includes `lib/typed_eav/query_builder.rb`).

**Resolution:** DEVN-02 is closed by this amendment. No source code is modified — the existing `when :eq, :currency_eq` branch at `lib/typed_eav/query_builder.rb` line 59 (verified at commit `6bd087dedc62550754b97a0e8a749771dbe3b11f`) is correct as-shipped.
```

3. Save the file. Do not touch any other planning artifact, source file, or spec.
  </action>
  <verify>
- `tail -50 .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` shows the new `## Plan Amendments` section.
- `grep -c '^## Plan Amendments$' .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` returns `1` (exactly one amendment section header).
- `grep -c 'when :eq, :currency_eq' .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` returns at least `1` (amendment text references the case-statement branch).
- `grep -c 'R01 plan-amendment for DEVN-02' .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` returns `1`.
- `git diff --stat` shows ONLY `.vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` modified (no source code, no other planning artifacts).
- `git diff .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` is purely additive (zero deletions; only insertions at the end of the file).
- The original truths block in `05-02-PLAN.md` is UNCHANGED (the false truth remains as historical record; the amendment supplies the correction).
- No source files modified: `git diff --name-only -- 'app/' 'lib/' 'spec/'` returns empty.
  </verify>
  <done>
- `05-02-PLAN.md` contains a `## Plan Amendments` section with a 2026-05-06 entry explicitly resolving DEVN-02 as a plan-truth correction.
- The amendment disambiguates the two dispatch layers (column resolution vs predicate emitter resolution) so future planners do not repeat the conflation.
- The amendment names the exact code change (`when :eq, :currency_eq` reusing `eq_predicate`) and confirms the operator-validation gate from plan 05-01 still narrows `:currency_eq` to `Field::Currency` only.
- No source code is modified.
- One atomic commit covering only `05-02-PLAN.md`.
  </done>
</task>
</tasks>
<verification>
1. `git log --oneline -1` shows a single new commit for this round touching only `.vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md`.
2. `git diff HEAD~1 HEAD --stat` shows exactly one file changed, purely additive.
3. `tail -60 .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` shows the appended `## Plan Amendments` section with the dated `R01 plan-amendment for DEVN-02` entry.
4. `bundle exec rspec` — full suite still green (820 examples, 0 failures, matching the pre-remediation baseline). The amendment is metadata-only; no test count change is expected.
5. `bundle exec rubocop` — clean. No source files modified.
6. `grep -n 'NO QueryBuilder changes are needed in this plan' .vbw-planning/phases/05-field-type-expansion/05-02-PLAN.md` still returns the original truth-block line (preserved as historical record). The amendment supplies the correction; it does NOT delete or rewrite the original.
7. The verification artifact's DEVN-02 row remains FAIL in `05-VERIFICATION.md` (verification artifacts are immutable post-write); this round's R01-SUMMARY.md will record the resolution and link to the plan amendment.
</verification>
<success_criteria>
- DEVN-02 is classified as `plan-amendment` in `fail_classifications:` with explicit rationale.
- `05-02-PLAN.md` contains a date-stamped `## Plan Amendments` section that:
  (a) Identifies the original false truth ("NO QueryBuilder changes are needed in this plan").
  (b) Disambiguates the two dispatch layers (`operator_column` for column resolution; case statement for predicate emitter resolution by operator NAME).
  (c) Documents the required code change: extend `:eq` branch to `when :eq, :currency_eq` reusing `eq_predicate` in `lib/typed_eav/query_builder.rb#filter`.
  (d) Notes that the operator-validation gate from plan 05-01 still narrows `:currency_eq` to `Field::Currency` only.
  (e) Notes that `lib/typed_eav/query_builder.rb` should have been in the plan's `files_modified:` list (the authoritative post-execution record lives in `05-02-SUMMARY.md`).
  (f) Confirms NO source code is modified — the existing branch at `query_builder.rb` line 59 is correct as-shipped at commit `6bd087d`.
- The original 05-02-PLAN.md truths block is preserved (append-only amendment; no historical rewrite).
- One atomic commit; one file modified; no source-code or spec changes.
- Full RSpec suite remains green at the post-remediation commit (820 examples, 0 failures — same as the verified baseline).
- RuboCop clean at the post-remediation commit.
</success_criteria>
<known_issue_workflow>
- This round's `input_mode` is `verification` and the verification artifact carries no known_issues backlog (DEVN-02 is the sole FAIL and is classified as plan-amendment, not as a known-issue carryover).
- `known_issues_input` and `known_issue_resolutions` are intentionally absent from frontmatter — the deterministic gate accepts empty/missing arrays when no known issues are carried into the round.
- If a future round inherits known issues from QA, this section will be expanded per the canonical `{test,file,error}` shape with matching disposition entries.
</known_issue_workflow>
<output>
R01-SUMMARY.md
</output>
