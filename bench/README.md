# Database baseline

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

Every checked-in result is smoke-only and cannot select a layout, justify a NULL index, or authorize a migration. A representative run refuses unless `TYPED_EAV_REPRESENTATIVE_OK=1` is explicitly configured; a qualified larger host and sizing evidence remain required.
