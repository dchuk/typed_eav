# TypedEAV Improvement Program Roadmap

**Goal:** TypedEAV Improvement Program

**Scope:** 5 phases

**Milestone intent:** Optimize and validate the current typed-column design with evidence before considering any replacement. Five macro phases, executed in this order; phase names and goals are preserved verbatim from the scoping request.

## Binding rules (every phase)

- **PostgreSQL is deliberate.** No adapter-portability work; PG-specific features (partial indexes, GIN, `text_pattern_ops`, `CONCURRENTLY`, pg_trgm) are in scope.
- **Preserve** public API, tenancy (two-axis scope / parent_scope, fail-closed), transactions, validation, auditability (versioning), polymorphic / STI / namespaced models, and Rails-native ergonomics.
- **One coherent concern and one conventional atomic commit per implementation task** (`{type}({scope}): {description}`).
- **Roles:** Sol High owns architecture, review, and gates (ADR approval, Gate sign-off). Luna Max handles bounded implementation tasks.
- **Never overlap writers** in `Value`, query contracts, scalar migrations, durability, or `Field::Base` extraction — those areas are strictly serialized.
- **Every performance decision requires benchmark or EXPLAIN evidence.** Smoke-tier results are labeled and never drive architecture decisions; representative evidence needs a larger isolated volume/host.
- **Optimize and validate the current typed-column design before considering replacement** (Phase 5 tournament decides on evidence).
- **Never manually edit `.vbw-planning`** — all planning state flows through VBW commands.
- **No version bump, tag, push, publication, or release** anywhere in this milestone (Phase 5 gates run without them).

## Progress
| Phase | Status | Plans | Tasks | Commits |
|-------|--------|-------|-------|---------|
| 1 | Pending | 0 | 0 | 0 |
| 2 | Pending | 0 | 0 | 0 |
| 3 | Pending | 0 | 0 | 0 |
| 4 | Pending | 0 | 0 | 0 |
| 5 | Pending | 0 | 0 | 0 |

---

