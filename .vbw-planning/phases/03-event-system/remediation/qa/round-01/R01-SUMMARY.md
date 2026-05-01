---
phase: 3
round: 01
plan: R01
title: Amend plan 03-02 to use previously_new_record? (resolves DEVN-02) and accept Configurable deprecation as pre-existing process-exception
type: remediation
status: complete
completed: 2026-05-01
tasks_completed: 1
tasks_total: 1
commit_hashes:
  - e91079d
files_modified:
  - .vbw-planning/phases/03-event-system/03-02-PLAN.md
deviations: []
known_issue_outcomes:
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before phase 03; phase 03 only added new config_accessor calls atop existing infrastructure. Carried forward from known-issues.json","disposition":"accepted-process-exception","rationale":"Pre-existing Rails 8.2 deprecation accepted as non-blocking for phase 03; deferred to a future Rails-8.2-prep phase."}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config included ActiveSupport::Configurable before plan 03-01; plan only added new config_accessor calls atop existing infrastructure.","disposition":"accepted-process-exception","rationale":"Same deprecation as above (near-duplicate registry entry from sync runs); accepted non-blocking."}'
  - '{"test":"ActiveSupport::Configurable deprecation warning","file":"lib/typed_eav/config.rb","error":"DEPRECATION WARNING: ActiveSupport::Configurable is deprecated without replacement, and will be removed in Rails 8.2. Pre-existing: Config used ActiveSupport::Configurable before phase 03; plans only added new config_accessor calls atop existing infrastructure.","disposition":"accepted-process-exception","rationale":"Same deprecation as above (near-duplicate registry entry); accepted non-blocking."}'
---

R01 plan-amendment round resolves DEVN-02 (FAIL AP-03) by realigning `03-02-PLAN.md` with the as-built code; no source/test changes were made and the full suite remains green at 547 examples / 0 failures.

## Task 1: R01-T01 — Amend 03-02-PLAN.md must_have + task P02 to reference previously_new_record?

### What Was Built
- Replaced prescriptive `created?` references with `previously_new_record?` in the Field-related must_have truth (frontmatter), the `<context>` "Newly-created-record idiom" paragraph, and the task P02 action body (rationale comments + the suggested `_dispatch_field_change` code block + the task `<done>` criterion). Added the canonical-AR-predicate parenthetical to the must_have per R01-PLAN.
- Added an `amendment_history` array to the YAML frontmatter with `round: 01`, `date: 2026-05-01`, `resolved_fail_id: "AP-03"`, and the locked reason string from R01-PLAN.
- Added a leading R01 plan-amendment note at the top of the task P02 action body so future readers see the substitution rationale before the prescriptive instructions begin.
- Verified `previously_new_record?` count is 11 (≥2 required: must_have + task P02 action). Remaining `created?` matches (5) are confined to historical/explanatory contexts (amendment_history.reason, amendment notes, "the plan originally referenced..." sentences) — none are prescriptive, satisfying R01-PLAN's verify clause.
- Confirmed `git diff HEAD~1 HEAD -- app/ lib/ spec/` is empty: this is a planning-artifact-only amendment.
- Ran the full suite post-amendment: 547 examples, 0 failures (unchanged from the 03-02-SUMMARY baseline).

### Files Modified
- `.vbw-planning/phases/03-event-system/03-02-PLAN.md` -- amended: substituted `previously_new_record?` for prescriptive `created?` references, added `amendment_history` frontmatter array, added a leading R01 amendment note in the P02 action body. No other content modified.

### Known Issue Outcomes
- `ActiveSupport::Configurable deprecation warning` (`lib/typed_eav/config.rb`) — `accepted-process-exception`: pre-existing Rails 8.2 deprecation. Config has used `ActiveSupport::Configurable` since before phase 03; phase 03 only added new `config_accessor` calls atop existing infrastructure. Migration belongs in a future Rails-8.2-prep phase, not phase 03.
- `ActiveSupport::Configurable deprecation warning` (`lib/typed_eav/config.rb`) — `accepted-process-exception`: same deprecation as above; near-duplicate registry entry from a sync run. Accepted non-blocking for phase 03.
- `ActiveSupport::Configurable deprecation warning` (`lib/typed_eav/config.rb`) — `accepted-process-exception`: same deprecation as above; third near-duplicate registry entry. Accepted non-blocking for phase 03.

### Deviations
None
