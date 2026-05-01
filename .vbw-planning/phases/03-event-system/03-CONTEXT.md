# Phase 3: Event system — Context

Gathered: 2026-04-30
Calibration: architect

## Phase Boundary

Define the event/context contract that Phase 4 versioning and Phase 7 materialized index both depend on:

- `Config.on_value_change = ->(value, change_type, context) { ... }` fires from `after_commit` on `Value` with `change_type ∈ [:create, :update, :destroy]`.
- `Config.on_field_change = ->(field, change_type) { ... }` companion hook on `Field`.
- `TypedEAV.with_context(...) { ... }` thread-local context stack mirroring `with_scope`; nests cleanly; outer context restored on exception.
- Hooks fire in the correct order relative to `Value#apply_pending_value` lifecycle.
- Hooks receive `Value` / `Field` as parameters; never assume specific attribute names (foundational principle from ROADMAP cross-cutting requirements).

ROADMAP-locked: public proc shape (`Config.on_value_change = ->(value, change_type, context) { }`), value-event change_type set `[:create, :update, :destroy]`, fire from `after_commit`, `with_scope`-style ensure-pop stack semantics. This phase delivers the contract; Phase 4 versioning + Phase 7 matview opt in via the internal-subscribers list defined here.

## Decisions Made

### Callback registration shape

