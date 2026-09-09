---
title: "Event hooks and versioning"
---

# Event hooks and versioning

[Documentation home](../index.md)

## Event hooks

`typed_eav` fires `after_commit` events for value and field changes. Use them
for audit logs, search-index synchronization, cache invalidation, or any
out-of-band reaction that must wait until the database write is durable.

### Public callback slots

```ruby
TypedEAV.configure do |c|
  c.on_value_change = ->(value, change_type, context) {
    # change_type ∈ [:create, :update, :destroy]
    # context is a frozen Hash (see `with_context` below) — read-only
  }

  c.on_field_change = ->(field, change_type) {
    # change_type ∈ [:create, :update, :destroy, :rename]
    # NOTE: no context arg — field changes are CRUD-on-config, not
    # per-entity user actions
  }
end
```

The `:rename` change_type fires whenever the field's `name` column changed
in the just-committed save, even when bundled with other attribute changes
(options, sort_order, default_value, etc.). The detection is intentionally
escalating so any registered consumer receives a rename event whenever the
persisted name changes.

`:update` on Value fires only when the typed value column changed. Saving
a Value record without modifying its typed column (e.g., touching only
bookkeeping columns) is a no-op for event dispatch.

`field_dependent: :nullify` cascades produce **no** Value `:destroy`
events. The FK `ON DELETE SET NULL` runs at the database level and
bypasses AR callbacks. Only the Field `:destroy` event fires. Use
`field_dependent: :destroy` if your consumer needs per-Value events on
field deletion.

For a persisted `field_dependent: :destroy` field with a large population,
call `field.destroy_with_values_in_batches!(batch_size: 1_000)` outside an
open transaction. The opt-in API selects only that exact `field_id` in ordered
primary-key batches, calls `Value#destroy!` for callback/version behavior, and
commits each batch independently. A retry resumes from the remaining rows. The
Field is retained until a locked, bounded residual drain proves zero rows, then
its ordinary callback-preserving `destroy!` runs. The API rejects unsaved or
non-destroy fields, open transactions, invalid batch sizes, and mismatched
connection pools. Existing `destroy`/`destroy!`, `:nullify`, and `:restrict`
behavior is unchanged.

### Thread-local context with `with_context`

```ruby
TypedEAV.with_context(request_id: request.uuid, actor_id: current_user.id) do
  contact.update!(typed_eav: { phone: "555-1234" })
  # on_value_change receives { request_id: "...", actor_id: 42 } as context
end
```

`with_context` is a thread-local stack with shallow per-key merge:

```ruby
TypedEAV.with_context(request_id: "abc") do
  TypedEAV.with_context(source: :bulk) do
    # current context: { request_id: "abc", source: :bulk }
  end
  # current context: { request_id: "abc" }
end
# current context: {}
```

The current-context hash is frozen — callbacks cannot mutate it. Outer
context is restored on exit even if the inner block raises.

`TypedEAV.current_context` returns the current frozen Hash (or a shared
frozen `{}` when no `with_context` block is active). It's safe to call
from any code path; it never returns nil.

### Error policy

User callbacks (`Config.on_value_change`, `Config.on_field_change`) are
rescued — exceptions are logged via `Rails.logger.error` and **do not
propagate** to the user's save call. The save row is already committed
when `after_commit` fires; re-raising would surface a misleading
"save failed" error.

This is the deliberate split with first-party features. Internal
observers used by `typed_eav` itself follow a different rule: their exceptions
**propagate**. Transactional version-writing errors are separate: they
propagate inside and roll back the source transaction.

### Ordering guarantee

When multiple subscribers are registered, they fire in this order:

1. First-party generic observers, in registration order. Errors propagate.
2. The user proc on `Config.on_value_change` / `Config.on_field_change`,
   last. Errors are rescued and logged.

Reassigning `Config.on_value_change` after gem initialization does **not**
disable internal subscribers — they live on a separate dispatcher list
and survive `Config.reset!`.

### Reset semantics

| Method | What it resets |
|---|---|
| `TypedEAV::Config.reset!` | User procs (`on_value_change`, `on_field_change`) plus `field_types`, `scope_resolver`, `require_scope`. Does **not** clear internal subscribers. |
| `TypedEAV::EventDispatcher.reset!` | Internal subscribers only. Does **not** touch Config. |

Production code rarely calls either — they exist for test isolation and
for the rare case where a host app wants to fully unwire the gem in a
specific request lifecycle.

## Versioning

