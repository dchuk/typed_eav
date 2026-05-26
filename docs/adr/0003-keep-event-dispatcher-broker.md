# Keep the EventDispatcher broker; do not inline

**Status:** accepted

An architecture review surfaced `EventDispatcher` as a possible "one adapter = hypothetical seam" — the internal-subscriber list (`value_change_internals`) has exactly one entry today (`Versioning::Subscriber`), and the broker pattern looked over-built for a 1:1 relationship. On closer inspection the broker is correctly designed for what's already in motion, and inlining would cost more than it saved.

We're keeping `EventDispatcher` as-is. The internal-vs-user-proc split is load-bearing on three counts that don't survive an inline.

## Why the broker stays

**The second internal adapter is imminent, not hypothetical.** Phase 7 matview is the next active milestone and will register on both `value_change_internals` and `field_change_internals`. Engine.rb's `config.after_initialize` ordering reserves slot 0 for versioning and slot 1+ for matview as a documented contract. Removing the broker now would mean re-introducing it within the next planning cycle.

**The error policy split is two different contracts, not stylistic.**

- Internal subscribers fail-closed: exceptions PROPAGATE. Versioning corruption (and, soon, matview drift) must be loud — silent failure leaves the audit log inconsistent with the live row.
- User procs fail-soft: `rescue StandardError`, log via `Rails.logger.error`, swallow. The Value/Field row is already committed when `after_commit` fires; re-raising would surface a misleading "save failed" error to the caller, when the save actually succeeded.

The broker is what enforces this split. Inlining would either duplicate the rescue logic across every subscriber site (bug surface) or collapse the contracts (silently demotes versioning errors to logged-and-swallowed, breaking the fail-closed invariant).

**The user-proc seam is public API and stays.** `Config.on_value_change` / `Config.on_field_change` are documented in README. External callers register here. Any refactor would have had to preserve them — at which point the question becomes "do you keep the broker for the user procs and inline only the internals?" That partial inline is what (c) in the grilling proposed and loses more than it gains: matview would still need its own registration site, the slot-ordering scaffold would have to be reinvented per-feature, and Value/Field's after_commit grows direct knowledge of each subscriber.

## Considered alternatives

- **(c) Collapse only the value-change internals path.** Direct calls from `Value#after_commit` to subscribers. Rejected because matview adds field-change subscribers too; the partial inline would force a second pass to inline field events, undoing more code each round.
- **(d) Original "inline the broker" recommendation.** Rejected once Phase 7's matview was identified as the imminent second adapter. The "one adapter = hypothetical seam" heuristic doesn't apply when the second adapter is in the next milestone.
- **(b) Defer the question until after Phase 7.** Rejected because matview design will assume the broker exists; revisiting the question afterward would mean undoing fresh work.

## Where the friction came from

The friction my original review identified was cognitive (tracing through Value → EventDispatcher → Subscriber → Registry takes four files) rather than architectural. Each file is doing one job well. The trace looks long because audit-trail plumbing genuinely involves four concerns (emit, route, write, gate per-entity opt-in); collapsing them would lose the seams, not the work.

Future contributors who hit the same "shouldn't this be inlined?" reaction should land here first.
