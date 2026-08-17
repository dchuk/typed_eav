# TypedEAV improvement program ledger

## T032 co-tenant representative execution

T032 provides a standalone, label-owned Docker runner for three same-seed trials with rotated candidate order. The designated host is continuously co-tenanted; load is recorded rather than rejected. PostgreSQL is capped at 2 CPUs/8 GiB/256 shares and the runner at 1 CPU/2 GiB/128 shares, both with best-effort I/O weight 100. Memory, Docker-root storage, sustained I/O wait, and inspect-based existing-container ID/state/health/restart invariants remain hard abort gates. Results are relative co-tenant evidence only, not clean-room absolute latency claims; no layout or migration decision is made here.

The accepted result is recorded in `bench/results/phase-2-scalar-representative.json`: seed 2201, 100,000 entities, 595,000 rows per candidate, three rotated trials, and equal candidate checksums. Primary insert/update dispersion is 0.081888 relative population standard deviation against the 0.25 gate. Query dispersion is 0.398261 and is retained as diagnostic evidence. The run preserved the existing-container invariant and verified exact owned cleanup after transfer. This is relative layout evidence under active co-tenants only; it does not establish clean-room absolute latency or choose a winner, index, ADR, or migration.

## T034 NULL-distribution decision

T034 measured the selected partial-covering integer index against the same layout plus `(field_id, entity_id) WHERE integer_value IS NULL` on a realistic six-type table. The seed-3301 dataset used 100,000 hosts, 5,000 missing integer rows, and low/high explicit-NULL distributions of 947/47,737 rows among 95,000 present integer rows. Three rotated same-seed trials passed checksum/count invariants on PostgreSQL 17.11. The isolated runner preserved the existing-container invariant, recorded six anonymous contention samples, and verified exact T034 cleanup. Existing co-tenants consumed 218.67%–354.18% aggregate CPU during the run, so absolute latency is not used for policy.

The decision is **Option B**: do not ship an automatic NULL index; retain partial-covering scalar indexes and offer targeted guidance only when an application's own EXPLAIN evidence shows frequent low-NULL explicit-NULL probes. A current-query-compatible integer NULL index necessarily captured 500,947 rows in the low-NULL dataset and 547,737 in the high-NULL dataset because the other five typed columns leave `integer_value` NULL. At low NULL it reduced explicit-NULL/`eq nil` median root-plan buffers from 5,115 to 849, while adding 37.5% index bytes and 28.7% insert WAL. At high NULL it increased those buffers from 5,069 to 9,349, while adding 43.4% index bytes and 32.4% insert WAL. NULL-inclusive `not_eq` buffers increased 8.6%/7.0%; `is_not_null` and `include_missing` were unchanged. Post-update EXPLAINs intentionally retain heap-fetch evidence rather than assuming an ideal visibility map.

The next migration must therefore create the six selected partial-covering scalar indexes concurrently before dropping the legacy indexes, preserve `text_pattern_ops` for string, and ship no automatic NULL index. Its rollback must recreate every legacy covering index before removing the new one. ADR 0008 records the exact names and NULL guidance.

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

## Phase 3 string-search evidence

T043 measured exact public `=`, `ILIKE`, and `NOT ILIKE` predicates against the shipped partial-covering B-tree, an additive lower-expression B-tree, and an additive partial `pg_trgm` GIN index. Seed 4401 supplied 250,000 target-field and 250,000 noise-field rows per candidate with deterministic skew, escaped `%`/`_`, short-pattern, suffix, prefix, positive, and negative controls. Three rotated PostgreSQL 17 trials passed dataset/operator checksum equality and primary dispersion at 0.150653. Existing-container state and exact cleanup passed under anonymous co-tenant load; absolute timing remains diagnostic.

GIN appeared in public plans for prefix, ordinary contains, suffix, and escaped-literal probes. It did not accelerate `NOT ILIKE` or one/two-character probes. Current B-tree equality remained index-only. The lower-expression B-tree appeared only for the separate `lower(string_value) LIKE ...` prototype; unchanged public `ILIKE` did not use it, and collation equivalence is not assumed. Median index bytes were 35,840,000 current, 59,867,136 lower-additive, and 57,851,904 GIN-additive. GIN median build time was 2,378.324 ms and insert/update throughput 85,449.9/40,828.6 rows/s versus 409.119 ms and 198,696.6/97,350.6 for current B-tree alone; GIN insert/update WAL was 17,589,544/14,149,224 versus 6,857,536/4,789,184 bytes.

