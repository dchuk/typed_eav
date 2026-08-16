# ADR 0008: Partial-covering scalar indexes

## Status

Accepted

## Context

Each `typed_eav_values` row has one applicable typed cell and normally leaves
the other typed cells NULL. The shipped scalar indexes are full B-trees on
`(field_id, typed_value)` with `INCLUDE (entity_id, entity_type)`, so every
scalar index maintains many rows that cannot satisfy a non-NULL typed query.

The representative scalar comparison selected a partial-covering layout as
the balanced default. The follow-up NULL comparison tested whether dropping
NULL entries required an automatic replacement index. It used 100,000 hosts,
six typed field families, 5,000 missing integer rows, and both 1% and 50%
explicit NULL among present integer rows. Three same-seed trials ran under
resource-capped co-tenancy; decisions use relative plans, buffers, storage,
and WAL rather than absolute latency.

## Decision

Replace the six scalar indexes with:

```sql
(field_id, typed_value) INCLUDE (entity_id)
WHERE typed_value IS NOT NULL
```

The string index retains `text_pattern_ops`. The migration uses these stable
names:

- `idx_te_values_field_int_present`
- `idx_te_values_field_dec_present`
- `idx_te_values_field_date_present`
- `idx_te_values_field_dt_present`
- `idx_te_values_field_bool_present`
- `idx_te_values_field_str_present`

Do not ship automatic typed NULL indexes. Applications with a measured,
low-NULL workload dominated by explicit-NULL or `eq nil` probes may evaluate a
targeted concurrent index such as:

```sql
CREATE INDEX CONCURRENTLY app_te_values_integer_null
ON typed_eav_values (field_id, entity_id)
WHERE integer_value IS NULL;
```

That guidance is opt-in and requires application-specific `EXPLAIN (ANALYZE,
BUFFERS)` and write/storage measurements. Under current query semantics, the
predicate also indexes every logical value stored in another typed column.

## Evidence

The partial-covering scalar layout reduced total relation bytes 54.6%, all
index bytes 67.2%, insert WAL 61.3%, and improved insert/update throughput
76.9%/131.1% relative to the shipped covering layout while preserving the
core non-NULL equality/range plan shape.

In the NULL follow-up, an additional integer NULL index contained 500,947 of
595,000 rows at low logical NULL and 547,737 at high logical NULL. At low NULL,
it reduced explicit-NULL and `eq nil` median root-plan buffers 83.4%, but added
37.5% index bytes and 28.7% insert WAL. At high NULL, it increased those query
buffers 84.4%, index bytes 43.4%, and insert WAL 32.4%. It increased
NULL-inclusive `not_eq` buffers in both distributions and did not change
`is_not_null` or `include_missing` plans. The raw evidence is in
`bench/results/phase-2-scalar-representative.json` and
`bench/results/phase-2-null-distributions.json`.

## Migration consequences

The upgrade migration must be nontransactional and use concurrent index DDL.
It creates all six new indexes before dropping any legacy scalar index, so an
upgrade does not open a core-query coverage gap. The down path recreates every
legacy `(field_id, typed_value) INCLUDE (entity_id, entity_type)` index before
removing its partial-covering replacement. Shipped migrations remain
unchanged, rollback is explicit, and no NULL index is created or dropped.
