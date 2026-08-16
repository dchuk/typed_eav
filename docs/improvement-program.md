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

## Schema authority and index inventory

The source of truth is the result of the complete shipped migration chain, not the initial migration alone: `20260330000000_create_typed_eav_tables.rb`, `20260430000000_add_parent_scope_to_typed_eav_partitions.rb`, `20260501000000_add_cascade_policy_to_typed_eav_fields.rb`, `20260505000000_create_typed_eav_value_versions.rb`, `20260506000001_add_version_group_id_to_typed_eav_value_versions.rb`, `20260507000000_add_label_to_typed_eav_fields.rb`, and `20260712000000_enforce_parent_scope_invariant.rb`. `typed_eav_values` stores one row per entity/field and eight nullable typed columns; only the field's applicable column is normally populated. The cascade-policy migration makes `typed_eav_values.field_id` nullable and changes its foreign key to `typed_eav_fields` to `ON DELETE SET NULL` (the down migration restores NOT NULL/CASCADE). Therefore a retained value row may have `field_id IS NULL` after its field is deleted. The baseline helper records exact catalog definitions, predicates, sizes, key/INCLUDE columns, row participation, `pg_stat_user_indexes`, and row/null counts.

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
| `idx_te_values_entity_field` | Unique `(entity_type, entity_id, field_id)` | Ordinary unique B-tree semantics permit multiple rows where nullable `field_id` is NULL; non-NULL triples remain unique | Medium | Value uniqueness and entity/field reads |
| `typed_eav_values_pkey`, `index_typed_eav_values_on_entity`, `index_typed_eav_values_on_field_id` | Rails primary-key, entity lookup, and field foreign-key B-tree indexes | Ordinary B-trees include NULL key values; no INCLUDE columns; the field index therefore retains orphaned rows with `field_id IS NULL` | Medium | AR identity/entity association and field joins |
| `idx_te_values_field_int/dec/date/dt/bool/str` | B-tree `(field_id, typed_column)`; string uses `text_pattern_ops` | Ordinary B-trees include rows with NULL typed keys; INCLUDE `(entity_id, entity_type)` supports covering reads | Medium | `QueryBuilder` equality/range/string predicates and `FilterQuery` entity-ID subqueries |
| `idx_te_values_json_gin` | Partial GIN on `json_value`, `json_value IS NOT NULL` | Partial predicate excludes NULL JSON rows; no INCLUDE | High | `QueryBuilder` `:any_eq`/`:all_eq` JSON containment |

The table above covers every `typed_eav_values` index: primary key, Rails entity and field lookups, entity/field uniqueness, six scalar indexes, and JSON GIN. The six scalar value indexes are intentionally non-partial today. Whether partial predicates, alternate keys, or INCLUDE changes are worthwhile requires measured footprint, WAL/write, and equality/range evidence on a larger isolated volume. Ordinary B-tree indexes include NULL key values; only a partial predicate controls partial-index participation.

For an exact cross-relation catalog check, the 35 index names present in `bench/results/phase-0-baseline.json` are: `idx_te_fields_lookup`, `idx_te_fields_uniq_global`, `idx_te_fields_uniq_scoped_full`, `idx_te_fields_uniq_scoped_only`, `index_typed_eav_fields_on_entity_type`, `index_typed_eav_fields_on_section_id`, `typed_eav_fields_pkey`; `idx_te_options_field_value`, `index_typed_eav_options_on_field_id`, `typed_eav_options_pkey`; `idx_te_sections_entity_active`, `idx_te_sections_lookup`, `idx_te_sections_uniq_global`, `idx_te_sections_uniq_scoped_full`, `idx_te_sections_uniq_scoped_only`, `typed_eav_sections_pkey`; `idx_te_vvs_entity`, `idx_te_vvs_field`, `idx_te_vvs_group`, `idx_te_vvs_value`, `index_typed_eav_value_versions_on_entity`, `index_typed_eav_value_versions_on_field_id`, `index_typed_eav_value_versions_on_value_id`, `typed_eav_value_versions_pkey`; `idx_te_values_entity_field`, `idx_te_values_field_bool`, `idx_te_values_field_date`, `idx_te_values_field_dec`, `idx_te_values_field_dt`, `idx_te_values_field_int`, `idx_te_values_field_str`, `idx_te_values_json_gin`, `index_typed_eav_values_on_entity`, `index_typed_eav_values_on_field_id`, `typed_eav_values_pkey`.

