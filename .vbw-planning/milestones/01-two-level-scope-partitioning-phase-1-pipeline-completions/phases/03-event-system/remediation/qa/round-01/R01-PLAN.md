---
phase: 3
round: 01
plan: R01
title: Amend plan 03-02 to use previously_new_record? (resolves DEVN-02) and accept Configurable deprecation as pre-existing process-exception
type: remediation
autonomous: true
effort_override: balanced
skills_used: [rails-architecture]
files_modified:
  - .vbw-planning/phases/03-event-system/03-02-PLAN.md
forbidden_commands: []
fail_classifications:
  - {id: "AP-03", type: "plan-amendment", rationale: "Original plan 03-02 prescribed `created?` as a Rails 6.1+ alias of `previously_new_record?`. Verified via dummy-app runtime probe: activerecord 8.1.3 does NOT define `created?` on AR records (NoMethodError on call); only `previously_new_record?` exists. Dev correctly substituted `previously_new_record?` (the canonical underlying predicate). Substitution is semantically equivalent and verified by the :create-detection branch in field_event_spec.rb plus full suite (547 examples, 0 failures). The plan as written cannot be implemented faithfully — this is a plan-vs-Rails-API mismatch in the original plan, not a code defect. Resolution path is to amend the original plan text so future readers see the actual approach.", source_plan: "03-02-PLAN.md"}
known_issues_input:
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before phase 03; phase 03 only added new config_accessor calls atop existing infrastructure. Carried forward from known-issues.json"}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before plan 03-01; plan only added new config_accessor calls atop existing infrastructure."}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config used ActiveSupport::Configurable before phase 03; plans only added new config_accessor calls atop existing infrastructure."}'
known_issue_resolutions:
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before phase 03; phase 03 only added new config_accessor calls atop existing infrastructure. Carried forward from known-issues.json","disposition":"accepted-process-exception","rationale":"Pre-existing Rails 8.2 deprecation. Phase 03 did not introduce ActiveSupport::Configurable usage; Config has used it since milestone 01. Migration off Configurable belongs in a future Rails-8.2-prep phase (out of scope for the event-system work). Confirmed non-blocking for phase 03 acceptance — the new config_accessor :on_value_change / :on_field_change calls work today and will need to migrate alongside the rest of Config when the gem moves off Configurable."}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before plan 03-01; plan only added new config_accessor calls atop existing infrastructure.","disposition":"accepted-process-exception","rationale":"Same root issue as the previous entry — the deprecation appears in three near-duplicate registry rows because sync-summaries/sync-verification ran multiple times during execution. All three rows describe the same single pre-existing deprecation. Accepted as non-blocking for phase 03."}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config used ActiveSupport::Configurable before phase 03; plans only added new config_accessor calls atop existing infrastructure.","disposition":"accepted-process-exception","rationale":"Same root issue as the previous two entries — Rails 8.2 removes ActiveSupport::Configurable. Pre-existing infrastructure, out of phase 03 scope, accepted non-blocking."}'
must_haves:
  truths:
    - "03-02-PLAN.md references `previously_new_record?` (NOT `created?`) in the Field::Base after_commit branch order specification, with an explanatory note that the plan was amended after activerecord 8.1.3 confirmed `created?` does not exist as a public AR predicate"
    - "The amendment preserves the locked branch order from 03-CONTEXT.md (`<predicate-for-create>` → `:create`, `destroyed?` → `:destroy`, `saved_change_to_attribute?(:name)` → `:rename`, else `:update`) — only the predicate name changes"
    - "The amendment is recorded as a single conventional commit `chore(vbw): amend phase 03 plan 02 created? -> previously_new_record? per Rails 8.1.3 reality (R01 plan-amendment)`"
  artifacts:
    - path: ".vbw-planning/phases/03-event-system/03-02-PLAN.md"
      provides: "amended must_have wording + amended task P02 action wording referencing previously_new_record?"
      contains: "previously_new_record?"
  key_links:
    - from: ".vbw-planning/phases/03-event-system/03-02-PLAN.md amended task P02 action"
      to: "app/models/typed_eav/field/base.rb#_dispatch_field_change"
      via: "predicate-name alignment between plan and as-built code"
---
<objective>
Resolve DEVN-02 via plan-amendment. The original plan 03-02 prescribed `created?` as a Rails 6.1+ alias predicate for use in `Field::Base#_dispatch_field_change`. Runtime verification on activerecord 8.1.3 (current dependency) confirmed `created?` is NOT a defined AR predicate — `previously_new_record?` is the canonical method. Dev-02 correctly substituted `previously_new_record?` during execution and documented the substitution inline. The cleanest resolution is plan-amendment: update 03-02-PLAN.md so the plan body and must_haves match the as-built code, leaving a clear historical record (frontmatter `amendment_history` or a leading note in the task) that the amendment is a plan-vs-Rails-API correction, not a code change.

This round produces NO code changes. Field::Base already uses `previously_new_record?` (commit d9cd538) with an inline rationale comment; the only artifact to modify is the original PLAN.md.

The three near-duplicate Configurable deprecation known-issues entries are pre-existing Rails 8.2 deprecation warnings unrelated to phase 03's work — accepted as process-exceptions and removed from the active known-issues registry.
</objective>
<context>
@.vbw-planning/phases/03-event-system/03-02-PLAN.md
@.vbw-planning/phases/03-event-system/03-02-SUMMARY.md
@.vbw-planning/phases/03-event-system/03-CONTEXT.md
@.vbw-planning/phases/03-event-system/03-VERIFICATION.md
@app/models/typed_eav/field/base.rb

