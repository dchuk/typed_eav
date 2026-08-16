---
phase: 4
plan: 01
title: Versioning schema, ValueVersion model, Config.versioning + Config.actor_resolver
status: complete
completed: 2026-05-05
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 815d151
  - 4d20622
  - e6eb2ee
  - a4b204e
files_modified:
  - db/migrate/20260505000000_create_typed_eav_value_versions.rb
  - app/models/typed_eav/value_version.rb
  - app/models/typed_eav/value.rb
  - lib/typed_eav.rb
  - lib/typed_eav/config.rb
  - spec/spec_helper.rb
  - spec/models/typed_eav/value_version_spec.rb
  - spec/lib/typed_eav/config_versioning_spec.rb
deviations:
  - "DEVN-02: spec/dummy/db/migrate/20260330000001_create_test_entities.rb listed in files_modified frontmatter but no schema change shipped this plan. The must_have offered two branches ('add versioned_workspace_id column' OR 'no dummy schema change here and plan 04-02 reuses Contact') and Plan-time decisions §1-5 did not pin a choice. Selected the no-change branch by absence-of-action — plan 04-02 will reuse existing Contact (tenant_id) / Project (workspace_id) test entities for per-entity opt-in integration tests, no new column needed."
  - "DEVN-01: removed redundant `foreign_key: :value_id` / `foreign_key: :field_id` from belongs_to declarations on TypedEAV::ValueVersion, and `foreign_key: :value_id` from has_many :versions on TypedEAV::Value (Rails/RedundantForeignKey rubocop offense — defaults match the association name). Behavior unchanged. Added `inverse_of: false` on belongs_to :field to satisfy Rails/InverseOf since Field::Base does not declare a reverse has_many :versions in this plan."
  - "DEVN-01: `validates :entity_id, presence: true` rubocop-disabled inline (Rails/RedundantPresenceValidationOnBelongsTo) with justification — the plan must_haves explicitly list it as a named validator so the grep contract is preserved alongside the implicit belongs_to-driven enforcement."
  - "DEVN-01: change_type inclusion validator uses custom message `must be one of: create, update, destroy` so the validation error is self-documenting; spec uses shoulda-matchers `with_message` to assert the matcher chain."
pre_existing_issues: []
ac_results:
  - criterion: "New table typed_eav_value_versions exists with declared columns + jsonb defaults + nullable changed_by + NOT NULL polymorphic entity"
    verdict: pass
    evidence: "commit 815d151; psql \\d typed_eav_value_versions confirms 13 columns with correct nullability and jsonb defaults '{}'"
  - criterion: "Foreign keys: value_id and field_id ON DELETE SET NULL (audit log survives Value/Field destruction)"
    verdict: pass
    evidence: "commit 815d151; spec/models/typed_eav/value_version_spec.rb 'FK ON DELETE SET NULL behavior' two examples both green"
  - criterion: "Three indexes (idx_te_vvs_value/entity/field) all DESC on changed_at, no GIN deferred"
    verdict: pass
    evidence: "psql \\d typed_eav_value_versions shows idx_te_vvs_value (value_id, changed_at DESC), idx_te_vvs_entity (entity_type, entity_id, changed_at DESC), idx_te_vvs_field (field_id, changed_at DESC)"
  - criterion: "TypedEAV::ValueVersion AR model exists at app/models/typed_eav/value_version.rb extending ApplicationRecord, table_name = typed_eav_value_versions"
    verdict: pass
    evidence: "commit 4d20622; app/models/typed_eav/value_version.rb"
  - criterion: "ValueVersion has belongs_to :value (optional), belongs_to :field (optional), belongs_to :entity (polymorphic)"
    verdict: pass
    evidence: "commit 4d20622; spec 'associations' three examples green via shoulda-matchers"
  - criterion: "ValueVersion validates change_type inclusion %w[create update destroy], entity_type/entity_id/changed_at presence"
    verdict: pass
    evidence: "commit 4d20622; spec 'validations' four examples green"
  - criterion: "ValueVersion has no default_scope (callers explicit-order)"
    verdict: pass
    evidence: "app/models/typed_eav/value_version.rb has no default_scope declaration"
  - criterion: "Config.versioning hand-rolled accessor (defined? idiom, false default), attr_writer, reset! resets to false"
    verdict: pass
    evidence: "commit e6eb2ee; spec/lib/typed_eav/config_versioning_spec.rb '.versioning' four examples + reset! coverage all green"
  - criterion: "Config.actor_resolver hand-rolled accessor (defined? idiom, nil default), attr_writer, reset! resets to nil"
    verdict: pass
    evidence: "commit e6eb2ee; spec/lib/typed_eav/config_versioning_spec.rb '.actor_resolver' four examples + reset! coverage all green"
  - criterion: "lib/typed_eav.rb autoload list includes autoload :ValueVersion"
    verdict: pass
    evidence: "commit 4d20622; grep `autoload :ValueVersion lib/typed_eav.rb` matches line 19"
  - criterion: "spec_helper.rb :event_callbacks hook snapshots/restores Config.versioning and Config.actor_resolver alongside existing four pieces of state"
    verdict: pass
    evidence: "commit a4b204e; grep saved_versioning|saved_actor_resolver matches four lines (save+clear+restore for both)"
  - criterion: "spec_helper.rb :real_commits hook deletes TypedEAV::ValueVersion.delete_all BEFORE TypedEAV::Value.delete_all"
    verdict: pass
    evidence: "commit a4b204e; grep `ValueVersion.delete_all spec/spec_helper.rb` matches line 149 (before Value.delete_all on line 150)"
  - criterion: "spec/dummy/db/migrate/20260330000001_create_test_entities.rb adds versioned_workspace_id OR no dummy schema change"
    verdict: pass
    evidence: "DEVN-02 above: selected 'no dummy schema change' branch; plan 04-02 reuses Contact/Project for opt-in tests"
  - criterion: "Engine boot does NOT register Phase 04 subscriber yet (plan 04-02's job)"
    verdict: pass
    evidence: "no changes to lib/typed_eav/engine.rb in this plan; Versioning::Subscriber namespace lands in plan 04-02"
  - criterion: "ApplicationRecord exists at app/models/typed_eav/application_record.rb — class TypedEAV::ValueVersion < ApplicationRecord extends it correctly"
    verdict: pass
    evidence: "app/models/typed_eav/value_version.rb line 36 `class ValueVersion < ApplicationRecord`"
  - criterion: "frozen_string_literal: true magic comment on every new .rb file"
    verdict: pass
    evidence: "all four new .rb files (value_version.rb, config_versioning_spec.rb, value_version_spec.rb, migration) have frozen_string_literal: true on line 1; migration is in db/migrate/ which is excluded by rubocop config but still has the comment"
