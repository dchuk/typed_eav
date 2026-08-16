# Requirements

Defined: 2026-04-28

## Requirements

### REQ-01: Event system for field-change auditing
**Must-have**

`Config.on_value_change` and `Config.on_field_change` callbacks; `TypedEAV.with_context` thread-local context stack mirroring `with_scope`. Foundation for REQ-02 versioning and REQ-05 materialized index.

### REQ-02: Versioning of field values
**Must-have**

Opt-in `TypedEAV::Versioned` concern + `typed_eav_value_versions` table (event-log shape). `Value#history`, `Value#revert_to`. Hook ordering: versioning fires before user `on_value_change` so callbacks see the persisted version row.

### REQ-03: Field type expansion
**Should-have**

New STI subclasses: Image / File (Active Storage), Reference (cross-scope safe), Currency (two typed columns: decimal_value + string_value), Percentage (Decimal wrapper, 0–1 range). Calculated/computed fields are out of scope.

### REQ-04: Bulk operations & import/export
**Should-have**

`bulk_set_typed_eav_values`, `Field.export_schema` / `Field.import_schema` (idempotence keyed on `(name, entity_type, scope, parent_scope)`), CSV mapping helper, `typed_eav_hash_for(records)` batch read.

### REQ-05: Read-path optimization via materialized index
**Should-have**

Optional `typed_eav_value_index_<entity>` materialized view per `(entity_type, scope, parent_scope)`. DDL regeneration triggered by REQ-01 `on_field_change`. SQL-injection safety on column generation. Eager-load helpers and cache primitives.

### REQ-06: Two-level scope partitioning
**Must-have**

Extend canonical partition tuple from `(entity_type, scope)` to `(entity_type, scope, parent_scope)` for fields AND sections. Paired partial unique indexes mirroring the existing scope-NULL / scope-NOT-NULL split. Foundational — every later requirement keys off this tuple.

### REQ-07: Phase-1 pipeline completions
**Must-have**

Three "complete the pipeline" items, each over existing infrastructure (no new columns):
- Display-ordering API (`acts_as_list`-style helpers over existing `sort_order`).
- Default-value pipeline (`before_validation` auto-populate + sentinel for "unset" vs "explicit nil" + `Field#backfill_default!`).
- Configurable cascade behavior (`field_dependent: :destroy | :nullify | :restrict_with_error`; `:nullify` requires coordinated column-nullable + FK-on-delete migration).

## TypedEAV Improvement Program (added 2026-08-15)

Milestone 2. REQ-01–REQ-04, REQ-06, REQ-07 shipped in milestone 1; REQ-05 remains deferred (see Out of Scope note). Binding for REQ-08–REQ-12: PostgreSQL is deliberate; preserve public API, tenancy, transactions, validation, auditability, polymorphic/STI/namespaced models, and Rails-native ergonomics; every performance decision requires benchmark or EXPLAIN evidence; optimize and validate the current typed-column design before considering replacement; no version bump, tag, push, publication, or release.

### REQ-08: Baseline and correctness
**Must-have**

Capture current Ruby/Rails/PostgreSQL, schema/indexes, CI, test count, public APIs, major query SQL, and reproducible benchmark scaffolding. Add pending behavioral reproductions for all seven confirmed correctness classes without production fixes (pending false assignment order; invalid-cast persistence; exact-partition Field and Section ordering; one-shot version-group correlation under object reuse; field/query Integer casting agreement; strict between input shape; full default-domain validation), then repair them in bounded serialized tasks and pass Gate 1. Phase must begin with the two serialized Phase 0A / Phase 0B tasks under their exact GoalBuddy T001 contracts.

### REQ-09: Scalar, text, and planner architecture
**Must-have**

Benchmark current vs partial scalar indexes before any migration; implement only the evidence-backed production-safe concurrent migration; analyze null/include_missing plans; benchmark text_pattern_ops, lower B-tree, and pg_trgm; test extended statistics, multi-filter SQL shapes, high-cardinality unscoped planning. Record ADRs for scalar indexes, string search, multi-filter SQL, and statistics. Representative evidence requires a larger isolated volume/host; smoke tiers cannot drive architecture decisions.

### REQ-10: Read, write, and lifecycle operations
**Should-have**

Profile BulkRead and safe field-definition caching. Characterize semantic BulkWrite, prototype a distinct high-throughput upsert surface, add explicit chunked semantic transactions without conflating guarantees. Add optional SQL-narrowed scoped backfill, field-owned multi-cell missing semantics, and scalable explicit field-deletion paths.

### REQ-11: Durability and structural cleanup
**Should-have**

Prove current after_commit failure semantics; compare transactional version writes, a minimal transactional outbox, and the current mechanism; approve an ADR before implementation. After persistence semantics stabilize: extract coherent Field ordering/backfill/cascade workflows, reduce Value lifecycle complexity only where safe, encapsulate execution/fiber context storage, clean historical production commentary while preserving public APIs.

### REQ-12: Tournament, architecture decision, and documentation
**Must-have**

Fairly benchmark optimized single-table TypedEAV, indexed JSONB, per-type EAV, and conventional SQL on the required representative matrix (hot-field projection contender only if justified). Write the final evidence-backed storage ADR. Correct README workload claims, publish complete benchmark methodology/results, and run final CI, compatibility, migration, package, and consumer-install gates without version bump, tag, push, publication, or release.

## Out of Scope

- MySQL / SQLite support (Postgres-only is committed; partial unique indexes, GIN, `text_pattern_ops`, materialized views are PG-specific).
- REQ-05 materialized-view read optimization — removed from milestone 1 (2026-08-15); not part of the Improvement Program. Phase 5's tournament and Phase 3's read profiling may inform whether it is ever revived.
- Any storage-design replacement before the current typed-column design has been optimized and validated with evidence (Improvement Program binding rule).
- Version bump, tag, push, RubyGems publication, or GitHub release during the Improvement Program.
- Adapter portability — explicitly out of scope per ROADMAP cross-cutting requirements.
- Calculated / computed fields (deferred to a separate design doc — see REQ-03 notes).
- Branching / merging on versioning (REQ-02 ships the event-log shape only).
- Multi-shard / cross-database scoping — single Postgres database is assumed.
- Standalone documentation site — README is the canonical user docs.
- Per-type query caster classes — there is one `QueryBuilder` module; field types only declare `value_column` + `cast`.
