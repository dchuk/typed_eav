---
phase: 3
title: Event System — Implementation Research
type: research
confidence: high
date: 2026-04-30
---

## Findings

### Pre-read: Locked constraints from 03-CONTEXT.md

Every item below treats these as fixed constraints. No section re-opens them.

1. `Config.on_value_change` / `Config.on_field_change` — public single-proc slots via `ActiveSupport::Configurable`.
2. Private internal-subscribers arrays fire FIRST in registration order; user proc fires LAST.
3. `:update` on Value fires only when `saved_change_to_attribute?(field.class.value_column)` is true.
4. `:create` / `:destroy` on Value always fire; `:create` / `:update` / `:destroy` / `:rename` on Field fire per locked branching logic.
5. Internal subscribers raise; user proc is `rescue StandardError` + `Rails.logger.error` + no re-raise.
6. `with_context(**kwargs)` is a thread-local stack with shallow per-key merge and ensure-pop.
7. `EventDispatcher` module is the locus of dispatch logic; internal-subscriber registration is first-party only.

---

## A. Value `after_commit` lifecycle and `saved_changes` shape

### Rails 8.1 confirmation (context7 source: `/rails/rails/v8.1.2`)

`after_commit` fires once per top-level transaction commit, AFTER the database write is durable. Exceptions inside `after_commit` do NOT roll back the saved record — the row is already committed. This distinction from `after_save` is documented explicitly in the Rails 8.1 callback guide.

`saved_changes` / `saved_change_to_attribute?` are `ActiveModel::Dirty` "previously changed" methods. After `save` returns (i.e., inside `after_commit`), `saved_changes` contains `{ "attr_name" => [before, after] }` for every attribute whose persisted value changed in the just-committed transaction. The predicate `saved_change_to_attribute?(:foo)` returns `true` iff `saved_changes.key?("foo")`. This is confirmed by the `previous_changes` / `previously_changed?` documentation in the Rails guide — `previous_changes` is the same hash accessible as `saved_changes` after `changes_applied` is called on save.

**Specific lifecycle behaviors:**

- **`:create`** — Inside `after_commit on: :create`, `saved_changes` includes all columns that transitioned from nil/default. For a Value row, this will include the typed column (if a non-nil value was written), `field_id`, `entity_id`, `entity_type`, `created_at`, `updated_at`. The `created?` predicate (alias: `previously_new_record?`) returns true.
- **`:update`** — Inside `after_commit on: :update`, `saved_changes` contains ONLY the columns that changed in this transaction. If only `string_value` changed, only `"string_value"` appears. `saved_change_to_attribute?(:string_value)` would be true; `saved_change_to_attribute?(:integer_value)` would be false.
- **`:destroy`** — Inside `after_commit on: :destroy`, `destroyed?` returns true. `saved_changes` is not meaningful for dispatch (we always fire `:destroy`). The record object remains in memory with its last attribute values; `field_id` is readable.

**Three-callback vs one-callback question:**

Recommendation: use THREE separate callbacks with `on:` option — `after_commit on: :create`, `after_commit on: :update`, `after_commit on: :destroy`. This is idiomatic Rails 8.1 (guide explicitly lists `after_create_commit`, `after_update_commit`, `after_destroy_commit` as aliases). The three-callback form avoids an explicit `if created? / elsif destroyed? / else` branch inside a single method body.

WARNING from Rails 8.1 docs: "Defining both `after_create_commit` and `after_update_commit` with the same method name causes only the last one to execute, as they both alias to `after_commit` internally." This means you CANNOT use the convenience alias form (`after_create_commit :_dispatch_value_change`) and then `after_update_commit :_dispatch_value_change` — the second registration wins. Use the explicit `after_commit :method_name, on: :create` / `on: :update` / `on: :destroy` form to avoid this.

**Insertion point in `app/models/typed_eav/value.rb`:**

Current callbacks section (line 125-126):
```
# ── Callbacks ──
after_initialize :apply_pending_value
```

Add the three `after_commit` declarations immediately after `after_initialize :apply_pending_value` at line 126. The ordering matters: `after_initialize` fires before save; `after_commit` fires after commit. They do not overlap. Concrete insertion is after line 126, before the blank line at line 128 (start of `private`).

**`field.class.value_column` when `destroyed?` is true:**

