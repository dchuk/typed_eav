# Compose `include_missing:` via set-complement at the FilterQuery altitude

**Status:** accepted

`Entity.with_field("status", :is_null)` today matches only hosts that have a `typed_eav_values` row whose value-column is NULL. Hosts that have no row at all are invisible — a common usability gap when admins build "is empty" filters. The G3 ticket (#19) adds an opt-in `include_missing:` keyword that broadens the `:is_null` semantic to "no non-NULL value, including no-row hosts" (Reading A).

The PRD's first sketch proposed a LEFT JOIN inside `QueryBuilder` for the `:is_null` branch. We're rejecting that framing and composing the wider predicate at the `FilterQuery` altitude as a **set complement** instead. `QueryBuilder` is not modified.

## Decision

In `FilterQuery`:

- **Single-scope branch** when `include_missing: true && operator == :is_null`:
  ```ruby
  non_missing_ids = QueryBuilder.entity_ids(field, :is_not_null, nil)
  query.where.not(id: non_missing_ids)
  ```
- **Multimap (`ALL_SCOPES`) branch** when `include_missing: true && operator == :is_null`:
  ```ruby
  non_missing_ids = fields.flat_map { |f|
    QueryBuilder.entity_ids(f, :is_not_null, nil).pluck(:entity_id)
  }.uniq
  query.where.not(id: non_missing_ids)
  ```
- `:is_not_null` + `include_missing: true` → no-op. The natural complement already covers the intent.
- Any other operator + `include_missing: true` → silently ignored.

The wrapper methods `Entity.with_field` and `Entity.where_typed_eav` accept `include_missing: false` by default and thread it through to `FilterQuery#initialize`.

## Why set-complement, not LEFT JOIN

The LEFT JOIN framing would push the "no row" branch into `QueryBuilder`, which today is a per-field SQL primitive that knows nothing about multi-filter composition, partition collision, or the multimap-vs-single-scope split (ADR-0002). Adding a LEFT JOIN there:

- Forks the `:is_null` branch's return-type contract (the existing `filter` returns an `ActiveRecord::Relation` of `TypedEAV::Value` records suitable for `select(:entity_id)`; a LEFT JOIN against the host table breaks that shape).
- Introduces a host-table dependency at the per-field altitude, which is exactly the multi-filter composition concern `FilterQuery` was extracted to own.
- Doesn't generalise cleanly to the multimap branch — "no non-NULL value across any matching field def" is set-complement at the host level, not a per-field LEFT JOIN.

Set-complement at `FilterQuery` reuses the existing `:is_not_null` primitive verbatim. `QueryBuilder.entity_ids(field, :is_not_null, nil)` returns the hosts that DO have a non-NULL value; `where.not(id: ...)` is the host-level complement. The math is "all hosts minus hosts with a value," which is precisely Reading A.

## Reading A vs Reading B on the multimap branch

The multimap branch unions field definitions across tenants (e.g. `name` defined separately for `ws-1`, `ws-2`, `ws-3`). When a user asks for "is empty," two readings are possible:

- **Reading A — "no non-NULL value across ANY matching field def."** A host matches iff none of the per-tenant field defs have a non-NULL value for it. A host with a NULL row in ws-1 and a populated row in ws-2 does NOT match (it has a non-NULL value in ws-2).
- **Reading B — "no row for any field def."** A host matches iff it has zero rows across all the matching field defs. A host with a NULL row anywhere does not match.

We're pinning **Reading A**. Rationale:

1. Reading A is the single-scope semantic, generalised. Users who escalate from a single-scope query to an `unscoped { }` block don't expect the meaning of `:is_null` to flip on them.
2. Reading B is operationally indistinguishable from "do any rows exist," which is a different question with its own clear phrasing.
3. The set-complement implementation falls out naturally for Reading A — union the non-missing entity_ids across all matching field defs, then complement. Reading B would need a separate row-existence query that doesn't reuse `:is_not_null`.

The `FilterQuery` RDoc pins Reading A explicitly so future contributors don't second-guess it.

## Why `:is_not_null` is a no-op

`:is_not_null` already returns the natural complement of `:is_null`'s NULL-row-only semantic. Layering `include_missing: true` on top would either (a) flip the meaning of `:is_not_null` to "has a non-NULL value OR has no row" (incoherent — a no-row host has neither a value nor a NULL), or (b) silently leave it alone. We pick (b) so filter UIs can pass `include_missing: true` uniformly without branching per operator.

## Why other operators silently ignore

Same UI ergonomics. A filter UI that exposes "Include records with no value" as a checkbox should be able to pass `include_missing: true` regardless of the current operator selection. `:eq`, `:gt`, `:contains`, `:references`, `:between`, `:starts_with`, etc. all have their own well-defined semantics that don't compose with "or has no row" in a useful way. Silent-ignore is the least-surprise behavior for a filter UI.

## Considered alternatives

- **LEFT JOIN inside `QueryBuilder`.** Rejected — forks the return-type contract and pushes multi-filter composition concerns into the per-field primitive (see "Why set-complement, not LEFT JOIN").
- **A new operator symbol (`:is_empty`).** Rejected — proliferates the operator vocabulary and forces filter UIs to branch on operator selection. The opt-in kwarg keeps the operator surface stable.
- **Reading B on the multimap branch.** Rejected — see "Reading A vs Reading B."
- **Make `include_missing:` default `true`.** Rejected — would silently change the meaning of `:is_null` for existing callers. The kwarg is opt-in by design.

## References

- Issue #19 — G3 PRD.
- ADR-0002 — `EntityQuery` / `FilterQuery` / `QueryBuilder` altitude split.
