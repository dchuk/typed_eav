# Split `HasTypedEav` into mixin + `EntityQuery` + query objects

**Status:** accepted

`HasTypedEav` had grown to 881 lines holding three responsibilities (the macro, class-level queries, instance accessors) with two heavy methods (`where_typed_eav`, `typed_eav_hash_for`) carrying blanket `Metrics/CyclomaticComplexity` rubocop disables. The file size was one friction; the methods' depth was another — and the file split alone wouldn't have addressed the second.

We split `HasTypedEav` structurally and extracted the heavy method bodies into focused query classes. The macro stays in `has_typed_eav.rb` (~150 lines). Per-record API lives in `has_typed_eav/instance_methods.rb`. Class-level orchestration lives in a new top-level `TypedEAV::EntityQuery` module. The `where_typed_eav` body extracts into `TypedEAV::FilterQuery`; `typed_eav_hash_for` extracts into `TypedEAV::BulkRead`. `bulk_set_typed_eav_values` already delegated to the existing `TypedEAV::BulkWrite`; no change. Field-collision helpers move from `HasTypedEav` module-statics to `TypedEAV::Partition` (where the partition-tuple precedence rule belongs).

## Two altitudes of query module

The project now has two layers of query module on purpose:

- **`QueryBuilder`** — low-level SQL primitives. Given `(field, operator, value)`, returns a relation or predicate. Knows nothing about scope, collision, or multiple filters.
- **`FilterQuery` / `BulkRead`** — high-level orchestration. Given filters + a resolved scope tuple + a model, calls down into `QueryBuilder` per filter and composes the result.

This split is intentional — keeping `QueryBuilder` narrow lets per-field SQL details (Arel predicates, ILIKE escaping, type casting) stay testable in isolation, while orchestration concerns (input normalization, scope resolution, multi-tuple collision) live one level up. Future query-shape additions should pick the matching altitude: per-field predicate work belongs in `QueryBuilder`; cross-filter or cross-tuple orchestration belongs in a new top-level query class.

## Considered alternatives

- **(a) Two-way relocation only**, no method extraction. Solves file-size friction; leaves the `Metrics/CyclomaticComplexity` disables in place. Rejected because the depth friction was the larger of the two.
- **(c) Depth-only**, no structural split. Extracts query classes but leaves the 881-line file behind (would shrink to ~500). Rejected because the shape friction was real on its own.
- **(d) Three-way split** with the macro in its own tiny module. Rejected as over-decomposition — the macro is naturally co-located with its module entry.

## Consequences

- Zero BC impact on public surfaces. `has_typed_eav` macro and all class/instance method signatures unchanged.
- `HasTypedEav.definitions_by_name` was technically reachable externally; treated as internal (not documented in README). Callers should use `Partition.definitions_by_name`.
- New unit-test surfaces (`filter_query_spec`, `bulk_read_spec`, `entity_query_spec`) can exercise query construction with stub models, decoupling tests from full AR setup where possible.
- The "extract heavy class methods into focused query classes" pattern is established as the project's stance for similar future refactors.