- **Decision:** Public single proc per slot (`Config.on_value_change`, `Config.on_field_change`) backed by `ActiveSupport::Configurable`, plus a private internal-subscribers array that fires FIRST. User proc fires LAST.
- **Mechanism:** `TypedEAV::EventDispatcher` (or equivalent) module exposes private `register_internal_value_change(callable)` / `register_internal_field_change(callable)` for first-party features (Phase 4 versioning, Phase 7 index DDL regen). Internal subscribers run in registration order; user proc runs after all of them.
- **Rationale:** Matches ROADMAP literally (`Config.on_value_change = ->(value, change_type, context) { }` is the documented public surface). Versioning + matview slot in deterministically without exposing a subscription protocol or forcing users to manually chain via super-style calls. A user reassigning `on_value_change` after gem initialization cannot silently disable Phase 4/7 features. Aligns with the codebase's `ActiveSupport::Configurable` pattern (see PATTERNS.md §"Configurables via ActiveSupport::Configurable").
- **Rejected alternatives:** ActiveSupport::Notifications (would change the ROADMAP-locked public shape; `instrument` Hash payloads don't carry the positional `(value, change_type, context)` signature). Pure single proc with no internal list (forces users to chain Phase 4 versioning into their own proc; reassigning `on_value_change` silently breaks versioning).

### `:update` firing semantics

- **Decision:** Fire `:update` on Value only when `saved_change_to_attribute?(field.class.value_column)` is true. `after_commit` callbacks that find no value-column change in `saved_changes` are no-ops.
- **Rationale:** A Value row's only meaningful state for downstream consumers is the typed column for its field. `apply_pending_value` (after_initialize) does not dirty the row, so this filter composes with the existing lifecycle. Avoids no-op version rows in Phase 4 (`typed_eav_value_versions` would otherwise pile up empty diffs) and avoids spurious matview refreshes in Phase 7.
- **Edge cases:** `entity_id` repointing or other column shifts are out-of-spec for `Value`; not fired. `:create` fires after the first commit regardless. `:destroy` fires after destroy commit regardless.
- **Rejected alternatives:** Fire on every `after_commit` (pushes deduplication into Phase 4 versioning + Phase 7 matview, multiplying complexity downstream).

### User-callback error policy

- **Decision:** Split policy.
  - **Internal subscribers** (Phase 4 versioning, Phase 7 index DDL regen): exceptions propagate. No rescue. Failure is loud.
  - **User proc** (`Config.on_value_change`, `Config.on_field_change`): wrapped in `rescue StandardError`; exception logged via `Rails.logger.error` with hook name + value/field id + change_type; does NOT propagate.
- **Rationale:** Mirrors the codebase's "fail-closed defaults; document the bypass" pattern (see PATTERNS.md §"Fail-closed by default; document the bypass"). Versioning is an integrity feature whose silent failure corrupts version history → must surface. User `on_value_change` is observability glue (audit logs, metrics, broadcasts) whose failure must never break a save the user already initiated. Pre-emptively closes the asymmetric risk: versioning-bug-as-silent vs user-callback-bug-as-blocking.
- **Logging shape:** `Rails.logger.error("[TypedEAV] on_value_change raised: #{err.class}: #{err.message}", value_id: value.id, field_id: value.field_id, change_type: change_type)`. Stack trace included. Never re-raised. No fallback `Config.on_callback_error` hook in this phase — defer to a later phase if a consumer needs structured error routing.
- **Rejected alternatives:** Pass-through (matches Rails' default `after_commit` swallow but makes versioning failures invisible unless host sets `raise_in_transactional_callbacks=true`). Always-rescue+reraise (couples user-callback robustness to versioning pipeline; user-proc bug now raises through `after_commit` and breaks saves users didn't expect to break).

### `on_field_change` change_type set

- **Decision:** `[:create, :update, :destroy, :rename]`. `:rename` fires whenever `name` is among `Field#saved_changes`, even when `name` changed alongside other attrs (options, default_value_meta, sort_order, field_dependent, etc.) in the same save.
- **Mechanism:** In Field's `after_commit`, branch on lifecycle:
  - `created?` → `:create`
  - `destroyed?` → `:destroy`
  - else if `saved_change_to_attribute?(:name)` → `:rename`
  - else → `:update`
- **Rationale:** Phase 7 needs DDL distinguishability — `:rename` triggers `ALTER TABLE` / matview regen on `typed_eav_value_index_<entity>`; `:update` (option list change, default change, sort_order shuffle) does not require DDL. Escalating to `:rename` whenever `name` changes is the safer default: false-positive cost is a redundant DDL regen (cheap on the matview opt-in path, which is async via Active Job per ROADMAP); false-negative cost is a corrupted matview where the SQL column name doesn't match the field name.
- **Rejected alternatives:** `[:create, :update, :destroy]` only (Phase 7 has to inspect `saved_changes` itself or stash prior `name` in a thread-local before save — pushes rename-detection complexity downstream). `:rename` only when `name` is the ONLY change (clean on paper, but a real rename combined with an option edit fires `:update` and Phase 7 misses the DDL trigger — false-negative is the corrupting failure mode).

### Open (Claude's discretion)

- **`with_context` nested-merge semantics:** Shallow per-key merge. Outer `with_context(request_id: "abc", actor_id: 42)` keys remain visible when an inner `with_context(source: :bulk)` block opens; values overwrite per-key on collision; deep-merge of nested Hash values is NOT promised. Implementation: stack stores pre-merged hashes (`merged = stack.last&.merge(new) || new` pushed on entry; popped in `ensure`). Reading current context = `stack.last || {}` (no merge cost on reads). Frozen-Hash dup-on-push to prevent mutation leaks across blocks.
- **Default empty context:** `{}` — not `{ source: :system }`. Hooks receive `context` and can default-fill on their side (`context.fetch(:source, :system)`).
- **Hook ordering relative to `apply_pending_value`:** `apply_pending_value` is `after_initialize` (pre-save); hooks fire in `after_commit` (post-save). No collision — `after_commit` always sees the resolved typed columns, never `@pending_value`.
- **Phase 4 ordering hook (forward-looking):** Phase 4 versioning will register on the internal-subscribers list as the FIRST internal subscriber. This guarantees the Phase 4 success criterion "versioning runs first; user callbacks see the persisted version row." Phase 3 reserves slot 0 of the internal list for versioning; document this in the dispatcher source.
- **Test scaffolding:** Spec metadata `:event_callbacks` opt-in with an `around` hook in `spec_helper.rb` that resets `Config.on_value_change` / `Config.on_field_change` and clears the internal-subscribers list before each example. Mirrors the `:scoping` / `:unscoped` opt-in metadata pattern (see PATTERNS.md §"`:unscoped` metadata for class-query specs"). Default is no reset — registry persistence rules still apply.

## Deferred Ideas

- **`Config.use_active_support_notifications = true` opt-in** to also broadcast via `ActiveSupport::Notifications` alongside the proc API. Revisit if multiple consumers want pub/sub semantics for observability tooling (Datadog, OpenTelemetry, etc.). Out of scope for Phase 3 — proc API is the canonical surface.
- **Deep-merge semantics for nested `with_context`.** Rejected in favor of shallow merge for predictability. Revisit if a real use case for hierarchical context (e.g., nested operation tags) emerges.
- **`Config.on_callback_error` hook** for structured error routing (route hook exceptions to Sentry, custom logger, etc.). Phase 3 uses `Rails.logger.error` directly; defer until a consumer reports needing it.
- **`:value_change_filter` config** to let users opt out of the value-column-change filter (fire on every `after_commit` instead). Out of scope — the filter is a correctness invariant for Phase 4/7, not an observability preference.
