---
title: "Bulk operations"
---

# Bulk operations

[Documentation home](../index.md)

## Bulk reads: `BulkRead`

`typed_eav_hash_for(records)` (the plural read) routes through `TypedEAV::BulkRead`. Given a record collection and an effective `(scope, parent_scope)`, it:

1. Resolves visible definitions and groups the requested field IDs.
2. Loads definitions, values, and field associations through one batched
   definition query, one values query, and one field-association preload
   (three SQL queries total; no host-table query).
3. Returns a `{record_id => {field_name => value}}` map while skipping orphaned
   values and preserving logical missingness.

Definitions, filters, reads, registry entries, and writes all use the host's
Rails `polymorphic_name`, so an STI leaf class reads and queries the same rows
written under its base-class polymorphic type.

The final production characterization reduced the 1,002 SQL statements observed
across 1,000 scopes to three for the same BulkRead shape. This is a statement-
count result, not a representative throughput claim; applications should still
measure their own scope cardinality, selected fields, hydration, and contention.

Single-record reads (`typed_eav_value`, `typed_eav_hash`) live on `InstanceMethods` and use the same partition helpers but without batching.

Use `fields:` to load only the values needed by a view or export:

```ruby
Contact.typed_eav_hash_for(contacts, fields: [:name, :score])
# => {123 => {"name" => "Ada", "score" => 42}, ...}
```

Omitting `fields:` (or passing `nil`) retains the all-fields behavior. A single
String/Symbol or an enumerable of names is accepted; duplicates are removed.
Unknown names and names unavailable in an individual record's partition are
omitted, as are missing value rows. An explicitly stored NULL remains `nil`.
`fields: []` returns an empty inner hash for each record without definition or
value queries (the supplied collection itself may still need loading). Selected
winning field IDs constrain the value query before hydration, so unrequested
values and their field readers are not loaded or evaluated. Definition lookup
remains batched across the records' partitions.

To explicitly reuse already-loaded values:

```ruby
contacts = Contact.where(tenant_id: "t1").includes(typed_values: :field).to_a
Contact.typed_eav_hash_for(contacts, fields: [:name], source: :preloaded)
```

The default `source: :database` still fetches persisted values afresh, even
when associations are loaded or edited in memory. `:preloaded` uses the caller's
association targets, including unsaved Value builds/assignments, without saving
or mutating them. It performs one fresh batched definition query to choose
current winners, but no Value or field-association preload queries. This is a
value snapshot, not a guarantee of current database contents or frozen schema.

Every host's `typed_values` association must be loaded, as must each retained
Value's `field` association; incomplete preloads raise `ArgumentError` instead
of silently issuing N+1 queries. With `fields:`, unselected Values need no field
preload. With all fields selected, all field associations must be loaded
(including loaded `nil` for orphans). `fields: []` needs neither associations
nor definition/value queries. Only `:database` and `:preloaded` are valid sources.

## Bulk writes: `BulkWrite`

`bulk_set_typed_eav_values(records, attrs)` routes through `TypedEAV::BulkWrite`,
and `bulk_set_typed_eav_values_per_record(values_by_record)` is its sibling for
record-varying hashes. Both are semantic writers that:

1. Memoize field definitions for the call via `Thread.current[:typed_eav_bulk_defs_memo]`.
2. Validate each attribute against its field type's cast contract.
3. Save each host through the normal callback/validation path inside an outer
   transaction with per-record savepoints.

`bulk_set_typed_eav_values_per_record` uses records as Hash keys, so two AR
instances of the same persisted row collapse to one entry; sequence separate
calls for two ordered updates, while the uniform Array API preserves duplicate
instances and caller order.

Under the default `transaction: :all`, per-record validation failures are captured at their
savepoints while other successes can commit, but an uncaught exception rolls
the entire outer transaction back.
`transaction: :chunks, chunk_size: N` commits completed chunks while isolating
later failures, preserving earlier committed chunks. Both forms require the
host, Field, and Value pools to match.
`bulk_upsert_typed_eav_values` is a separate reduced-semantics fast path: it
casts and validates typed values, then performs one PostgreSQL upsert while
omitting host saves, persistence callbacks, delete shorthand, and versioning.

Callers must pass `acknowledge_reduced_semantics: true`. The same values hash
applies to every record; records must be persisted and unique, and string or
symbol field keys that normalize to the same name are rejected. The return
value is the integer number of value rows upserted, not a semantic
`successes`/`errors_by_record` result. Value casting, domain/entity/partition
checks, and Value validation callbacks remain; host callbacks and validations,
Value persistence callbacks, versioning, delete shorthand, and per-record
savepoint isolation are skipped.