`typed_eav` ships an opt-in append-only audit log for changes to typed
values. When enabled, each `:create` / `:update` / `:destroy` event on
a Value writes a row to `typed_eav_value_versions` capturing the
before-state, after-state, actor, context, and timestamp.

Default off. Apps that don't enable it pay zero overhead — transactional
Value callbacks are not installed at boot
at all when `Config.versioning = false`. Zero callable in the dispatcher
chain, zero per-write method dispatch, zero per-write config read.

### Enabling versioning

Two steps:

```ruby
# 1. Set the gem-level master switch in an initializer.
#    config/initializers/typed_eav.rb
TypedEAV.configure do |c|
  c.versioning = true
  c.actor_resolver = -> { Current.user }   # optional; nil is permissive
end

# 2. Opt the host model in. Either via the kwarg form:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id, versioned: true
end

# Or via the concern (equivalent — pick whichever fits your conventions):
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
  include TypedEAV::Versioned
end
```

The two opt-in forms produce identical Registry state. The kwarg form is
preferred for new code; the concern form fits codebases with established
mixin-based feature wiring.

### Querying history

```ruby
contact.typed_eav_attributes = [{ name: "age", value: 41 }]
contact.save!
contact.typed_eav_attributes = [{ name: "age", value: 42 }]
contact.save!

value = contact.typed_values.find_by(field: age_field)
value.history          # most-recent-first relation
# => [<ValueVersion change_type: "update" before: {"integer_value" => 41} after: {"integer_value" => 42}>,
#     <ValueVersion change_type: "create" before: {} after: {"integer_value" => 41}>]

value.history.first.changed_by   # => "42" (User#42 — coerced to id.to_s)
value.history.first.context      # => { "request_id" => "abc-123" } if with_context was active
```

`value.history` is a chainable relation. Filter, paginate, pluck:

```ruby
value.history.where(change_type: "update").pluck(:changed_at, :changed_by)
value.history.limit(5).each { |v| ... }
```

### Querying full audit history (including destroy events)

`Value#history` returns versions where `value_id` matches the live Value
record. After the live Value is destroyed, the FK `ON DELETE SET NULL`
nullifies `value_id` on the existing version rows, and the new `:destroy`
version is written by the transactional destroy callback with `value_id: nil`
before the parent row is removed. So `Value#history`
cannot surface destroy versions, and after Value destruction it can no
longer be called at all.

To query the FULL audit history for a given (entity, field), including
destroy events and post-destruction lookup, use the entity-scoped query
directly:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.polymorphic_name, entity_id: contact.id, field_id: age_field.id)
  .order(changed_at: :desc, id: :desc)
# => [<ValueVersion change_type: "destroy" before: {"integer_value" => 42} after: {} value_id: nil>,
#     <ValueVersion change_type: "update"  before: {"integer_value" => 41} after: {"integer_value" => 42} value_id: nil>,
#     <ValueVersion change_type: "create"  before: {} after: {"integer_value" => 41} value_id: nil>]
```

This pattern is the canonical way to surface "what happened to this
field on this entity" across the full lifecycle, including post-destroy.
The `entity_type` + `entity_id` columns remain the durable identity even
after the parent Value row is gone, and `field_id` survives because
destroying a Value does not destroy its Field.

For broader audit views — "show all version history across all fields
for a given entity" (e.g., admin entity-history pages, compliance
exports) — drop the `field_id` filter:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.polymorphic_name, entity_id: contact.id)
  .order(changed_at: :desc, id: :desc)
# => all version rows for every typed field on this contact, most-recent-first.
# Includes :create, :update, and :destroy events across every field the
# entity has ever had a typed value for.
```

The field-scoped query (with `field_id:`) is the common case for
"history of a single field"; the entity-scoped query (without `field_id:`)
is the broad-audit case for "all version history across all fields for
this entity".

### Version row jsonb shape

`before_value` and `after_value` are jsonb hashes keyed by typed-column
name:

| Field type | Snapshot shape (single key) |
|---|---|
| `text`, `email`, `url`, `color` | `{"string_value": "..."}` |
| `long_text` | `{"text_value": "..."}` |
| `integer` | `{"integer_value": 42}` |
| `decimal` | `{"decimal_value": "10.5"}` |
| `boolean` | `{"boolean_value": true}` |
| `date` | `{"date_value": "2026-05-05"}` |
| `date_time` | `{"datetime_value": "2026-05-05T12:00:00Z"}` |
| `select` | `{"string_value": "..."}` |
| `multi_select`, `*_array`, `json` | `{"json_value": [...]}` |

