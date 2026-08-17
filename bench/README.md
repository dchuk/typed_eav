# Database baseline

The remote runner records anonymous `docker system df` totals before and after execution. It may leave only public `postgres:17`/`ruby:3.4-bookworm` base images and BuildKit cache layers; it never prunes them or any unrelated resource. The run-labeled runner image, network, volume, containers, transfer archive, staging directory, and result copy are audited and removed.

The Linux runner image does not depend on the local lockfile: it installs and build-checks `pg` 1.6.3 explicitly, then invokes the benchmark with plain Ruby. The runner drops all capabilities, enables `no-new-privileges`, and limits PIDs; PostgreSQL retains its image defaults.

`database_baseline.rb` is a dependency-free, read-only PostgreSQL inventory. It boots the existing dummy Rails environment, reads PostgreSQL catalogs and `pg_stat_user_indexes`, and never creates tables, changes rows, runs `ANALYZE`/`VACUUM`, or resets shared statistics.

Run it against the configured test database:

```sh
RAILS_ENV=test bundle exec ruby bench/database_baseline.rb --output bench/results/phase-0-baseline.json
```

The JSON records server settings, relation and index sizes, exact index definitions and predicates, key/INCLUDE columns, estimated write cost and dependent TypedEAV query paths, row counts, typed-column non-NULL counts, and cumulative index statistics. `bytes_per_logical_value` is a coarse relation-footprint ratio: total `typed_eav_values` relation bytes divided by rows having at least one non-NULL typed value.

An empty database is an explicit valid result. Counts and sizes may be zero, and `bytes_per_logical_value` is `null`; no values are invented. Ordinary PostgreSQL B-tree indexes include rows with NULL key columns; partial-index predicates control participation, while INCLUDE columns do not. Statistics are cumulative and may be all zero on a fresh database.

## Phase 2A scalar-index smoke harness

`scalar_index_benchmark.rb` creates a uniquely named disposable PostgreSQL database with the `typed_eav_phase2_smoke_` prefix, validates that prefix before dropping it, and records a post-drop proof. It never connects to `typed_eav_test`. The smoke tier uses seed `2201`, 10,000 entities, six deterministic typed fields, repeated equality/range/update measurements, exact six-column DDL for each candidate, EXPLAIN JSON (`ANALYZE`, `BUFFERS`, `WAL`, `SETTINGS`), relation/index/database bytes, WAL, and `pg_stat_user_indexes`.

```sh
PATH=/Users/darrindemchuk/.rbenv/versions/3.4.4/bin:$PATH \
  RAILS_ENV=test bundle exec ruby bench/scalar_index_benchmark.rb \
  --tier smoke --seed 2201 --output /private/tmp/typed-eav-phase-2-scalar-smoke.json
```

Smoke results cannot select a layout, justify a NULL index, or authorize a migration. The checked-in T032 result is a qualified representative run, but remains relative co-tenant evidence only; it does not select a layout or authorize a migration. Representative execution refuses unless `TYPED_EAV_REPRESENTATIVE_OK=1` is explicitly configured.

The harness streams rows directly into PostgreSQL and computes incremental SHA-256 checksums, so candidate tables receive byte-for-byte equivalent logical rows without materializing the dataset in Ruby. Smoke projected and actual database sizes remain capped at 500 MiB. Representative execution additionally requires at least `max(30 GiB, projected footprint + 8 GiB)` free on the PostgreSQL data volume before `CREATE DATABASE`, records the data directory/free-space qualification, and rechecks the 8 GiB reserve while running. A refused representative attempt writes its qualification evidence and creates no database.

### Isolated representative Docker execution

