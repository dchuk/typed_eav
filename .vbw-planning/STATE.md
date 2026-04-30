# State

**Project:** typed_eav
**Milestone:** Enhancement plan v1

## Current Phase
Phase: 2 of 7 (Pipeline Completions)
Plans: 0/0
Progress: 0%
Status: pending

## Phase Status
- **Phase 1:** ✓ Complete (7 plans / 5 waves shipped, R01 remediation applied, UAT 3/3 pass)
- **Phase 2:** Pending
- **Phase 3:** Pending
- **Phase 4:** Pending
- **Phase 5:** Pending
- **Phase 6:** Pending
- **Phase 7:** Pending

## Key Decisions
| Decision | Date | Rationale |
|----------|------|-----------|
| Postgres-only commitment is binding | 2026-04-28 | Partition tuple (paired partial unique indexes), GIN on jsonb, `text_pattern_ops`, and Phase 7's materialized views are all PG-specific. Adapter portability is explicitly out of scope. |
| Hook ordering is locked at Phase 3 | 2026-04-28 | Phase 4 (versioning) and Phase 7 (materialized index) both consume `on_value_change` / `on_field_change`. Defining the contract once prevents two refactors later. |
| Foundational principle: no hardcoded attribute references | 2026-04-28 | Every accessor takes a name/id parameter; every callback receives Value/Field, never assumes attribute names. Binding for every phase. |
| Backwards compatibility is binding | 2026-04-28 | Every phase preserves current API surface. Phase 2 aliases rather than renames `Field.sorted`; Phase 1 `parent_scope` is nullable; Phase 2 cascade default unchanged. |
| Idempotence key for Phase 6 schema import is `(name, entity_type, scope, parent_scope)` | 2026-04-28 | Using field name alone collapses two tenants' identically-named fields. Key derives directly from Phase 1's partition tuple. |

## Todos
_(All Phase 01 known issues resolved by R01 remediation: 16 scoping_spec entries fixed by plan 06 (commit e5e78a4); 7 rubocop entries accepted as process-exception (typed_eav.gemspec:22-26 — pre-existing, ROADMAP housekeeping item.)_

- [KNOWN-ISSUE] rubocop (typed_eav.gemspec:22-26): Layout/HashAlignment: hash literal keys not aligned in metadata{} block (5 oc... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:d04d129f)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (5 offenses) (typed_eav.gemspec:22-26): 5 Layout/HashAlignment offenses in metadata{} block hash keys. Confirmed pre-... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:99094394)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 1) (typed_eav.gemspec:22): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:bf6b7384)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 2) (typed_eav.gemspec:23): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:a6a39615)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 3) (typed_eav.gemspec:24): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:98fd8203)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 4) (typed_eav.gemspec:25): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:56a33f0d)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 5) (typed_eav.gemspec:26): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-29) (ref:61b27064)

## Blockers
None

## Activity Log
- 2026-04-28: Created Enhancement plan v1 milestone (7 phases)
- 2026-04-29: Planned phase 01 (two-level scope partitioning) — 7 plans across 5 waves
- 2026-04-29: Built phase 01 — 7 plans landed (commits 5ff7c30, 52014a3, 6c3afb5, 9c7e916, c628372, e5e78a4, b8fbc91). Suite 440/440 green. Version 0.2.0.
- 2026-04-29: Phase 01 QA remediation R01 applied (8 commits) — plan-amendments for 11 tracked deviations + known-issue reconciliation (16 resolved, 7 accepted-process-exception)
- 2026-04-29: Phase 01 UAT 3/3 pass (docs quality, migration guide, validation behavior section)
