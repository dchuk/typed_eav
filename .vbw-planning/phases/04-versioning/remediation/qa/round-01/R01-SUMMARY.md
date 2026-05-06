---
phase: 4
round: 01
title: Phase 04 plan-amendment remediation — align 04-01 and 04-03 PLANs with shipped code (DEV-01..DEV-05)
type: remediation
status: complete
completed: 2026-05-06
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 7d4b4070142fe9e2697d97d7fef81d6f3c8daee6
  - 88c4f45fe3b9bd03751d7ae982b583af1a1a019d
  - f85f4c51163cbdac6f54328a4de43878efcb9b57
  - fc70ccc187d27910729eebc4fd3b28c1bb0116e4
  - 4fbe322cde78370caa867ebc604588dce32b37fb
files_modified:
  - .vbw-planning/phases/04-versioning/04-01-PLAN.md
  - .vbw-planning/phases/04-versioning/04-03-PLAN.md
  - .vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md
deviations: []
known_issue_outcomes: []
---

Round-01 of Phase 04 QA remediation: all five DEV-0* FAILs from 04-VERIFICATION.md were plan-versus-code drift, not code defects. Five atomic plan-amendment commits brought 04-01-PLAN.md and 04-03-PLAN.md into byte-level agreement with the shipped code; DEV-03 was recorded as a documented process-exception per Plan §P05 step 7. No code, README, migrations, specs, or SUMMARY.md files were modified.

## Task 1: T1 — DEV-01 plan-amendment: collapse 04-01 dummy-migration must_have to a single branch and remove from files_modified