Disposable PostgreSQL 15.19, 16.15, and 18.6 lanes proved `pg_trgm` availability plus create, idempotent create, update, drop, and recreate/drop by a database owner whose superuser, createdb, createrole, and replication flags were all false. Those lanes test extension lifecycle, not planner behavior, and hosted-service privileges may differ.

T044 selected a documentation-only policy, recorded in ADR 0009. The gem retains the shipped B-tree and public SQL, does not require or install `pg_trgm`, and ships no GIN or GiST index. Applications with measured positive `ILIKE` workloads may evaluate an application-owned partial GIN index using concurrent DDL, retaining the shared extension on rollback. They must measure real selectivity and pattern lengths with EXPLAIN plus storage, WAL, and write costs. The policy explicitly excludes claims for `NOT ILIKE`, one/two-character probes, every positive pattern, the lower/LIKE prototype, or GiST.

The additive GIN increased median candidate index bytes 61.417% and build WAL 50.293%; insert/update throughput fell 56.995%/58.060% while WAL rose 156.499%/195.441%. Full raw plans, checksums, sizes, and build measurements are retained for trial 1. The artifact retains cross-trial metric arrays and rotation metadata but not raw trial 2/3 plans, checksums, sizes, or build times, limiting independent audit of those items. PostgreSQL 17 plan evidence and co-tenant absolute timing are not generalized.

## Phase 4A planner-statistics evidence

T051 completed the preregistered target-100 Williams crossover on PostgreSQL 17. Ten trials supplied 50 one-`ANALYZE` blocks and 1,100 raw plans. Every extended block proved the ordinary `pg_stats` sample identical after dropping its statistics objects and before capturing the paired base suite. Seed, 300,000-entity cardinality, dataset checksums, candidate order, statistics targets, output hashes, existing-container invariant, and exact cleanup all passed. ANALYZE elapsed time ranged from 125.077 to 1,133.4 ms under co-tenant load; absolute timing is diagnostic.

The shared deterministic 20,000-replicate trial-cluster bootstrap classified candidate-wide dependencies as an improvement in absolute corrected log2 estimate error: median paired delta -2.0883, 98.75% interval [-2.0991, -2.0463]. MCV, ndistinct, and the combined object were candidate-wide practical equivalence at 0.0 in this workload. Query-level dependencies evidence was heterogeneous: seven improvements, two practical-equivalence ranges, one inconclusive rare-integer equality, and one worsening for the date equality probe labeled common. That probe queried `2024-01-01`, while generated common dates begin at `2024-01-02`, and matched zero rows. It is absent-date evidence, not common-date evidence. Dependencies apply to compatible equality/`IN` clauses and did not apply to the range probes. MCV changed common skewed integer/string equalities and integer/date ranges while remaining practically equivalent elsewhere; ndistinct was practically equivalent for all 11 queries. Inconclusive and heterogeneous outcomes are retained rather than promoted to a global failure or policy.

No candidate caused a paired plan-shape change, sequential scan, or index-only loss. Dependencies and MCV each had seven near-stable and four stable query signatures across sampling trials; ndistinct and the combined object were stable for all 11. Matching MCV groups supplied the four estimates changed by the combined object, explaining why it mirrored MCV rather than the dependencies-only aggregate result. ADR 0010 selects documentation-only, application-owned evaluation of dependencies statistics for measured equality misestimates. TypedEAV installs no statistics object and ships no migration, helper, generator, API, or query change. Applications must own the DDL and names, choose typed columns and targets from their workload, run `ANALYZE`, measure estimates/plans/runtime and maintenance cost, coordinate shared-database ownership, and drop only verified application-owned objects. Target 100 is not universal, and these PostgreSQL 17 synthetic results make no cross-version or runtime-benefit claim.

## Phase 4B multi-filter evidence

T062 completed the preregistered right-censored comparison without changing production SQL. Across 100,000 primary hosts, more than 50 field definitions, nominally 20 values per host, 25 scenarios, three rotations, and four strategies, the artifact retains exactly 2,940 uniformly capped attempts, 294 representative identity-oracle outcomes, and 75 scenario/trial semantic summaries. It includes scope and shadowing resolution, polymorphic host identity, explicit NULL, missing values, duplicate internal matches, empty-filter behavior, and error controls. Direct grouped `HAVING` remains explicitly ineligible where it cannot represent host-universe complement/missing or empty-filter semantics.

The representative run retained 622 SQLSTATE 57014 measured censors and 64 matching non-ANALYZE fallback plans. Of 294 non-retried 5,000 ms representative oracles, 282 completed and 12 timed out with null identities; no completed oracle mismatched and no oracle errored. The embedded seed-4502 smoke completed all 98 eligible oracles with equal identities and resolved-filter hashes. The representative timeouts are `unproved_timeout`, not equality or inequality. Consequently `representative_equivalence_proven=false`, `production_replacement_eligible=false`, and `retain_current_sql=true`. No query replacement is authorized. The corrected seven-stage export-before-drop drill, 300 diagnostic checkpoints, existing-container invariant, transfer, exact cleanup, and post-cleanup audit passed on the capped co-tenant Tailscale host.

