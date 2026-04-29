# typed_eav — Milestone Context

Gathered: 2026-04-28
Calibration: architect

## Scope Boundary

The post-v0.1.0 enhancement arc for the typed_eav gem. Seven phases that together extend the foundation: a binding new partition tuple (`parent_scope`), the "complete the pipeline" Phase-1 items, an event/context contract, opt-in versioning, four new field types, bulk + import/export APIs, and read-path optimization.

The arc is bounded by the items in `typed_eav-enhancement-plan.md` (the project's strategic plan) reconciled against the codebase mapping in `.vbw-planning/codebase/` and externally reviewed via the Codex Plan Reviewer in April 2026.

## Decomposition Decisions

### Phase Count & Grouping

Seven phases, one per logically independent unit of work in the enhancement plan. Each phase owns a single API contract or capability, can be planned and shipped on its own merit, and either unblocks or is independent of every other phase below it. Smaller decomposition (e.g., grouping Phase 1 + Phase 2 into a single "foundation" phase) was rejected because the scope tuple change in Phase 1 has a much larger blast radius than the Phase-2 pipeline completions and they should be plannable / verifiable independently. Larger decomposition (e.g., splitting Phase 5 into one phase per field type) was rejected because the four new field types share a single planning unit (the STI-extension pattern) — splitting them would multiply ceremony without adding clarity.

### Phase Ordering

This roadmap is dependency-ordered, not category-grouped. The plan organizes items by category (foundational, field types, bulk, perf, events). The roadmap orders them by what unblocks what:

1. **Phase 1 first** because it changes the partition key tuple `(entity_type, scope) → (entity_type, scope, parent_scope)`. Every later phase — uniqueness, sections, schema import, references, ordering, materialized index — keys off this tuple. Doing it later means re-doing them.
2. **Phase 2 next** because the pipeline-completion items (sort_order helpers, default-value pipeline, configurable cascade) build on the new partition tuple but have small change-surface and can ship quickly.
3. **Phase 3 before Phase 4** because versioning fires from the same `after_commit` site as `on_value_change` and `with_context` is required for `changed_by` resolution. Defining the events contract before its consumers is cheaper than refactoring it twice.
4. **Phase 4 before Phase 6** because Phase 6 bulk's `version_grouping:` option is undefinable without versioning to exist.
5. **Phase 5 anywhere after Phase 1** — it depends only on the partition tuple, not on events or versioning. Placed in slot 5 to ride the versioning hook contract from Phase 4 (so new field types get versioning for free).
6. **Phase 6 after Phase 4** for `version_grouping:`.
7. **Phase 7 last** because the materialized index depends on Phase 3's `on_field_change` event for DDL regeneration timing. Eager-load helpers and cache primitives are cheap and could be done earlier, but they don't unblock other phases — there's no cost to grouping them with Phase 7.

### Scope Coverage

**Covers:** scope partitioning extension, pipeline-completion items, event/context contract, opt-in versioning, four new field types (Image / File / Reference / Currency / Percentage), bulk write + schema import-export + CSV mapping + bulk read APIs, eager-load + materialized index + cache primitives.

**Explicitly does NOT cover:**
- MySQL / SQLite portability (Postgres-only is committed; partial unique indexes, GIN, `text_pattern_ops`, materialized views are PG-specific).
- Calculated / computed fields — separate design doc.
- Branching / merging on versioning — Phase 4 ships event-log shape only.
- Multi-shard / cross-database scoping.
- Documentation site beyond README.
- Per-type query caster classes — there is one `QueryBuilder` module by design.

## Requirement Mapping

| Phase | Name | Requirements |
|-------|------|--------------|
| 1 | Two-level scope partitioning | REQ-06 |
| 2 | Phase-1 pipeline completions | REQ-07 |
| 3 | Event system | REQ-01 |
| 4 | Versioning | REQ-02 |
| 5 | Field type expansion | REQ-03 |
| 6 | Bulk operations & import/export | REQ-04 |
| 7 | Read optimization | REQ-05 |

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Postgres-only commitment is binding | The partition tuple (paired partial unique indexes), GIN on jsonb, `text_pattern_ops`, and Phase 7's materialized views are all PG-specific. Adapter portability is explicitly out of scope. |
| Hook ordering is locked at Phase 3 | Versioning (Phase 4) and materialized index (Phase 7) both consume `on_value_change` / `on_field_change`. Defining the contract once at Phase 3 prevents two refactors later. |
| Foundational principle: no hardcoded attribute references | Every accessor takes a name/id parameter; every callback receives Value/Field, never assumes attribute names. Binding for every phase. |
| Backwards compatibility is binding | Every phase preserves current API surface. Phase 2 must alias rather than rename `Field.sorted`. Phase 2 default-value pipeline must keep direct `default_value=` callers working. Phase 2 cascade default unchanged. Phase 1 `parent_scope` is nullable. |
| Idempotence key for Phase 6 schema import is `(name, entity_type, scope, parent_scope)` | Using field name alone collapses two tenants' identically-named fields. The key derives directly from Phase 1's partition tuple. |
| Currency field uses two typed columns per Value row (Phase 5) | `decimal_value` (amount) + `string_value` (currency) preserves native amount indexing. Rejected alternative: `json_value` storage loses range-scan performance on amount. |
| Materialized index column generation requires SQL-injection guard rails (Phase 7) | Field names are user-supplied with minimal constraints today (`RESERVED_NAMES` only excludes Rails STI/timestamp collisions). Restrict to `[A-Za-z0-9_]`, reject reserved SQL identifiers, always quote with `format("%I", name)`. |

## Deferred Ideas

- **Calculated / computed fields** — referenced in plan note line 94. Needs a separate design doc; not part of this roadmap arc.
- **Plan-validated explanation layer** for `.explain` (Phase 7.4) — keep only if a TypedEAV-specific interpretation adds value over plain AR `.explain`. Otherwise drop at phase start.
- **Adapter portability** to MySQL / SQLite — out of scope; documented as such in README §"Database Support".
- **`typed_eav-0.1.0.gem` cleanup** — built artifact committed at repo root. Independent of phases; flagged in ROADMAP §Housekeeping.
- **`TEST_PLAN.md` refresh** — "Current State" lists 6 spec files but the suite now has 22. Independent of phases; flagged in ROADMAP §Housekeeping.