## Phase List
- [ ] [Phase 1: Baseline and correctness](#phase-1-baseline-and-correctness)
- [ ] [Phase 2: Scalar, text, and planner architecture](#phase-2-scalar-text-and-planner-architecture)
- [ ] [Phase 3: Read, write, and lifecycle operations](#phase-3-read-write-and-lifecycle-operations)
- [ ] [Phase 4: Durability and structural cleanup](#phase-4-durability-and-structural-cleanup)
- [ ] [Phase 5: Tournament, architecture decision, and documentation](#phase-5-tournament-architecture-decision-and-documentation)

---

## Phase 1: Baseline and correctness

**Goal:** Capture current Ruby/Rails/PostgreSQL, schema/indexes, CI, test count, public APIs, major query SQL, and reproducible benchmark scaffolding. Add pending behavioral reproductions for all seven confirmed correctness classes without production fixes: pending false assignment order; invalid-cast persistence; exact-partition Field and Section ordering; one-shot version-group correlation under object reuse; field/query Integer casting agreement; strict between input shape; full default-domain validation. Then repair those defects in bounded serialized tasks and pass Gate 1.

**Requirements:** REQ-08

**Success Criteria:**
- Phase opens with exactly two serialized tasks — Phase 0A (spec/regressions/improvement_program_phase_0_spec.rb) and Phase 0B (docs/improvement-program.md, bench/README.md, bench/database_baseline.rb, bench/results/phase-0-baseline.json) — executed under the contracts copied exactly from GoalBuddy T001 (see "Mandatory opening tasks" below). No other Phase 1 work starts before both are complete.
- Baseline is captured and committed: current Ruby/Rails/PostgreSQL versions, schema and index definitions, CI configuration, test count, public API surface, major query SQL shapes, and reproducible benchmark scaffolding (bench/ helper + JSON results with empty-database caveats).
- Pending behavioral reproductions exist for all seven confirmed correctness classes, added WITHOUT production fixes: (1) pending false assignment order; (2) invalid-cast persistence; (3) exact-partition Field and Section ordering; (4) one-shot version-group correlation under object reuse; (5) field/query Integer casting agreement; (6) strict between input shape; (7) full default-domain validation.
- Each of the seven defects is repaired in its own bounded, serialized task — one coherent concern, one conventional atomic commit — and its pending reproduction flips to passing; no two writers overlap in Value or query contracts.
- Gate 1 passes: targeted RSpec, full RSpec, RuboCop, and git diff --check are green on Ruby 3.4.4 (/Users/darrindemchuk/.rbenv/versions/3.4.4/bin); public API, tenancy, transactions, validation, and auditability contracts unchanged.

**Dependencies:** None

**Mandatory opening tasks (contracts copied exactly from GoalBuddy T001 — Phase 1 must begin with these two serialized tasks, in this order, before any other Phase 1 work):**

- **Phase 0A** — allowed file: `spec/regressions/improvement_program_phase_0_spec.rb`. Verify targeted RSpec, full RSpec, file RuboCop, and `git diff --check` using Ruby 3.4.4 through `/Users/darrindemchuk/.rbenv/versions/3.4.4/bin`. Stop on any production/factory/spec-helper/migration/planning edit, unrelated baseline failure, nondeterministic suspicion, already-correct behavior forced pending, or dirty worktree.
- **Phase 0B** — allowed files: `docs/improvement-program.md`, `bench/README.md`, `bench/database_baseline.rb`, `bench/results/phase-0-baseline.json`. The helper is read-only, dependency-free beyond current Rails/ActiveRecord/pg, performs no DDL/data mutation/ANALYZE/VACUUM/stat reset, and emits deterministic catalog/index/stat/row-count/bytes-per-logical-value JSON with empty-database caveats. Verify helper execution/output keys, RuboCop, and `git diff --check`. Stop on catalog access failure, missing exact definitions/settings/counts/caveats, new dependency, mutation, out-of-scope file, or dirty worktree.

**Seven confirmed correctness classes (reproduce first as pending, then repair in bounded serialized tasks):** (1) pending false assignment order; (2) invalid-cast persistence; (3) exact-partition Field and Section ordering; (4) one-shot version-group correlation under object reuse; (5) field/query Integer casting agreement; (6) strict between input shape; (7) full default-domain validation.

**Gate 1:** targeted RSpec + full RSpec + RuboCop + `git diff --check` green on Ruby 3.4.4; all seven reproductions passing; owned by Sol High.

---

## Phase 2: Scalar, text, and planner architecture

**Goal:** Benchmark current versus partial scalar indexes before any migration; implement only the evidence-backed production-safe concurrent migration; analyze null/include_missing plans; benchmark text_pattern_ops, lower B-tree, and pg_trgm strategies; test extended statistics, multi-filter SQL shapes, and high-cardinality unscoped planning. Record ADRs for scalar indexes, string search, multi-filter SQL, and statistics. Representative evidence requires a larger isolated volume/host; smoke tiers cannot drive architecture decisions.

**Requirements:** REQ-09

**Success Criteria:**
- Current versus partial scalar index benchmarks are recorded (bench/results) BEFORE any migration is written; every index decision cites benchmark or EXPLAIN evidence.
- Only the evidence-backed, production-safe concurrent scalar-index migration is implemented (algorithm: :concurrently, reversible); if evidence does not justify a change, no migration ships and the ADR says so.
- null / include_missing query plans are analyzed with EXPLAIN (ANALYZE, BUFFERS) evidence and documented.
- text_pattern_ops, lower() B-tree, and pg_trgm string-search strategies are benchmarked on the same data with results recorded.
- Extended statistics, multi-filter SQL shapes, and high-cardinality unscoped planning are tested with recorded evidence.
- Four ADRs are recorded under docs/adr/: scalar indexes, string search, multi-filter SQL, statistics — each citing its evidence and explicitly labeling smoke-tier results as non-decisional.
- Representative evidence comes from a larger isolated volume/host run; the tier of every result is labeled and no architecture decision rests on a smoke tier.

**Dependencies:** Phase 1

**Gate 2:** four ADRs (scalar indexes, string search, multi-filter SQL, statistics) recorded and approved by Sol High; every decision cites benchmark/EXPLAIN evidence with tier labels; scalar-migration tasks strictly serialized.

---

## Phase 3: Read, write, and lifecycle operations

**Goal:** Profile BulkRead and safe field-definition caching. Characterize semantic BulkWrite, prototype a distinct high-throughput upsert surface, and add explicit chunked semantic transactions without conflating guarantees. Add optional SQL-narrowed scoped backfill, field-owned multi-cell missing semantics, and scalable explicit field-deletion paths.

**Requirements:** REQ-10

**Success Criteria:**
- BulkRead (typed_eav_hash_for) is profiled with recorded before/after evidence; safe field-definition caching is profiled and, if adopted, invalidates correctly across scope/parent_scope and field-change events.
- Semantic BulkWrite (bulk_set_typed_eav_values) behavior is characterized (validation, versioning, transaction guarantees) and documented.
- A distinct high-throughput upsert surface is prototyped as a separate public entry point — never conflated with the semantic BulkWrite guarantees — with its guarantees stated explicitly.
- Explicit chunked semantic transactions are added with clearly documented per-chunk atomicity; the existing all-or-nothing default is preserved.
- Optional SQL-narrowed scoped backfill (Field#backfill_default!) is added and covered by specs; default behavior unchanged.
- Field-owned multi-cell missing semantics (Currency and other multi-cell types) are defined on the field class and covered by specs.
- Scalable explicit field-deletion paths exist for large value sets (batched, cascade-policy aware) with specs and evidence; public API and tenancy guarantees preserved.

**Dependencies:** Phase 2

**Gate 3:** BulkRead / BulkWrite / upsert / chunked-transaction guarantees documented separately and never conflated; all new surfaces spec-covered; full suite green; Value-touching tasks strictly serialized.

---

## Phase 4: Durability and structural cleanup

**Goal:** Prove current after_commit failure semantics; compare transactional version writes, a minimal transactional outbox, and the current mechanism; approve an ADR before implementation. After persistence semantics stabilize, extract coherent Field ordering/backfill/cascade workflows, reduce Value lifecycle complexity only where safe, encapsulate execution/fiber context storage, and clean historical production commentary while preserving public APIs.

**Requirements:** REQ-11

**Success Criteria:**
- Current after_commit failure semantics (versioning subscriber, user hooks) are proven with reproducible specs and documented evidence.
- Transactional version writes, a minimal transactional outbox, and the current after_commit mechanism are compared with evidence; a durability ADR is written and approved by the architecture owner BEFORE any implementation lands.
- Only after persistence semantics stabilize: coherent Field ordering / backfill / cascade workflows are extracted into cohesive units without changing behavior.
- Value lifecycle complexity is reduced only where the change is proven safe by the existing suite plus targeted specs; no overlapping writers touch Value concurrently.
- Execution/fiber context storage (with_scope / with_context stacks) is encapsulated behind a single seam.
- Historical production commentary is cleaned; public APIs, tenancy, transactions, validation, and auditability contracts remain unchanged and the full suite stays green.

**Dependencies:** Phase 3

**Gate 4:** durability ADR approved BEFORE implementation; structural cleanup lands only after persistence semantics stabilize; public API surface diff is empty; durability and Field::Base extraction tasks strictly serialized.

---

## Phase 5: Tournament, architecture decision, and documentation

**Goal:** Fairly benchmark optimized single-table TypedEAV, indexed JSONB, per-type EAV, and conventional SQL on the required representative matrix; add a hot-field projection contender only if the first four justify it. Write the final evidence-backed storage ADR. Correct README workload claims, publish complete benchmark methodology/results, and run final CI, compatibility, migration, package, and consumer-install gates without version bump, tag, push, publication, or release.

**Requirements:** REQ-12

**Success Criteria:**
- Optimized single-table TypedEAV, indexed JSONB, per-type EAV, and conventional SQL are benchmarked fairly on the required representative matrix (same host, same data volume, same workloads) with results recorded.
- A hot-field projection contender is added ONLY if the first four contenders' results justify it, with the justification recorded.
- The final evidence-backed storage ADR is written under docs/adr/, citing the tournament results; the current typed-column design is validated (or its replacement is justified) by evidence, not assumption.
- README workload claims are corrected to match measured results; complete benchmark methodology and results are published in-repo.
- Final CI, compatibility, migration, package, and consumer-install gates all pass — with NO version bump, tag, push, publication, or release.

**Dependencies:** Phase 4

**Gate 5 (final):** CI, compatibility, migration, package, and consumer-install gates green; final storage ADR + benchmark methodology/results published; README claims corrected; explicitly NO version bump, tag, push, publication, or release.

