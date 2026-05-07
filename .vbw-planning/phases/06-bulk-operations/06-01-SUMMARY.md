---
phase: 6
plan: 01
title: version_group_id migration + subscriber injection point
status: complete
completed: 2026-05-06
tasks_completed: 3
tasks_total: 3
commit_hashes:
  - f21f607
  - 22706e8
  - ae616fd
files_modified:
  - db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb
  - lib/typed_eav/versioning/subscriber.rb
  - spec/models/typed_eav/value_version_spec.rb
  - spec/lib/typed_eav/versioning/subscriber_spec.rb
deviations:
  - "DEVN-02: migration timestamp bumped from 20260506000000 to 20260506000001. The original timestamp collided with spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb (Phase 05 dummy-app migration). Plan and orchestrator both pre-amended the timestamp before the agent ran; classname AddVersionGroupIdToTypedEAVValueVersions is unchanged."
pre_existing_issues: []
ac_results:
  - criterion: "New migration db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb adds nullable version_group_id :uuid column + concurrent idx_te_vvs_group index; uses disable_ddl_transaction! and explicit up/down"
    verdict: pass
    evidence: "commit f21f607; migrate/rollback/re-migrate cycle verified — column appears as uuid nullable=true and index appears with columns=['version_group_id']"
  - criterion: "Column type is Postgres :uuid (not :string), no null: false, no default — non-bulk writes leave NULL"
    verdict: pass
    evidence: "ActiveRecord::Base.connection.columns inspection confirms version_group_id sql_type='uuid' null=true; new spec 'leaves version_group_id NULL when no with_context block is active' green"
  - criterion: "Index name is exactly idx_te_vvs_group; add_index uses algorithm: :concurrently, if_not_exists: true; remove_index uses if_exists: true, algorithm: :concurrently"
    verdict: pass
    evidence: "commit f21f607; ActiveRecord::Base.connection.indexes confirms idx_te_vvs_group on [version_group_id]; migration source matches required keyword arguments verbatim"
  - criterion: "Migration is reversible: migrate → rollback → migrate succeeds with column and index in place at the end"
    verdict: pass
    evidence: "MigrationContext.migrate / rollback(1) / migrate executed against spec/dummy database with clean output; final schema check shows column + index present"
  - criterion: "subscriber.rb ValueVersion.create! call passes version_group_id: context[:version_group_id]; key absent → nil; 3-arg signature unchanged"
    verdict: pass
    evidence: "commit 22706e8; lib/typed_eav/versioning/subscriber.rb diff shows the new keyword argument grouped next to context: context.to_h; existing 35 versioning specs continue to pass"
  - criterion: "TypedEAV::ValueVersion AR model needs no change (additive column auto-discovered from schema)"
    verdict: pass
    evidence: "no changes to app/models/typed_eav/value_version.rb; new spec asserts ValueVersion.new.respond_to?(:version_group_id) is true"
  - criterion: "Config.versioning runtime gate unchanged at engine boot — no defensive code in subscriber for disabled-versioning + version_group_id present (Plan 03 enforces ArgumentError at call site)"
    verdict: pass
    evidence: "lib/typed_eav/versioning.rb register_if_enabled untouched; engine-boot registration spec 'register_if_enabled with Config.versioning=false leaves value_change_internals empty' continues to pass"
  - criterion: "spec/models/typed_eav/value_version_spec.rb extended with describe '#version_group_id' block — responds_to + create!(version_group_id: SecureRandom.uuid) round-trip via reload"
    verdict: pass
    evidence: "commit ae616fd; two new examples in #version_group_id describe block; both green"
  - criterion: "spec/lib/typed_eav/versioning/subscriber_spec.rb extended with positive (with_context → version_group_id forwarded) + negative (no with_context → nil) examples; uses :event_callbacks (file-level) + :real_commits"
    verdict: pass
    evidence: "commit ae616fd; new describe 'version_group_id forwarding (Phase 06 correlation tag)' contains both examples; outer file-level :event_callbacks metadata covers Config snapshot/restore"
  - criterion: "No engine-boot change: subscriber registration in lib/typed_eav/versioning.rb:85-92 unchanged"
    verdict: pass
    evidence: "git diff shows no changes outside the four files in plan files_modified; no edits to lib/typed_eav/versioning.rb"
  - criterion: "frozen_string_literal: true on new spec/lib edits (CONVENTIONS.md §Style); not required on the migration (db/migrate excluded)"
    verdict: pass
    evidence: "subscriber.rb retains existing magic comment; both spec files retain existing magic comments; migration file deliberately omits per CONVENTIONS.md"
  - criterion: "Foundational principle: version_group_id is a runtime-resolved correlation tag passed through context — never inferred from a record attribute"
    verdict: pass
    evidence: "subscriber reads context[:version_group_id] by key (commit 22706e8 line at write_version_row); the 3-arg public signature (value, change_type, context) is preserved verbatim"
  - criterion: "bin/rspec spec/models/typed_eav/value_version_spec.rb spec/lib/typed_eav/versioning/ runs green"
    verdict: pass
    evidence: "bundle exec rspec on the two paths returns 39 passed, 0 failures; full suite (824 specs) also passes"
  - criterion: "rubocop reports no offenses on the four plan-touched files"
    verdict: pass
    evidence: "bundle exec rubocop on the four files reports 'rubocop (4 files)' clean"
  - criterion: "Schema integrity: idx_te_vvs_group index exists on typed_eav_value_versions(version_group_id)"
    verdict: pass
    evidence: "ActiveRecord::Base.connection.indexes(:typed_eav_value_versions) finds idx_te_vvs_group with columns=['version_group_id']"
  - criterion: "No N+1 regression: existing Phase 4 specs continue to pass without new query-count regressions"
    verdict: pass
    evidence: "55 versioning-related specs (subscriber + value_version + value_versioning_integration + value_history) pass; full-suite run shows no new failures"