`Value#destroyed?` is true inside `after_commit on: :destroy`. The `field` association (`belongs_to :field, optional: true`) is loaded in memory from before the destroy. The AR `destroy` sequence: (1) runs `before_destroy` callbacks, (2) executes the DELETE SQL, (3) marks the record frozen/destroyed, (4) runs `after_commit`. At step 4, `self.field` is still accessible via the in-memory AR object — the association object was loaded before the delete and was not separately destroyed (unless `field_dependent: :destroy` on the FIELD side was running, but that is Field destroying its Values, not a Value destroying its own Field). 

The association is `optional: true` (field_id nullable since Phase 02 migration `20260501000000`). An orphan Value (field_id NULL) has `field.nil? == true` even before destroy. The guard is:

```ruby
after_commit on: :destroy do
  return unless field  # orphan guard — field_id was NULL; skip dispatch
  EventDispatcher.dispatch_value_change(self, :destroy)
end
```

The `field` instance var is still readable inside `after_commit on: :destroy` — `destroy` does not nil out associations. This is standard Rails behavior (associations are loaded into memory, and the AR freeze only prevents attribute mutation, not reading).

**`:update` filter with `value_column`:**

```ruby
after_commit on: :update do
  return unless field  # orphan guard
  return unless saved_change_to_attribute?(field.class.value_column)
  EventDispatcher.dispatch_value_change(self, :update)
end
```

`value_column` is a delegating reader on `Value` (line 92-94: `def value_column; field.class.value_column; end`). Inside `after_commit on: :update`, `field` is still the in-memory object. If `field` is nil (orphan value that just had another column updated), the first guard short-circuits. If `field` is present, `field.class.value_column` returns the correct symbol (e.g., `:string_value`). `saved_change_to_attribute?` accepts either a symbol or string; Rails normalizes internally.

**Orphan Value `:update` decision (locked):** Do NOT fire `:update` for orphan Values (field nil). The event shape `(value, change_type, context)` assumes `value.field` is accessible for consumers. An orphan with field nil would confuse downstream consumers. Decision: guard `return unless field` at the top of all three dispatch methods.

---

## B. Field `after_commit` lifecycle, `:rename` detection, and Phase 02 cascade interaction

### STI: callback on `Field::Base` covers all subclasses

`Field::Base` is the STI parent (`self.table_name = "typed_eav_fields"`). AR callbacks declared on the STI parent fire for every subclass instance. This is the correct level — declaring `after_commit` on `Field::Base` at `app/models/typed_eav/field/base.rb` ensures Text, Integer, Select, etc., all fire field-change events without duplication. No subclass override needed.

### Insertion point in `app/models/typed_eav/field/base.rb`

Current callbacks section (lines 61-71):
```
# ── Callbacks ──
# Dispatch on `field_dependent`. Runs BEFORE the field row is deleted...
before_destroy :dispatch_field_dependent
```

Add the `after_commit` callback declaration immediately after `before_destroy :dispatch_field_dependent` at line 71. This keeps all callbacks co-located in the `# ── Callbacks ──` section.

### `:rename` detection — exact branching shape

The locked decision (03-CONTEXT.md line 47-51):
- `created?` → `:create`
- `destroyed?` → `:destroy`
- `else if saved_change_to_attribute?(:name)` → `:rename`
- `else` → `:update`

This branches in a single `after_commit` callback (not three separate ones). Reason: `:rename` requires `saved_change_to_attribute?(:name)` which is only meaningful in the `:update` path. A three-callback split would put `:rename` inside the `on: :update` callback, which is fine, but using a single method with explicit branching is slightly cleaner for the Field case since `:rename` and `:update` share the same lifecycle trigger.

Recommended shape:
```ruby
after_commit :_dispatch_field_change

private

def _dispatch_field_change
  change_type = if created?
                  :create
                elsif destroyed?
                  :destroy
                elsif saved_change_to_attribute?(:name)
                  :rename
                else
                  :update
                end
  EventDispatcher.dispatch_field_change(self, change_type)
end
```

`saved_change_to_attribute?` with a string or symbol: both work in Rails 8; `:name` (symbol) is idiomatic. Confirmed: the `saved_change_to_*` family normalizes symbols to string keys internally since Rails 5.1+.

### Phase 02 cascade interaction — critical path

