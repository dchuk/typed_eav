# TypedEAV improvement program ledger

This ledger is the durable Phase 0 baseline for the correctness-first TypedEAV improvement program. It is evidence-led: no schema or architecture change is approved from this snapshot alone. The nested repository is currently version 0.6.0; the checked-in CI contract is the support authority.

## Support and execution baseline

- Ruby: >= 3.3, < 4.1; CI lanes 3.3, 3.4, and 4.0.
- Rails: >= 7.2, < 8.2; CI lanes 7.2, 8.0, and 8.1.
- PostgreSQL: 15 through 18; CI tests 15, 16, and 18. Local Phase 0 verification uses Ruby 3.4.4, Rails 8.1.3, and PostgreSQL 17.7.
- CI also runs RuboCop, full RSpec, migration setup, and consumer-install migration coverage. The full suite baseline is 1,201 examples, 0 failures, and 8 intentional Phase 0 pending probes (T004/T006).
- Public surfaces sampled for this program: `has_typed_eav`, `typed_eav_value`, `typed_eav_hash`, `set_typed_eav_value`, `typed_eav_attributes=`, `where_typed_eav`, `typed_eav_definitions`, `bulk_set_typed_eav_values`, and `bulk_set_typed_eav_values_per_record`.
- Representative generated SQL is Active Record/Arel against `typed_eav_values`, typically `WHERE field_id = ? AND integer_value > ?`, with entity IDs consumed as a subquery by `where_typed_eav`; JSON multi-select uses `json_value @> ?`.
- Existing benchmark infrastructure was absent before Phase 0. Representative multi-strategy tournament work is currently resource-blocked by approximately 3.1 GiB free disk; smoke runs cannot decide architecture.

## Schema and index inventory

The source of truth is `db/migrate/20260330000000_create_typed_eav_tables.rb`. `typed_eav_values` stores one row per entity/field and eight nullable typed columns; only the field's applicable column is normally populated. The baseline helper records exact catalog definitions, predicates, sizes, key/INCLUDE columns, row participation, `pg_stat_user_indexes`, and row/null counts.

| Relation/index | Definition and purpose | NULL / INCLUDE participation | Likely write cost | Dependent query paths |
| --- | --- | --- | --- | --- |
| `idx_te_sections_uniq_scoped_full`, `idx_te_sections_uniq_scoped_only` | Unique scoped `(entity_type, code, scope[, parent_scope])` partial indexes for full/only parent-scope rows | Partial predicates select scoped rows; no INCLUDE | Medium | Section scoped definition uniqueness |
| `idx_te_sections_uniq_global` | Unique `(entity_type, code)` partial, `scope IS NULL` | Partial predicate selects global rows | Medium | Section global definition uniqueness |
| `idx_te_sections_entity_active` | B-tree `(entity_type, active)` | NULL-free columns | Medium | Active section lookup |
| `idx_te_fields_uniq_scoped_full`, `idx_te_fields_uniq_scoped_only` | Unique scoped `(name, entity_type, scope[, parent_scope])` partial indexes for full/only parent-scope rows | Partial predicates select scoped rows | Medium | Field scoped uniqueness |
| `idx_te_fields_uniq_global` | Unique `(name, entity_type)` partial, `scope IS NULL` | Partial predicate selects global rows | Medium | Field global uniqueness |
| Rails entity-type field index | B-tree `(entity_type)` | NULL-free | Medium | Field partition lookup |
| `idx_te_fields_lookup` | B-tree `(entity_type, scope, parent_scope, sort_order, name)` | NULL keys remain eligible in ordinary B-tree; ordering follows PostgreSQL NULL rules | Medium | Ordered definitions and generated scaffold |
| `idx_te_options_field_value` | Unique `(field_id, value)` | NULL-free | Medium | Option uniqueness/lookup |
| `idx_te_values_entity_field` | Unique `(entity_type, entity_id, field_id)` | NULL-free | Medium | Value uniqueness and entity/field reads |
| `typed_eav_values_pkey`, `index_typed_eav_values_on_entity`, `index_typed_eav_values_on_field_id` | Rails primary-key, entity lookup, and field foreign-key B-tree indexes | Ordinary B-trees include NULL key values; no INCLUDE columns | Medium | AR identity/entity association and field joins |
| `idx_te_values_field_int/dec/date/dt/bool/str` | B-tree `(field_id, typed_column)`; string uses `text_pattern_ops` | Ordinary B-trees include rows with NULL typed keys; INCLUDE `(entity_id, entity_type)` supports covering reads | Medium | `QueryBuilder` equality/range/string predicates and `FilterQuery` entity-ID subqueries |
| `idx_te_values_json_gin` | Partial GIN on `json_value`, `json_value IS NOT NULL` | Partial predicate excludes NULL JSON rows; no INCLUDE | High | `QueryBuilder` `:any_eq`/`:all_eq` JSON containment |

