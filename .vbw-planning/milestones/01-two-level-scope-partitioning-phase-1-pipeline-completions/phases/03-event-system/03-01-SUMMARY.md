---
phase: 3
plan: 01
title: Event dispatch infrastructure (EventDispatcher, with_context, Config accessors)
status: complete
completed: 2026-05-01
tasks_completed: 3
tasks_total: 3
commit_hashes:
  - a647ce9
  - 9694fe7
  - 5215634
deviations: []
pre_existing_issues: []
ac_results:
  - criterion: "EventDispatcher module exists at lib/typed_eav/event_dispatcher.rb with class-level @value_change_internals/@field_change_internals arrays, register_internal_value_change/register_internal_field_change, dispatch_value_change/dispatch_field_change, and reset!"
    verdict: "pass"
    evidence: "lib/typed_eav/event_dispatcher.rb commit a647ce9; defines `class << self` with all 7 methods (value_change_internals, field_change_internals, register_internal_value_change, register_internal_field_change, dispatch_value_change, dispatch_field_change, reset!)"
  - criterion: "EventDispatcher is eager-loaded at engine boot via require_relative in engine.rb's typed_eav.autoload initializer"
    verdict: "pass"
    evidence: "lib/typed_eav/engine.rb line 17 `require_relative \"event_dispatcher\"` inside the `typed_eav.autoload` initializer (commit a647ce9). Smoke test: `bundle exec ruby -e 'require \"./spec/dummy/config/environment\"; puts TypedEAV::EventDispatcher.value_change_internals.class'` prints `Array` immediately after engine load (no autoload trigger needed)."
  - criterion: "TypedEAV.with_context(**kwargs) is a thread-local stack mirroring with_scope: pre-merged frozen Hash pushed on entry, ensure-pop on exit, shallow per-key merge across nesting"
    verdict: "pass"
    evidence: "lib/typed_eav.rb commit 9694fe7. Verified live: nested `with_context(a: 1) { with_context(b: 2) { current_context } }` returns `{a: 1, b: 2}`; override `with_context(a: 1) { with_context(a: 2) { current_context } }` returns `{a: 2}`; `with_context(a: 1) { raise 'boom' }; current_context` returns `{}` (ensure-pop). Stored Hash is frozen — `current_context[:b] = 2` raises FrozenError."
  - criterion: "TypedEAV.current_context returns the top of the stack (already a frozen Hash) or {}.freeze when stack is empty — never returns nil and never returns an unfrozen Hash"
    verdict: "pass"
    evidence: "lib/typed_eav.rb `EMPTY_FROZEN_CONTEXT = {}.freeze` private_constant; `current_context` returns `Thread.current[THREAD_CONTEXT_STACK]&.last || EMPTY_FROZEN_CONTEXT`. Live verification: `TypedEAV.current_context.frozen?` → `true`; identity check `current_context.equal?(current_context)` returns `true` (single shared instance, no per-call allocation)."
  - criterion: "Config exposes on_value_change and on_field_change as nil-default config_accessors and Config.reset! resets BOTH back to nil"
    verdict: "pass"
    evidence: "lib/typed_eav/config.rb commit 5215634. Live verification: `Config.on_value_change` → `nil`; assign a lambda → returns the lambda; `Config.reset!`; `Config.on_value_change` → `nil`. Same for `on_field_change`. config_and_registry_spec.rb passes (13 examples, 0 failures)."
  - criterion: "EventDispatcher.reset! clears ONLY the internal-subscribers arrays — does NOT touch Config (engine-load registrations from later phases must survive Config.reset!)"
    verdict: "pass"
    evidence: "EventDispatcher.reset! body sets `@value_change_internals = []` and `@field_change_internals = []` only. Module-level comment block documents the split rationale."
  - criterion: "dispatch_value_change runs internals in registration order (raise propagates), then user proc wrapped in rescue StandardError + Rails.logger.error + swallow"
    verdict: "pass"
    evidence: "dispatch_value_change body iterates `value_change_internals.each { |cb| cb.call(value, change_type, context) }` (no rescue — raise propagates), then if user proc set, calls `user.call(value, change_type, context)` inside `begin/rescue StandardError/Rails.logger.error/end`. Comment cross-references 03-CONTEXT.md §User-callback error policy."
  - criterion: "dispatch_value_change passes (value, change_type, TypedEAV.current_context) to internals and user proc; dispatch_field_change passes (field, change_type) — context arg deliberately omitted on field signature"
    verdict: "pass"
    evidence: "dispatch_value_change captures `context = TypedEAV.current_context` once and passes it as 3rd arg to both internals and user. dispatch_field_change uses 2-arg call signature; comment at module head and on the method documents the locked asymmetry per 03-CONTEXT.md §Phase Boundary."
  - criterion: "with_context uses **kwargs (not positional Hash) — enforces keyword form per Ruby 3.0+ kwargs/Hash separation"
    verdict: "pass"
    evidence: "Method signature `def with_context(**kwargs)`. Live verification: `TypedEAV.with_context({ a: 1 }) { }` raises `ArgumentError: wrong number of arguments (given 1, expected 0)`; only `TypedEAV.with_context(a: 1) { }` is accepted."
  - criterion: "frozen_string_literal: true on lib/typed_eav/event_dispatcher.rb"
    verdict: "pass"
    evidence: "Line 1 of lib/typed_eav/event_dispatcher.rb is `# frozen_string_literal: true`. `bundle exec rubocop lib/` reports 0 offenses across all 11 files."
---