---

Phase 04 plan 01 ships the versioning schema, AR model, and Config accessors as the wave-1 foundation for per-entity opt-in versioning landing in plans 04-02 and 04-03. Five tasks, four atomic source commits (P05 verification-only), 574 examples green under random ordering.

## What Was Built

- Migration `db/migrate/20260505000000_create_typed_eav_value_versions.rb` — append-only audit log table with 11 typed columns + timestamps, jsonb before/after/context defaulting to `{}`, nullable changed_by, NOT NULL polymorphic entity, two FKs ON DELETE SET NULL on value_id and field_id, three DESC composite indexes (idx_te_vvs_value/entity/field) on changed_at
- `TypedEAV::ValueVersion` AR model — table_name = "typed_eav_value_versions", belongs_to :value (optional), :field (optional, inverse_of: false), :entity (polymorphic), CHANGE_TYPES = %w[create update destroy] inclusion validator with custom message, presence validators on entity_type / entity_id / changed_at
- `lib/typed_eav.rb` gains `autoload :ValueVersion` after `autoload :EventDispatcher`
- `TypedEAV::Value` gains `has_many :versions, class_name: "TypedEAV::ValueVersion", inverse_of: :value`
- `Config.versioning` (default false) and `Config.actor_resolver` (default nil) hand-rolled accessors using the `defined?(@var)` idiom; `Config.reset!` resets both alongside the existing five
- `spec/spec_helper.rb` `:event_callbacks` hook now snapshots/restores Config.versioning + Config.actor_resolver alongside the existing four pieces of state; `:real_commits` cleanup deletes ValueVersion rows first; metadata-contract comment block updated for Phase 04 mentions
- 27 new spec examples (16 for ValueVersion model, 11 for Config accessors + isolation markers); full suite 574 examples green under random ordering, baseline was 547

## Files Modified

- `db/migrate/20260505000000_create_typed_eav_value_versions.rb` -- create: append-only audit log table for Phase 04 versioning
- `app/models/typed_eav/value_version.rb` -- create: TypedEAV::ValueVersion AR model with associations and validators
- `app/models/typed_eav/value.rb` -- modify: add has_many :versions association (inverse of belongs_to :value on ValueVersion)
- `lib/typed_eav.rb` -- modify: add `autoload :ValueVersion` after `autoload :EventDispatcher`
- `lib/typed_eav/config.rb` -- modify: add Config.versioning + Config.actor_resolver hand-rolled accessors and reset! coverage
- `spec/spec_helper.rb` -- modify: extend :event_callbacks snapshot list and :real_commits cleanup ordering for Phase 04 state
- `spec/models/typed_eav/value_version_spec.rb` -- create: associations, validations, jsonb defaults/round-trip, FK ON DELETE SET NULL
- `spec/lib/typed_eav/config_versioning_spec.rb` -- create: defaults, set/get, defined?-idiom probe, reset!, isolation markers

## Deviations

- DEVN-02: spec/dummy/db/migrate/20260330000001_create_test_entities.rb listed in plan files_modified frontmatter but no schema change shipped this plan (must_have offered two explicit branches; Plan-time decisions did not pin one; selected the no-change branch by absence-of-action — plan 04-02 reuses Contact/Project)
- DEVN-01: removed redundant `foreign_key:` declarations to satisfy rubocop Rails/RedundantForeignKey; behavior unchanged (defaults match association names)
- DEVN-01: `validates :entity_id, presence: true` retained with inline rubocop-disable (Rails/RedundantPresenceValidationOnBelongsTo) and justification, preserving the plan must_have grep contract
- DEVN-01: change_type inclusion uses custom message; spec uses shoulda-matchers `with_message` for the matcher chain
- P05 install-generator smoke test in /tmp scratch app skipped (impractical without interactive bundle install). Minimum acceptance documented in plan §P05 step 6 satisfied: dummy app migrate + rollback + re-migrate all clean (verified in P01); engine boot smoke test from plan §verification 6 prints all 13 columns + `false` + `nil` correctly. The standard `typed_eav:install:migrations` task is idempotent per Scout §5; greenfield apps will pick up all four migrations on first install, upgraded apps only the new one