**Confirmed from Phase 02 SUMMARY (02-01-SUMMARY.md line 25-27):** The FK `typed_eav_values.field_id` is now `ON DELETE SET NULL` (not ON DELETE CASCADE). The AR `has_many :values` on `Field::Base` has no `dependent: :destroy` (removed in Phase 02, line 28-32 of `field/base.rb`). The `before_destroy :dispatch_field_dependent` handles three policies:

1. **`field_dependent: "destroy"`** — `values.destroy_all` is called explicitly inside `before_destroy`. This fires AR's destroy chain on each Value row, which means the Value `after_commit on: :destroy` callback WILL fire per Value row (AR `destroy_all` calls `destroy` on each record individually via AR). So Value `:destroy` events ARE fired per-row when the field uses `field_dependent: "destroy"`.

2. **`field_dependent: "nullify"`** — `before_destroy` is a no-op. The FK `ON DELETE SET NULL` fires at the DB level, NULLing `field_id` on Value rows without touching them via AR. The Value `after_commit on: :destroy` callback does NOT fire — the Value rows are NOT destroyed, they are merely updated (field_id → NULL). No Value `:destroy` events fire. No Value `:update` events fire either (the DB-level FK action bypasses AR callbacks entirely). Downstream consumers (Phase 4 versioning, Phase 7 matview) must NOT expect `:destroy` events on Value rows when a Field with `field_dependent: "nullify"` is destroyed. Document this explicitly in EventDispatcher.

3. **`field_dependent: "restrict_with_error"`** — `throw(:abort)` prevents the Field destroy entirely. No cascade occurs. No Value events fire.

**Summary for the planner:** When `field_dependent: "destroy"`, each Value row is AR-destroyed → Value `after_commit on: :destroy` fires per row → EventDispatcher receives `:destroy` per Value. When `field_dependent: "nullify"`, no Value events fire (DB-level FK action, not AR destroy). The Field `after_commit on: :destroy` fires ONCE for the Field row itself in all non-abort cases.

**Important sequencing nuance:** `values.destroy_all` runs inside `before_destroy` (pre-transaction commit). This means the Value destroy calls are nested inside the same transaction as the Field destroy. In Rails, `after_commit` callbacks for all records in a transaction run after the outermost `commit`. So in a single `field.destroy!` call:
- The transaction wraps: `dispatch_field_dependent` (→ `values.destroy_all`) + Field row DELETE.
- After commit: all Value `after_commit on: :destroy` callbacks fire, then the Field `after_commit on: :destroy` fires.
- The order among Value and Field `after_commit` callbacks within a single transaction is deterministic in Rails 8: callbacks fire in the order their respective records were committed (Values first since `destroy_all` precedes the Field delete).

---

## C. `with_context` mirror of `with_scope`

### File location and constant

Lives in `lib/typed_eav.rb` alongside `with_scope`. Mirror the thread-local-key declaration pattern at lines 23-25:

```ruby
THREAD_SCOPE_STACK   = :typed_eav_scope_stack
THREAD_UNSCOPED      = :typed_eav_unscoped
THREAD_CONTEXT_STACK = :typed_eav_context_stack   # NEW
private_constant :THREAD_SCOPE_STACK, :THREAD_UNSCOPED, :THREAD_CONTEXT_STACK
```

The `private_constant` call at line 25 already lists both existing constants. Extend the argument list to include `THREAD_CONTEXT_STACK`.

### Exact implementation shape

Based on `with_scope` (lines 124-130):

```ruby
def with_context(**kwargs)
  stack = (Thread.current[THREAD_CONTEXT_STACK] ||= [])
  merged = (stack.last || {}).merge(kwargs).freeze
  stack.push(merged)
  yield
ensure
  stack&.pop
end

def current_context
  Thread.current[THREAD_CONTEXT_STACK]&.last || {}
end
```

Key differences from `with_scope`:
- Input is `**kwargs` not a single positional arg — enforces keyword-argument form, no bare Hash ambiguity.
- Value pushed is a pre-merged frozen Hash: `(stack.last || {}).merge(kwargs).freeze`. This is the locked decision from 03-CONTEXT.md line 56 ("stack stores pre-merged hashes... pushed on entry").
- `current_context` returns `stack.last || {}` — always returns a frozen Hash or `{}` (empty, unfrozen). The `{}` fallback means callers can call `.fetch` on the result without nil-guarding.
- No `normalize_scope` analog needed — context is already a Hash, no coercion required.

