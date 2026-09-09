---
title: "Design decisions"
nav_group: Project
nav_exclude: false
---

# Design decisions

The choices below explain behavior you may encounter when integrating or
extending TypedEAV. Each summary covers the decision, why it exists, and what
it means for your application. Links lead to the full engineering rationale.

## Fields and extension points

- **Fields own typed storage.** A custom field declares its columns and implements
  logical reads, writes, and defaults. Change detection and snapshots derive from
  those column declarations, avoiding duplicate storage mappings that can drift.
  Multi-column types use the same extension pattern as built-in Currency.
  [Rationale](0001-collapse-column-mapping-stack.md)
- **Related types share validation behavior.** String and range-bounded field
  families, plus a shared option-handling concern, keep validation consistent.
  Custom types can reuse these families instead of rebuilding length, range,
  and option checks. [Rationale](0004-field-family-intermediate-bases.md)

For implementation examples, see [custom field types](../guides/fields.md#custom-field-types).

## Scoping and queries

- **Field predicates and query composition are separate.** Per-field SQL handles
  typed operands; higher-level queries handle filters and partition resolution.
  This keeps type-specific behavior independent of how multiple filters combine.
  Applications normally use the host model API rather than these internal classes.
  [Rationale](0002-entity-query-orchestration.md)
- **Missing values are an explicit query choice.** Ordinary `is_null` matches an
  existing NULL value row. With `include_missing: true`, the query also includes
  hosts without a value row, using the caller's host set and excluding non-NULL
  matches. This supports “is empty” searches without changing the default SQL-like
  NULL contract. [Rationale](0006-include-missing-via-set-complement.md)
- **Visibility and mutation have different boundaries.** Reads may include global
  and less-specific fallback definitions; ordering mutations target the exact
  partition. Reordering a tenant's definitions therefore cannot renumber shared
  fallback definitions or another partition's fields.
  [Rationale](0007-visibility-versus-mutation-relations.md)
- **Multiple filters retain the existing subquery strategy.** TypedEAV combines
  per-field matches through host `IN` predicates. Alternative query shapes have
  not demonstrated a sufficiently reliable, semantically equivalent improvement
  to justify a replacement. There is no adaptive query-strategy switch.
  [Rationale](0011-multi-filter-query-strategy.md)
- **Cross-partition queries are an administrative tool.** `unscoped` considers
  definitions across partitions, so broad queries can require substantially more
  work. Applications own authorization, narrowing, and batching; the gem does not
  claim a universal safe partition count. Normal tenant requests should use scoped
  resolution. [Rationale](0012-cross-scope-administrative-query-policy.md)

See [query behavior](../guides/queries.md) and [scoping](../guides/scoping.md)
for the public contracts and examples.

## Indexing and performance

- **Default scalar indexes omit NULL cells.** Values normally populate only their
  applicable typed columns. Partial covering indexes avoid indexing unrelated NULL
  cells while supporting non-NULL scalar queries. Separate NULL indexes are not
  installed automatically because their storage and write costs depend on the
  workload. [Rationale](0008-partial-covering-scalar-indexes.md)
- **Trigram indexes are application-owned.** The gem keeps its default string
  B-tree and public `ILIKE` operators. Trigram indexing can help selected searches,
  but short patterns and negative searches need different expectations. Applications
  evaluate the extension, index, and write/storage costs on their own data.
  [Rationale](0009-string-search-indexing.md)
- **Extended planner statistics are opt-in.** Correlated field/value predicates
  can benefit from better estimates, but better estimates do not necessarily
  improve runtime. TypedEAV does not install statistics objects or prescribe a
  universal target; applications add them only when their query plans justify it.
  [Rationale](0010-planner-statistics-policy.md)

These are workload choices, not universal speed guarantees. See
[storage and performance](../guides/performance.md) for evaluation guidance.

## Imports, events, and audit history

- **Import utilities remain independently usable.** Schema portability moves
  definitions, CSV mapping transforms rows, and bulk writing persists values.
  Keeping them separate lets applications preview, validate, and save in the order
  their workflow requires. Their different return values reflect different jobs;
  there is no mandatory import pipeline.
  [Rationale](0005-keep-phase-six-modules-independent.md)
- **Public event hooks have a separate error policy.** Public callbacks run after
  commit, and their errors are logged rather than making a committed save appear
  to have failed. The event dispatcher preserves that boundary. Applications
  needing reliable external delivery must provide their own delivery mechanism.
  [Rationale](0003-keep-event-dispatcher-broker.md)
- **Enabled audit history shares the value transaction.** Value changes and their
  audit rows commit or roll back together, requiring a shared connection pool.
  Public after-commit hooks remain separate. Large field deletions have an explicit
  batched path that preserves value callbacks and versioning; committed batches
  remain committed if a later batch fails, and the field is retained for retry.
  [Rationale](0013-durable-versioning-and-field-deletion.md)

See [CSV mapping](../guides/csv-import.md), [schema portability](../guides/schema.md),
[bulk operations](../guides/bulk-operations.md), and
[events and versioning](../guides/events-and-versioning.md) for usage details.