## Generated SQL evidence

The following is captured output from the existing Rails/dummy test environment (`RAILS_ENV=test`, Ruby 3.4.4, Rails 8.1.3, PostgreSQL 17.7), using temporary test fixtures and the public `QueryBuilder`, `FilterQuery`, and `Contact.where_typed_eav` paths. IDs are the actual field IDs emitted during that run; bind-parameter output can differ by adapter/logging mode.

| Public path | Representative generated SQL | What it demonstrates |
| --- | --- | --- |
| `QueryBuilder.filter(integer_field, :eq, 37)` | `SELECT "typed_eav_values".* FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" = 37` | Scalar equality |
| `QueryBuilder.filter(integer_field, :gt, 20)` | `SELECT "typed_eav_values".* FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" > 20` | Scalar range |
| `QueryBuilder.filter(integer_field, :between, [20, 40])` | `SELECT "typed_eav_values".* FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" BETWEEN 20 AND 40` | Inclusive `between` |
| `QueryBuilder.filter(text_field, :contains, "port")` | `SELECT "typed_eav_values".* FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121137 AND "typed_eav_values"."string_value" ILIKE '%port%'` | String pattern |
| `QueryBuilder.filter(integer_array_field, :any_eq, 2)` | `SELECT "typed_eav_values".* FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121138 AND (json_value @> '[2]')` | JSON-array containment |
| `FilterQuery.new(...filters: age > 20, city contains port).to_relation` | `SELECT "contacts".* FROM "contacts" WHERE "contacts"."id" IN (SELECT DISTINCT "typed_eav_values"."entity_id" FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" > 20) AND "contacts"."id" IN (SELECT DISTINCT "typed_eav_values"."entity_id" FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121137 AND "typed_eav_values"."string_value" ILIKE '%port%')` | Multi-filter AND composition through entity-ID subqueries |
| `Contact.where_typed_eav({name: "age", op: :is_null, value: nil}, scope: nil)` | `SELECT "contacts".* FROM "contacts" WHERE "contacts"."id" IN (SELECT DISTINCT "typed_eav_values"."entity_id" FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" IS NULL)` | Explicit value-row NULL predicate |
| Same public path with `include_missing: true` | `SELECT "contacts".* FROM "contacts" WHERE "contacts"."id" NOT IN (SELECT DISTINCT "typed_eav_values"."entity_id" FROM "typed_eav_values" WHERE "typed_eav_values"."field_id" = 121136 AND "typed_eav_values"."integer_value" IS NOT NULL)` | Missing-row-inclusive complement semantics |

## Nine-column program tracker

