# ADR 0011: Retain chained-IN multi-filter queries

## Status

Accepted

## Context

TypedEAV currently resolves every requested field before constructing SQL. It
then builds one typed value subquery per filter, selects distinct `entity_id`
values from each, and adds each result to the host relation as an `id IN (...)`
predicate. This chained-`IN` shape preserves the host relation as the universe
for complement and missing-value operations.

Phase 4B compared that implementation with `INTERSECT`, correlated `EXISTS`,
and direct grouped `HAVING`. `INTERSECT` and `EXISTS` reused the same resolved
per-filter subqueries. Grouped `HAVING` was eligible only for compatible
present-row predicates: without a host join or a separate complement it cannot
represent missing or host-universe complement semantics, and a direct grouped
value scan cannot return the unfiltered host relation for an empty filter set.

The seed-4502 representative run used 100,000 primary hosts, more than 50 field
definitions, 25 scenarios, three rotations, and ten attempts per eligible
strategy group. It retained 2,940 uniformly capped attempts, 294 sorted
host-identity oracles, and 75 scenario/trial summaries on PostgreSQL 17 under
resource-capped co-tenancy. Of the attempts, 622 reached the 1,000 ms timeout
and are right-censored lower bounds. Of the 294 non-retried 5,000 ms oracles,
282 completed and 12 timed out; the timed-out identities are unknown, not equal
or unequal. No completed oracle mismatched or errored. The embedded 2,000-host
smoke completed all 98 eligible oracles with equal identities, but that does
not establish representative-scale equivalence.

The candidates did not produce a robust general winner. `INTERSECT`, `EXISTS`,
and grouped `HAVING` strongly improved the high-selectivity 10-predicate case,
but the mixed 10-predicate case regressed and many low-, mixed-, and
skewed-selectivity large cases were censored or otherwise inconclusive.

Two evidence defects further limit the result:

- The artifact's derived buffer totals are false zeros because the extractor
  split each multiword EXPLAIN block key into individual words. The retained
  raw plans contain nonzero block counters and can be reparsed, but the
  published derived zero values are not valid buffer evidence.
- The 20-predicate scenarios repeat ten fields, while the skewed 10- and
  20-predicate scenarios repeat five fields. The run therefore does not measure
  20 distinct fields, and its skewed cases do not measure 10 distinct fields.

Absolute timings and dispersion from the continuously busy co-tenant host are
diagnostic. PostgreSQL 17 plan choices are not evidence for every supported
PostgreSQL version or application distribution.

## Decision

Retain the current chained host `IN` query strategy. Production query code and
public APIs do not change.

`INTERSECT` and correlated `EXISTS` remain research-only alternatives. Direct
grouped `HAVING` is also research-only for compatible present-row predicates
and remains ineligible for missing-value, host-universe complement, and empty-
filter semantics. No adaptive selector or production replacement is available
or authorized.

## Gates for future research

Future adaptive or replacement work must pass all of these gates before a
production change can be considered:

1. **Semantic coverage.** Build every strategy from identical resolved fields,
   typed operands, predicates, datasets, and host universes. Prove scope,
   parent-scope, global/scoped shadowing, all-scope administration,
   polymorphic host identity, arbitrary supported operators, explicit NULL,
   missing and `include_missing` complements, duplicate internal matches,
   empty filters, ordering where requested, and supported error behavior.
   Grouped `HAVING` must stay ineligible where it cannot express the contract.
2. **Representative equivalence.** Complete the sorted `(entity_type, id)`
   count/checksum oracle for every eligible representative group. A timeout,
   mismatch, or error cannot be treated as equality; no completed-only sample,
   retry, imputation, or censored bound may authorize replacement.
3. **Distinct-field scale.** Measure actual 10- and 20-distinct-field workloads
   across high-, low-, mixed-, and skewed-selectivity families rather than
   reaching those predicate counts by repeating five or ten fields.
4. **Correct buffer evidence.** Re-extract separate shared/local/temp read,
   hit, dirtied, and written block counters from every retained raw plan,
   validate derived totals against the source EXPLAIN JSON, and obtain complete
   comparable `ANALYZE` buffer evidence. The current derived zeros cannot be
   used as a baseline.
5. **Performance threshold.** Show uncensored improvement of at least 20% at
   p95 for both 10- and 20-filter workloads in at least three workload families.
   Preserve all scheduled repetitions and right-censored results; do not infer
   a winner from completed attempts alone.
6. **Planning and plan shape.** Pre-register material-regression bounds, then
   show bounded planning-time and buffer behavior and no material plan-shape
   regression, including index use and host-relation behavior, across the
   eligible semantic matrix. Repeat planner evidence on the PostgreSQL versions
   for which a production strategy would be claimed.
Cross-scope planning at high tenant cardinality remains separate required
Phase 4 evidence. Passing a favorable microbenchmark or repairing only one of
the defects above is insufficient for Gate 4 or production authorization.

## Consequences

TypedEAV keeps the broadly exercised semantics and predictable public behavior
of its current composition path. It also forgoes the strong improvements seen
in one high-selectivity case until those gains survive the full semantic and
operational evidence gates. The representative artifact remains useful as
negative and retention evidence; it is not proof that alternatives are
equivalent, eligible, adaptive, or generally slower.