ADR 0011 accepts this only as negative/retention evidence. The current chained host `IN` strategy remains production behavior; `INTERSECT` and correlated `EXISTS` are research-only, and grouped `HAVING` is additionally ineligible for missing/host-universe complement and empty-filter semantics. Alternatives strongly improved `high_10`, but `mixed_10` regressed and large low/mixed/skewed workloads were commonly censored or inconclusive. There is no general winner or authorized adaptive selector.

The audit found that all derived buffer totals are false zeros because the extractor split each multiword EXPLAIN block key into individual words; 2,318 retained raw plans contain nonzero counters that can be reparsed. It also found that 20-predicate scenarios repeat ten fields, while `skewed_10` and `skewed_20` repeat five. The PostgreSQL 17 co-tenant run therefore proves neither valid zero-buffer behavior, clean-room/cross-version performance, nor 20-distinct-field scaling. Before future adaptive research can support a production proposal, it must preserve the complete resolution/scope/shadowing/operator/NULL/missing/complement/polymorphic/duplicate/empty/error contract, complete every representative identity oracle, measure actual 10/20 distinct fields, validate corrected buffers against raw plans, show uncensored >=20% p95 gains at both sizes in at least three families, and satisfy pre-registered planning/buffer/plan-shape bounds. Cross-scope high-cardinality evidence remains required before Gate 4; any cross-version claim requires evidence beyond this PostgreSQL 17 run.

T076 supplies the bounded corrective evidence without changing the historical artifact, production SQL, APIs, schema, or ADR 0011. Its eight-scenario high/low/mixed/skewed × 10/20 matrix proves exact distinct field names, one definition per predicate, and the declared distinct field-ID count. Three rotations retained 960 attempts, 96 representative oracles, and 24 summaries. There were 340 completed attempts, 620 honest SQLSTATE 57014 censors, and 63 lossless fallback-plan groups. Of the representative oracles, 81 completed and 15 timed out with null identity; none mismatched or errored. Historical and corrective smoke completed 98/98 and 32/32 equal eligible identities respectively.

The independent validator inflated and hash-checked every retained completed plan, then exactly matched all ten root-plan shared/local/temp block counters; every one of the 340 completed plans contained a nonzero counter. It rejected independently injected duplicate-field, altered-buffer, missing-plan, and corrupt-hash artifacts. The embedded export-before-drop drill, existing-container invariant, capped internal networking, 96 checkpoints, transfer, and exact cleanup passed. One absent official `ruby:3.4.4-bookworm` image was pulled once after headroom checks, verified as Ruby 3.4.4 at its `ruby@sha256:` digest, used with `--pull=false`, and its introduced tag/image ID were removed without prune. Representative equivalence remains unproved because of the 15 timeouts, so production replacement is ineligible and current chained `IN` remains retained pending Gate 4 review.

## Phase 4C cross-scope administrative policy

Phase 4C closes with a conservative, qualitative guardrail rather than a
performance result. Code-path analysis establishes that ordinary tenant
resolution chooses the most-specific definition among global, scope-only, and
full-tuple candidates. The explicit `ALL_SCOPES` administrative path instead
materializes all visible same-name definitions, builds their per-definition
relations, and combines those relations for each filter.

T066 and T069 did not produce an accepted representative artifact. T066
rejected during artifact validation without retaining its decisive rejection
detail. T069 rejected at the required checkpoint gate, and assertion ordering
again prevented the exported rejection diagnostic from being retained. Local
smoke exercised semantics only. No rejected output is treated as representative
evidence, and no latency, throughput, planner, cardinality limit, or
prototype-comparison claim is made.

ADR 0012 keeps `TypedEAV.unscoped` as an explicit administration, analytics,
migration, and audit escape hatch. Consuming applications should narrow the
definition universe and batch broad work at application-owned boundaries based
on their own measurements. TypedEAV adds no threshold, warning, batching API,
query rewrite, schema object, or dependency, and does not adopt the
benchmark-only homogeneous `field_id`-array prototype.

## Phase 5A BulkRead evidence

T086 characterizes the unchanged public `typed_eav_hash_for` path through real
Rails/Active Record models. The accepted artifact covers 100 records/1 scope
and 1,000 records at 1, 100, and 1,000 scopes, with 20 values per host, three
rotations, 12 warmups, and 120 measured observations. All six semantic controls
and independent result identities pass. SQL notification row counts are
complete, and no observation is censored, retried, imputed, mismatched, or
errored.