Multi-cell field types (e.g., `Currency`) produce two-key snapshots:
`{"decimal_value": "99.99", "string_value": "USD"}`. The version row's
snapshot asks the field's storage contract for its cells, so new field
types get the right shape automatically.

`{}` (empty hash) and `{"<col>": null}` are distinct semantics:

- `{}` means **no recorded value** — typical of `before_value` on a
  `:create` event, or `after_value` on a `:destroy` event.
- `{"<col>": null}` means **recorded nil** — the user explicitly
  cleared the cell.

### Reverting

```ruby
target = value.history.find_by(change_type: "update")
value.revert_to(target)
# value's typed columns now match target.before_value.
# A NEW version row is written capturing the revert (append-only).
```

`revert_to` writes the targeted version's `before_value` columns back
via `self[col] = …` and `save!`. The transactional version callback writes a
NEW version row whose
`after_value` reflects the targeted version's `before_value`. The
audit log is append-only — every revert is itself versioned.

To record the intent of the revert, wrap the call in `with_context`:

```ruby
TypedEAV.with_context(reverted_from_version_id: target.id, actor: current_user) do
  value.revert_to(target)
end
# The new version row's `context` column captures both keys.
```

`revert_to` raises `ArgumentError` in three documented conditions, checked in order:

- when `version.value_id` is nil (the source Value was destroyed — destroy
  versions have `value_id: nil` per the locked subscriber contract; you
  can't restore a destroyed AR record by `save!`);
- when the version's `before_value` is empty (the version represents a
  `:create` event with no before-state to revert to);
- when the version belongs to a different Value (`value_id` mismatch).

In practice only `:update` versions are revertable. To restore a
destroyed entity's typed values, create a new `TypedEAV::Value` record
manually using `version.before_value` as the seed state.

### Hook ordering guarantee

Versioning is installed as boot-latched transactional callbacks on `Value`,
and the public callback remains an after-commit observer. The version row is
written in the source transaction.
```
Value#save! → transactional Value callback → ValueVersion.create!
          → after_commit → EventDispatcher.dispatch_value_change:
  1. ... any other generic internal observers ...
  2. Config.on_value_change user proc        # sees the persisted version
```

Internal observer errors propagate. Transactional version-writing errors also
propagate inside and roll back the source transaction.
User proc errors are rescued and logged via `Rails.logger.error` —
the save itself already committed.

### Actor resolution

`Config.actor_resolver` mirrors `Config.scope_resolver`'s callable shape
but returns whatever the app chooses (an AR record, a string, an integer,
nil). The subscriber coerces non-nil returns via `id.to_s` (for AR
records) or `to_s` (for scalars) before storing in the `changed_by`
column (string, nullable).

`nil` is the documented permissive sentinel: system writes, migrations,
console-without-actor, and background jobs without a `with_context(actor:
...)` wrap all flow through with `changed_by: nil`. This is intentional —
forcing every Versioned write to have an actor would reject every console
save and every migration backfill, which is hostile-by-default for a gem.

Apps that need stricter enforcement do it inside the resolver:

```ruby
c.actor_resolver = -> { Current.user || raise(MyApp::ActorRequired) }
```

`Config.reset!` (documented in [Event hooks](#event-hooks)) also resets `Config.versioning`
to `false` and `Config.actor_resolver` to `nil`.

### What versioning does not do

- **No branching/merging across version chains.** Phase 4 ships event-log
  shape only. Roadmap explicitly defers branching to a future design.
- **No snapshot storage by default.** `typed_eav_value_versions` is an
  event log — one row per change, not a full-row snapshot. For
  high-volume apps that want snapshot storage, extend `ValueVersion` in
  your own code (the gem keeps the event-log shape canonical so future
  upgrades don't break your extension).
- **No automatic `reverted_from_version_id` injection.** Use
  `with_context` to record revert intent; the gem captures whatever
  context the caller set.
- **No per-Field versioning toggle.** Opt-in is per-entity (host model)
  in Phase 4. Per-field granularity may land later if a real need
  surfaces.
- **No GIN indexes on `before_value` / `after_value` content.** Apps
  that need to query inside the snapshot jsonb add their own indexes.
  Phase 4 ships only the temporal indexes (`changed_at DESC` keyed on
  `value_id`, `(entity_type, entity_id)`, and `field_id`).

For the gem’s callback metadata and test setup, see [Development and test isolation](development.md).