**`freeze` safety:** `Hash#merge` returns a NEW Hash; `freeze` prevents mutation of that new hash. Any callback that receives the context hash and attempts to mutate it will get `FrozenError` — this is intentional (context is read-only for callbacks). Documented in the method comment as "Without freeze, a callback modifying the context hash would corrupt the stack for the current and any outer with_context blocks."

**`**kwargs` vs `Hash` positional arg:** `**kwargs` enforces keyword syntax: `TypedEAV.with_context(request_id: "abc")` works; `TypedEAV.with_context({ request_id: "abc" })` raises `ArgumentError` in Ruby 3.0+ (kwargs/Hash separation). This is a cleaner contract than `with_scope`'s permissive positional arg, matching the locked decision's "shallow per-key merge" semantics where keys are always symbols.

**Return value from `with_context`:** Returns the block's return value (yield return falls through). `ensure; stack&.pop` guarantees pop even on exception — identical pattern to `with_scope` lines 128-130.

### Verifying `with_scope` ensure-pop pattern (lines 124-130)

```ruby
def with_scope(value)
  stack = (Thread.current[THREAD_SCOPE_STACK] ||= [])
  stack.push(normalize_scope(value))
  yield
ensure
  stack&.pop
end
```

`with_context` mirrors this exactly, substituting:
- `THREAD_SCOPE_STACK` → `THREAD_CONTEXT_STACK`
- `normalize_scope(value)` → `(stack.last || {}).merge(kwargs).freeze`

The `stack&.pop` safe-navigation is a guard for the theoretical case where `stack` was nil — practically impossible since the `||= []` assignment ensures it's always an Array, but the pattern is preserved for consistency.

---

## D. EventDispatcher module placement and internal-subscribers list

### Module placement

`lib/typed_eav/event_dispatcher.rb` — mirrors `lib/typed_eav/registry.rb` placement exactly. 

Add `autoload :EventDispatcher` to `lib/typed_eav.rb` at line 14-17 (the autoload block):

```ruby
autoload :Config
autoload :Registry
autoload :HasTypedEAV
autoload :QueryBuilder
autoload :EventDispatcher   # NEW — Phase 3 event system
```

Also add `require_relative "event_dispatcher"` to the `"typed_eav.autoload"` initializer in `lib/typed_eav/engine.rb` alongside the existing `require_relative "config"` and `require_relative "registry"` lines (lines 8-10). This mirrors how `config` and `registry` are eager-loaded at engine initialization.

### Internal-subscribers list: class-level array on `EventDispatcher`

NOT on `Config`. Rationale: `Config` owns user-facing configuration; `EventDispatcher` owns dispatch mechanics. The internal list is an implementation detail of dispatch, not a user-facing config knob. Keeping it on `EventDispatcher` allows `EventDispatcher.reset!` to manage its own state without touching `Config`.

Shape:

```ruby
module TypedEAV
  module EventDispatcher
    class << self
      def value_change_internals
        @value_change_internals ||= []
      end

      def field_change_internals
        @field_change_internals ||= []
      end

      # Register a first-party internal subscriber for value-change events.
      # Internal subscribers fire BEFORE the user proc (Config.on_value_change).
      # Exceptions from internal subscribers propagate (fail-closed — versioning
      # corruption must be loud). Phase 4 versioning calls this at engine load
      # time and is slot 0 by convention.
      #
      # Not private_class_method: Phase 4 versioning lives in a separate
      # namespace (TypedEAV::Versioning::*) and cannot call a truly-private
      # method. Convention instead: the name and this comment signal
      # "first-party only" to gem extension authors.
      def register_internal_value_change(callable)
        value_change_internals << callable
      end

      def register_internal_field_change(callable)
        field_change_internals << callable
      end

      # Clears internal subscribers and user procs. Used by test teardown
      # (spec :event_callbacks opt-in) and NOT called by Config.reset! —
      # engine-load registrations (Phase 4 versioning) must survive Config.reset!
      # since Config.reset! is called frequently in scoping_spec/field_spec etc.
      def reset!
        @value_change_internals = []
        @field_change_internals = []
        TypedEAV::Config.on_value_change = nil
        TypedEAV::Config.on_field_change = nil
      end

      def dispatch_value_change(value, change_type)
        value_change_internals.each { |cb| cb.call(value, change_type, TypedEAV.current_context) }
        user = TypedEAV::Config.on_value_change
        return unless user

        begin
          user.call(value, change_type, TypedEAV.current_context)
        rescue StandardError => e
          Rails.logger.error(
            "[TypedEAV] on_value_change raised: #{e.class}: #{e.message} " \
            "(value_id=#{value.id} field_id=#{value.field_id} change_type=#{change_type})"
          )
        end
      end

      def dispatch_field_change(field, change_type)
        field_change_internals.each { |cb| cb.call(field, change_type) }
        user = TypedEAV::Config.on_field_change
        return unless user

        begin
          user.call(field, change_type)
        rescue StandardError => e
          Rails.logger.error(
            "[TypedEAV] on_field_change raised: #{e.class}: #{e.message} " \
            "(field_id=#{field.id} field_name=#{field.name} change_type=#{change_type})"
          )
        end
      end
    end
  end
end
```

