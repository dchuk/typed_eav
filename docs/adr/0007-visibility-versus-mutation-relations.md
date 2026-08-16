# ADR 0007: Visibility versus mutation relations

## Status

Accepted

## Decision

Typed EAV keeps two relations for partitioned definitions:

- `for_entity` is a visibility relation. It includes the requested
  `(entity_type, scope, parent_scope)` row plus the global and partial-scope
  fallback rows used for collision precedence.
- `for_partition` is a mutation relation. It matches `entity_type`, `scope`,
  and `parent_scope` exactly, including SQL `NULL` axes, and is used by
  ordering mutations and their `FOR UPDATE` locks.

Field ordering queries `TypedEAV::Field::Base.for_partition` so STI field
subclasses remain one ordering partition. Section ordering queries the Section
base relation directly for the same reason of keeping the mutation boundary
independent from the receiver's relation scope.

## Consequences

Moving a definition cannot renumber a global fallback, a scope-only fallback,
or a different full `(scope, parent_scope)` tuple. Visibility lookup and its
collision precedence remain unchanged. Mutation locks still run in one
transaction, acquire every exact-partition row in deterministic `id` order,
and normalize only those rows.
