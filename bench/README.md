# Database baseline

`database_baseline.rb` is a dependency-free, read-only PostgreSQL inventory. It boots the existing dummy Rails environment, reads PostgreSQL catalogs and `pg_stat_user_indexes`, and never creates tables, changes rows, runs `ANALYZE`/`VACUUM`, or resets shared statistics.

Run it against the configured test database:

```sh
RAILS_ENV=test bundle exec ruby bench/database_baseline.rb --output bench/results/phase-0-baseline.json
```

The JSON records server settings, relation and index sizes, exact index definitions and predicates, key/INCLUDE columns, estimated write cost and dependent TypedEAV query paths, row counts, typed-column non-NULL counts, and cumulative index statistics. `bytes_per_logical_value` is a coarse relation-footprint ratio: total `typed_eav_values` relation bytes divided by rows having at least one non-NULL typed value.

An empty database is an explicit valid result. Counts and sizes may be zero, and `bytes_per_logical_value` is `null`; no values are invented. Ordinary PostgreSQL B-tree indexes include rows with NULL key columns; partial-index predicates control participation, while INCLUDE columns do not. Statistics are cumulative and may be all zero on a fresh database.
