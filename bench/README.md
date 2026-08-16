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