`bench/docker/scalar-index/run_remote.sh` is the T032 standalone runner. It requires three consecutive read-only samples with at least 16 GiB available memory, at least 30 GiB plus the exact 1.785 GB projected footprint free on Docker root, and unchanged existing-container identity/state; continuous transcoding load is recorded as co-tenant contention and is never stopped or throttled. It then creates only unique, label-owned internal Docker objects. PostgreSQL is capped at 2 CPUs/8 GiB/256 shares and the runner at 1 CPU/2 GiB/128 shares, both with best-effort I/O weight 100 and memory-swap equal to memory. Three same-seed trials rotate candidate order; raw candidate timing windows, medians, primary insert/update dispersion, query dispersion, and anonymous telemetry are recorded. Primary throughput dispersion above 25% rejects the result; query jitter remains diagnostic. No host ports, host networking, privileged mode, socket/media mounts, restart policy, Compose, or existing object is permitted. The runner image is removed after label verification; public base images may remain cached. Results are explicitly co-tenant representative comparisons suitable for relative layout evidence, not clean-room absolute latency claims. Cleanup removes only exact label-owned containers, image, network, volume, and validated temporary paths, then audits zero run-labeled leftovers before result transfer.

The accepted seed-2201 representative result uses 100,000 entities and 595,000 rows per candidate across three rotated trials. All candidate checksums match the source checksum. Primary insert/update dispersion is 0.081888 relative population standard deviation (below the 0.25 acceptance threshold); query dispersion is 0.398261 and remains diagnostic rather than an acceptance gate. The result records anonymous host contention telemetry, PostgreSQL 17.11, the resource limits, and `post_cleanup_verified: true`. These measurements describe relative behavior under active co-tenants, not clean-room absolute latency, and no candidate is declared a winner.

### NULL-distribution follow-up

`null_index_benchmark.rb` narrows the Phase 2 NULL-policy question without changing application queries. It compares the selected partial-covering integer index with the same layout plus `(field_id, entity_id) WHERE integer_value IS NULL`. The six-type table shape is deliberate: under current query predicates, that NULL index also contains decimal, boolean, date, datetime, and string rows because their `integer_value` cell is NULL. The seed-3301 dataset has 100,000 hosts, 5,000 missing integer rows, and either 1% or 50% explicit NULL among the 95,000 present integer rows. It measures explicit stored NULL, `eq nil`, NULL-inclusive `not_eq`, `is_not_null`, and `include_missing`, plus index/relation bytes and insert/NULL-transition WAL.

Run the isolated T034 comparison with:

```sh
bench/docker/scalar-index/run_remote_null.sh
```

The runner creates only uniquely named, T034-labeled resources on the configured SSH host. It uses the same CPU, memory, I/O, network, privilege, headroom, telemetry, invariant, and exact-cleanup boundaries as the representative scalar runner. Three same-seed trials rotate candidate order. The committed artifact is `bench/results/phase-2-null-distributions.json`; its schema/checksum checks, existing-container invariant, and post-cleanup audit pass.

The result supports Option B: ship no automatic NULL index, retain partial-covering scalar indexes as the default, and document a targeted application-owned NULL index only for a measured low-NULL workload dominated by explicit-NULL probes. At 1% logical NULL, the extra index reduced median root-plan buffers for explicit NULL and `eq nil` by 83.4%, but increased total index bytes 37.5% and insert WAL 28.7%. At 50% logical NULL it increased those query buffers 84.4%, index bytes 43.4%, and insert WAL 32.4%. It did not improve `is_not_null` or `include_missing`, and increased NULL-inclusive `not_eq` buffers in both distributions. Absolute timings remain diagnostic under continuous co-tenant transcoding.

## Phase 3 string-search benchmark

`string_search_benchmark.rb` compares the shipped partial-covering `text_pattern_ops` B-tree with additive lower-expression B-tree and partial `pg_trgm` GIN candidates. GiST remains smoke-only. The unchanged public predicates are measured separately from the prototype: equality uses `=`, positive string operators use `ILIKE`, `not_contains` uses `NOT ILIKE`, and `lower(string_value) LIKE ...` is explicitly not presented as serving public `ILIKE`.