### Rails.logger keyword-args question

The `Rails.logger.error` keyword-args question from 03-CONTEXT.md. In Rails 8, `Rails.logger` is a `ActiveSupport::Logger` (or `ActiveSupport::BroadcastLogger`). The underlying Logger API is `logger.error(message)` — single positional string. There is NO keyword-args variant in the standard Logger API. The structured hash form (`Rails.logger.error(message, key: val)`) is NOT supported by the default Rails logger. Some third-party logging adapters (Semantic Logger, `lograge`) accept keyword args, but the default does not.

**Recommendation:** Concatenate structured info into the message string, as shown in the dispatch shape above:
```ruby
Rails.logger.error(
  "[TypedEAV] on_value_change raised: #{e.class}: #{e.message} " \
  "(value_id=#{value.id} field_id=#{value.field_id} change_type=#{change_type})"
)
```

This is consistent with PATTERNS.md §"Errors tell you how to fix it" — include enough context inline. The 03-CONTEXT.md "logging shape" (line 40) shows the keyword-args form as aspirational; fall back to concatenated string.

⚠ POSSIBLE DECISION REVISIT: The `on_field_change` signature in 03-CONTEXT.md is `(field, change_type)` — TWO args, no `context`. Compare: `on_value_change` signature is `(value, change_type, context)` — THREE args. This asymmetry is locked in 03-CONTEXT.md (line 11-12) and in the phase boundary description. The planner should confirm whether `on_field_change` intentionally omits `context` (Field changes are structural, not entity-level operations, so thread context is less relevant) or if this is an oversight. Both the dispatch method shape and the spec shape need to be consistent.

### `Config.reset!` current behavior

`lib/typed_eav/config.rb` lines 124-128:
```ruby
def reset!
  self.field_types = BUILTIN_FIELD_TYPES.dup
  self.scope_resolver = DEFAULT_SCOPE_RESOLVER
  self.require_scope = true
end
```

