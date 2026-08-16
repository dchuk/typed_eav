# ADR 0010: Application-owned evaluation of planner statistics

## Status

Accepted

## Context

TypedEAV stores many logical fields in one physical table. A predicate such as
`field_id = 42 AND integer_value = 7` can therefore violate the planner's
default assumption that the two columns are independent. PostgreSQL extended
statistics can describe a column group in three different ways:

- `dependencies` describes functional dependencies between columns. PostgreSQL
  can use it for compatible equality and `IN` clauses, but not range clauses.
- `mcv` stores frequencies for common combinations of values. It can help when
  a queried combination is represented in that list.
- `ndistinct` estimates the number of distinct column combinations. It is
  principally relevant to grouping cardinality, not the field/value `WHERE`
  predicates exercised here.

The Phase 4A benchmark created a separate object for each tested typed column,
paired with `field_id`, and compared `dependencies`, `mcv`, `ndistinct`, and a
combined object. Its deterministic 300,000-entity dataset ran ten trials and 50
paired blocks on PostgreSQL 17.11. The target of 100 controlled this experiment;
it is not a recommended target for every database.

Dependencies improved aggregate equality-estimate accuracy in this synthetic
workload, but did not apply to ranges. The combined object did not reproduce the
dependencies-only aggregate result: for the four probes whose estimates
changed, matching MCV groups supplied the estimate, so the combined candidate
mirrored MCV instead. `ndistinct` did not change these `WHERE` estimates. No
candidate changed a plan shape, introduced a sequential scan, or lost an
index-only plan, and the experiment does not demonstrate execution-time benefit.

One preregistered probe was mislabeled. `date_skewed_common_eq` queried
`2024-01-01`, while the generated common dates begin at `2024-01-02`; the probe
matched zero rows. It is absent-date estimation evidence, not common-date
evidence. The retained artifact remains mechanically valid and discloses the
query and row count, so it is not rewritten.

## Decision

TypedEAV will not create extended-statistics objects automatically and will not
ship a migration, generator, or helper for them. Production schema, queries, and
installation behavior remain unchanged.

An application may evaluate application-owned `dependencies` statistics when
its own plans show persistent field/value equality misestimates. The application
must choose the typed columns and target from its workload; it must not copy the
benchmark's target of 100 as a universal setting. `mcv`, `ndistinct`, or a
combined object require their own workload evidence and must not be added merely
because PostgreSQL supports them.

For example, an application investigating integer equality could test an
application-specific object in a representative preproduction database:

```sql
CREATE STATISTICS app_te_values_field_integer_dependencies (dependencies)
ON field_id, integer_value
FROM typed_eav_values;

ALTER STATISTICS app_te_values_field_integer_dependencies
SET STATISTICS <application-selected-target>;

ANALYZE typed_eav_values;
```

Creation alone does not populate statistics; `ANALYZE` is required. Compare the
same representative queries before and after with `EXPLAIN (ANALYZE, BUFFERS,
WAL, SETTINGS)`, checking estimated versus actual rows, plan shape, planning and
execution time, and workload-level latency. Also measure `ANALYZE` duration,
catalog size, and maintenance effects. Repeat after realistic data churn and on
every PostgreSQL version the application operates. Keep an object only when the
observed benefit justifies those costs.

The consuming application owns the DDL, stable names, deployment timing, and
rollback. Before creating or dropping anything, inspect `pg_statistic_ext` and,
when the role is permitted to read it, `pg_statistic_ext_data`; verify the name,
table, columns, kinds, owner, and target. In a database shared by multiple
applications, coordinate a single owner and do not alter or drop a statistics
object merely because its name looks familiar. Removal is explicit and followed
by another measurement cycle:

```sql
DROP STATISTICS IF EXISTS app_te_values_field_integer_dependencies;
ANALYZE typed_eav_values;
```

Dropping the object removes the extended data; the follow-up `ANALYZE` refreshes
ordinary statistics for a comparable post-removal baseline. Schedule creation,
`ANALYZE`, and removal according to the application's table size and operational
constraints rather than assuming the benchmark's costs transfer.

## Consequences

- TypedEAV adds no schema object or maintenance cost for applications that have
  not demonstrated a planner-estimation problem.
- Applications can test the narrow `field_id`/typed-column correlation without
  changing TypedEAV query semantics.
- Application owners must evaluate targets, PostgreSQL versions, data
  distributions, and operational costs themselves.
- Phase 4A remains bounded PostgreSQL 17 synthetic evidence. It supports this
  evaluation policy, not a claim of runtime improvement or general planner
  behavior.