---

Phase 06 plan 01 lands the additive `version_group_id` UUID column on `typed_eav_value_versions` and wires the Phase 04 versioning subscriber to forward `context[:version_group_id]` onto each version row. Three tasks, three atomic commits, 39 plan-touched specs green; full suite (824 specs) green.

## What Was Built

- Migration `db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb` — additive nullable `version_group_id :uuid` column on `typed_eav_value_versions` plus concurrent btree index `idx_te_vvs_group`. Mirrors the production-safety template from Phase 01: `disable_ddl_transaction!`, explicit `up` / `down`, `if_not_exists:` / `if_exists:` for re-run idempotency.
- `lib/typed_eav/versioning/subscriber.rb` — single keyword argument added to `TypedEAV::ValueVersion.create!`: `version_group_id: context[:version_group_id]`. The 3-arg public signature `(value, change_type, context)` is unchanged. When the key is absent (the dominant non-bulk-write path), the value is nil and the column stays NULL — backward-compatible with every existing caller.
- 4 new spec examples covering (a) ValueVersion responds_to :version_group_id (auto-discovered from schema), (b) round-trip via SecureRandom.uuid, (c) subscriber forwards version_group_id when wrapped in `TypedEAV.with_context(version_group_id: uuid) { ... }`, (d) subscriber leaves version_group_id NULL when no context block is active.

## Files Modified

- `db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb` -- create: nullable uuid column + concurrent idx_te_vvs_group btree index on typed_eav_value_versions
- `lib/typed_eav/versioning/subscriber.rb` -- modify: forward context[:version_group_id] to ValueVersion.create! (one new keyword argument; signature unchanged)
- `spec/models/typed_eav/value_version_spec.rb` -- modify: add describe "#version_group_id" block (responds_to + uuid round-trip)
- `spec/lib/typed_eav/versioning/subscriber_spec.rb` -- modify: add describe "version_group_id forwarding (Phase 06 correlation tag)" block (positive + negative examples)

## Commits

- `f21f607` feat(versioning): add version_group_id uuid column to typed_eav_value_versions
- `22706e8` feat(versioning): forward context[:version_group_id] to ValueVersion rows
- `ae616fd` test(versioning): cover version_group_id round-trip and subscriber forwarding

## Deviations

- DEVN-02: Migration timestamp bumped from `20260506000000` to `20260506000001`. The original timestamp collided with `spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb` (the Phase 05 dummy-app Active Storage migration). The plan and the orchestrator's task instructions both pre-amended the timestamp before the agent ran. Class name `AddVersionGroupIdToTypedEAVValueVersions` is unchanged. No behavioral or schema impact — purely a sequencing fix.

## Acceptance Criteria

All 16 acceptance criteria pass. See `ac_results` frontmatter for per-criterion evidence.