Median SQL statements rose from 3 at one scope to 102 at 100 scopes and 1,002
at 1,000 scopes. Median loaded rows and Active Record instantiations were 2,140,
20,140, 34,000, and 160,000 across the four cells. Wall-time p50 values were
52.074, 466.893, 949.885, and 5,284.589 ms respectively. These absolute times
are diagnostic co-tenant evidence: the Tailscale host continuously transcodes
video, and the artifact retains 18 anonymous pressure samples. The result
supports later bounded investigation of query/row/object growth, but authorizes
no cache, chunking, raw-row path, requested-field API, or production change.

T086 also establishes the prospective benchmark-runner contract without
rewriting historical runners. Local Ruby 3.4.4 is explicitly resolved and
verified; injected older-Ruby and validator failures prove rejection plus
hash-stable payload retention without accepted publication. The live remote
drill proves seven ordered cancellation stages, export before disposable DB
cleanup, transferred hashes, and zero leftovers. The representative run passed
resource caps, internal-only networking, read-only/writable-path boundaries,
anonymous existing-container invariance, deadline, image lifecycle, sealed
transfer, and exact cleanup. Artifact SHA-256:
`28a903902f806b9e3faa5a86a437790f35a049a3a6884df8eeb6e111888a90cb`.

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
| 2 | T032 scalar index experiment | Worker/Judge | done | Gate 1 + qualified host | Select partial covering `(field_id, value) INCLUDE (entity_id) WHERE value IS NOT NULL` | Three rotated representative trials; footprint, WAL, write and core-query plans | `5249d1c` | Apply NULL policy before migration |
| 2 | T034 NULL distributions | Worker | done | T025/T026/T033 | **Option B**: no automatic NULL index; targeted measured guidance only | Low/high NULL, five query shapes, bytes/WAL, three trials, exact cleanup | task commit | Concurrent partial-covering migration; Gate 2 |
| 2 | T036 scalar index migration | Worker | done | T034/T035 | Concurrent create-before-drop upgrade and recreate-before-remove rollback with exact catalog enforcement | Six partial-covering replacements, interrupted-run recovery, definition-drift rejection, packaged consumer up/down/up | task commit | Run Gate 2 integration review |
| 3 | T043–T045 string-search policy | Worker/Judge | done | Gate 2/T042 | Documentation-only, application-owned `pg_trgm` GIN evaluation; preserve shipped B-tree and public SQL | Three rotated PG17 trials; PG15/16/18 lifecycle-only logs; operator plans, write/storage costs, ADR 0009 | task commits | Close Phase 3; no installer, automatic index, GiST, or query change |
| 4 | T051–T053 extended statistics policy | Worker/Judge | done | T049 protocol | Documentation-only, application-owned evaluation of dependencies statistics; no gem schema/helper change | 10 trials, 50 paired blocks, 1,100 raw PG17 plans; ADR 0010; zero-row date disclosure | task commits | Evaluate only measured equality misestimates; continue multi-filter and cross-scope evidence |
| 4 | T062–T064 multi-filter query policy | Worker/Judge | done | T059 protocol | ADR 0011: retain chained `IN`; alternatives research-only; no adaptive strategy | 2,940 attempts; 622 censors; 294 oracles (282 completed, 12 timeout); false-zero derived buffers; repeated-field limits | task commits | Repair buffer/distinct-field evidence and complete cross-scope scaling before Gate 4 |
| 4 | T073–T076 corrective multi-filter evidence | Judge/Worker | done | ADR 0011/T062 audit | Preserve current chained `IN`; corrected evidence remains research-only and replacement-ineligible | 960 attempts; 620 censors; 96 oracles (81 completed, 15 timeout); 340 validated plans; exact distinct fields | task commit | Post-run Gate 4 review; no production or ADR change |
| 4 | T065–T072 cross-scope administrative policy | Scout/Workers/Judges | done | Phase 4C code-path analysis | ADR 0012: keep `unscoped` administrative; application-owned bounding/batching; no quantitative or prototype claim | T066/T069 representative artifacts rejected; local smoke is semantic-only; rejected harness removed | task commit | Keep production behavior unchanged; use consuming-workload evidence for operational bounds |
| 4 | Planner/query paths | PM/Workers | queued | Phase 3 policy | Compare statistics and multi-filter plans | Operator-specific benchmark evidence | — | Preserve scope and missing semantics |
| 5 | T086 BulkRead characterization | Worker | done | Gate 4/T083 | Preserve production path; characterize scope-driven query/row/object growth before optimization | 4-cell matrix; 12 warmups; 120 observations; exact SQL/rows/AR objects; real drill and cleanup | task commit | Review evidence before any cache/read-path design |
| 6–8 | Write/durability/cleanup | PM/Workers | queued | Gates 4/6 | Characterize semantics before optimizing | Profiles, failure proofs, ADRs | — | Preserve callbacks, versioning, tenant isolation |
| 9–12 | Tournament and documentation | PM/Workers | queued | Prior gates + host | Choose architecture only from fair benchmark | Comparable strategies and final ADRs | — | Final audit and full-outcome proof |

