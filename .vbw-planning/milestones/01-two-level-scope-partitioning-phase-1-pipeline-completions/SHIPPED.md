# Shipped: Enhancement plan v1

**Milestone slug:** 01-two-level-scope-partitioning-phase-1-pipeline-completions
**Project:** typed_eav
**Shipped:** 2026-08-15
**Source version at archive:** 0.6.0 (phases 1–6 shipped through v0.4.0; phase 7 shipped 2026-06-01; correctness/query hardening followed through 0.6.0)
**Git tag:** none (`--no-tag`)
**Branch:** main (no `milestone/*` branch)

## Summary

The post-v0.1.0 enhancement arc for the typed_eav gem: a binding new partition tuple (`parent_scope`), the "complete the pipeline" Phase-1 items (ordering, defaults, cascade), an event/context contract, opt-in versioning, new field types (Currency, Percentage, Image, File, Reference), bulk write / schema import-export / CSV mapping / bulk read APIs, and a human-facing field display label (issue #21).

## Phases

| # | Phase | Plans | Tasks | Completed |
|---|-------|-------|-------|-----------|
| 1 | Two-level scope partitioning | 7/7 | 31/31 | 2026-04-29 |
| 2 | Phase-1 pipeline completions | 4/4 | 16/16 | 2026-04-29 |
| 3 | Event system | 2/2 | 8/8 | 2026-05-01 |
| 4 | Versioning | 3/3 | 14/14 | 2026-05-05 |
| 5 | Field type expansion | 4/4 | 19/20 | 2026-05-06 |
| 6 | Bulk operations & import/export | 5/5 | 15/15 | 2026-05-06 |
| 7 | Field display label (issue #21) | 1/1 | 5/5 | 2026-06-01 |

## Metrics

- **Phases:** 7 (all complete)
- **Plans:** 26/26 complete
- **Tasks:** 108/109 complete (05-04 shipped 4/5 — see its SUMMARY deviations)
- **Commits:** 72 plan-task commits + 20 QA-remediation commits
- **Deviations recorded:** 52 (all resolved via QA remediation rounds — every phase's authoritative `R01-VERIFICATION.md` is PASS)
- **UAT:** every phase has a `complete` UAT; phase 5 resolved via remediation round 01
- **Requirements satisfied:** 6/7 — REQ-01, REQ-02, REQ-03, REQ-04, REQ-06, REQ-07. REQ-05 (read-path optimization) was scoped as the original Phase 7, deferred 2026-06-01, and removed from this milestone 2026-08-15; carried forward in `CONTEXT.md` § Deferred Ideas.

## Removed / deferred scope

- **Read optimization** (eager-load helpers, opt-in materialized value index regenerated via `on_field_change`, `cache_version` / `TypedEAV.cache_key_for` primitives, `TypedEAV.benchmark`, `.explain` interpretation layer) — REQ-05. Full original scope is in this milestone's ROADMAP.md git history prior to commit `83a47ef`. Candidate for a future milestone.

## Notes

- Phase 8 (Field display label) was renumbered to Phase 7 on 2026-08-15 when the deferred read-optimization phase was removed; artifact filenames under `phases/07-field-display-label/` reflect the new number.
- Archived without a git tag by request (`--no-tag`). Release tags for the gem itself live on the `vX.Y.Z` tags per `RELEASING.md`.