Lands the in-process event-dispatch infrastructure that Phase 04 versioning and Phase 07 materialized index both depend on. Plan 01 delivers the contract surface only — the `EventDispatcher` module, `with_context` / `current_context` thread-local stack, and the `Config.on_value_change` / `Config.on_field_change` accessors. No model wiring or specs in this plan; those live in 03-02.

## What Was Built

- New `TypedEAV::EventDispatcher` module (`lib/typed_eav/event_dispatcher.rb`) with seven class methods:
  - `value_change_internals` / `field_change_internals` — readers backed by lazy-init `@arr ||= []`, exposed for test introspection.
  - `register_internal_value_change(callable)` / `register_internal_field_change(callable)` — first-party-only registration entry points (Phase 04 versioning, Phase 07 matview).
  - `dispatch_value_change(value, change_type)` — captures `TypedEAV.current_context` once, fires internals first (3-arg, raise-propagating), then user proc last (3-arg, rescued + `Rails.logger.error` + swallowed).
  - `dispatch_field_change(field, change_type)` — fires internals first (2-arg, raise-propagating), then user proc last (2-arg, rescued + logged + swallowed). Asymmetry vs value-change is intentional and locked.
  - `reset!` — clears ONLY internal-subscriber arrays; does NOT touch Config user procs.
- Module-level RDoc + per-method "comment the failure mode" blocks documenting why each design choice exists.
- Eager-load wiring via `require_relative "event_dispatcher"` in `lib/typed_eav/engine.rb`'s `typed_eav.autoload` initializer (so Phase 04 versioning can register at engine boot, before any model reference triggers autoload).
- `autoload :EventDispatcher` added to `lib/typed_eav.rb` for direct const-resolution outside the engine path.
- `THREAD_CONTEXT_STACK` private_constant + `EMPTY_FROZEN_CONTEXT = {}.freeze` private_constant (single shared instance for the empty-context hot path, avoids per-call allocation).
- `TypedEAV.with_context(**kwargs)` mirroring `with_scope`'s ensure-pop shape: shallow per-key merge with outer stack, frozen on push, `ensure; stack&.pop`. Enforces keyword-syntax via `**kwargs` per Ruby 3+ kwargs/Hash separation.
- `TypedEAV.current_context` returns the frozen top-of-stack or `EMPTY_FROZEN_CONTEXT` — always frozen, never nil.
- `Config.on_value_change` / `Config.on_field_change` `config_accessor` declarations with full doc comments (signatures, error policy, internal-vs-user proc distinction). Defaults to `nil`.
- `Config.reset!` body now also resets both new accessors back to `nil` for test isolation. Internal-subscriber arrays are deliberately NOT touched here — Phase 04+ engine-load registrations must survive `Config.reset!`.

## Files Modified

- `lib/typed_eav/event_dispatcher.rb` — new file (commit a647ce9). Defines `module TypedEAV::EventDispatcher` with `class << self` block containing all seven class methods plus module-level and per-method comment blocks.
- `lib/typed_eav.rb` — modified twice:
  - commit a647ce9: added `autoload :EventDispatcher` to the autoload block.
  - commit 9694fe7: added `THREAD_CONTEXT_STACK` constant + `EMPTY_FROZEN_CONTEXT` constant + `with_context(**kwargs)` and `current_context` methods inside `class << self`. Extended the `private_constant` call to cover all three thread-local keys plus `EMPTY_FROZEN_CONTEXT`.
- `lib/typed_eav/engine.rb` — modified (commit a647ce9). Added `require_relative "event_dispatcher"` to the `typed_eav.autoload` initializer alongside `column_mapping`, `config`, and `registry`. Inline comment explains why eager-load (not autoload) is required for Phase 04.
- `lib/typed_eav/config.rb` — modified (commit 5215634). Added `config_accessor :on_value_change, default: nil` and `config_accessor :on_field_change, default: nil` with full doc comments below `config_accessor :require_scope`. Updated `Config.reset!` to also reset both new accessors to `nil`.

## Final Verification

- `bundle exec rubocop lib/` — 11 files inspected, 0 offenses.
- `bundle exec rspec spec/lib/typed_eav/config_and_registry_spec.rb spec/lib/typed_eav/zeitwerk_loading_spec.rb spec/lib/typed_eav/scoping_spec.rb` — 59 examples, 0 failures.
- `bundle exec rspec` (full suite) — 496 examples, 0 failures.
- Engine boot smoke-test (`require './spec/dummy/config/environment'; ...`) prints `Array`, `true`, `nil` — eager-load fires, current_context is frozen, on_value_change defaults to nil.
- `with_context` live verification: empty default `{}` (frozen=true); single-level `{request_id: 'abc'}` (frozen); nested merge `{a: 1, b: 2}`; override `{a: 2}`; mutation guard raises `FrozenError`; ensure-pop after raise restores `{}`; positional Hash form raises `ArgumentError`; shared-empty identity check passes.

## Deviations

**None.**

## Locked Decisions Honored

All locked decisions from `03-CONTEXT.md` are reflected in the as-built code:

1. Internal subscribers raise (fail-closed); user proc rescues StandardError + logs + swallows.
2. Internals fire FIRST, user proc LAST. Registration order preserved.
3. 3-arg `dispatch_value_change`, 2-arg `dispatch_field_change` (asymmetry intentional).
4. `**kwargs`-only `with_context`; positional Hash rejected by Ruby 3 kwargs separation.
5. `current_context` returns shared frozen `{}`, never nil, never unfrozen.
6. `EventDispatcher.reset!` clears arrays only; `Config.reset!` resets user procs only.
7. `EventDispatcher` eager-loaded via `require_relative` (not autoloaded).
8. `frozen_string_literal: true` on the new file; double-quoted strings; trailing commas in multiline literals.
