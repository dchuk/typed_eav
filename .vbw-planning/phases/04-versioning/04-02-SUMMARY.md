---
phase: 4
plan: 02
title: Versioning subscriber, value_columns plural, Registry/has_typed_eav opt-in, engine wiring
status: complete
completed: 2026-05-05
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 568a2392edf8bcfd484c2dcc63ce55a2dcec68b3
  - 54ea8a921782f6b2d8531fd802d32bfc9d264387
  - c9ceac22e290c6a99e08c3886f7e353fa1f3db47
  - 4fc7f51e14c447585860355651e0c41d0e6c6c38
  - 1f1d6c4e96898ae93d4b5d8de7a6b22233e2552f
files_modified:
  - lib/typed_eav/column_mapping.rb
  - lib/typed_eav/registry.rb
  - lib/typed_eav/has_typed_eav.rb
  - lib/typed_eav/versioned.rb
  - lib/typed_eav/versioning.rb
  - lib/typed_eav/versioning/subscriber.rb
  - lib/typed_eav/engine.rb
  - lib/typed_eav.rb
  - app/models/typed_eav/value.rb
  - spec/lib/typed_eav/column_mapping_value_columns_spec.rb
  - spec/lib/typed_eav/registry_versioned_spec.rb
  - spec/lib/typed_eav/versioned_concern_spec.rb
  - spec/lib/typed_eav/versioning/subscriber_spec.rb
  - spec/models/typed_eav/value_versioning_integration_spec.rb
deviations: []
pre_existing_issues: []
ac_results:
  - criterion: "ColumnMapping has class-level `value_columns` method defaulting to [value_column]; raises NotImplementedError on subclasses without value_column"
    verdict: pass
    evidence: "568a239 — lib/typed_eav/column_mapping.rb:46-68; spec/lib/typed_eav/column_mapping_value_columns_spec.rb (7 examples)"
  - criterion: "All 17 current Field STI subclasses inherit default value_columns returning [value_column] — verified by spec iterating Config.field_types.values"
    verdict: pass
    evidence: "568a239 — spec/lib/typed_eav/column_mapping_value_columns_spec.rb 'covers every built-in field type with the default'"
  - criterion: "Value#_dispatch_value_change_update uses field.class.value_columns.any? { |col| saved_change_to_attribute?(col) } (plural) — Scout §3 / Discrepancy D3 fix"
    verdict: pass
    evidence: "1f1d6c4 — app/models/typed_eav/value.rb:343; spec/models/typed_eav/value_versioning_integration_spec.rb update + touch examples"
  - criterion: "Registry.register accepts versioned: false kwarg; entry hash {types:, versioned:}; existing types-only callers unaffected"
    verdict: pass
    evidence: "54ea8a9 — lib/typed_eav/registry.rb:41; spec/lib/typed_eav/registry_versioned_spec.rb (4 'with versioned: kwarg' examples)"
  - criterion: "Registry.versioned?(entity_type) returns stored boolean for opted-in, false for unregistered (defensive); O(1) Hash#dig"
    verdict: pass
    evidence: "54ea8a9 — lib/typed_eav/registry.rb:62; spec/lib/typed_eav/registry_versioned_spec.rb (5 '.versioned?' examples including Hash#dig spy)"
  - criterion: "has_typed_eav macro accepts versioned: false kwarg, forwards to Registry.register"
    verdict: pass
    evidence: "54ea8a9 — lib/typed_eav/has_typed_eav.rb:105 + 145; spec/lib/typed_eav/registry_versioned_spec.rb 'has_typed_eav versioned: kwarg integration'"
  - criterion: "TypedEAV::Versioned concern at lib/typed_eav/versioned.rb; included after has_typed_eav re-registers with versioned: true; raises ArgumentError on missing precondition"
    verdict: pass
    evidence: "c9ceac2 — lib/typed_eav/versioned.rb; spec/lib/typed_eav/versioned_concern_spec.rb (8 examples covering opt-in, equivalence, precondition, idempotence)"
  - criterion: "TypedEAV::Versioning module + register_if_enabled helper; nested autoload :Subscriber; conditional engine config.after_initialize registration"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning.rb (autoload :Subscriber line 58; register_if_enabled line 85); lib/typed_eav/engine.rb:68 config.after_initialize block"
  - criterion: "Subscriber jsonb snapshot logic — :create empty before / populated after; :update both populated; :destroy populated before / empty after; column names stringified"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning/subscriber.rb build_before_snapshot / build_after_snapshot; spec/lib/typed_eav/versioning/subscriber_spec.rb 'snapshot logic' (5 examples)"
  - criterion: "Subscriber writes value_id: nil for :destroy events to avoid FK violation; entity_type/entity_id/field_id remain populated for audit"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning/subscriber.rb:101 (version_value_id ternary); spec destroy snapshot + 'destroy event does NOT raise FK violation' regression"
  - criterion: "Subscriber actor coercion: AR record → id.to_s; scalar → to_s; nil flows through (mirrors normalize_one)"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning/subscriber.rb resolve_actor; spec 'actor coercion' (4 examples)"
  - criterion: "Subscriber writes changed_at: Time.current and context: context.to_h"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning/subscriber.rb write_version_row; spec ':create lifecycle' asserts changed_at within 5 seconds; 'context capture' asserts to_h shape"
  - criterion: "Subscriber registration CONDITIONAL on Config.versioning, gated at config.after_initialize via register_if_enabled — true zero overhead when off"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/engine.rb:68; lib/typed_eav/versioning.rb register_if_enabled returns early when versioning false; engine boot probe shows value_change_internals=[] under default boot"
  - criterion: "Runtime toggle of c.versioning = true after config.after_initialize fires has NO effect — process restart required"
    verdict: pass
    evidence: "1f1d6c4 — spec/models/typed_eav/value_versioning_integration_spec.rb 'runtime toggle of Config.versioning does NOT affect already-registered subscriber'"
  - criterion: "Defense-in-depth zero-overhead spec: register_if_enabled with versioning=false leaves array be_empty AND not_to include Subscriber.method(:call)"
    verdict: pass
    evidence: "4fc7f51 — spec/lib/typed_eav/versioning/subscriber_spec.rb engine-boot-registration-gating block 'register_if_enabled with Config.versioning=false leaves value_change_internals empty (true zero overhead)'"
  - criterion: "register_if_enabled idempotent — calling N times with versioning=true produces exactly ONE entry via Method#== semantic equality"
    verdict: pass
    evidence: "4fc7f51 — lib/typed_eav/versioning.rb:88 Array#include? guard; spec 'registering twice when versioning=true results in exactly one entry'"
  - criterion: "lib/typed_eav.rb autoload includes :Versioned and :Versioning"
    verdict: pass
    evidence: "c9ceac2 + 4fc7f51 — lib/typed_eav.rb:20-21"
  - criterion: "frozen_string_literal: true on every new .rb file"
    verdict: pass
    evidence: "All 8 new .rb files (lib/typed_eav/versioned.rb, versioning.rb, versioning/subscriber.rb + 5 spec files) carry the magic comment"
  - criterion: "Subscriber raises propagate (consistent with EventDispatcher internal-vs-user error policy)"
    verdict: pass
    evidence: "4fc7f51 — spec/lib/typed_eav/versioning/subscriber_spec.rb 'raise propagation (locked internal-error policy)'"
  - criterion: "Versioning specs use snapshot/restore via :event_callbacks; no EventDispatcher.reset! direct calls in new specs (Discrepancy D1)"
    verdict: pass
    evidence: "All 5 new specs use :event_callbacks metadata; grep -rn 'EventDispatcher.reset!' spec/ shows only pre-existing matches in spec_helper comment + event_dispatcher_spec.rb (which test reset! itself)"
  - criterion: "Discrepancy D4: integration specs explicitly re-register subscriber inside before(:each) because :event_callbacks hook clears value_change_internals at example entry"
    verdict: pass
    evidence: "spec/lib/typed_eav/versioning/subscriber_spec.rb (4 describe blocks with re-registration); spec/models/typed_eav/value_versioning_integration_spec.rb (top-level before block)"