Within each `transaction: :all` unit—or each requested chunk—the upsert path
resolves every record partition through one batched field-definition SELECT.
It shares BulkRead's internal tuple resolver, retaining global, scope-only, and
full-tuple precedence independently for each record without broadening tenant
visibility.

`BulkWrite` and `BulkRead` are siblings — one read path, one write path — but they don't share a base class. Per [ADR-0005](../adr/0005-keep-phase-six-modules-independent.md), keeping them independent preserves the option to evolve each on its own schedule.

## Writing a batch and handling results

```ruby
contacts = Contact.where(tenant_id: "t1").to_a
result = Contact.bulk_set_typed_eav_values(contacts, { score: 10 })
result[:successes].map(&:id)
result[:errors_by_record].each do |record, errors|
  Rails.logger.info(contact_id: record.id, errors: errors)
end

# Different sparse updates for each record:
result = Contact.bulk_set_typed_eav_values_per_record(
  { alice => { score: 12 }, bob => { nickname: { _destroy: true } } },
  transaction: :chunks, chunk_size: 100
)

# Explicit fast path; returns a count of Value rows:
rows_written = Contact.bulk_upsert_typed_eav_values(
  contacts, { score: 10 }, acknowledge_reduced_semantics: true
)
```

Semantic results are a symbol-keyed Hash with `successes` (host instances) and
`errors_by_record` (host-instance keys, string-keyed validation-message hashes).
An empty batch returns empty collections. Unlisted fields are untouched; the
`{ _destroy: true }` value removes the named Value through normal destruction.
Input errors and uncaught save exceptions propagate instead of becoming result
entries. Check `errors_by_record` even when `transaction: :all` is used: ordinary
validation failures do not make this an all-or-nothing batch.

Records can span partitions; each scoped record resolves its own definitions.
Filter and authorize the records before handing them to the writer. `chunk_size:`
must be a positive Integer with `transaction: :chunks`; it is ignored with
`:all`. An enclosing application transaction can still roll back work described
as committed chunks. Host saves also run validations/callbacks for other pending
host changes, so use records whose pending state you intend to save.

### Version grouping

Both semantic APIs accept `version_grouping:`:

| Value | Behavior |
| --- | --- |
| `:default` | Groups changes per record when versioning callbacks are installed; otherwise does no grouping. |
| `:per_record` | Assigns a group UUID for each record's pending typed-value changes. |
| `:per_field` | Shares a UUID for each written field name across the batch, including across chunks. Per-record hashes use the union of their field names. |
| `:none` | Adds no bulk grouping; normal enabled versioning still runs. |

Explicit `:per_record` or `:per_field` requires versioning installed at boot and
raises `ArgumentError` otherwise. Unknown grouping values also raise. Grouping
controls audit identity, not transaction atomicity. See
[events and versioning](events-and-versioning.md) for enabling history.

## Bulk operation guarantees

`bulk_upsert_typed_eav_values` is an explicit reduced-semantics API: it
prevalidates/casts values and performs a PostgreSQL upsert, while intentionally
omitting host callbacks and versioning. Use the regular bulk writer when those
semantics are required; chunked semantic transactions are opt-in.

The fast path still casts and runs domain, entity, partition, and validation
callbacks before its single upsert against the exact entity/field conflict
target; it omits host saves/host callbacks, Value persistence callbacks,
delete shorthand, and versioning. It requires one shared connection pool and
returns validation errors before SQL. `:all` is one unit; `:chunks` commits
completed chunks before a later failure. Semantic writes retain host saves,
per-record savepoint/error isolation, and one outer `:all` transaction.

BulkWrite evidence is intentionally bounded to the exercised 100- and 1,000-host
lanes. It does not establish 10,000- or 100,000-host throughput, nor does it
justify a universal batch size or storage choice.

## Operational guarantees

The semantic writer preserves the caller's transaction and callback/versioning
contract. Version rows are written in the source transaction, so a rollback
rolls back the Value mutation and its audit row together. The reduced-semantics
upsert is intentionally separate and does not claim those callbacks or audit
guarantees.

Field deletion has a callback-preserving, keyset-batched path that locks and
destroys only the exact field's Values before bounded finalization. It scales by
bounded primary-key batches and preserves the Field if a batch fails; it is not
a claim of unbounded deletion throughput.

## Default backfill narrowing

`Field::Base#backfill_default!` optionally accepts an exact-host
`ActiveRecord::Relation` to SQL-narrow eligible entities before batching. The default
all-host behavior remains unchanged; partition checks, batch transactions,
callbacks, validations, idempotence, versions, and errors remain in force.
Typed storage defines logical missingness across all declared cells, so a
partially populated multi-cell value is present while a fully empty Currency
value is missing.