## Baseline commands and evidence policy

Run `bench/database_baseline.rb` against an isolated configured PostgreSQL database. It is read-only and reports empty-database caveats instead of fabricating measurements. The checked-in `bench/results/phase-0-baseline.json` is a real local PostgreSQL 17.7 capture from the empty `typed_eav_test` database; `/tmp/typed-eav-phase-0-baseline.json` is the reproducible verification artifact for this task.

No Phase 2 or tournament result may be treated as representative until a larger dedicated volume/host is available. Local PostgreSQL settings and cumulative `pg_stat_user_indexes` values are context, not cross-version CI evidence.

## Phase 2A smoke harness evidence

`bench/scalar_index_benchmark.rb` provides a benchmark-only smoke tier for the three scalar layouts: current covering `(field_id, value) INCLUDE (entity_id, entity_type)`, partial non-covering `(field_id, value) WHERE value IS NOT NULL`, and partial covering `(field_id, value) INCLUDE (entity_id) WHERE value IS NOT NULL`. It creates a uniquely prefixed disposable database, validates the prefix before cleanup, and records a post-drop proof. The deterministic seed-2201 dataset covers integer, decimal, boolean, date, datetime, and string values, with explicit NULL and missing-row controls. The checked-in result is smoke-only: it reports bytes, bytes/live logical value, insert/update and equality/range samples, WAL, EXPLAIN JSON, index-only indicators, and `pg_stat_user_indexes`, but does not select a layout, justify a NULL index, or authorize a migration. Representative tier execution is gated on an explicitly qualified environment.

The accepted harness streams deterministic rows directly into PostgreSQL and computes incremental per-candidate SHA-256 checksums without retaining the complete dataset in Ruby. Smoke projected and actual disposable-database ceilings remain 500 MiB. Representative creation requires `TYPED_EAV_REPRESENTATIVE_OK=1` and `max(30 GiB, projected footprint + 8 GiB)` free on the PostgreSQL data volume; evidence records the data directory, observed/required bytes, reserve, and qualification. The reserve is rechecked during execution, and an unqualified current host refuses before `CREATE DATABASE`.
### T091 bulk-write surface

T091 adds a separately named, explicitly acknowledged reduced-semantics bulk
upsert and opt-in chunked semantic transactions while preserving the default
transaction behavior. The benchmark protocol compares isolated insert and
update workloads, validates exact logical identity, and records callback,
version, SQL, resource, and transaction evidence. Local latency remains
single-session evidence and must not be read as an absolute production claim.
The reduced path retains cast/domain/entity/partition validation and validation
callbacks, requires one connection pool and the entity/field conflict target,
but skips host/Value persistence callbacks, host saves, versioning, and delete
shorthand. Semantic `:all` is one outer transaction with savepoint isolation;
`:chunks` repeats that envelope per chunk with earlier chunk commits durable.

### T092 bounded local bulk-write closure

T092 closes the available local Phase 6 evidence ceiling with an isolated
100/1,000-host tier. The local runner uses project Ruby 3.4.4, an explicit
unique `DATABASE_URL`, a 2 GiB disk floor, schema/current-database/table
identity checks, and an early cleanup trap. It never selects or mutates
`typed_eav_test`. The validated artifact contains 18 cells across insert,
update without versioning, and update with versioning for semantic, fast, and
chunked surfaces. Every cell has exact logical identity and semantic/chunk
parity. At 1,000 hosts, fast records 4 SQL statements and one typed-value
write versus 23,001/10,000 for non-versioned semantic/chunk paths; versioned
semantic/chunk paths record 63,001 statements and 10,000 audit rows, while
fast records zero audit rows. RSS is unsupported on the local macOS host and
WAL is supported. This is bounded local diagnostic evidence only: it does not
claim representative latency, production throughput, 10,000 hosts, or
100,000 values. The remote runner is statically corrected to use the unique
database through `DATABASE_URL` and a host-side tar-to-stdout export, but is
not executed by T092.
