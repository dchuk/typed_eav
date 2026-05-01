---
phase: 3
plan: 02
title: Wire after_commit dispatch on Value/Field, add specs, document event hooks in README
status: complete
completed: 2026-05-01
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 7631f0a
  - d9cd538
  - 05f5e06
  - 65bb4d1
  - dd806ac
deviations:
  - "DEVN-02: Plan P02 prescribed `created?` as a Rails 6.1+ alias of `previously_new_record?`. That alias does not exist on activerecord 8.1.3 — verified via dummy-app probe (`previously_new_record?: true, created?: false, id_previously_changed?: true`). Substituted `previously_new_record?` (semantically identical, documented Rails predicate). All locked branch-order semantics from 03-CONTEXT.md preserved. Inline comment in field/base.rb#_dispatch_field_change documents the substitution."
pre_existing_issues: []
ac_results:
  - criterion: "Value model has three after_commit callbacks declared as `after_commit :method, on: :create|:update|:destroy` (NOT after_create_commit/after_update_commit/after_destroy_commit alias forms)"
    verdict: "pass"
    evidence: "app/models/typed_eav/value.rb lines 140-142 (commit 7631f0a). `grep after_commit app/` shows only the explicit `on:` form. Comment block at lines 128-139 explains the alias-collision rationale."
  - criterion: "Value :update callback fires only when `field && saved_change_to_attribute?(field.class.value_column)` — uses no hardcoded attribute name"
    verdict: "pass"
    evidence: "app/models/typed_eav/value.rb#_dispatch_value_change_update lines 305-310 reads value_column from field.class. value_event_spec.rb 'does NOT fire when only updated_at changes (touch path)' confirms the filter rejects touch path; live probe confirms touch DOES fire after_commit on :update (so the filter is doing real work, not relying on Rails empty-changes short-circuit)."
  - criterion: "Value :create and :destroy callbacks skip when `field.nil?` (orphan Value with NULL field_id)"
    verdict: "pass"
    evidence: "app/models/typed_eav/value.rb _dispatch_value_change_create line 302 and _dispatch_value_change_destroy line 314 both `return unless field`. value_event_spec.rb 'orphan Value (field.nil?) skip' covers the post-cascade reload-then-touch path."
  - criterion: "Field::Base has a single `after_commit :_dispatch_field_change` callback (no `on:` filter) whose branch order matches 03-CONTEXT.md verbatim"
    verdict: "pass"
    evidence: "app/models/typed_eav/field/base.rb line 95 (single `after_commit :_dispatch_field_change`). _dispatch_field_change body lines 668-679 branches `previously_new_record? → :create, destroyed? → :destroy, saved_change_to_attribute?(:name) → :rename, else :update`. STI parent declaration verified by field_event_spec.rb 'STI subclass dispatch' (covers Field::Text and Field::Integer)."
  - criterion: "Dispatch methods on both models forward immediately to TypedEAV::EventDispatcher.dispatch_value_change / dispatch_field_change — models stay thin"
    verdict: "pass"
    evidence: "Value's three forwarders contain only the orphan/value-column guards then a single `EventDispatcher.dispatch_value_change(self, change_type)` call (lines 303, 309, 316). Field's _dispatch_field_change ends with `EventDispatcher.dispatch_field_change(self, change_type)` (line 680). All policy (ordering, error handling, context capture) is in EventDispatcher, exercised by event_dispatcher_spec.rb."
  - criterion: "spec/spec_helper.rb has a `config.around(:each, :event_callbacks)` hook that snapshots Config.on_value_change, Config.on_field_change, EventDispatcher.value_change_internals.dup, EventDispatcher.field_change_internals.dup, runs the example, restores all four — uses snapshot/restore (NOT EventDispatcher.reset!)"
    verdict: "pass"
    evidence: "spec/spec_helper.rb lines 78-104 (commit 05f5e06). Snapshot via .dup; restore via instance_variable_set(:@value_change_internals, saved). No reset! call in the hook body."
  - criterion: "spec/spec_helper.rb has a separate `config.around(:each, :real_commits)` hook that disables transactional fixtures for the example and runs an after-block that manually deletes Value rows then Field::Base rows then Section rows (FK order)"
    verdict: "pass"
    evidence: "spec/spec_helper.rb lines 130-143. Per-example toggle via `example.example_group.use_transactional_tests = false/true`. Cleanup order: TypedEAV::Value → Option → Field::Base → Section → Contact/Product/Project. Smoke test confirmed after_commit fires durably under this hook (probe in /tmp during P03 verification, removed after green)."
  - criterion: "value.id is readable inside `after_commit on: :destroy` (verified via spec); error-log message in EventDispatcher correctly resolves value_id even on destroyed records"
    verdict: "pass"
    evidence: "value_event_spec.rb ':destroy event fires on destroy commit and value.id is readable inside the proc' captures `v.id` inside the user proc on a real destroy and asserts it equals the pre_destroy_id. Live validation passes — no fallback needed in EventDispatcher dispatch_value_change error-log line."
  - criterion: "Test coverage exists for: Value :create/:update/:destroy dispatch, :update filter (only fires when value_column changed), orphan Value skip, Field :create/:update/:destroy/:rename dispatch, :rename detection across multi-attr saves, STI subclass dispatch, internal-vs-user ordering, internal raise propagates / user raise rescued+logged, with_context nesting + frozen-hash + ensure-pop on raise"
    verdict: "pass"
    evidence: "spec/lib/typed_eav/event_dispatcher_spec.rb (22 examples covering ordering, context injection, error policy split, 2-arg field signature, reassignment safety, reset! split). spec/lib/typed_eav/event_context_spec.rb (10 examples covering nesting, freeze, ensure-pop, Hash-positional rejection, block-return passthrough). spec/models/typed_eav/value_event_spec.rb (9 examples). spec/models/typed_eav/field_event_spec.rb (10 examples covering all four change_types incl. :rename bundled with other attrs, STI Text+Integer dispatch, :nullify cascade interaction). 51 new examples total."
  - criterion: "README has new §\"Event hooks\" section after §\"Validation Behavior\" covering: signature shapes, with_context usage, error policy split, ordering guarantee, reset! split"
    verdict: "pass"
    evidence: "README.md §Event hooks at line 567 (commit dd806ac), between §Validation Behavior (553) and §Database Support (704). Covers public callback slots, :rename detection, :update value-column filter, :nullify cascade no-Value-events note, with_context shallow merge, frozen context, error policy split, ordering guarantee, :event_callbacks + :real_commits test isolation, reset! split table. Cross-reference bullet added at line 565."
  - criterion: "Full spec suite remains green (no regressions in scoping_spec, field_spec, value_spec, field_cascade_spec, etc.)"
    verdict: "pass"
    evidence: "`bundle exec rspec` → 547 examples, 0 failures. `bundle exec rspec --order rand` (seed 20236) → 547 examples, 0 failures. Spec count delta: +51 new examples (496 → 547). `bundle exec rubocop` → 64 files inspected, 0 offenses."