### What Was Built
- Removed `spec/dummy/db/migrate/20260330000001_create_test_entities.rb` from 04-01-PLAN.md frontmatter `files_modified` (the file was never modified in commits 815d151..a4b204e — that line was the verifier's primary anchor for DEV-01).
- Replaced the two-branch must_have ("...OR no dummy schema change here and plan 04-02 reuses Contact (Lead must pin the choice...)") with the single-branch wording matching what shipped: "No dummy schema change shipped this plan: spec/dummy/db/migrate/20260330000001_create_test_entities.rb is unchanged. Plan 04-02 reuses the existing Contact (tenant_id) and Project (workspace_id) test entities for per-entity opt-in integration tests — no new column required."

### Files Modified
- `.vbw-planning/phases/04-versioning/04-01-PLAN.md` -- amend: drop dummy-migration line from `files_modified` frontmatter; replace two-branch must_have at line 36 with single-branch wording.

### Acceptance Evidence
- `awk '/^files_modified:/,/^forbidden_commands:/'` returns no `20260330000001_create_test_entities` hits.
- `awk '/^  artifacts:/,/^  key_links:/'` returns no `20260330000001_create_test_entities` hits.
- `grep "OR no dummy schema change\|Lead must pin\|versioned_workspace_id"` returns zero hits.
- `grep "no dummy schema change shipped"` returns one hit (the new single-branch wording at line 35).

### Deviations
None.

## Task 2: T2 — DEV-02 plan-amendment: document the exact rubocop-compliant validator approach in 04-01 model task

### What Was Built
- Updated `must_haves.truths` belongs_to bullet (line 27) to specify: NO redundant `foreign_key:` argument on any of `:value`, `:field`, or `:entity` (Rails/RedundantForeignKey); `inverse_of: :versions` on `:value`; `inverse_of: false` on `:field` (Field::Base does not declare a reverse `has_many :versions`); has_many :versions on TypedEAV::Value also declared without redundant `foreign_key: :value_id`.
- Updated `must_haves.truths` validations bullet (line 28) to require: `change_type` inclusion validator with custom message ("must be one of: create, update, destroy"); `entity_id` presence retained as a named validator with inline `# rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo` plus justification; spec asserts via shoulda-matchers `with_message(...)`.
- Edited Task P02 ruby snippet for the `TypedEAV::ValueVersion` model: removed `foreign_key: :value_id` and `foreign_key: :field_id` from the two relevant `belongs_to` declarations; added `inverse_of: false` on `belongs_to :field`; added the rubocop:disable comment on `validates :entity_id, presence: true`; added explanatory comment block above the validators (matches shipped value_version.rb byte-for-byte).
- Edited Task P02 ruby snippet for the value.rb `has_many :versions` declaration: removed `foreign_key: :value_id`; added comment "No redundant foreign_key: :value_id (Rails/RedundantForeignKey)".
- Updated Task P02 spec snippet so the `validate_inclusion_of(:change_type)` matcher chains `.with_message("must be one of: create, update, destroy")` (matches shipped value_version_spec.rb lines 15-19).
- Updated `<verify>` and `<done>` blocks to reflect the no-redundant-FK has_many declaration on Value.

### Files Modified
- `.vbw-planning/phases/04-versioning/04-01-PLAN.md` -- amend: belongs_to / has_many declarations + validators + spec snippet now match shipped code; must_haves and verify/done blocks updated.

### Acceptance Evidence
- `grep -i "redundant"` returns hits in both must_haves (lines 27-28) and Task P02 ruby/comment text (lines 329-330, 344-345, 374, 411, 572, 577).
- `grep "with_message\|must be one of: create, update, destroy"` returns hits in must_have (line 28) and spec snippet (line 440).
- `grep "inverse_of: false"` returns hits in must_have (line 27) and ruby snippet (lines 341, 349).
- No raw `foreign_key: :value_id` or `foreign_key: :field_id` arguments remain on any `belongs_to` declaration in the ruby snippets — only in negative-context comments stating they are absent.

### Deviations
None.

## Task 3: T3 — DEV-03 process-exception: record P05 scratch-app smoke-test deferral

### What Was Built
- Confirmed the §Process Exceptions block in R01-PLAN.md (lines 410-458, top-level between `<success_criteria>` and `<known_issue_workflow>`) is well-formed and records the formal deferral of the /tmp scratch-app smoke flow. The block names DEV-03 by id, classifies it as process-exception per Plan §P05 step 7, explains why interactive `bundle install` is non-executable in an autonomous agent context, and lists the three pieces of equivalent-acceptance evidence (dummy-app migrate/rollback/re-migrate, engine-boot column-list probe, Scout §5 idempotency guarantee).
- Appended a single cross-reference bullet to 04-01-PLAN.md Task P05's `<done>` block (line 998): "Round-01 process-exception: see ... R01-PLAN.md §Process Exceptions for the formal record of DEV-03's deferral and the functionally equivalent acceptance criteria (dummy app migrate/rollback/re-migrate + engine-boot column-list probe + Scout §5 idempotency guarantee)."

### Files Modified
- `.vbw-planning/phases/04-versioning/04-01-PLAN.md` -- amend: append one new bullet to Task P05's `<done>` block cross-referencing R01-PLAN.md §Process Exceptions.
- `.vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md` -- referenced (no edits needed; §Process Exceptions block already present).

### Acceptance Evidence
- `grep "process_exceptions\|Process Exceptions" R01-PLAN.md` returns hits in §Process Exceptions block at lines 410-458 and §title references throughout.
- `grep "DEV-03\|process-exception" R01-PLAN.md` returns hits in `fail_classifications`, §Process Exceptions block, and rationale prose.
- `grep "Round-01 process-exception\|R01-PLAN.md §Process" 04-01-PLAN.md` returns one hit at line 998 (the new cross-reference in P05's `<done>` block).
- 04-01-SUMMARY.md is unchanged: `git diff --stat` returns empty.

### Deviations
None.

## Task 4: T4 — DEV-04 plan-amendment (Critical): align 04-03 history-spec narrative + README cross-reference with FK ON DELETE SET NULL semantics

### What Was Built
- Replaced the `value_history_spec covers` must_have bullet (line 30) with a schema-correct narrative: pre-destroy `value.history` excludes `:destroy` because the subscriber writes the destroy version AFTER the after_commit chain runs; post-destroy via the entity-scoped `TypedEAV::ValueVersion.where(entity_type:, entity_id:, field_id:)` query exposes the full create+update+destroy lifecycle with ALL pre-existing rows having `value_id: nil` because FK ON DELETE SET NULL nullifies value_id on every row referencing the destroyed Value (not just the new :destroy row).
- Rewrote Task P01 post-destruction describe block (lines 273-318) to match the shipped value_history_spec.rb byte-for-byte: pre-destroy assertion uses `value.history.pluck(:change_type)` with `contain_exactly("create", "update")` and `not_to include("destroy")`; post-destroy assertion uses the entity-scoped query and asserts `change_types_full` includes all three change types. Added the inline comment block describing the FK ON DELETE SET NULL ripple semantic.
- Updated Task P03 README §"Querying full audit history" snippet (lines 992-1023) so the illustrative ruby query result shows all three rows (create / update / destroy) with `value_id: nil` post-destroy. Replaced the prior narrative claim that ":destroy versions have value_id: nil" with the schema-correct framing: "the FK ON DELETE SET NULL ripples on destroy — destroying the parent Value nullifies value_id on EVERY pre-existing version row referencing it ... All three rows end up with value_id: nil post-destruction." Matches the shipped README at lines 769-797 byte-for-byte on this shape.

### Files Modified
- `.vbw-planning/phases/04-versioning/04-03-PLAN.md` -- amend: must_haves.truths value_history_spec coverage bullet rewritten; Task P01 post-destruction describe block rewritten; Task P03 README §"Querying full audit history" snippet rewritten.

### Acceptance Evidence
- `grep "value_id: nil\|FK ON DELETE SET NULL nullifies"` returns multiple hits across must_haves (line 30), Task P01 body (lines 264, 283, 294, 301, 305, 315), and Task P03 README snippet (lines 1000, 1007, 1021-1023).
- `grep "create and update versions retain their value_id\|only the destroy version is orphaned"` returns ZERO hits.
- `grep -E "value_id: ([0-9]+)"` returns ZERO hits — no numeric value_id remains in any README snippet.
- 04-03-SUMMARY.md is unchanged: `git diff --stat` returns empty.

### Deviations
None.

## Task 5: T5 — DEV-05 plan-amendment: allow paired AbcSize disable/enable + specific-instance stub in 04-03 P02 must_haves

### What Was Built
- Appended the two rubocop-allowance sub-clauses to the `must_haves.truths` revert_to bullet (line 23): paired `# rubocop:disable Metrics/AbcSize -- ... justification ...` / `# rubocop:enable Metrics/AbcSize` per CONVENTIONS.md "disable rubocop with a justification, not silently"; save-failure spec uses `allow(value).to receive(:validate_value)` on the specific instance (not `allow_any_instance_of`) per RSpec/AnyInstance cop.
- Added paired rubocop comments around the `def revert_to` method in Task P02 ruby snippet (lines 423/477) — `# rubocop:disable Metrics/AbcSize -- three guard clauses (each with a multi-line error message including ids) plus the column-iteration body genuinely belong together; splitting them would obscure the locked check ordering documented above. The ABC complexity is just over the 25 threshold and reflects the explicit error-message construction (not control-flow density).` and the matching `# rubocop:enable Metrics/AbcSize` after the closing `end`. Matches shipped value.rb lines 186/240.
- Replaced the save-failure spec snippet `allow_any_instance_of(TypedEAV::Value).to receive(:validate_value) do |v| ... end` block with `allow(value).to receive(:validate_value) do ... end` plus an explanatory comment "Avoids allow_any_instance_of (RSpec/AnyInstance) — `value` is the only instance we need to fail, and it is the same in-memory record revert_to operates on." Matches shipped value_revert_to_spec.rb lines 198-204.

### Files Modified
- `.vbw-planning/phases/04-versioning/04-03-PLAN.md` -- amend: must_haves revert_to bullet appended; Task P02 ruby snippet wraps `def revert_to` in paired rubocop:disable/enable Metrics/AbcSize; Task P02 spec snippet replaces `allow_any_instance_of` with `allow(value)`.

### Acceptance Evidence
- `grep "rubocop:disable Metrics/AbcSize\|rubocop:enable Metrics/AbcSize"` returns paired hits at must_have (line 23) and Task P02 ruby snippet (lines 423 disable / 477 enable).
- `grep "allow_any_instance_of"` returns hits ONLY in negative-context strings (must_have explanation that we DON'T use it; spec comment "Avoids allow_any_instance_of (RSpec/AnyInstance)") — no actual usage remains.
- `grep "allow(value).to receive(:validate_value)"` returns hits in must_have (line 23) and spec body (line 685).
- `grep "RSpec/AnyInstance\|specific instance"` returns hits in both must_have (line 23) and spec body comments (lines 681-682).
- 04-03-SUMMARY.md is unchanged: `git diff --stat` returns empty.

### Deviations
None.
