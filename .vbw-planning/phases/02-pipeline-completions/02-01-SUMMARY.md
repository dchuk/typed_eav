---
phase: 2
plan: 01
title: Cascade policy — field_dependent column, FK ON DELETE SET NULL, before_destroy dispatch
status: complete
completed: 2026-04-29
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - f9ef7e8
deviations:
  - "DEVN-01 (minor): plan specified migration class name `AddCascadePolicyToTypedEavFields` (default Rails inflection). Repo registers `EAV` as an inflection acronym in lib/typed_eav.rb so the actual class name had to be `AddCascadePolicyToTypedEAVFields` (uppercase EAV) to match the existing migration class-name pattern (`CreateTypedEAVTables`, `AddParentScopeToTypedEAVPartitions`). Fixed inline in db/migrate/20260501000000_add_cascade_policy_to_typed_eav_fields.rb."
  - "DEVN-02 (critical, plan-amended): plan predicted shoulda-matchers `belong_to(:field)` (bare) would not assert required-ness, so spec/models/typed_eav/value_spec.rb was not in files_modified. In this version of shoulda-matchers it DOES assert required by default, and the failing matcher had to read `belong_to(:field).optional`. Reported as blocker_report; team-lead amended the plan frontmatter to add spec/models/typed_eav/value_spec.rb to files_modified. Resolution: 1-line spec change + rationale comment."
  - "DEVN-01 (minor): plan listed db/schema.rb in files_modified expecting Rails to regenerate it during migrate, but this engine repo has no committed schema.rb (the dummy app's `maintain_test_schema!` does not dump in this configuration). Skipped staging db/schema.rb; commit landed 7 files instead of 8."
  - "DEVN-01 (minor): RuboCop noise from new specs required two stylistic fixes outside the literal plan text — used `described_class` in field_cascade_spec.rb body (RSpec/DescribedClass), gave the second `RSpec.describe TypedEAV::Field::Base` block in field_spec.rb a `'#field_dependent'` description string (RSpec/RepeatedExampleGroupDescription + RSpec/DescribeMethod), and added an inline `rubocop:disable RSpec/SpecFilePathFormat` with justification because spec/lib/typed_eav/field_cascade_spec.rb deliberately groups cross-cutting cascade behavior alongside scoping_spec.rb rather than under spec/models/typed_eav/field/."
pre_existing_issues:
  - "{\"test\": \"rubocop\", \"file\": \"typed_eav.gemspec:22-26\", \"error\": \"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Documented as a known process-exception in STATE.md and acknowledged in 02-01-PLAN.md verify step. Pre-existing on main; not in plan files_modified; not addressed.\"}"