Seed 4401 supplies 250,000 target-field rows and 250,000 noise-field rows per candidate with deterministic skew. It includes equality, prefix, contains, suffix, negative, escaped `%`/`_`, and one/two-character controls. Candidate and per-operator entity-ID checksums must agree. Plans use `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON)` and include nodes, indexes, buffers, heap fetches, sizes, build time/WAL, and indexed insert/update throughput/WAL.

```sh
PATH=/Users/darrindemchuk/.rbenv/versions/3.4.4/bin:$PATH \
  ruby bench/string_search_benchmark.rb \
  --tier smoke --seed 4401 --output /private/tmp/typed-eav-phase-3-string-smoke.json

bench/docker/string-search/run_remote.sh
```

The isolated runner first proves least-privilege `pg_trgm` availability, install, idempotent create, update, drop, and recreate/drop on PostgreSQL 15, 16, and 18, retaining checksummed version-tagged startup logs. PostgreSQL 18 mounts its owned volume at `/var/lib/postgresql`; 15/16 use `/var/lib/postgresql/data`. Only then does it run three rotated PostgreSQL 17 trials. Unique T043 labels, an internal network, conservative resource caps, continuous headroom/no-impact checks, and exact cleanup isolate the run; it uses no published ports, host networking, Compose, privileged mode, restart policy, Docker socket, or media bind.

The accepted artifact is `bench/results/phase-3-string-search-representative.json`. Primary dispersion was 0.150653, below the 0.25 gate without a rerun. Public PostgreSQL 17 plans used GIN for `starts_with`, `contains`, `ends_with`, and escaped-literal patterns with extractable trigrams, but not `not_contains` or one/two-character probes. Equality retained the shipped index-only B-tree plan. The additive lower B-tree was used only by the separate lower/LIKE prototype, which is not the public `ILIKE` contract. GiST remained smoke-only and is not authorized.

ADR 0009 selects documentation-only, application-owned evaluation. `pg_trgm` is not a dependency, required extension, installer feature, or automatic index. An application considering it should first reproduce its actual pattern lengths, selectivity, field distribution, and concurrency, then compare `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)`, index/total relation bytes, build and write WAL, insert/update throughput, and maintenance cost. PostgreSQL 17 plan choices do not establish behavior on other versions; the PostgreSQL 15/16/18 lanes exercised extension lifecycle only. Absolute timing under continuous co-tenant transcoding is diagnostic, not a headline latency claim.

The measured additive candidate was:

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'pg_trgm';

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX CONCURRENTLY app_te_values_string_trgm
ON typed_eav_values USING gin (string_value gin_trgm_ops)
WHERE string_value IS NOT NULL;
```

Run this only from a consuming application's nontransactional migration after verifying the target service exposes `pg_trgm` and the deploy role has permission. Use a stable application-owned name and validate the resulting catalog definition. On rollback, use `DROP INDEX CONCURRENTLY IF EXISTS app_te_values_string_trgm`; retain the database-wide extension because other indexes or applications may depend on it. Interrupted concurrent builds can leave an invalid index and must be detected and repaired before retry. A narrower per-field partial index is an application-specific experiment, not a benchmarked recommendation.

The operator boundary is deliberate: `=` stays on the shipped B-tree; positive `ILIKE` prefix/contains/suffix searches are candidates only when their literals yield useful trigrams and their selectivity makes the plan worthwhile; escaped `%`/`_` probes benefited only when the remaining literal did so. GIN did not serve `NOT ILIKE` or one/two-character probes, and the evidence does not promise it for every positive or high-match query.

Versus the current B-tree candidate, the additive GIN increased median candidate index bytes 61.417% and build WAL 50.293%. Median insert/update throughput fell 56.995%/58.060%, while insert/update WAL rose 156.499%/195.441%. The artifact retains full raw plans, checksums, sizes, and build measurements for trial 1, plus cross-trial metric arrays and rotation metadata. Raw trial 2/3 plans, checksums, sizes, and build times were not retained, so those claims are not independently auditable from this artifact; rerun the harness for application decisions.

## Phase 5A BulkRead characterization

`bulk_read_benchmark.rb` measures the existing public
`Model.typed_eav_hash_for(materialized_hosts)` path without changing production
code or adding a cache. The semantic gate covers global/scope/full-tuple
precedence, explicit NULL versus a missing row, multi-cell Currency values,
orphan skipping, and the public integer-keyed hash shape. An independent
per-record identity oracle must match every warmup and observation.

The representative matrix fixes 20 integer values per host and runs 100
records/1 scope plus 1,000 records at 1, 100, and 1,000 scopes. Three cyclic
workload rotations each contain one warmup and ten measured calls with the
Active Record query cache disabled. The artifact retains exact SQL and binds,
notification row counts, Active Record instantiations, Ruby allocations,
ObjectSpace deltas, RSS, GC count/time, wall time, dataset/result identities,
relation sizes, and runtime versions. Host materialization occurs before each
measurement.

```sh
bench/docker/bulk-read/run_remote.sh

