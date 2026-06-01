---
phase: 8
plan: "08-01"
title: Field display label (label column + display_name + schema round-trip)
status: complete
completed: 2026-06-01
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - f88b986
  - 5d67f04
  - 447663b
  - a3a2e60
  - ffeba33
deviations:
  - "spec/dummy/db/schema.rb was listed in the plan's files_modified but does NOT exist in this repo and was NOT created (DEVN-02). The dummy app intentionally commits no schema dump (documented in spec/spec_helper.rb lines 22-30); the test DB is built by maintain_test_schema! plus direct application of engine migrations. The label migration was applied to the test DB via the engine MigrationContext (matching how prior phases worked) and reversibility was verified by rollback + re-migrate. Generating a schema.rb now would introduce a large unrelated artifact inconsistent with the repo's documented choice."
pre_existing_issues: []
ac_results:
  - criterion: "typed_eav_fields.label is a nullable string column with no index, no default, no backfill; migration is reversible."
    verdict: "pass"
    evidence: "f88b986; verified via connection.columns (null:true, no label index) and rollback+re-migrate round-trip"
  - criterion: "Field#display_name returns label.presence || name.humanize — present label wins, blank/nil falls back to name.humanize."
    verdict: "pass"
    evidence: "5d67f04; spec/models/typed_eav/field_spec.rb 'Field display label (issue #21) #display_name'"
  - criterion: "label has NO uniqueness and NO format constraint; RESERVED_NAMES and slug-uniqueness apply to :name only and are unchanged."
    verdict: "pass"
    evidence: "5d67f04; grep 'validates :label' shows only length/allow_nil; specs for no-uniqueness and reserved-like label value"
  - criterion: "Editing only :label dispatches on_field_change with :update, NEVER :rename — _dispatch_field_change unchanged."
    verdict: "pass"
    evidence: "447663b; spec/regressions/issue_21_label_no_rename_spec.rb (3 examples)"
  - criterion: "Field.sorted ordering stays (sort_order, name); label never participates in ordering."
    verdict: "pass"
    evidence: "5d67f04; grep shows order(sort_order: :asc, name: :asc) unchanged; sorted-ordering spec with re-sorting labels"
  - criterion: "export_field_entry emits a 'label' key carrying field.label (raw); import reproduces it and divergence detection treats a differing label as a difference."
    verdict: "pass"
    evidence: "a3a2e60; schema_portability_spec 'field label round-trip' export/round-trip/overwrite/divergence cases"
  - criterion: "Legacy import payloads with no 'label' key import label as NULL (no version gate) and display_name falls back."
    verdict: "pass"
    evidence: "a3a2e60; schema_portability_spec legacy-payload-no-label-key example"
  - criterion: "export_snapshot_field_entry emits a resolved 'display_name' key (render-oriented)."
    verdict: "pass"
    evidence: "a3a2e60; schema_portability_spec snapshot display_name (present + nil fallback) examples"
  - criterion: "RSpec suite (~820+ examples) stays green; no existing name-based caller changes behavior."
    verdict: "pass"
    evidence: "ffeba33 green gate: 1158 examples, 0 failures"
---

Added an optional free-text `label` column + canonical `display_name` reader to TypedEAV::Field, fully additive and backwards compatible, with raw-label round-trip in regular schema export/import and resolved `display_name` in snapshot export.

## What Was Built

- Reversible additive migration adding a nullable `:string` `label` column to `typed_eav_fields` (no index, no default, no backfill).
- `Field#display_name => label.presence || name.humanize` plus an optional `validates :label, length: { maximum: 255 }, allow_nil: true` — no uniqueness/format constraint; `:name` constraints, `RESERVED_NAMES`, rename dispatch, and `sorted` ordering all untouched.
- A regression guard (`spec/regressions/issue_21_label_no_rename_spec.rb`) pinning that a label-only edit dispatches `:update`, never `:rename`, with a `:name`-change contrast case proving the discriminator.
- Schema portability: `export_field_entry` emits raw `"label"`; `overwrite_field!` allow-lists `label`; `create_field!` unchanged (label passes through `entry.except("options_data")`); `export_snapshot_field_entry` emits resolved `"display_name"`. Legacy payloads (no `label` key) import as NULL with no version gate.
- One README bullet under §"Validation Behavior" documenting the label/display_name contract.

## Files Modified

- `db/migrate/20260507000000_add_label_to_typed_eav_fields.rb` -- created: additive nullable label column on typed_eav_fields.
- `app/models/typed_eav/field/base.rb` -- edited: added `display_name` reader and optional label length validation.
- `lib/typed_eav/schema_portability.rb` -- edited: raw label round-trip in export/overwrite; resolved display_name in snapshot.
- `spec/models/typed_eav/field_spec.rb` -- edited: display_name (present/blank/nil), label validation, no-uniqueness, slugified-name, sorted-ordering specs.
- `spec/lib/typed_eav/schema_portability_spec.rb` -- edited: label round-trip / legacy / overwrite / divergence / snapshot display_name specs; updated one existing snapshot key-set assertion to include `display_name`.
- `spec/regressions/issue_21_label_no_rename_spec.rb` -- created: label-only-edit => :update regression guard.
- `README.md` -- edited: label/display_name contract bullet under §"Validation Behavior".

## Deviations

`spec/dummy/db/schema.rb` (listed in the plan) does not exist in this repo and was not created — the dummy app commits no schema dump by design (see `spec/spec_helper.rb` lines 22-30). The migration was applied to the test DB via the engine `MigrationContext` and verified reversible (rollback + re-migrate), matching how prior phases delivered schema changes. All other files match the plan.
