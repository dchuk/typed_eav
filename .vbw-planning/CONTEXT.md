# typed_eav — Milestone Context

Gathered: 2026-08-15
Calibration: architect

## Scope Boundary

**Milestone:** TypedEAV Improvement Program.

Optimize and validate the current typed-column (hybrid EAV on PostgreSQL) design with evidence before considering any replacement. The user mandated exactly five macro phases, preserved verbatim and in this order:

1. **Baseline and correctness.** Capture current Ruby/Rails/PostgreSQL, schema/indexes, CI, test count, public APIs, major query SQL, and reproducible benchmark scaffolding. Add pending behavioral reproductions for all seven confirmed correctness classes without production fixes: pending false assignment order; invalid-cast persistence; exact-partition Field and Section ordering; one-shot version-group correlation under object reuse; field/query Integer casting agreement; strict between input shape; full default-domain validation. Then repair those defects in bounded serialized tasks and pass Gate 1.
2. **Scalar, text, and planner architecture.** Benchmark current versus partial scalar indexes before any migration; implement only the evidence-backed production-safe concurrent migration; analyze null/include_missing plans; benchmark text_pattern_ops, lower B-tree, and pg_trgm strategies; test extended statistics, multi-filter SQL shapes, and high-cardinality unscoped planning. Record ADRs for scalar indexes, string search, multi-filter SQL, and statistics. Representative evidence requires a larger isolated volume/host; smoke tiers cannot drive architecture decisions.
3. **Read, write, and lifecycle operations.** Profile BulkRead and safe field-definition caching. Characterize semantic BulkWrite, prototype a distinct high-throughput upsert surface, and add explicit chunked semantic transactions without conflating guarantees. Add optional SQL-narrowed scoped backfill, field-owned multi-cell missing semantics, and scalable explicit field-deletion paths.
4. **Durability and structural cleanup.** Prove current after_commit failure semantics; compare transactional version writes, a minimal transactional outbox, and the current mechanism; approve an ADR before implementation. After persistence semantics stabilize, extract coherent Field ordering/backfill/cascade workflows, reduce Value lifecycle complexity only where safe, encapsulate execution/fiber context storage, and clean historical production commentary while preserving public APIs.
5. **Tournament, architecture decision, and documentation.** Fairly benchmark optimized single-table TypedEAV, indexed JSONB, per-type EAV, and conventional SQL on the required representative matrix; add a hot-field projection contender only if the first four justify it. Write the final evidence-backed storage ADR. Correct README workload claims, publish complete benchmark methodology/results, and run final CI, compatibility, migration, package, and consumer-install gates without version bump, tag, push, publication, or release.

**Binding rules for every phase:** PostgreSQL is deliberate; preserve public API, tenancy, transactions, validation, auditability, polymorphic/STI/namespaced models, and Rails-native ergonomics; one coherent concern and one conventional atomic commit per implementation task; Sol High owns architecture/review/gates; Luna Max handles bounded implementation; never overlap writers in Value, query contracts, scalar migrations, durability, or Field::Base extraction; every performance decision requires benchmark or EXPLAIN evidence; optimize and validate the current typed-column design before considering replacement; never manually edit .vbw-planning.

**Mandatory Phase 1 opening (contracts copied exactly from GoalBuddy T001):**

- **Phase 0A** — allowed file: `spec/regressions/improvement_program_phase_0_spec.rb`. Verify targeted RSpec, full RSpec, file RuboCop, and `git diff --check` using Ruby 3.4.4 through `/Users/darrindemchuk/.rbenv/versions/3.4.4/bin`. Stop on any production/factory/spec-helper/migration/planning edit, unrelated baseline failure, nondeterministic suspicion, already-correct behavior forced pending, or dirty worktree.
- **Phase 0B** — allowed files: `docs/improvement-program.md`, `bench/README.md`, `bench/database_baseline.rb`, `bench/results/phase-0-baseline.json`. The helper is read-only, dependency-free beyond current Rails/ActiveRecord/pg, performs no DDL/data mutation/ANALYZE/VACUUM/stat reset, and emits deterministic catalog/index/stat/row-count/bytes-per-logical-value JSON with empty-database caveats. Verify helper execution/output keys, RuboCop, and `git diff --check`. Stop on catalog access failure, missing exact definitions/settings/counts/caveats, new dependency, mutation, out-of-scope file, or dirty worktree.