`Config.reset!` does NOT reset `on_value_change` / `on_field_change` (they don't exist yet). When Phase 3 adds `config_accessor :on_value_change, default: nil` and `config_accessor :on_field_change, default: nil`, they MUST also be reset in `Config.reset!`:

```ruby
def reset!
  self.field_types = BUILTIN_FIELD_TYPES.dup
  self.scope_resolver = DEFAULT_SCOPE_RESOLVER
  self.require_scope = true
  self.on_value_change = nil   # NEW
  self.on_field_change = nil   # NEW
end
```

The `EventDispatcher.reset!` method (shown above) calls `Config.on_value_change = nil` and `Config.on_field_change = nil` itself, so there is overlap. The planner should decide: either `Config.reset!` clears the user procs and `EventDispatcher.reset!` only clears internal subscribers, or `EventDispatcher.reset!` is the single point. The safer design: `Config.reset!` resets user procs (it already owns them), and `EventDispatcher.reset!` ONLY clears internal subscribers. Test teardown calls BOTH when it needs a full reset.

---

## E. Wiring `after_commit` into Value and Field

### Value — three private dispatch methods + three `after_commit` declarations

Idiomatic form using explicit `after_commit on:` (avoids the alias collision documented in section A):

```ruby
# ── Callbacks ──
after_initialize :apply_pending_value
after_commit :_dispatch_value_change_create,  on: :create
after_commit :_dispatch_value_change_update,  on: :update
after_commit :_dispatch_value_change_destroy, on: :destroy
```

Private methods:
```ruby
def _dispatch_value_change_create
  return unless field
  TypedEAV::EventDispatcher.dispatch_value_change(self, :create)
end

def _dispatch_value_change_update
  return unless field
  return unless saved_change_to_attribute?(field.class.value_column)
  TypedEAV::EventDispatcher.dispatch_value_change(self, :update)
end

def _dispatch_value_change_destroy
  return unless field
  TypedEAV::EventDispatcher.dispatch_value_change(self, :destroy)
end
```

Each method delegates immediately to `EventDispatcher` — models stay thin, dispatch logic is testable in isolation without instantiating AR records.

The leading underscore on `_dispatch_value_change_*` signals "internal callback method, not part of public interface" — same convention used elsewhere in Rails-generated code. These live in the `private` block that begins at line 128.

### Field — single dispatch method

As discussed in Section B, Field uses a single `after_commit` that branches internally (needed because `:rename` is a sub-case of the `:update` lifecycle):

```ruby
# In ── Callbacks ── section, after before_destroy :dispatch_field_dependent
after_commit :_dispatch_field_change
```

Private method (appended to existing `private` block):
```ruby
def _dispatch_field_change
  change_type = if created?
                  :create
                elsif destroyed?
                  :destroy
                elsif saved_change_to_attribute?(:name)
                  :rename
                else
                  :update
                end
  TypedEAV::EventDispatcher.dispatch_field_change(self, change_type)
end
```

Note: `created?` is `previous_new_record?` — available in Rails 6.1+ (and Rails 8). Confirmed by the Rails dirty-tracking docs: `new_record?` returns true before save; `previously_new_record?` / `created?` returns true inside `after_commit` for records that were just inserted.

### Model thinness principle

Both `_dispatch_value_change_*` and `_dispatch_field_change` contain zero dispatch logic — they are forwarding methods. All branching for internal-vs-user proc, error handling, and context injection lives in `EventDispatcher`. This means EventDispatcher can be unit-tested with doubles (no AR needed), and model tests can stub `EventDispatcher.dispatch_value_change` cleanly.

### `value_column` as symbol vs string in `saved_change_to_attribute?`

`field.class.value_column` returns a Symbol (per `ColumnMapping` DSL: `value_column :integer_value` stores `:integer_value`). `saved_change_to_attribute?` accepts Symbol or String in Rails 8 (normalizes to string key internally). No coercion needed.

---

## F. Test pattern: `:event_callbacks` opt-in metadata

### Existing `:scoping` / `:unscoped` pattern verbatim

From `spec/spec_helper.rb` lines 59-65:
```ruby
config.around do |example|
  if example.metadata[:unscoped]
    TypedEAV.unscoped { example.run }
  elsif example.metadata[:scoping]
    # :scoping examples manage scope explicitly — no wrapping,
    # but this branch ensures the check is an elsif, not two ifs,
    # so :scoping examples never accidentally enter the unscoped block.
    example.run
  else
    example.run
  end
end
```

Actually the current code at lines 59-65 is simpler (only checks `:unscoped`; `:scoping` is handled by metadata on the describe block with a `before`/`after` in the spec itself). The relevant pattern is the `config.around` hook.

### Proposed `:event_callbacks` around hook for spec_helper.rb

```ruby
config.around(:each, :event_callbacks) do |example|
  # Snapshot current proc state
  saved_on_value_change   = TypedEAV::Config.on_value_change
  saved_on_field_change   = TypedEAV::Config.on_field_change
  saved_value_internals   = TypedEAV::EventDispatcher.value_change_internals.dup
  saved_field_internals   = TypedEAV::EventDispatcher.field_change_internals.dup

  # Clear for the example
  TypedEAV::Config.on_value_change = nil
  TypedEAV::Config.on_field_change = nil
  TypedEAV::EventDispatcher.value_change_internals.clear
  TypedEAV::EventDispatcher.field_change_internals.clear

  example.run
ensure
  # Restore
  TypedEAV::Config.on_value_change = saved_on_value_change
  TypedEAV::Config.on_field_change = saved_on_field_change
  TypedEAV::EventDispatcher.instance_variable_set(:@value_change_internals, saved_value_internals)
  TypedEAV::EventDispatcher.instance_variable_set(:@field_change_internals, saved_field_internals)
end
```

**Critical design note:** This hook uses snapshot-and-restore (not `EventDispatcher.reset!`). The reason: `EventDispatcher.reset!` wipes both the internal list AND the user procs. If Phase 4 versioning has already registered on the internal list at engine load time (as spec'd in 03-CONTEXT.md line 59), calling `reset!` in teardown would wipe that registration and break Phase 4 specs that follow. Snapshot-restore preserves engine-load registrations across the example boundary.

The `config.around(:each, :event_callbacks)` form (passing metadata key as second argument) is the same pattern used throughout RSpec for opt-in around hooks. Examples opt in with `:event_callbacks` metadata: `RSpec.describe "...", :event_callbacks do`.

**Why NOT use `Config.reset!` for this:** `Config.reset!` resets `field_types`, `scope_resolver`, `require_scope` — things event-callback specs don't need to reset. Layering `:event_callbacks` as a separate opt-in avoids unintentional side effects (e.g., clearing a custom `scope_resolver` set up in a `before` block of the same spec).

### `with_context` spec pattern (mirrors `with_scope` specs in scoping_spec.rb)

Mirror the `with_scope` spec structure (scoping_spec.rb lines 16-44). Key cases for `with_context`:

1. Sets context inside block.
2. Restores prior context after block exits (nesting).
3. Restores prior context even when block raises (exception safety).
4. Shallow merge: outer keys visible inside inner block; inner key overrides outer on collision.
5. `current_context` returns `{}` outside any block (not nil).
6. Context is frozen — mutation inside callback raises `FrozenError`.

These live in a new `spec/lib/typed_eav/event_context_spec.rb` or appended to `scoping_spec.rb`.

---

## G. Open Questions for the Planner

1. **`on_field_change` context parameter:** `on_value_change` receives `(value, change_type, context)` (3 args). `on_field_change` in 03-CONTEXT.md line 11 is described as `(field, change_type)` (2 args — no context). Confirm this is intentional. If Field-change events should also carry `with_context` data (e.g., `changed_by` actor when renaming a field from an admin UI), the signature should be `(field, change_type, context)` for consistency. Changing it later would be a BC break on the user-proc signature. The internal `field_change_internals` callable shape should match the public shape.

2. **`self.field` inside `after_commit on: :destroy` for Value:** Confirmed readable via in-memory AR object (see Section A). However, if a Value is destroyed inside a `values.destroy_all` called from Field's `before_destroy` (the `field_dependent: "destroy"` path), the Field record is in the process of being destroyed in the same transaction. Inside the Value's `after_commit on: :destroy`, `self.field` will return the Field AR object (still in memory) but the Field row in the DB is ALSO deleted (the transaction committed everything). This is safe for reading `field.class.value_column` (a class method call, no DB query), but callers of `value.field` inside the user proc should be warned that the Field row no longer exists in the DB. Document in the dispatch method comment: "⚠ Inside `:destroy` callbacks when triggered by `field_dependent: :destroy`, the `value.field` object is in-memory but the DB row may be gone."

3. **`current_context` return value frozen-ness:** `stack.last` is a frozen Hash (pushed pre-frozen). The `{}` fallback is NOT frozen. Decide: should `current_context` return `{}.freeze` (always frozen) or just `{}` (unfrozen empty hash)? Recommendation: `{}.freeze` — ensures callers cannot mutate the "no context" path either, consistent behavior regardless of whether a `with_context` block is active.

4. **`EventDispatcher` autoload vs eager-load:** The current `engine.rb` uses `require_relative` for `config` and `registry` inside `initializer "typed_eav.autoload"`. If `EventDispatcher` is declared as `autoload :EventDispatcher` in `lib/typed_eav.rb`, it will be lazily loaded on first reference. But if Phase 4 versioning registers on `EventDispatcher.register_internal_value_change` during engine initialization, the EventDispatcher must be loaded BEFORE Phase 4's initializer runs. Safest: add `require_relative "event_dispatcher"` to the `"typed_eav.autoload"` initializer in `engine.rb` alongside `config` and `registry`, ensuring it is eager-loaded at engine start.

5. **Where does `EventDispatcher.dispatch_value_change` get `value.id`?** Inside `after_commit on: :destroy`, the record is frozen (AR sets the "destroyed" flag). `value.id` should still be readable (AR frozen records allow attribute reads). Verify with a `⚠ REQUIRES LIVE VALIDATION` note: confirm that `value.id` is accessible inside `after_commit on: :destroy` on a frozen AR record. This affects the error log message in `rescue StandardError`.

---

## Relevant Patterns

- **`ActiveSupport::Configurable` pattern** (`PATTERNS.md` §"Configurables via `ActiveSupport::Configurable`"): `config_accessor :on_value_change, default: nil` and `config_accessor :on_field_change, default: nil`. The block-form default (`config_accessor(:foo) { mutable_default }`) is used when the default is a mutable object; `nil` defaults use the keyword form.
- **`private_constant` for thread-local keys** (`lib/typed_eav.rb` lines 23-25): extend the list to include `THREAD_CONTEXT_STACK`.
- **Naming: leading underscore on callback methods** (`_dispatch_value_change_create` etc.): signals internal-callback-method convention.
- **Comment style: "Without this, ..." rationale** (`PATTERNS.md` §"Comment the failure mode"): every new comment in dispatch methods should explain what would break.
- **`idx_te_*` index naming** (`PATTERNS.md`): no new indexes required for Phase 3 — event system is in-process, no new tables.
- **`frozen_string_literal: true`** — required on `lib/typed_eav/event_dispatcher.rb` per codebase convention (`.context-scout.md` conventions line 87).

---

## Risks

1. **Alias collision for `after_commit`:** Using `after_create_commit :method` and `after_update_commit :method` with the same method name causes the last registration to win (Rails 8.1 docs, context7 confirmed). Use `after_commit :method, on: :create` / `on: :update` / `on: :destroy` form exclusively.

2. **`field_dependent: "nullify"` produces no Value `:destroy` events:** The DB-level FK `ON DELETE SET NULL` bypasses AR callbacks. Consumers (Phase 4, Phase 7) must not assume Value `:destroy` events fire when a Field is destroyed with `field_dependent: "nullify"`. Document in `EventDispatcher` inline comments.

3. **`values.destroy_all` inside `before_destroy` — nested transaction:** `dispatch_field_dependent` (`before_destroy`) calls `values.destroy_all` inside the same outer transaction. `destroy_all` uses AR destroy (not `delete_all`), so each Value's `before_destroy` / `after_commit` chain fires. `after_commit` for the Values fires after the outermost commit (same transaction as Field delete). This is correct behavior but means Value `:destroy` events and the Field `:destroy` event all fire together in the same post-commit batch.

4. **`current_context` read performance:** Stack reads are O(1) (`stack.last`). No concern.

5. **Test isolation regression:** If `Config.reset!` is amended to also reset `on_value_change` / `on_field_change`, any existing spec that calls `Config.reset!` in `after` (currently: `scoping_spec.rb` line 8) will now also clear user procs. This is correct behavior but means Phase 4/7 engine-load registrations (stored on `EventDispatcher.value_change_internals`, NOT on `Config`) survive `Config.reset!`. Internal-subscribers list is separate from Config — survives `Config.reset!`.

---

## Recommendations

1. Add `config_accessor :on_value_change, default: nil` and `config_accessor :on_field_change, default: nil` to `lib/typed_eav/config.rb` (after line 102, alongside `require_scope`). Extend `Config.reset!` to reset both to nil.

2. Add `THREAD_CONTEXT_STACK = :typed_eav_context_stack` and extend the `private_constant` call in `lib/typed_eav.rb` (lines 23-25). Add `with_context(**kwargs)` and `current_context` to the `class << self` block.

3. Create `lib/typed_eav/event_dispatcher.rb` with the `EventDispatcher` module shape from Section D. Add `autoload :EventDispatcher` to `lib/typed_eav.rb` and `require_relative "event_dispatcher"` to `engine.rb`.

4. Wire three `after_commit` callbacks on `Value` (lines after 126), three private `_dispatch_value_change_*` methods in the `private` block.

5. Wire one `after_commit :_dispatch_field_change` on `Field::Base` (after line 71 in callbacks section), one private `_dispatch_field_change` method in the `private` block.

6. Add the `:event_callbacks` around hook to `spec/spec_helper.rb` using snapshot-restore (not `EventDispatcher.reset!`).

7. Resolve the `on_field_change` context-parameter open question (Section G item 1) before plan execution — changing the proc arity later is a BC break.

8. Add `{}.freeze` as the `current_context` fallback (not bare `{}`).