PATH=/Users/darrindemchuk/.rbenv/versions/3.4.4/bin:$PATH \
  ruby bench/validate_bulk_read_artifact.rb \
  bench/results/phase-5-bulk-read-representative.json
```

The accepted PostgreSQL 17.11, Ruby 3.4.4, Rails 8.1.3.1 artifact contains 120
measured observations and 12 warmups with no censored/error or semantic
mismatch. Median statement/returned-row/AR-instantiation counts were 3/2,140/
2,140 at 100 records/1 scope, 3/20,140/20,140 at 1,000/1, 102/34,000/34,000 at
1,000/100, and 1,002/160,000/160,000 at 1,000/1,000. Corresponding wall-time
p50/p95/p99 values were 52.074/62.988/64.647 ms, 466.893/515.471/534.044 ms,
949.885/1,165.825/1,304.299 ms, and 5,284.589/5,727.954/5,910.779 ms.

These are characterization results, not optimization targets or clean-room
latency claims. The host was continuously transcoding video; 18 anonymous
pressure samples accompany the run. Whole-process RSS/ObjectSpace and
instrumentation overhead limit absolute interpretation. The evidence shows
query count and loaded-row/object growth with scope cardinality; it does not
authorize caching, raw-row loading, chunking, a requested-fields API, or a
production implementation change.

The T086 runner prospectively uses the shared benchmark contract: it pins and
verifies local Ruby 3.4.4, rejects an interpreter mismatch, preserves a
hash-verified transferred payload before local validation, and publishes the
accepted artifact only after validation. Its real task-owned cancellation drill
records seven ordered stages, observes and terminates a live disposable
PostgreSQL session, seals/exports evidence before dropping the drill database,
and audits cleanup. The representative workflow uses only labeled internal
Docker resources, read-only runner roots with four bounded writable paths, no
ports or media mounts, fixed caps, anonymous before/after container hashes, and
exact post-transfer cleanup. The artifact SHA-256 is
`28a903902f806b9e3faa5a86a437790f35a049a3a6884df8eeb6e111888a90cb`.

## Phase 4A planner extended statistics

`planner_statistics_benchmark.rb` measures field/value cardinality estimates without changing production schema or queries. Seed `4601` generates 300,000 entities and deterministic uniform plus skewed integer, string, and date fields; unrelated field-family rows retain NULL typed cells. The preregistered representative protocol fixes `default_statistics_target`, the four relevant column targets, and every extended-statistics target at 100. Its ten-sequence Williams schedule runs 50 blocks across baseline, dependencies, MCV, ndistinct, and their combination.

Each block performs exactly one `ANALYZE`. An extended candidate is planned first, its statistics objects are dropped without another `ANALYZE`, an exact `pg_stats` hash proves the ordinary sample unchanged, and the paired base plans are then captured. Baseline blocks capture two base suites. The retained artifact contains 1,100 raw JSON plans for 11 public field/value predicates, exact DDL, ANALYZE cost, catalog metadata, targets, checksums, zero classes, signed/absolute/relative/log errors, and paired plan signatures.

Run a local smoke block with:

```sh
TYPED_EAV_TRIAL=1 \
TYPED_EAV_CANDIDATE_ORDER=baseline,dependencies,dependencies_mcv_ndistinct,mcv,ndistinct \
bundle exec ruby bench/planner_statistics_benchmark.rb \
  --tier smoke --seed 4601 --output /tmp/planner-statistics-smoke.json
