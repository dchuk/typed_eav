# ADR 0013: Durable versioning and callback-preserving field deletion

## Status

Proposed

## Context

TypedEAV currently writes `ValueVersion` rows from an internal `after_commit`
subscriber. That boundary is intentionally after the source transaction: a
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
transaction as the smallest follow-up boundary, conditional on proving that
`TypedEAV::Value` and `TypedEAV::ValueVersion` use the same connection pool.
That is a proposal for the next implementation task, not a production change in
this ADR task. The implementation must preserve the public callback contract:
application callbacks remain best-effort, rescued and logged after commit, and
must not be presented as durable or fail-closed delivery.

The generic outbox is deferred. It becomes appropriate only if version events
must cross a database/process boundary or require an independently operated
consumer. Until then, its additional queue, retry, idempotency, ordering, and
retention surface is not justified.

## Field deletion contract for a later implementation

Field-dependent destruction must not use `delete_all`, broad unscoped deletes,
or early Field removal. A later implementation should:

1. identify the exact `field_id` and process dependent Values in bounded
   primary-key keyset batches (`id > last_id`, ordered by `id`);
2. destroy each Value through Active Record so Value callbacks and the selected
   versioning boundary run, while retaining exact-field and source-transaction
   isolation;
3. commit each bounded batch, recording only the last successfully drained
   key, so a failure resumes from remaining rows without skipping or repeating
   committed work;
4. retry/resume until an exact-field query proves no dependent Values remain;
5. destroy the Field only after the final drain proof, preserving its own
   callbacks and policy semantics.

The operation must be idempotent, preserve ordering by keyset position, and
retain enough logs/metrics to distinguish a committed batch from a failed or
unattempted batch. It must not claim that an after-commit callback failure
rolled back source data.

## Evidence and limits

The real-commit regressions establish current failure semantics for Value
create/update/destroy and field-dependent cascades. They do not measure retry
cost, batch size, queue latency, or cross-database behavior. Those questions
require a separately approved implementation and protocol.

## Related decisions

- ADR 0003 keeps the EventDispatcher as the internal callback broker.
- ADR 0012 keeps broad administrative work application-bounded.
