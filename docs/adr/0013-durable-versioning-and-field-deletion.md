# ADR 0013: Durable versioning and callback-preserving field deletion

## Status

Accepted and implemented by the atomic versioning boundary work.

## Context

The historical implementation wrote `ValueVersion` rows from an internal
`after_commit` subscriber. That boundary was intentionally after the source transaction: a
source `Value` create, update, or destroy can commit successfully and then the
version writer can raise. The same applies when a field's `field_dependent:
"destroy"` callback destroys its dependent Values. Real-commit regression
coverage records this observable divergence: the source rows and field cascade
remain committed while the attempted version rows are absent.

This is not a rollback guarantee. An `after_commit` exception can be surfaced
to the caller, but it cannot undo the already committed source mutation. Public
application callbacks remain a separate concern and should remain best-effort
after-commit hooks, rescued and logged rather than making source persistence
fail closed.

## Options

| Option | Boundary | Strength | Cost and limitation |
| --- | --- | --- | --- |
| Current after-commit delivery | `Value` commits, then subscriber writes `ValueVersion` | Backward-compatible and simple | A subscriber failure leaves committed source state without a version row; retries and visibility are external concerns |
| Synchronous source-transaction write | Write `ValueVersion` before the `Value` transaction commits | Source and version row succeed or roll back together; smallest durable boundary | Requires `Value` and `ValueVersion` to share the same connection pool; changes callback ordering and needs explicit recursion/rollback tests |
| Generic outbox | Source transaction appends an event; a worker writes versions | Cross-process retry, replay, and operational observability | Adds schema, worker/queue, idempotency, retention, ordering, and deployment machinery before a cross-database or external-consumer requirement exists |

## Decision

Characterization selects synchronous `ValueVersion` writes inside the source
transaction as the smallest follow-up boundary. Enablement remains
boot-latched: when versioning is disabled at boot, no subscriber is registered
and the disabled path adds no per-mutation hot-path predicate. When enabled,
activation must fail closed unless
`TypedEAV::Value.connection_pool.equal?(TypedEAV::ValueVersion.connection_pool)`
is true. A pool mismatch is a startup/configuration error, not a permitted
best-effort mode. This is a proposal for the next implementation task, not a
production change in this ADR task.

The implementation uses actual Value callback-chain inspection as its
boot-latch truth, reinstalls missing callbacks idempotently, and rejects a
Value/ValueVersion pool mismatch before installation. BulkWrite preserves the
caller context and carries version-group correlation through an internal
pending marker. The implementation must preserve the existing write contract: registry opt-in,
exact entity/field tuple and tenant/partition semantics, before/after typed
snapshots, context, actor resolution, `changed_at`, version-group selection,
and pending-marker cleanup on both commit and rollback. A source rollback must
roll back its synchronous version rows; a successful source mutation produces
exactly one corresponding version row. Public application callbacks remain
best-effort, rescued and logged after commit, and must not be presented as
durable or fail-closed delivery.

The generic outbox is deferred. It becomes appropriate only if version events
must cross a database/process boundary or require an independently operated
consumer. Until then, its additional queue, retry, idempotency, ordering, and
retention surface is not justified.

## Durability boundaries and historical limits

Idempotency is one version row per successful source mutation. A caller owns a
whole-source retry: retry the complete source transaction after a rollback or
connection failure, rather than replaying an individual version write. There is
no asynchronous replay cursor, checkpoint protocol, or durable event identity
in this proposal. Ordering is the order of mutations within one source
transaction; no total order is promised across concurrent transactions or
databases.

The synchronous boundary does not repair historical gaps created by the current
after-commit path, and it does not infer or rewrite history after model,
registry, tenant, field, or snapshot semantics drift. Existing gaps remain
observable historical gaps and require a separately approved, application-owned
repair process if a consumer needs one. Version rows remain append-only;
retention, archival, and deletion are application-owned policies and are not
automated here.

## Implemented bounded Field deletion contract

Field-dependent destruction must not use `delete_all`, broad unscoped deletes,
or early Field removal. The explicit
`Field#destroy_with_values_in_batches!(batch_size: 1_000)` API:

1. identify the exact `field_id` and process dependent Values in bounded
   primary-key keyset batches (`id > last_id`, ordered by `id`);
2. destroy each Value through Active Record so Value callbacks and the selected
   versioning boundary run, while retaining exact-field and source-transaction
   isolation;
3. commits each bounded batch independently; a retry re-derives the remaining
   rows from the exact-field keyset without skipping or repeating committed
   work;
4. retry/resume until an exact-field query proves no dependent Values remain;
5. destroy the Field only after the final drain proof, preserving its own
   callbacks and policy semantics.

The operation is idempotent and preserves ordering by keyset position. It is
explicitly rejected inside an open transaction or when Field, Value, and
ValueVersion do not share one connection pool. The final drain locks the Field,
accepts at most one bounded residual batch, proves zero exact-field rows, and
only then invokes ordinary Field destruction. It does not claim that an
after-commit callback failure rolled back source data.

After the final Field deletion, the foreign keys intentionally null both
`ValueVersion.value_id` (when its Value is subsequently gone) and
`ValueVersion.field_id` (when the Field is gone). The durable `entity_type`,
`entity_id`, and payload can remain queryable, but direct Value/Field identity is
then lost. This is an accepted identity tradeoff, not something the ADR hides
or promises to reconstruct with a schema snapshot.

## Evidence and limits

The real-commit regressions establish current failure semantics for Value
create/update/destroy and field-dependent cascades. They do not measure retry
cost, batch size, queue latency, or cross-database behavior. Those questions
require a separately approved implementation and protocol.

## Related decisions

- ADR 0003 keeps the EventDispatcher as the internal callback broker.
- ADR 0012 keeps broad administrative work application-bounded.
