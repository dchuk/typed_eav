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
