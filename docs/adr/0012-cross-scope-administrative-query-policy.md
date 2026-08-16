# ADR 0012: Bound cross-scope administrative queries in applications

## Status

Accepted

## Context

`TypedEAV.unscoped` is the deliberate escape hatch for administration,
analytics, migrations, and cross-tenant audits. It is not the ordinary tenant
request path. Within a tenant tuple, field visibility considers global,
scope-only, and full-tuple definitions and selects the most-specific definition
for each name. Under `unscoped`, the same-name definitions across every
partition remain visible and query construction unions their per-definition
relations for each filter.

Code-path analysis shows that the `ALL_SCOPES` branch eagerly materializes the
visible definitions, groups them by name, constructs one relation per matching
definition, and combines those relations with Arel OR nodes. Repeating that
work across filters makes construction depend on the definitions visible to
the administrative query as well as its filters. This behavior is distinct
from bounded tenant specificity and must not be generalized to normal tenant
traffic.

Phase 4C attempted representative cross-scope measurement in T066 and T069.
Neither execution produced an accepted representative artifact. T066 rejected
at artifact validation without retaining the decisive rejection detail. T069
then rejected at the required checkpoint gate, and runner ordering again lost
the exported diagnostic before local retention. Local smoke exercised the
intended semantics, but smoke evidence does not establish representative
scaling or candidate equivalence. The rejected runs therefore support no
latency, throughput, planner, cardinality-limit, or comparative-performance
claim.

## Decision

Keep `TypedEAV.unscoped` as an explicit administrative and analytics surface.
Applications should keep the definition universe for each administrative job
as narrow as their use case permits and batch broad cross-partition work at an
application-owned boundary. The appropriate relation, partition selection,
batch size, scheduling, and operational limits depend on the consuming
application and must be measured there.

TypedEAV does not add a built-in threshold, warning, guardrail, batching API,
query rewrite, schema object, or dependency. The benchmark-only homogeneous
`field_id`-array prototype is not adopted. It lacked accepted representative
semantic and performance evidence and was ineligible for mixed field casts,
operators, and NULL/missing complement semantics.

No numeric definition limit is recommended. Applications that operate across
many partitions should inspect their own generated SQL, planning and execution
behavior, memory use, and workload interference before selecting an operational
boundary. Ordinary tenant requests should continue using scoped resolution,
not `unscoped` as a shortcut around scope configuration.

## Consequences

- Tenant-scoped lookup retains most-specific global/scope/full-tuple behavior.
- Cross-scope queries retain their existing union semantics and public API.
- Administrative callers own bounding and batching for broad work.
- No rejected benchmark output is published as representative evidence.
- A future production optimization requires a new accepted protocol that
  preserves polymorphism, field-owned casts, shadowing, supported operators,
  explicit NULL, missing rows, and `include_missing` semantics.

## Related decisions

- ADR 0002 separates entity-query orchestration from per-field predicates.
- ADR 0006 defines `include_missing` as host-level set complement, including
  the `ALL_SCOPES` multimap branch.
- ADR 0011 retains the chained-`IN` multi-filter strategy and requires complete
  representative equivalence before replacement.