```

The authorized runner is `bench/docker/planner-statistics/run_remote.sh`. It uses only T051-labeled internal Docker objects, resource caps, an owned output volume, closed-file SHA-256 manifests, explicit tar streaming, unchanged existing-container checks, and exact cleanup. Absolute co-tenant timing is diagnostic. PostgreSQL 17 is the only planner evidence, classifications may be inconclusive, and mechanical completeness—not a favorable result—accepts the artifact.

ADR 0010 selects documentation-only, application-owned evaluation. TypedEAV
does not install an extended-statistics object or ship a migration, generator,
or helper. The statistics kinds answer different questions: `dependencies` can
adjust compatible equality and `IN` estimates for correlated columns but does
not apply to ranges; `mcv` stores frequencies for common column combinations;
and `ndistinct` estimates distinct combinations, principally for grouping. In
the representative result, matching MCV groups supplied all four estimates that
changed under the combined object, so it mirrored MCV rather than the
dependencies-only aggregate result.

The artifact also preserves a mislabeled zero-row probe.
`date_skewed_common_eq` queried `2024-01-01`, but generated common dates begin at
`2024-01-02`. Treat it as absent-date estimation evidence, not common-date
evidence. Do not infer execution-time or plan improvement: no candidate changed
plan shape, introduced a sequential scan, or lost an index-only plan. The plans
come only from PostgreSQL 17, and target 100 was a fixed experimental control,
not a universal recommendation.

An application investigating a demonstrated integer-equality misestimate can
start with application-owned DDL in a representative preproduction database:

```sql
CREATE STATISTICS app_te_values_field_integer_dependencies (dependencies)
ON field_id, integer_value
FROM typed_eav_values;

ALTER STATISTICS app_te_values_field_integer_dependencies
SET STATISTICS <application-selected-target>;