| Phase | Task | Owner agent | Status | Dependencies | Decision | Evidence | Commit | Follow-up |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | T004 correctness probes | Worker | done | T001/T002 | Preserve confirmed defects as pending probes | 12 targeted examples; full suite restored by T006 | `b26b256` | Gate 0 judge maps each suspicion |
| 0 | T006 documentation recovery | Worker | done | T004 | Synchronize maintainer docs | 1,201 examples, 0 failures, 8 pending | `1d94f73` | Keep docs consistency green |
| 0 | T005 database baseline | Worker | done | T004/T006 | Capture catalog evidence before optimization | This ledger, helper, and real local PostgreSQL 17.7 empty-database capture; command output is reproducible | `91b4c1f` | Refresh on isolated representative database |
| 0 | T007 Gate 0 ledger correction | Worker | done | T003 | Correct migration-derived schema/index authority and record generated SQL evidence | All 35 baseline indexes; actual SQL for scalar equality/range, between, string pattern, JSON-array containment, multi-filter, `is_null`, and `include_missing`; 1,201 examples, 0 failures, 8 pending | task commit | Gate 0 judge retry |
| 0 | T008 Gate 0 retry | Judge | done | T004–T007 | **APPROVED**: correctness repair may begin; performance work remains locked behind Gate 1 | Invariant-by-invariant audit; clean worktree; 1,201 examples, 0 failures, 8 intentional pending | GoalBuddy receipt | Execute T012 → T013 → T014 → T015 serially |
| 1 | T010 Phase 1 coordination | PM | done | T008 | Materialize four non-overlapping-in-time Worker cards and preserve Judge order | T012–T015 scopes, verification, and stop conditions recorded on GoalBuddy board | task commit | Activate T012 only |
| 1 | T012 Value state correctness | Worker | done | T008/T010 | Use payload presence for deferred values; keep cast failure observational; consume version groups at transaction-record finalization | 1,207 examples, 0 failures, 4 remaining intentional pending; lifecycle coverage for success, skipped/no-row versioning, rollback, callback failure, bulk correlation, and object reuse | `e38b2b6` | Execute T013 exact-partition mutation |
| 1 | T013 exact-partition mutation | Worker | done | T012 | Keep visibility widening separate from exact mutation; lock all mixed-STI Field siblings by exact tuple | 1,212 examples, 0 failures, 3 remaining intentional pending; Field and Section coverage for global, scope-only, full tuple, other scopes/parents, and mixed STI | `441facb` | ADR 0007; execute T014 query operands |
| 1 | T014 field-owned query operands | Worker | done | T013 | Normalize operands through field casting; keep Currency/Reference operator policy explicit and `between` shape strict | 1,215 examples, 0 failures, 1 remaining intentional pending; focused scalar/array/between and existing Currency/Reference/LIKE/JSONB compatibility coverage | `b700a33` | Execute T015 default domains |
| 1 | T015 default-domain validation | Worker | done | T014 | Reuse `validate_typed_value` through an in-memory error target; remap errors without Value rows or copied rules | 1,226 examples, 0 failures, no pending; numeric, string, custom, option, array, Currency, valid controls, and unsaved-domain coverage | `5ed588b` | Run T011 Gate 1 |
| 1 | T011 Gate 1 | Judge | done | T012–T015 | **APPROVED**: correctness gate passed; Phase 2 may begin benchmark-first | 1,226/0/no pending; 127-file RuboCop; migration/consumer smoke; five repeated seeds; Ruby/Rails 3.3/7.2, 3.4/8.0, 4.0/8.1 on PostgreSQL 17.7 | GoalBuddy receipt | Build smoke-only Phase 2A harness; qualify representative host before decisions |
| 2 | Scalar index experiments | PM/Workers | queued | Gate 1 + larger volume | Benchmark alternatives; do not rewrite shipped migration | EXPLAIN, footprint, WAL, write/read measurements | — | Safe concurrent migration only if justified |
| 3–4 | String/planner/query paths | PM/Workers | queued | Gate 2 | Compare B-tree/trigram and multi-filter plans | Operator-specific benchmark evidence | — | Preserve scope and missing semantics |
| 5–8 | Read/write/durability/cleanup | PM/Workers | queued | Gates 4/6 | Characterize semantics before optimizing | Profiles, failure proofs, ADRs | — | Preserve callbacks, versioning, tenant isolation |
| 9–12 | Tournament and documentation | PM/Workers | queued | Prior gates + host | Choose architecture only from fair benchmark | Comparable strategies and final ADRs | — | Final audit and full-outcome proof |

## Baseline commands and evidence policy

Run `bench/database_baseline.rb` against an isolated configured PostgreSQL database. It is read-only and reports empty-database caveats instead of fabricating measurements. The checked-in `bench/results/phase-0-baseline.json` is a real local PostgreSQL 17.7 capture from the empty `typed_eav_test` database; `/tmp/typed-eav-phase-0-baseline.json` is the reproducible verification artifact for this task.

No Phase 2 or tournament result may be treated as representative until a larger dedicated volume/host is available. Local PostgreSQL settings and cumulative `pg_stat_user_indexes` values are context, not cross-version CI evidence.

## Phase 2A smoke harness evidence

`bench/scalar_index_benchmark.rb` provides a benchmark-only smoke tier for the three scalar layouts: current covering `(field_id, value) INCLUDE (entity_id, entity_type)`, partial non-covering `(field_id, value) WHERE value IS NOT NULL`, and partial covering `(field_id, value) INCLUDE (entity_id) WHERE value IS NOT NULL`. It creates a uniquely prefixed disposable database, validates the prefix before cleanup, and records a post-drop proof. The deterministic seed-2201 dataset covers integer, decimal, boolean, date, datetime, and string values, with explicit NULL and missing-row controls. The checked-in result is smoke-only: it reports bytes, bytes/live logical value, insert/update and equality/range samples, WAL, EXPLAIN JSON, index-only indicators, and `pg_stat_user_indexes`, but does not select a layout, justify a NULL index, or authorize a migration. Representative tier execution is gated on an explicitly qualified environment.