## Decomposition Decisions

### Phase Count & Grouping
Five phases, because the user mandated exactly five macro phases verbatim and in order; no merging, splitting, or renaming was permitted. Each phase groups one coherent concern: (1) evidence baseline + correctness repair, (2) storage/planner architecture for scalar and text queries, (3) read/write/lifecycle operation surfaces, (4) durability semantics and structural cleanup, (5) storage-design tournament, final ADR, and documentation/gates. Phase 1's two Phase 0A/0B opening tasks are part of Phase 1 (serialized, first), not separate phases.

### Phase Ordering
- **Correctness before everything:** every later benchmark and ADR must measure correct behavior; the seven confirmed correctness classes are reproduced (pending, no production fix) and then repaired before any performance work.
- **Planner/index architecture (2) before operations (3):** BulkRead/BulkWrite/backfill/deletion profiling must run against the final scalar/text index shape, or its evidence goes stale.
- **Durability decision (4) before structural cleanup (same phase, later):** Field workflow extraction, Value lifecycle reduction, and context-storage encapsulation must not move a persistence seam that the durability ADR is about to change; the ADR is approved before implementation.
- **Tournament last (5):** the storage comparison is only fair once the current design is optimized (phases 2–4); a hot-field projection contender is admitted only if the first four contenders justify it.
- Gates 1–5 close each phase; Sol High signs off.

### Scope Coverage
**Covers:** REQ-08 through REQ-12 (baseline/correctness; scalar/text/planner; read/write/lifecycle; durability/structural cleanup; tournament/ADR/docs), including bench scaffolding, ADRs under `docs/adr/`, README workload-claim corrections, and final CI/compat/migration/package/consumer-install gates.

**Explicitly excluded:** REQ-05 materialized-view read optimization (removed from milestone 1, not part of this program); any storage-design replacement before the current design is optimized and validated; version bump, tag, push, RubyGems publication, or GitHub release; adapter portability (Postgres-only is committed); manual edits to `.vbw-planning`.

## Requirement Mapping

| Phase | Name | Requirements |
|-------|------|--------------|
| 1 | Baseline and correctness | REQ-08 |
| 2 | Scalar, text, and planner architecture | REQ-09 |
| 3 | Read, write, and lifecycle operations | REQ-10 |
| 4 | Durability and structural cleanup | REQ-11 |
| 5 | Tournament, architecture decision, and documentation | REQ-12 |

## Key Decisions

(Also recorded in STATE.md Key Decisions, dated 2026-08-15.)

- Five macro phases preserved verbatim and in order (rationale under Phase Ordering).
- Preserve the full contract surface: public API, tenancy (two-axis, fail-closed), transactions, validation, auditability, polymorphic/STI/namespaced models, Rails-native ergonomics; PostgreSQL is deliberate.
- Every performance decision requires benchmark or EXPLAIN evidence; smoke tiers are labeled non-decisional; representative evidence needs a larger isolated volume/host.
- Optimize and validate the current typed-column design before considering replacement; the Phase 5 tournament decides on evidence.
- Serialized writers in Value, query contracts, scalar migrations, durability, and Field::Base extraction; one coherent concern + one conventional atomic commit per task. Roles: Sol High — architecture/review/gates; Luna Max — bounded implementation.
- Phase 1 opens with Phase 0A / Phase 0B under the exact GoalBuddy T001 contracts (allowed files, Ruby 3.4.4 verification, stop conditions) before any production fix.
- Durability ADR approved before implementation; structural cleanup waits for persistence semantics to stabilize.
- No version bump, tag, push, publication, or release anywhere in this milestone.

## Deferred Ideas

- REQ-05 read-path optimization via materialized index (eager-load helpers, opt-in materialized value index, `cache_version` / `TypedEAV.cache_key_for`, `TypedEAV.benchmark`, `.explain` interpretation) — carried from milestone 1; Phase 3 read profiling and the Phase 5 tournament may inform whether it is revived.
- Hot-field projection contender — conditional inside Phase 5; admitted only if the first four contenders' results justify it.
- Storage-design replacement (indexed JSONB, per-type EAV, conventional SQL, or projection) — only if the Phase 5 tournament and final ADR justify it; would be a separate milestone.
- Release / publication of the resulting changes — a separate, explicit decision per `RELEASING.md` after this milestone.
