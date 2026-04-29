# State

**Project:** typed_eav
**Milestone:** Enhancement plan v1

## Current Phase
Phase: 1 of 7
Plans: 0/7
Progress: 0%
Status: planned

## Phase Status
- **Phase 1:** Planned (7 plans, waves 0-4)
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
None.

## Blockers
None

## Activity Log
- 2026-04-28: Created Enhancement plan v1 milestone (7 phases)
- 2026-04-29: Planned phase 01 (two-level scope partitioning) — 7 plans across 5 waves
