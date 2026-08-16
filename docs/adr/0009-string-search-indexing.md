# ADR 0009: Application-owned trigram indexes for measured string workloads

## Status

Accepted

## Context

TypedEAV's public string operators use three distinct SQL contracts: equality
uses `=`, positive pattern operators use `ILIKE`, and `not_contains` uses
`NOT ILIKE`. The shipped partial-covering `text_pattern_ops` B-tree preserves
efficient equality. It does not make every `ILIKE` shape efficient.

The Phase 3 comparison kept those predicates unchanged while adding either a
`lower(string_value) text_pattern_ops` B-tree or a partial `pg_trgm` GIN index.
The deterministic dataset contained 250,000 target-field rows and 250,000
noise-field rows. Three candidate-order rotations ran on PostgreSQL 17.11
under resource-capped co-tenancy. Disposable PostgreSQL 15.19, 16.15, and 18.6
lanes tested extension lifecycle only; they are not planner evidence.

## Decision

Keep the shipped partial-covering B-tree and public SQL unchanged. TypedEAV
does not require `pg_trgm`, install it, create a trigram index, or provide an
installer or generator for one.

Applications whose measured workload is dominated by positive `ILIKE`
patterns with extractable trigrams may evaluate an application-owned partial
GIN index:

```sql
CREATE INDEX CONCURRENTLY app_te_values_string_trgm
ON typed_eav_values USING gin (string_value gin_trgm_ops)
WHERE string_value IS NOT NULL;
```

The decision is operator- and workload-specific:

| Public query | Shipped B-tree | Observed use of additive GIN | Policy |
| --- | --- | --- | --- |
| `eq` (`=`) | Index-only in the representative plan | Not needed | Retain the B-tree |
| `starts_with` (`ILIKE 'value%'`) | Not reliably pattern-indexed by this B-tree for public `ILIKE` | Used for the measured extractable pattern | Evaluate only with application plans/selectivity |
| `contains` (`ILIKE '%value%'`) | May scan/filter B-tree entries or the relation | Used for the measured extractable pattern | Primary candidate for workload-specific evaluation |
| `ends_with` (`ILIKE '%value'`) | Not suffix-indexed | Used for the measured extractable pattern | Evaluate only with application plans/selectivity |
| Escaped `%` and `_` literals | Semantics remain escaped `ILIKE` | Used when the remaining literal supplied trigrams | Do not infer support for every escaped pattern |
| `not_contains` (`NOT ILIKE`) | No selective negative-search guarantee | Not used | Do not recommend GIN as acceleration |
| One- or two-character probes | No useful trigram extraction | Not used | Do not recommend GIN as acceleration |

The separate `lower(string_value) LIKE ...` prototype used its expression
B-tree, but that predicate is not the public `ILIKE` contract. It does not
justify changing public semantics or assuming collation equivalence. GiST was
smoke-only and has no representative justification, so it is not recommended.

## Application ownership and deployment

Before deployment, the application owner must confirm `pg_trgm` is available
and that the deploy role may create it in the target database:

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'pg_trgm';

CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

The benchmark's non-superuser database owner could manage the extension on
stock PostgreSQL 15, 16, and 18. Hosted services may impose different
privileges, so this is a preproduction check, not a portability promise.

The consuming application should own a nontransactional migration with a
stable application-specific index name. It must create and drop the index with
`CONCURRENTLY`, monitor invalid indexes after interruption, and verify the
catalog definition rather than accepting a same-named but different index.
Rollback drops only the application-owned index:

```sql
DROP INDEX CONCURRENTLY IF EXISTS app_te_values_string_trgm;
```

Do not drop `pg_trgm` during index rollback. Extensions are database-wide and
may be shared by unrelated application objects. Extension removal belongs in
a separate, explicitly owned operation only after catalog checks prove no
remaining dependants.

Before keeping the index, compare representative before/after plans with
`EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)`, including real pattern lengths,
selectivity, field distribution, and concurrency. Also measure index and total
relation bytes, build and write WAL, insert/update throughput, and ongoing
maintenance. A per-field partial predicate may be worth testing for a known
hot field, but it was not the Phase 3 candidate and requires its own evidence.

## Consequences and evidence limits

The additive GIN candidate increased median candidate index bytes by 61.417%
and build WAL by 50.293% versus the current B-tree candidate. Median insert and
update throughput fell 56.995% and 58.060%, while their WAL rose 156.499% and
195.441%. These costs make automatic installation inappropriate.

The retained artifact contains the full plans, checksums, sizes, and build
measurements for trial 1 plus cross-trial metric arrays and rotation metadata.
It does not retain the raw trial 2/3 plans, checksums, sizes, or build times, so
those items are not independently auditable from the artifact. The result is
relative evidence under active co-tenants; absolute timings are diagnostic,
and PostgreSQL 17 plan choices must not be generalized to every version or
workload. Applications should rerun the comparison in their own environment.