ac_results:
  - criterion: "Greenfield install runs the new migration and lands a typed_eav_fields.field_dependent string column with NOT NULL DEFAULT 'destroy'"
    verdict: pass
    evidence: "f9ef7e8 db/migrate/20260501000000_add_cascade_policy_to_typed_eav_fields.rb; verified columns_hash[\"field_dependent\"].null=false default=\"destroy\""
  - criterion: "typed_eav_values.field_id becomes nullable (NULL allowed) after the migration"
    verdict: pass
    evidence: "f9ef7e8 migration up; verified columns_hash[\"field_id\"].null=true"
  - criterion: "Foreign key from typed_eav_values.field_id → typed_eav_fields.id is ON DELETE SET NULL after the migration (was ON DELETE CASCADE)"
    verdict: pass
    evidence: "f9ef7e8 migration up; verified foreign_keys[\"typed_eav_values\"].on_delete=:nullify; rollback verified restoring :cascade"
  - criterion: "Field::Base validates field_dependent is one of %w[destroy nullify restrict_with_error]; default 'destroy' from DB"
    verdict: pass
    evidence: "f9ef7e8 app/models/typed_eav/field/base.rb +validates inclusion; spec/models/typed_eav/field_spec.rb #field_dependent block (3 examples)"
  - criterion: "Field::Base no longer carries dependent: :destroy on has_many :values; before_destroy callback dispatches by field_dependent"
    verdict: pass
    evidence: "f9ef7e8 field/base.rb has_many :values without dependent: + before_destroy :dispatch_field_dependent"
  - criterion: "field_dependent: 'destroy' → before_destroy calls values.destroy_all so Value rows are removed before the FK fires"
    verdict: pass
    evidence: "spec/lib/typed_eav/field_cascade_spec.rb 'destroys all Value rows for a global field when the field is destroyed' (8 examples total in cascade spec)"
  - criterion: "field_dependent: 'nullify' → before_destroy is a no-op; FK ON DELETE SET NULL nulls field_id automatically"
    verdict: pass
    evidence: "spec/lib/typed_eav/field_cascade_spec.rb 'leaves Value rows in DB with field_id IS NULL when a global field is destroyed'"
  - criterion: "field_dependent: 'restrict_with_error' → before_destroy adds errors[:base] and throws :abort when values.exists?; field row is NOT deleted; the existing field_dependent column value is unchanged"
    verdict: pass
    evidence: "spec/lib/typed_eav/field_cascade_spec.rb 'blocks destroy when Values exist; field row remains and base error is added' — also asserts field_dependent unchanged after failed destroy"
  - criterion: "Value#belongs_to :field is optional: true so orphaned (field_id IS NULL) Value rows do not fail belongs_to presence validation"
    verdict: pass
    evidence: "f9ef7e8 app/models/typed_eav/value.rb +optional: true; spec/models/typed_eav/value_spec.rb belongs_to(:field).optional matcher"
  - criterion: "Existing read-path orphan guards (typed_eav_value, typed_eav_hash, apply_pending_value) continue to silently skip rows where field is nil — no changes needed"
    verdict: pass
    evidence: "spec/lib/typed_eav/field_cascade_spec.rb 'nullifies field_id on a parent-scoped field; entity reads silently skip orphans' — asserts typed_eav_hash returns {}"
  - criterion: "v0.1.0 default behavior preserved: field.destroy! with no field_dependent set defaults to 'destroy' which mirrors the prior dependent: :destroy behavior"
    verdict: pass
    evidence: "DB default 'destroy' verified in migration verify; cascade spec global-destroy example exercises the default path"
  - criterion: "Migration is reversible: down restores field_id NOT NULL, recreates ON DELETE CASCADE FK, drops field_dependent column"
    verdict: pass
    evidence: "Manual migrate→rollback→migrate cycle in Task 1 verify; rollback verified columns_hash[\"field_id\"].null=false, FK on_delete=:cascade, field_dependent column dropped"
  - criterion: "ROADMAP.md Phase 2 goal language refined from 'without adding new columns' to 'additive schema changes only; defaults preserve v0.1.0 behavior'"
    verdict: pass
    evidence: "f9ef7e8 .vbw-planning/ROADMAP.md line 32 updated"
---

Cascade policy wired end-to-end: schema migration + Field::Base validation/before_destroy dispatch + Value optional belongs_to + 11 new specs, all green; v0.1.0 default behavior preserved.

## What Was Built

- New reversible migration `db/migrate/20260501000000_add_cascade_policy_to_typed_eav_fields.rb` adds `typed_eav_fields.field_dependent` (NOT NULL DEFAULT 'destroy'), makes `typed_eav_values.field_id` nullable, drops and recreates the FK with `on_delete: :nullify`. Verified via migrate → rollback → migrate cycle.
- `Field::Base` now: drops `dependent: :destroy` from `has_many :values`, validates `field_dependent` inclusion in `%w[destroy nullify restrict_with_error]`, and dispatches via `before_destroy :dispatch_field_dependent` — `destroy` calls `values.destroy_all`, `nullify` is a no-op (FK does the work), `restrict_with_error` adds an errors[:base] message and `throw(:abort)`s.
- `Value#belongs_to :field` made `optional: true` so orphaned rows (`field_id IS NULL`) validate; rationale comment added linking to the Phase 02 cascade migration and existing read-path guards.
- New `spec/lib/typed_eav/field_cascade_spec.rb` (8 examples) covers the three policies × global/scoped/parent-scoped partitions, including the read-path orphan-skip behavior.
- `spec/models/typed_eav/field_spec.rb` gains a `#field_dependent` describe block (3 examples) exercising the inclusion validator and DB-default.
- `spec/models/typed_eav/value_spec.rb` updated to `belong_to(:field).optional` matcher.
- `.vbw-planning/ROADMAP.md` Phase 2 goal language refined to reflect additive-schema reality.

## Files Modified

- `db/migrate/20260501000000_add_cascade_policy_to_typed_eav_fields.rb` -- create: schema delivery (column, nullability, FK).
- `app/models/typed_eav/field/base.rb` -- modify: remove dependent: :destroy, add field_dependent validator, add before_destroy dispatch + private method.
- `app/models/typed_eav/value.rb` -- modify: belongs_to :field becomes optional: true with rationale comment.
- `spec/lib/typed_eav/field_cascade_spec.rb` -- create: 8-example cascade-policy matrix.
- `spec/models/typed_eav/field_spec.rb` -- modify: add #field_dependent describe block (3 examples).
- `spec/models/typed_eav/value_spec.rb` -- modify: belong_to(:field).optional matcher (plan amendment, see DEVN-02).
- `.vbw-planning/ROADMAP.md` -- modify: Phase 2 goal sentence refined.
