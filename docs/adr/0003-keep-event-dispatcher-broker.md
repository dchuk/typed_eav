# Keep the EventDispatcher broker; do not inline

**Status:** accepted

An architecture review surfaced `EventDispatcher` as a possible "one adapter = hypothetical seam" — the internal-subscriber list (`value_change_internals`) is intentionally generic, and the broker pattern looked over-built for a 1:1 relationship. On closer inspection the broker is correctly designed for its public/internal callback split, and inlining would cost more than it saved.

We're keeping `EventDispatcher` as-is. The internal-vs-user-proc split is load-bearing on three counts that don't survive an inline.

## Why the broker stays

The broker remains useful for the shipped split between generic internal
observers and public callbacks. The earlier Phase 7 materialized-view plan is
retired and is not a current subscriber, ordering promise, or implementation
milestone; future consumers must register and document their own contract.

**The error policy split is two different contracts, not stylistic.**

- Internal subscribers fail-closed: exceptions PROPAGATE. Transactional
  versioning is outside this broker; its failures propagate inside and roll
  back the source transaction.
- User procs fail-soft: `rescue StandardError`, log via `Rails.logger.error`, swallow. The Value/Field row is already committed when `after_commit` fires; re-raising would surface a misleading "save failed" error to the caller, when the save actually succeeded.

The broker is what enforces this split. Inlining would either duplicate the rescue logic across every subscriber site (bug surface) or collapse the contracts (silently demotes internal errors to logged-and-swallowed, breaking the fail-closed invariant).

**The user-proc seam is public API and stays.** `Config.on_value_change` / `Config.on_field_change` are documented in README. External callers register here. Any refactor would have to preserve them — at which point the question becomes "do you keep the broker for the user procs and inline only the internals?" That partial inline loses the shared registration and error-policy seam while making Value/Field know each subscriber.

## Considered alternatives

- **(c) Collapse only the value-change internals path.** Direct calls from `Value#after_commit` to subscribers. Rejected because the broker preserves a generic future-consumer seam and the public/internal error-policy split.
- **(d) Original "inline the broker" recommendation.** Rejected because the broker is the documented callback boundary, not because of an imminent materialized projection.
- **(b) Defer the question until a future consumer exists.** Rejected because the current seam already has a stable public contract and does not need a speculative redesign.

## Where the friction came from

The friction my original review identified was cognitive (tracing through Value → EventDispatcher → Subscriber → Registry takes four files) rather than architectural. Each file is doing one job well. The trace looks long because audit-trail plumbing genuinely involves four concerns (emit, route, write, gate per-entity opt-in); collapsing them would lose the seams, not the work.

Future contributors who hit the same "shouldn't this be inlined?" reaction should land here first.
