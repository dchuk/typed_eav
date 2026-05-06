---
phase: 04
tier: standard
result: FAIL
passed: 20
failed: 5
total: 25
date: 2026-05-06
verified_at_commit: 3a6887a671873a009a9bf5467a6c5cb069676a05
writer: write-verification.sh
plans_verified:
  - 04-01
  - 04-02
  - 04-03
---

## Must-Have Checks

| # | ID | Truth/Condition | Status | Evidence |
|---|-----|-----------------|--------|----------|
| 1 | MH-01 | typed_eav_value_versions table migration exists with all declared columns + timestamps, jsonb defaults {}, nullable changed_by, NOT NULL polymorphic entity | PASS | db/migrate/20260505000000_create_typed_eav_value_versions.rb: before_value/after_value/context null: false default: {}; changed_by nullable; t.references :entity polymorphic: true null: false |
| 2 | MH-02 | FKs: value_id -> typed_eav_values ON DELETE SET NULL; field_id -> typed_eav_fields ON DELETE SET NULL; both columns nullable | PASS | Migration lines 41-45 confirm on_delete: :nullify for both value_id and field_id FKs; null: true on both t.references |
| 3 | MH-03 | Three indexes: idx_te_vvs_value, idx_te_vvs_entity, idx_te_vvs_field — all DESC on changed_at; no GIN on before_value/after_value | PASS | Migration lines 106-118 confirm order: {changed_at: :desc} and idx_te_vvs_* names; no add_index on before_value/after_value |
| 4 | MH-04 | TypedEAV::ValueVersion AR model exists, table_name = typed_eav_value_versions, extends ApplicationRecord; correct belongs_to associations with optional/polymorphic flags | PASS | value_version.rb: class ValueVersion < ApplicationRecord, self.table_name = 'typed_eav_value_versions', belongs_to :value (optional: true), :field (optional: true, inverse_of: false), :entity (polymorphic: true) |
| 5 | MH-05 | ValueVersion validates change_type inclusion with custom message; entity_type/entity_id/changed_at presence; entity_id has inline rubocop-disable with justification | PASS | value_version.rb lines 79-90: CHANGE_TYPES constant, custom message; rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo with justification on entity_id line 89 |
| 6 | MH-06 | No default_scope on ValueVersion; lib/typed_eav.rb autoload includes :ValueVersion at line 19 | PASS | grep: no default_scope in value_version.rb; lib/typed_eav.rb line 19: autoload :ValueVersion |
| 7 | MH-07 | Config.versioning hand-rolled accessor (false default); Config.actor_resolver (nil default); Config.reset! resets both | PASS | config.rb:139 def versioning returns false; config.rb:171 def actor_resolver returns nil; config.rb:240-241 reset! sets versioning=false and actor_resolver=nil |
| 8 | MH-08 | spec_helper :event_callbacks snapshots/restores Config.versioning + Config.actor_resolver; :real_commits deletes ValueVersion rows BEFORE Value rows | PASS | spec_helper.rb lines 94-95 save both; lines 110-111 restore both; line 149 ValueVersion.delete_all before line 150 Value.delete_all |
| 9 | MH-09 | ColumnMapping.value_columns returns [value_column] by default; all 17 STI subclasses inherit it; NotImplementedError when value_column not declared | PASS | column_mapping.rb:66-67 def value_columns; [value_column]; end. 48 combined unit specs pass |
| 10 | MH-10 | Value#_dispatch_value_change_update uses value_columns.any? (plural fix for forward-compat with Phase 05 Currency) | PASS | value.rb:475: return unless field.class.value_columns.any? { &#124;col&#124; saved_change_to_attribute?(col) } |
| 11 | MH-11 | Registry.register accepts versioned: false kwarg; Registry.versioned? O(1) lookup; has_typed_eav macro forwards versioned: kwarg to Registry | PASS | registry.rb:41 register accepts versioned: false; registry.rb:81 def versioned?; has_typed_eav.rb:105+144 accepts and forwards versioned: |
| 12 | MH-12 | TypedEAV::Versioned concern at lib/typed_eav/versioned.rb; re-registers entity with versioned: true; raises ArgumentError if has_typed_eav not called first | PASS | versioned.rb: module Versioned, included block checks typed_eav_scope_method, raises ArgumentError. 35 specs pass |
| 13 | MH-13 | TypedEAV::Versioning module with register_if_enabled + nested autoload :Subscriber; engine config.after_initialize delegates to register_if_enabled | PASS | versioning.rb:58 autoload :Subscriber; versioning.rb:85 def self.register_if_enabled; engine.rb:68 config.after_initialize { TypedEAV::Versioning.register_if_enabled } |
| 14 | MH-14 | Config.versioning=false: register_if_enabled returns early — zero callable in value_change_internals (true zero overhead); idempotent via Array#include? Method#== guard | PASS | versioning.rb:86 return unless TypedEAV.config.versioning; versioning.rb:89 include?(method_ref) idempotency guard. Slot-0 regression spec (4 examples) confirms both paths |
| 15 | MH-15 | Subscriber writes value_id: nil for :destroy events; snapshots via value_columns iteration with stringified column names; actor coercion mirrors normalize_one | PASS | subscriber.rb:108 version_value_id = change_type == 'destroy' ? nil : value.id; build_before/after_snapshot iterate value_columns. 23 plan 04-03 specs pass |
| 16 | MH-16 | Value#history returns versions.order(changed_at: :desc, id: :desc) — chainable relation with id tie-break; implemented as instance method not has_many scope | PASS | value.rb:134-136: def history; versions.order(changed_at: :desc, id: :desc); end. 7 examples in value_history_spec pass |
| 17 | MH-17 | Value#revert_to raises ArgumentError in 3 ordered conditions (value_id nil, before_value empty, value_id mismatch); writes before_value via value_columns iteration; calls save! | PASS | value.rb:194-235: three ArgumentError guards in plan-specified order; field.class.value_columns.each; self[col] = version.before_value[col.to_s]; save! |
| 18 | MH-18 | README §Versioning section at line 705 — after §Event hooks (line 568) and before §Database Support (line 981); §Validation Behavior cross-reference bullet at line 566 | PASS | grep README.md: ## Event hooks line 568, ## Versioning line 705, ## Database Support line 981, cross-reference bullet line 566 |
| 19 | MH-19 | spec/regressions/review_round_5_versioning_slot_zero_spec.rb has 4 examples testing register_if_enabled (default-off, slot-0, semantic equivalence, idempotency); uses :event_callbacks | PASS | File at 131 lines; 4 it-blocks confirmed; :event_callbacks metadata present. All 4 examples pass |
| 20 | MH-20 | Full RSpec suite green — 653 examples, 0 failures | PASS | bundle exec rspec output: 653 passed (6.47s) |
| 21 | DEV-01 | DEVIATION (04-01 DEVN-02): spec/dummy/db/migrate/20260330000001_create_test_entities.rb listed in files_modified but no schema change shipped; plan offered two branches; no-change branch selected | FAIL | Declared in 04-01-SUMMARY.md deviations. File absent from commits 815d151-a4b204e. Classification: plan-amendment — plan should be updated to remove this file from files_modified since both branches were valid and the no-change path is correct. |
| 22 | DEV-02 | DEVIATION (04-01 DEVN-01): redundant foreign_key: declarations removed; entity_id rubocop-disable with justification retained; change_type uses custom message with shoulda with_message in spec | FAIL | Declared in 04-01-SUMMARY.md. value_version.rb confirmed: no redundant FK args; line 89 rubocop-disable with justification; custom message on CHANGE_TYPES validator. Classification: plan-amendment — rubocop-compliance improvements align with CONVENTIONS.md; plan should document the exact validator approach. |
| 23 | DEV-03 | DEVIATION (04-01): P05 install-generator smoke test in /tmp scratch app skipped as impractical in autonomous agent context | FAIL | Declared in 04-01-SUMMARY.md. Dummy app migrate/rollback/re-migrate verified; engine boot probe confirmed. Classification: process-exception — interactive bundle install in a scratch app is genuinely non-executable in CI/agent; the plan's P05 acceptance criteria for the install path are satisfied via the dummy app path. |
| 24 | DEV-04 | DEVIATION (04-03 DEVN-02, Critical): value_history_spec post-destruction example restructured due to ON DELETE SET NULL nullifying ALL pre-existing version rows (not just the new destroy row) when Value is destroyed | FAIL | Declared critical deviation in 04-03-SUMMARY.md. Spec asserts pre-destroy via value.history and post-destroy via entity-scoped query. README updated. Classification: plan-amendment — plan's post-destruction assertion was based on incorrect FK semantics; restructured spec correctly matches the schema behavior. |
| 25 | DEV-05 | DEVIATION (04-03 DEVN-01 Minor): Metrics/AbcSize on revert_to resolved with paired rubocop:disable/enable + justification; RSpec/AnyInstance resolved with allow(value) on specific instance | FAIL | Declared in 04-03-SUMMARY.md. value.rb lines 186/240 paired disable/enable with justification confirmed. allow(value) used in spec. Classification: plan-amendment — valid CONVENTIONS.md-compliant rubocop fixes; plan should note revert_to AbcSize suppression. |

## Summary

**Tier:** standard
**Result:** FAIL
**Passed:** 20/25
**Failed:** DEV-01, DEV-02, DEV-03, DEV-04, DEV-05