Locked decisions binding on this amendment:
- The branch order in `_dispatch_field_change` is locked: create → destroy → rename → update. Only the create-predicate name is being amended.
- The asymmetry of `dispatch_field_change(field, change_type)` (no context arg) vs `dispatch_value_change(value, change_type)` (3-arg with context) remains locked. This amendment does not touch dispatch signatures.
- `:rename` detection (`saved_change_to_attribute?(:name)`) remains unchanged — the only edit is the create-predicate.
</context>
<tasks>
<task type="auto">
  <name>R01-T01 — Amend 03-02-PLAN.md must_have + task P02 to reference previously_new_record?</name>
  <files>
    .vbw-planning/phases/03-event-system/03-02-PLAN.md
  </files>
  <action>
1. Read the current `.vbw-planning/phases/03-event-system/03-02-PLAN.md`. Locate the must_have truth that prescribes the Field::Base branch order (it currently mentions `created?`).

2. Replace `created?` with `previously_new_record?` in that must_have truth string. Add a parenthetical clarification: `(canonical AR predicate; activerecord 8.1.3 does not define a public `created?` alias — see R01 plan-amendment)`.

3. In the same plan file, locate the task P02 action body (the task that wires Field::Base after_commit). Replace `created?` with `previously_new_record?` in the branch-order action description. Add a single-sentence note explaining the amendment.

4. Add a YAML frontmatter `amendment_history` array entry (or append to it if it exists), with a short record:
   ```
   amendment_history:
     - round: 01
       date: 2026-05-01
       reason: "created? → previously_new_record? (activerecord 8.1.3 does not define created?). Verified via dummy-app probe; previously_new_record? is the canonical predicate. Branch order otherwise unchanged."
       resolved_fail_id: "AP-03"
   ```

5. Do NOT edit any other plan content — must_haves for other tasks, artifacts list, key_links, etc. all stay as-is. Only the create-predicate references change.

6. Do NOT touch `app/models/typed_eav/field/base.rb` — the live code already uses `previously_new_record?` and has a documenting comment. This task is plan-only.
  </action>
  <verify>
- `grep -n "created?" .vbw-planning/phases/03-event-system/03-02-PLAN.md` should return zero matches in the must_have or task P02 action body (matches in `amendment_history.reason` strings or quoted historical context are acceptable as long as they describe the amendment, not prescribe it).
- `grep -n "previously_new_record?" .vbw-planning/phases/03-event-system/03-02-PLAN.md` should return at least 2 matches (must_have + task P02 action).
- The `amendment_history` array in frontmatter has one entry with `round: 01`, `resolved_fail_id: "AP-03"`.
- All other content in 03-02-PLAN.md is byte-identical to the pre-amendment version (diff should show only the create-predicate substitution and the amendment_history addition).
  </verify>
  <done>
- 03-02-PLAN.md amended: must_have + task P02 body reference `previously_new_record?` instead of `created?`.
- amendment_history entry added with round=01 and resolved_fail_id=AP-03.
- No other plan content modified.
- One commit: `chore(vbw): amend phase 03 plan 02 created? -> previously_new_record? per Rails 8.1.3 reality (R01 plan-amendment)`
  </done>
</task>
</tasks>
<verification>
1. `grep -c "created?" .vbw-planning/phases/03-event-system/03-02-PLAN.md` — at most 1 match (in amendment_history reason); zero matches in must_have / task P02 action body.
2. `grep -c "previously_new_record?" .vbw-planning/phases/03-event-system/03-02-PLAN.md` — at least 2 matches.
3. Plan file frontmatter has `amendment_history` array with the round-01 entry described above.
4. `bundle exec rspec` (full suite) — still 547 examples, 0 failures (this round makes NO code changes; suite must remain green).
5. `git diff HEAD~1 HEAD -- app/ lib/ spec/` — empty (no source code changes in this round).
6. `git diff HEAD~1 HEAD -- .vbw-planning/phases/03-event-system/03-02-PLAN.md` — shows only the predicate substitution + amendment_history addition.
</verification>
<success_criteria>
- DEVN-02 (FAIL AP-03) is resolved by plan-amendment: 03-02-PLAN.md now matches the as-built code semantics.
- Configurable deprecation known issues (3 near-duplicate entries) are accepted as process-exceptions — non-blocking for phase 03 acceptance, deferred to a future Rails-8.2-prep phase.
- known-issues.json is cleared (or reduced to entries that are still actively unresolved — none here, since all carried entries are accepted process-exceptions).
- Single commit, conventional commit format, scope `vbw`.
- No source code modifications. No test changes. Full suite remains green.
</success_criteria>
<known_issue_workflow>
All three known-issues entries (Configurable deprecation, near-duplicates) are dispositioned `accepted-process-exception` per the per-issue rationales above. QA must verify the deprecation is real but non-blocking, omit it from `pre_existing_issues` in R01-VERIFICATION.md, and rely on `known_issue_outcomes` in R01-SUMMARY.md to preserve visibility after the registry clears.
</known_issue_workflow>
<output>
R01-SUMMARY.md
</output>
