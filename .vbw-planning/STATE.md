# State

**Project:** typed_eav
**Milestone:** TypedEAV Improvement Program

## Current Phase
Phase: 1 of 5
Plans: 0/0
Progress: 0%
Status: ready

## Phase Status
- **Phase 1:** Pending planning
- **Phase 2:** Pending
- **Phase 3:** Pending
- **Phase 4:** Pending
- **Phase 5:** Pending

## Key Decisions
| Decision | Date | Rationale |
|----------|------|-----------|
| Postgres-only commitment is binding | 2026-04-28 | Partition tuple (paired partial unique indexes), GIN on jsonb, `text_pattern_ops` are all PG-specific (as would be any future materialized-view read optimization). Adapter portability is explicitly out of scope. |
| Hook ordering is locked at Phase 3 | 2026-04-28 | Phase 4 (versioning) consumes `on_value_change` / `on_field_change`, and any future materialized index would too. Defining the contract once prevents refactoring it later. |
| Foundational principle: no hardcoded attribute references | 2026-04-28 | Every accessor takes a name/id parameter; every callback receives Value/Field, never assumes attribute names. Binding for every phase. |
| Backwards compatibility is binding | 2026-04-28 | Every phase preserves current API surface. Phase 2 aliases rather than renames `Field.sorted`; Phase 1 `parent_scope` is nullable; Phase 2 cascade default unchanged. |
| Idempotence key for Phase 6 schema import is `(name, entity_type, scope, parent_scope)` | 2026-04-28 | Using field name alone collapses two tenants' identically-named fields. Key derives directly from Phase 1's partition tuple. |
| Improvement Program: five macro phases preserved verbatim and in order | 2026-08-15 | Baseline/correctness → scalar/text/planner → read/write/lifecycle → durability/structural cleanup → tournament/ADR/docs. Correctness first so all later benchmarks measure correct behavior; planner work before operations so read/write profiling runs against the final index shape; durability decided before structural cleanup so refactors don't move a persistence seam that is about to change; tournament last so it compares the optimized design. |
| Improvement Program: preserve the full contract surface | 2026-08-15 | Public API, tenancy (two-axis, fail-closed), transactions, validation, auditability, polymorphic/STI/namespaced models, and Rails-native ergonomics are preserved in every phase; PostgreSQL is deliberate. |
| Every performance decision requires benchmark or EXPLAIN evidence | 2026-08-15 | Smoke tiers are labeled and never drive architecture decisions; representative evidence needs a larger isolated volume/host. Prevents index/SQL/storage changes justified by intuition. |
| Optimize and validate the current typed-column design before considering replacement | 2026-08-15 | The Phase 5 tournament (TypedEAV vs indexed JSONB vs per-type EAV vs conventional SQL; hot-field projection only if justified) decides on evidence; no storage replacement before the current design is optimized and measured. |
| Serialized writers in Value, query contracts, scalar migrations, durability, Field::Base extraction | 2026-08-15 | Single-writer areas to avoid stale inputs and conflicting edits; one coherent concern + one conventional atomic commit per implementation task. Sol High owns architecture/review/gates; Luna Max handles bounded implementation. |
| Phase 1 opens with Phase 0A / Phase 0B under exact GoalBuddy T001 contracts | 2026-08-15 | Two serialized tasks (pending reproductions spec; read-only baseline helper + docs) with fixed allowed files, Ruby 3.4.4 verification, and explicit stop conditions — bounded before any production fix. |
| Durability ADR approved before implementation | 2026-08-15 | Transactional version writes vs minimal outbox vs current after_commit are compared first; structural cleanup waits until persistence semantics stabilize. |
| No version bump, tag, push, publication, or release in this milestone | 2026-08-15 | Phase 5's final CI/compat/migration/package/consumer-install gates run without any release surface; releasing is a separate explicit decision per RELEASING.md. |

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
- 2026-08-15: Created TypedEAV Improvement Program milestone (5 phases)
