---
title: "Storage and performance"
---

# Storage and performance

[Documentation home](../index.md)

## Why Typed Columns?

JSONB is a useful fit when an application owns stable paths and wants expression B-tree indexes or GIN containment indexes. A single JSONB document is not inherently faster or slower than TypedEAV; the right choice depends on access patterns, selectivity, update shape, and operational constraints. For example, an application-owned expression index may support a stable path:

```sql
CAST(value_meta->>'const' AS bigint) = 42
```

This can work well for stable, known paths. It does not provide the same column-level schema and typed-value contract as TypedEAV, and arbitrary paths still require application-owned index and validation decisions. GIN is useful for containment workloads; expression B-trees are useful for selected stable scalar paths.

TypedEAV stores values in native columns, so queries become:

```sql
WHERE integer_value = 42
```

TypedEAV supplies stable typed columns and ordinary per-type indexes. Range scans and sorts can use those indexes, while each Field casts and validates the operand according to its own semantics before the query reaches the typed column. Neither design is a universal storage winner; choose from measured workload fit.

### Optional trigram indexing for string search

TypedEAV keeps its partial-covering `text_pattern_ops` B-tree as the default
string index. Equality uses that B-tree, while `:starts_with`, `:contains`, and
`:ends_with` use `ILIKE`; `:not_contains` uses `NOT ILIKE`. The gem does not
require or install `pg_trgm` and does not create a trigram index automatically.

An application with frequent positive `ILIKE` searches containing at least
three useful characters may evaluate its own partial GIN index. This is a
workload decision: the representative benchmark used GIN for measured prefix,
contains, suffix, and escaped-literal patterns, but not for `NOT ILIKE` or
one/two-character probes. It does not prove that every positive pattern or
selectivity will benefit. A `lower(string_value) LIKE ...` expression index is
not equivalent to TypedEAV's public `ILIKE`, and the benchmark did not justify
GiST.

Application owners should check extension availability and deploy-role
privileges in preproduction, then create the extension and index in their own
migrations. Use nontransactional `CREATE INDEX CONCURRENTLY`, a stable
application-specific name, and workload-specific `EXPLAIN (ANALYZE, BUFFERS,
WAL, SETTINGS)` plus storage and write-WAL measurements. Rollback should drop
only the application-owned index concurrently; do not drop the database-wide
extension because other objects may share it. See
[ADR 0009](../adr/0009-string-search-indexing.md) and the
[benchmark guide](https://github.com/dchuk/typed_eav/blob/main/bench/README.md#phase-3-string-search-benchmark) for the
operator matrix, measured costs, SQL, and evidence limits.

### Optional planner statistics for correlated field/value predicates

TypedEAV does not install PostgreSQL extended-statistics objects. An application
whose own plans persistently misestimate `field_id = ... AND typed_value = ...`
may evaluate application-owned `dependencies` statistics for that exact typed
column. Dependency statistics apply to compatible equality and `IN` clauses,
not range predicates. `mcv` describes common value combinations, while
`ndistinct` primarily informs distinct-group estimates; neither should be added
without workload evidence.

The representative PostgreSQL 17 benchmark found better aggregate equality
estimates from dependencies, but no plan-shape or demonstrated runtime benefit.
Its combined object mirrored MCV on the four changed probes because matching MCV
groups supplied those estimates. The experiment's target of 100 was a controlled
input, not a universal recommendation. One probe labeled common-date equality
actually queried an absent date and returned zero rows; it is not evidence about
common-date estimates.

Applications should own stable names and DDL, select targets from representative
data, run `ANALYZE`, and compare estimated/actual rows, plans, runtime, planning
cost, maintenance cost, and data churn before retaining an object. Coordinate
ownership in shared databases, inspect catalog definitions before changing
objects, and drop only application-owned statistics during rollback. See
[ADR 0010](../adr/0010-planner-statistics-policy.md) and the
[benchmark guide](https://github.com/dchuk/typed_eav/blob/main/bench/README.md#phase-4a-planner-extended-statistics) for safe
evaluation SQL and evidence limits.

### Multi-filter query strategy

TypedEAV retains its current multi-filter query shape: it resolves each field,
builds the corresponding typed value subquery, and chains those results onto
the host relation with `id IN (...)`. There is no adaptive strategy or alternate
production query API.

A PostgreSQL 17 benchmark compared the shipped shape with `INTERSECT`,
correlated `EXISTS`, and direct grouped `HAVING` under resource-capped
co-tenancy. The run retained 2,940 attempts, including 622 right-censored
timeouts, and 294 representative identity oracles. Twelve oracles timed out, so
representative equivalence is unproved even though all 282 completed oracles
matched and the smaller 98-oracle smoke matched. Alternatives remain
research-only. Grouped `HAVING` is additionally ineligible for missing-value,
host-universe complement, and empty-filter semantics.

The result also does not establish valid buffer comparisons or 20-distinct-
field scaling. A parser defect made every derived buffer total a false zero;
nonzero counters remain recoverable from the retained raw plans. The
20-predicate workloads repeat ten fields, and the skewed 10/20 workloads repeat
five. Future research must repair and validate buffer extraction, exercise
actual 10/20 distinct fields, complete every representative equivalence oracle,
cover the full scope/NULL/missing/polymorphic/error contract, and show the
pre-registered p95, planning-time, buffer, and plan-shape gates before any
adaptive or replacement proposal. See
[ADR 0011](../adr/0011-multi-filter-query-strategy.md) and the
[benchmark guide](https://github.com/dchuk/typed_eav/blob/main/bench/README.md#phase-4b-multi-filter-query-shapes).