---

Completes Phase 03 (Event System / REQ-01) by wiring the `after_commit` dispatch on Value and Field::Base, landing comprehensive spec coverage with the `:event_callbacks` + `:real_commits` opt-in metadata pattern, and documenting the public event-hook contract in README.

## What Was Built

- Three explicit `after_commit ..., on: :create|:update|:destroy` declarations on `TypedEAV::Value` (NOT alias forms — Rails 8.1 alias-collision sidestep). Each forwards to a private `_dispatch_value_change_*` method that guards on `field.nil?` (orphan skip) and (for :update only) on `saved_change_to_attribute?(field.class.value_column)`, then delegates to `EventDispatcher.dispatch_value_change`.
- Single `after_commit :_dispatch_field_change` on `TypedEAV::Field::Base` (STI parent declaration covers all subclasses) with branch order locked to 03-CONTEXT.md: `previously_new_record? → :create, destroyed? → :destroy, saved_change_to_attribute?(:name) → :rename, else :update`. Forwards to `EventDispatcher.dispatch_field_change`.
- Two new spec_helper.rb metadata hooks: `:event_callbacks` (snapshot/restore Config.on_value_change, Config.on_field_change, EventDispatcher.value_change_internals.dup, field_change_internals.dup) and `:real_commits` (per-example toggle of `use_transactional_tests` + manual FK-ordered cleanup of Value → Option → Field::Base → Section → Contact/Product/Project).
- Four new spec files (51 examples total): `event_dispatcher_spec.rb` (unit ordering, error policy, reset split), `event_context_spec.rb` (with_context nesting/freeze/ensure-pop), `value_event_spec.rb` (Value integration incl. orphan skip + post-destroy id readability live validation), `field_event_spec.rb` (Field integration incl. STI dispatch, :rename bundled with other attrs, :nullify cascade interaction).
- New §"Event hooks" section in README between §"Validation Behavior" and §"Database Support" (138 lines), plus a new cross-reference bullet in §"Validation Behavior". Covers public callback slots, with_context, error policy split, ordering guarantee, test-isolation metadata, reset! split table.

## Files Modified

- `app/models/typed_eav/value.rb` — modified (commit 7631f0a). Added three `after_commit ..., on: :X` declarations + three private `_dispatch_value_change_*` forwarder methods.
- `app/models/typed_eav/field/base.rb` — modified (commit d9cd538). Added single `after_commit :_dispatch_field_change` callback + private branching method using `previously_new_record?`/`destroyed?`/`saved_change_to_attribute?(:name)`.
- `spec/spec_helper.rb` — modified (commit 05f5e06). Added `:event_callbacks` and `:real_commits` around hooks; updated metadata-contract comment block with two new bullets.
- `spec/lib/typed_eav/event_dispatcher_spec.rb` — new file (commit 05f5e06). 22 examples.
- `spec/lib/typed_eav/event_context_spec.rb` — new file (commit 05f5e06). 10 examples.
- `spec/models/typed_eav/value_event_spec.rb` — new file (commit 65bb4d1). 9 examples.
- `spec/models/typed_eav/field_event_spec.rb` — new file (commit 65bb4d1). 10 examples.
- `README.md` — modified (commit dd806ac). New §"Event hooks" section + cross-reference bullet in §"Validation Behavior".