---

Phase 04 plan 02 lands the full versioning subscriber pipeline plus the singular→plural dispatch fix. Default boot stays zero-overhead; opt-in apps get audit rows on every Value lifecycle event.

## What Was Built

- `TypedEAV::ColumnMapping.value_columns` plural class method (defaults to `[value_column]`); 17-type coverage spec locks the contract
- `TypedEAV::Registry.register` accepts `versioned:` kwarg; new `Registry.versioned?(entity_type)` lookup; `has_typed_eav` macro forwards `versioned:` to Registry
- `TypedEAV::Versioned` concern provides post-`has_typed_eav` opt-in alternative; raises ArgumentError on missing precondition
- `TypedEAV::Versioning` namespace shell with `register_if_enabled` testable seam + nested autoload for `Subscriber`
- `TypedEAV::Versioning::Subscriber.call` writes one ValueVersion row per :create/:update/:destroy event; gates on field-presence + Registry.versioned?; :destroy uses `value_id: nil` to avoid FK violation; iterates `value_columns` for Phase 05 forward-compat
- Engine `config.after_initialize` block delegates to `register_if_enabled`; default boot leaves `value_change_internals` empty (true zero overhead per CONTEXT line 17)
- `Value#_dispatch_value_change_update` now uses `value_columns.any?` — Discrepancy D3 / Plan-time decision §5 closed
- 56 new examples across 5 spec files (column mapping, registry, concern, subscriber, integration); full suite 630 passing under both ordered and `--order rand`

## Files Modified

- `lib/typed_eav/column_mapping.rb` -- modified: add `value_columns` plural class method
- `lib/typed_eav/registry.rb` -- modified: add `versioned:` kwarg + `versioned?` lookup
- `lib/typed_eav/has_typed_eav.rb` -- modified: forward `versioned:` kwarg through has_typed_eav macro
- `lib/typed_eav/versioned.rb` -- created: post-has_typed_eav opt-in concern
- `lib/typed_eav/versioning.rb` -- created: namespace shell + `register_if_enabled` helper + nested Subscriber autoload
- `lib/typed_eav/versioning/subscriber.rb` -- created: Subscriber.call entry, snapshot logic, actor coercion
- `lib/typed_eav/engine.rb` -- modified: add `config.after_initialize` block delegating to register_if_enabled
- `lib/typed_eav.rb` -- modified: extend autoload list with :Versioned and :Versioning
- `app/models/typed_eav/value.rb` -- modified: `_dispatch_value_change_update` uses `value_columns.any?` (plural fix)
- `spec/lib/typed_eav/column_mapping_value_columns_spec.rb` -- created: value_columns default + 17-subclass sweep + override path
- `spec/lib/typed_eav/registry_versioned_spec.rb` -- created: kwarg storage, lookup, BC, macro forwarding (14 examples)
- `spec/lib/typed_eav/versioned_concern_spec.rb` -- created: opt-in, equivalence, precondition, idempotence (8 examples)
- `spec/lib/typed_eav/versioning/subscriber_spec.rb` -- created: gates, snapshots, multi-cell, actor coercion, raise prop, idempotency, identity (18 examples)
- `spec/models/typed_eav/value_versioning_integration_spec.rb` -- created: end-to-end :create/:update/:destroy + opt-out + audit chain + late-toggle (9 examples)

## Deviations

None.