ANALYZE typed_eav_values;
```

Test only the typed columns and statistics kinds implicated by real queries.
Compare a before/after corpus with `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)`,
estimated versus actual rows, planning/execution time, workload latency,
`ANALYZE` duration, catalog size, and maintenance cost. Repeat after realistic
data churn and for each operated PostgreSQL version. Creation does not populate
the object until `ANALYZE` runs.

The application owns stable names, target selection, DDL timing, and removal.
Inspect `pg_statistic_ext` and, when permitted, `pg_statistic_ext_data` to verify
table, columns, kinds, owner, target, and collected data. In a shared database,
coordinate one owner; never change or remove another application's object based
on its name alone. Roll back only the verified application-owned object, then
refresh and remeasure the baseline:

```sql
DROP STATISTICS IF EXISTS app_te_values_field_integer_dependencies;
ANALYZE typed_eav_values;
```

## Phase 4B multi-filter query shapes

`multi_filter_benchmark.rb` compares the shipped chained host `IN` shape with
`INTERSECT`, correlated `EXISTS`, and direct grouped `HAVING` where the latter
can preserve semantics. Seed `4502` fixes 100,000 primary hosts, more than 50
field definitions, nominally 20 values per host, 25 scenarios, three cyclic
strategy rotations, and ten attempts per eligible strategy group. The corpus
covers 1/3/10/20-filter high-, low-, mixed-, and skewed-selectivity workloads,
plus scope resolution, shadowing, polymorphic hosts, NULL, missing values,
duplicate internal matches, empty filters, and error controls.

Each of the 2,940 measured attempts uses a uniform 1,000 ms
`statement_timeout`. A SQLSTATE 57014 result is retained as a Type-1
right-censored lower bound, never retried or imputed. Only after all ten
attempts does the group run one non-retried 5,000 ms sorted host-identity
oracle. Representative oracle timeouts retain null identity and mean
`unproved_timeout`; they neither prove nor disprove equivalence. The embedded
2,000-host smoke completed all 98 eligible oracles with equal identities.

The representative artifact retained 2,940 attempts, 294 oracle outcomes, 75
scenario/trial summaries, 622 censored attempts, and 64 first-timeout fallback
plans. Of the representative oracles, 282 completed and 12 timed out; none
mismatched or errored. Therefore representative equivalence is not proven,
production replacement is ineligible, and current SQL is retained. These are
mechanically complete co-tenant PostgreSQL 17 results, not an authorization to
change production queries. The artifact is
`bench/results/phase-4-multi-filter-representative.json`; the isolated Tailscale
runner is `bench/docker/multi-filter/run_remote.sh`.

ADR 0011 retains chained host `IN` as the production strategy. `INTERSECT` and
correlated `EXISTS` are research-only. Direct grouped `HAVING` is additionally
ineligible for missing/host-universe complement and empty-filter contracts.
There is no adaptive strategy. Although all 282 completed representative
oracles matched, the 12 timeouts have null identities and remain unproved; the
98 equal smoke identities do not promote them to representative equivalence.
The alternatives strongly improved `high_10`, but `mixed_10` regressed and
large low/mixed/skewed cases were commonly censored or inconclusive, so the run
does not establish a general winner.

Do not use the artifact's derived buffer totals. They are false zeros caused by
an extractor that split each multiword EXPLAIN block key into individual words.
The 2,318 retained raw plans contain nonzero block counters and remain
recoverable for a corrected, source-validated extraction. Workload names also
describe predicate count, not always distinct-field count: 20-predicate cases
repeat ten fields, while `skewed_10` and `skewed_20` repeat five. This evidence
therefore proves neither valid zero-buffer behavior nor 20-distinct-field
scaling. PostgreSQL 17 co-tenant plans and diagnostic timings do not establish
other-version or clean-room behavior.

The bounded corrective artifact repairs those two evidence defects without
replacing the historical artifact. It measures only high/low/mixed/skewed ×
10/20, with exactly one distinct field definition per predicate. Across three
rotations it retains 960 attempts, 96 representative oracles, and 24 summaries.
Of those attempts, 340 completed and 620 were right-censored; 63 groups retain
a matching non-ANALYZE fallback plan. Of the oracles, 81 completed and 15 timed
out with null identity; no completed oracle mismatched and no oracle errored.
The historical smoke completed 98/98 eligible identities and the corrective
smoke completed 32/32.

`validate_multi_filter_corrective_artifact.rb` inflates every completed raw
plan, verifies its SHA-256, and independently recomputes the ten exact root
keys for shared, local, and temporary block counters. All 340 completed plans
had at least one nonzero counter, proving the extractor no longer reports the
historical false zeros. Independent duplicate-field, altered-buffer,
missing-plan, and corrupted-hash mutations were all rejected. The artifact is
`bench/results/phase-4-multi-filter-corrective-representative.json`; the runner
is `bench/docker/multi-filter-corrective/run_remote.sh`.

The corrective result still has `representative_equivalence_proven=false`,
`production_replacement_eligible=false`, and `retain_current_sql=true`. It is
co-tenant PostgreSQL 17 research evidence for later Gate 4 review, not an
adaptive or production authorization. Its one official Ruby base-image pull
was digest/version verified, the build disabled pulling, and the introduced
tag and image ID were removed after export without pruning.

Any future adaptive or replacement experiment must pre-register and pass the
full gate in [ADR 0011](../docs/adr/0011-multi-filter-query-strategy.md):
identical resolution and full scope/shadowing/operator/NULL/missing/complement/
polymorphic/duplicate/empty/error semantics; completed equal identity oracles
for every representative eligible group; actual 10- and 20-distinct-field
families; corrected raw-plan-validated buffer totals; uncensored >=20% p95 wins
at both 10 and 20 filters in at least three families; and bounded, pre-specified
planning, buffer, and plan-shape regressions. Cross-scope high-cardinality
planning is still required before Gate 4. Any claim beyond PostgreSQL 17 also
requires evidence on the PostgreSQL versions for which it is made.
### T091 bulk-write characterization

`bulk_write_benchmark.rb` compares the unchanged semantic writer with the
explicitly acknowledged reduced-semantics `bulk_upsert` and opt-in chunked
semantic transactions. The protocol records isolated insert and update
workloads, exact logical checksums, callback/version/result evidence, SQL
counts, allocations, GC, RSS/WAL support, and semantic/chunk parity. Fast
upsert intentionally omits host callbacks and version rows; callers must opt
into that reduced contract. Local timing is single-session evidence and is not
an absolute latency claim. The representative wrapper uses the shared T086
runner contract and does not repeat its cancellation drill.

Fast upsert validates casting, domain/entity/partition constraints, and Value
validation callbacks, but intentionally skips host persistence callbacks,
Value persistence callbacks, versioning, and delete shorthand. It requires the
host, Value, and Field pools to match and targets the entity/field conflict
index. Semantic `:all` keeps one outer transaction with per-record savepoints;
`:chunks` repeats that envelope per chunk, so prior chunks survive later errors.

### T093 SQL-narrowed default backfill

`Field::Base#backfill_default!` retains its all-host default path and accepts
an optional exact-host `ActiveRecord::Relation` for SQL narrowing. It rejects
non-relations and relations whose model is not the field's exact entity class;
it does not infer a scope column from `scope_method`. Backfill still performs
the same partition checks, batch transactions, callbacks, validations,
idempotent skip behavior, and error propagation.