The table above covers every `typed_eav_values` index: primary key, Rails entity and field lookups, entity/field uniqueness, six scalar indexes, and JSON GIN. The six scalar value indexes are intentionally non-partial today. Whether partial predicates, alternate keys, or INCLUDE changes are worthwhile requires measured footprint, WAL/write, and equality/range evidence on a larger isolated volume. Ordinary B-tree indexes include NULL key values; only a partial predicate controls partial-index participation.

## Nine-column program tracker

| Phase | Task | Owner agent | Status | Dependencies | Decision | Evidence | Commit | Follow-up |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | T004 correctness probes | Worker | done | T001/T002 | Preserve confirmed defects as pending probes | 12 targeted examples; full suite restored by T006 | `b26b256` | Gate 0 judge maps each suspicion |
| 0 | T006 documentation recovery | Worker | done | T004 | Synchronize maintainer docs | 1,201 examples, 0 failures, 8 pending | `1d94f73` | Keep docs consistency green |
| 0 | T005 database baseline | Worker | done | T004/T006 | Capture catalog evidence before optimization | This ledger, helper, and real local PostgreSQL 17.7 empty-database capture; command output is reproducible | current commit | Refresh on isolated representative database |
| 1 | Correctness repair | PM/Workers | queued | Gate 0 | No index redesign before correctness | Pending probes and gate decision required | — | Cover Value state, partition mutation, casting, defaults |
| 2 | Scalar index experiments | PM/Workers | queued | Gate 1 + larger volume | Benchmark alternatives; do not rewrite shipped migration | EXPLAIN, footprint, WAL, write/read measurements | — | Safe concurrent migration only if justified |
| 3–4 | String/planner/query paths | PM/Workers | queued | Gate 2 | Compare B-tree/trigram and multi-filter plans | Operator-specific benchmark evidence | — | Preserve scope and missing semantics |
| 5–8 | Read/write/durability/cleanup | PM/Workers | queued | Gates 4/6 | Characterize semantics before optimizing | Profiles, failure proofs, ADRs | — | Preserve callbacks, versioning, tenant isolation |
| 9–12 | Tournament and documentation | PM/Workers | queued | Prior gates + host | Choose architecture only from fair benchmark | Comparable strategies and final ADRs | — | Final audit and full-outcome proof |

## Baseline commands and evidence policy

Run `bench/database_baseline.rb` against an isolated configured PostgreSQL database. It is read-only and reports empty-database caveats instead of fabricating measurements. The checked-in `bench/results/phase-0-baseline.json` is a real local PostgreSQL 17.7 capture from the empty `typed_eav_test` database; `/tmp/typed-eav-phase-0-baseline.json` is the reproducible verification artifact for this task.

No Phase 2 or tournament result may be treated as representative until a larger dedicated volume/host is available. Local PostgreSQL settings and cumulative `pg_stat_user_indexes` values are context, not cross-version CI evidence.
