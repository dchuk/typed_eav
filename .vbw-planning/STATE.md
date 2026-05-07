# State

**Project:** typed_eav
**Milestone:** Enhancement plan v1

## Current Phase
Phase: 7 of 7 (Read Optimization)
Plans: 0/0
Progress: 0%
Status: ready

## Phase Status
- **Phase 1 (Two Level Scope Partitioning):** Complete
- **Phase 2 (Pipeline Completions):** Complete
- **Phase 3 (Event System):** Complete
- **Phase 4 (Versioning):** Complete
- **Phase 5 (Field Type Expansion):** Complete
- **Phase 6 (Bulk Operations):** Complete
- **Phase 7 (Read Optimization):** Pending

## Key Decisions
| Decision | Date | Rationale |
|----------|------|-----------|
| Postgres-only commitment is binding | 2026-04-28 | Partition tuple (paired partial unique indexes), GIN on jsonb, `text_pattern_ops`, and Phase 7's materialized views are all PG-specific. Adapter portability is explicitly out of scope. |
| Hook ordering is locked at Phase 3 | 2026-04-28 | Phase 4 (versioning) and Phase 7 (materialized index) both consume `on_value_change` / `on_field_change`. Defining the contract once prevents two refactors later. |
| Foundational principle: no hardcoded attribute references | 2026-04-28 | Every accessor takes a name/id parameter; every callback receives Value/Field, never assumes attribute names. Binding for every phase. |
| Backwards compatibility is binding | 2026-04-28 | Every phase preserves current API surface. Phase 2 aliases rather than renames `Field.sorted`; Phase 1 `parent_scope` is nullable; Phase 2 cascade default unchanged. |
| Idempotence key for Phase 6 schema import is `(name, entity_type, scope, parent_scope)` | 2026-04-28 | Using field name alone collapses two tenants' identically-named fields. Key derives directly from Phase 1's partition tuple. |

## Todos
_(No outstanding known issues. typed_eav.gemspec Layout/HashAlignment offenses resolved 2026-04-30 — see commit history.)_

- [KNOWN-ISSUE] rubocop (typed_eav.gemspec:22-26): Layout/HashAlignment: hash literal keys not aligned in metadata{} block (5 oc... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:d04d129f)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (5 offenses) (typed_eav.gemspec:22-26): 5 Layout/HashAlignment offenses in metadata{} block hash keys. Confirmed pre-... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:99094394)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 1) (typed_eav.gemspec:22): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:bf6b7384)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 2) (typed_eav.gemspec:23): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:a6a39615)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 3) (typed_eav.gemspec:24): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:98fd8203)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 4) (typed_eav.gemspec:25): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:56a33f0d)
- [KNOWN-ISSUE] rubocop Layout/HashAlignment (offense 5) (typed_eav.gemspec:26): Layout/HashAlignment: Align the keys of a hash literal if they span more than... — accepted as process-exception for this phase (phase 01, seen 1x) (see remediation/qa/round-01/R01-SUMMARY.md) (added 2026-04-30) (ref:61b27064)

<!-- ActiveSupport::Configurable deprecation entries (3 near-duplicates from phase 03 round-01 promotion) resolved 2026-05-01 — Config and Registry migrated off ActiveSupport::Configurable to hand-rolled class-level accessors. Suite stays green at 547/547; no Rails 8.2 deprecation. -->


## Blockers
None

## Activity Log
- 2026-04-28: Created Enhancement plan v1 milestone (7 phases)
- 2026-04-29: Planned phase 01 (two-level scope partitioning) — 7 plans across 5 waves
- 2026-04-29: Built phase 01 — 7 plans landed (commits 5ff7c30, 52014a3, 6c3afb5, 9c7e916, c628372, e5e78a4, b8fbc91). Suite 440/440 green. Version 0.2.0.
- 2026-04-29: Phase 01 QA remediation R01 applied (8 commits) — plan-amendments for 11 tracked deviations + known-issue reconciliation (16 resolved, 7 accepted-process-exception)
- 2026-04-29: Phase 01 UAT 3/3 pass (docs quality, migration guide, validation behavior section)
- 2026-04-29: Discussed phase 02 (architect mode) — 4 binding decisions captured in 02-CONTEXT.md
- 2026-04-29: Planned phase 02 — 4 plans across 2 waves (commit pending)
- 2026-05-04: Discussed phase 04 (architect mode) — 4 binding decisions captured in 04-CONTEXT.md (opt-in granularity, jsonb shape, revert_to semantics, actor_resolver nil semantics)
- 2026-05-05: Planned phase 04 (versioning) — 3 plans across 3 waves (linear chain; file conflicts on value.rb and lib/typed_eav.rb force sequencing). 14 tasks total. Open items resolved: changed_by=string, three indexes shipped, FK ON DELETE SET NULL on value_id+field_id, generator unchanged (idempotent re-runs), value_columns plural fix bundled in plan 04-02.
- 2026-05-06: Planned phase 06 (bulk operations) — 5 plans across 3 waves. Wave 1 parallel: 06-01 version_group_id migration + subscriber, 06-02 schema export/import, 06-03 CSV mapper. Wave 2: 06-04 bulk read (typed_eav_hash_for). Wave 3: 06-05 bulk write (bulk_set_typed_eav_values) — depends on 06-01 (migration) and 06-04 (file-level serialization on has_typed_eav.rb ClassQueryMethods). 15 tasks total.