Logical missingness is owned by `Field::TypedStorage`: a value is missing only
when every declared physical cell is nil. Thus a fully empty Currency value is
backfilled, while a partially populated amount/currency pair is preserved.
The rejected T099 benchmark package has been withdrawn. The clean f1d4cb9
commit therefore has behavioral support for this API and missingness semantics,
but no accepted comparative-performance or throughput evidence. A fair
default-versus-SQL-narrowed measurement over equivalent total populations is
deferred to T100; no local scaling result should be used as a performance claim.

### T092 bounded local bulk-write evidence

`bench/docker/bulk-write/run_local.sh` creates one exact-prefix disposable
PostgreSQL database, verifies `current_database()` and the required TypedEAV
tables, runs the dummy Rails configuration through an explicit `DATABASE_URL`,
and drops the database from an early cleanup trap. It refuses below a 2 GiB
source-volume floor and never selects or mutates `typed_eav_test`.

The bounded `--tier bounded` protocol measures 18 cells: hosts_100 and
hosts_1000 crossed with insert/versioning-off, update/versioning-off, and
update/versioning-on across semantic, fast, and chunks. Every cell has exact
logical digest and semantic/chunk identity. At 1,000 hosts, fast uses 4 SQL
statements and one typed-value write versus 23,001/10,000 for non-versioned
semantic/chunks; versioned semantic/chunks use 63,001 statements and produce
10,000 audit rows, while fast produces zero. RSS is unsupported on macOS; WAL
is available. These are local single-session diagnostics, not representative
or production-throughput claims.
