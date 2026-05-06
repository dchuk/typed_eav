---
phase: 4
round: 01
plan: R01
title: Phase 04 plan-amendment remediation — align 04-01 and 04-03 PLANs with shipped code (DEV-01..DEV-05)
type: remediation
autonomous: true
effort_override: balanced
skills_used: [rails-architecture, database-migrations, tdd-cycle]
files_modified:
  - .vbw-planning/phases/04-versioning/04-01-PLAN.md
  - .vbw-planning/phases/04-versioning/04-03-PLAN.md
  - .vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md
forbidden_commands:
  - bin/rails *
  - bundle exec rspec *
  - bundle exec rubocop *
  - git commit *
fail_classifications:
  - {id: "DEV-01", type: "plan-amendment", source_plan: "04-01-PLAN.md", rationale: "DEVN-02 selected the no-schema-change branch in shipped code; the plan must_have offered two branches and listed the dummy migration in files_modified. Plan must be amended to single-branch wording matching what shipped — no test edits required."}
  - {id: "DEV-02", type: "plan-amendment", source_plan: "04-01-PLAN.md", rationale: "DEVN-01 rubocop-compliance adjustments (RedundantForeignKey removal, RedundantPresenceValidationOnBelongsTo inline disable on entity_id, custom message on change_type with shoulda with_message in spec) align with CONVENTIONS.md. Plan must document the exact validator approach the shipped model uses."}
  - {id: "DEV-03", type: "process-exception", rationale: "P05 install-generator scratch-app smoke test in /tmp requires interactive `bundle install`, which is non-executable in autonomous agent context. Dummy app migrate/rollback/re-migrate plus engine-boot smoke probe satisfy P05 functional acceptance per Scout §5 idempotency guarantee. Plan §P05 already permits documented deferral; round-01 records the exception explicitly."}
  - {id: "DEV-04", type: "plan-amendment", source_plan: "04-03-PLAN.md", rationale: "DEVN-02 (Critical): plan-supplied post-destruction example assumed `versions_for_value_id.pluck(:change_type) == [\"create\", \"update\"]` would survive destroy. Actual schema (FK ON DELETE SET NULL on typed_eav_value_versions.value_id) nullifies value_id on ALL pre-existing version rows when parent Value is destroyed. Plan P01 spec narrative and README §\"Querying full audit history\" cross-reference must reflect the schema-correct semantics."}
  - {id: "DEV-05", type: "plan-amendment", source_plan: "04-03-PLAN.md", rationale: "DEVN-01 (Minor) rubocop fixes: paired Metrics/AbcSize disable/enable with justification on revert_to (per CONVENTIONS.md \"disable rubocop with a justification, not silently\"); RSpec/AnyInstance replaced with `allow(value)` on the specific instance. Plan P02 must_haves must allow these explicitly so future readers do not flag them as drift."}
known_issues_input: []
known_issue_resolutions: []
must_haves:
  truths:
    - "04-01-PLAN.md must_have for DEVN-02 reads as a single-branch decision (\"no dummy schema change shipped this plan; plan 04-02 reuses Contact/Project test entities for per-entity opt-in integration tests\") and the dummy-migrate file is removed from frontmatter `files_modified`. The two-branch wording (\"OR no dummy schema change here\") is gone."
    - "04-01-PLAN.md must_have block and Task body for the ValueVersion model document the exact rubocop-compliant validator approach: (a) `belongs_to` declarations carry no redundant `foreign_key:` argument (defaults match the association name; satisfies Rails/RedundantForeignKey); (b) `validates :entity_id, presence: true` retained with inline `# rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo` + justification (preserves the named-validator grep contract alongside the implicit belongs_to enforcement); (c) `change_type` inclusion validator carries a custom message (\"must be one of: create, update, destroy\") and the spec asserts via shoulda-matchers `with_message(...)`."
    - "04-01-PLAN.md §P05 carries an explicit Process Exceptions note (or R01-PLAN.md carries an equivalent §Process Exceptions block referenced from the plan) explaining that the scratch-app smoke test in /tmp is non-executable in an autonomous agent context (no interactive `bundle install`). The dummy app's migrate/rollback/re-migrate cycle (verified in P01) plus the engine-boot column-list probe (plan §verification step 6) plus Scout §5's documented idempotency guarantee for the standard `typed_eav:install:migrations` rake task collectively satisfy P05's acceptance."
    - "04-03-PLAN.md Task P01 (Value#history spec) post-destruction example asserts: pre-destroy via `value.history` excludes `:destroy` (subscriber writes the destroy version AFTER the after_commit chain runs, so it does not appear in pre-destroy reads); post-destroy via the entity-scoped `TypedEAV::ValueVersion.where(entity_type:, entity_id:, field_id:)` query exposes the full lifecycle (create + update + destroy) with ALL pre-existing rows having `value_id: nil` because FK ON DELETE SET NULL nullifies value_id on every row referencing the destroyed Value (not just the new :destroy row). The README §\"Querying full audit history\" cross-reference matches that post-destroy shape."
    - "04-03-PLAN.md Task P02 (Value#revert_to) must_haves explicitly allow: (a) paired `# rubocop:disable Metrics/AbcSize` / `# rubocop:enable Metrics/AbcSize` with inline justification per CONVENTIONS.md; (b) the save-failure spec uses `allow(value).to receive(:validate_value)` on the specific instance (not `allow_any_instance_of`) per RSpec/AnyInstance cop."
    - "Shipped code is unchanged — no app/, lib/, spec/, db/migrate/, or README edits in this round. Only `.vbw-planning/phases/04-versioning/04-01-PLAN.md` and `.vbw-planning/phases/04-versioning/04-03-PLAN.md` are amended; SUMMARY.md files are NOT modified."
  artifacts:
    - path: ".vbw-planning/phases/04-versioning/04-01-PLAN.md"
      provides: "Plan 04-01 amended to match shipped code: single-branch dummy-migration wording (DEV-01); explicit validator approach for DEVN-01 rubocop fixes (DEV-02); P05 process-exception note for the scratch-app smoke test (DEV-03)"
      contains: "no dummy schema change"
    - path: ".vbw-planning/phases/04-versioning/04-03-PLAN.md"
      provides: "Plan 04-03 amended to match shipped code: schema-correct post-destruction history-spec narrative + README cross-reference (DEV-04); paired AbcSize disable/enable + specific-instance stub allowance for revert_to (DEV-05)"
      contains: "value_id: nil"
    - path: ".vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md"
      provides: "This remediation plan; records all five FAIL classifications and the §Process Exceptions block for DEV-03"
      contains: "fail_classifications"
  key_links:
    - from: ".vbw-planning/phases/04-versioning/04-01-PLAN.md frontmatter must_haves + Task P02/P03 body"
      to: "app/models/typed_eav/value_version.rb (shipped)"
      via: "amended wording matches shipped CHANGE_TYPES custom message + entity_id rubocop-disable + no-redundant-FK pattern"
    - from: ".vbw-planning/phases/04-versioning/04-01-PLAN.md frontmatter files_modified + DEVN-02 must_have"
      to: "(absence of) spec/dummy/db/migrate/20260330000001_create_test_entities.rb edits in commits 815d151..a4b204e"
      via: "single-branch wording removes the file and the OR-clause; commits show the file is unchanged"
    - from: ".vbw-planning/phases/04-versioning/04-03-PLAN.md Task P01 spec narrative + README cross-reference"
      to: "spec/models/typed_eav/value_history_spec.rb post-destruction example (shipped) + README §Querying full audit history (shipped)"
      via: "amended narrative reflects FK ON DELETE SET NULL nullifying all pre-existing rows"
    - from: ".vbw-planning/phases/04-versioning/04-03-PLAN.md Task P02 must_haves"
      to: "app/models/typed_eav/value.rb revert_to (paired AbcSize disable/enable, lines 186/240) + spec/models/typed_eav/value_revert_to_spec.rb (allow(value) on specific instance)"
      via: "amended must_haves allow CONVENTIONS.md-compliant rubocop suppressions"
---
<objective>
Round-01 of Phase 04 QA remediation. The shipped code is correct (`bundle exec rspec` reports 653 examples / 0 failures, full rubocop clean). The five `DEV-0*` FAILs in 04-VERIFICATION.md are plan-versus-code drift, not code defects. This round amends plans 04-01 and 04-03 in place so a future re-verification (a) finds the plan must_haves match shipped code byte-for-byte where it matters and (b) records DEV-03's smoke-test deferral as a documented process exception rather than an undocumented gap.

No code changes. No SUMMARY.md edits (SUMMARYs are immutable post-execution artifacts). No new tasks introduced beyond the five required to clear DEV-01..DEV-05.
</objective>
<context>
@.vbw-planning/phases/04-versioning/04-VERIFICATION.md
@.vbw-planning/phases/04-versioning/04-01-PLAN.md
@.vbw-planning/phases/04-versioning/04-01-SUMMARY.md
@.vbw-planning/phases/04-versioning/04-03-PLAN.md
@.vbw-planning/phases/04-versioning/04-03-SUMMARY.md
@.vbw-planning/phases/04-versioning/04-CONTEXT.md
@.vbw-planning/codebase/CONVENTIONS.md
@/Users/darrindemchuk/.claude/skills/rails-architecture/SKILL.md
@/Users/darrindemchuk/.claude/skills/database-migrations/SKILL.md
@/Users/darrindemchuk/.claude/skills/tdd-cycle/SKILL.md

Locked decisions binding on this round:

- **Plans, not code, are amended.** The verifier flagged drift between plan must_haves and shipped code. Shipped code is correct (5 deviations were all reasoned design responses to either rubocop or actual schema semantics). Round-01 brings the plans up to match.
- **SUMMARY.md files are immutable.** Both 04-01-SUMMARY.md and 04-03-SUMMARY.md remain untouched — they are the post-execution record of what shipped, including the deviations as filed. Amending them would erase the audit trail.
- **DEV-03 is a process-exception, not a code or plan defect.** Plan §P05 step 7 already permits documented deferral. Round-01 makes the deferral explicit in a §Process Exceptions block.
- **No re-verification in this round.** This is a planning-artifact edit. The next QA verification pass (round-02 or post-amend re-run) will confirm the plans now match shipped code.
</context>
<tasks>
<!-- Tasks are sequential. T1, T2, T3 amend 04-01-PLAN.md; T4, T5 amend 04-03-PLAN.md.
     Within each plan, edits are ordered top-to-bottom so earlier edits don't invalidate later anchors. -->

<task type="auto">
  <name>T1 — DEV-01 plan-amendment: collapse 04-01 dummy-migration must_have to a single branch and remove from files_modified</name>
  <files>
.vbw-planning/phases/04-versioning/04-01-PLAN.md
  </files>
  <action>
Amend 04-01-PLAN.md to align with the no-schema-change branch that shipped (per 04-01-SUMMARY.md DEVN-02).

**Edit 1 — frontmatter `files_modified` array.** Locate the line:
```
- spec/dummy/db/migrate/20260330000001_create_test_entities.rb
```
in the top-of-file `files_modified:` list (around line 17). Remove that line entirely. The shipped commits (815d151, 4d20622, e6eb2ee, a4b204e) do not modify this file; keeping it in `files_modified` is the verifier's primary anchor for DEV-01.

**Edit 2 — `must_haves.truths` two-branch must_have.** Locate the bullet (around line 36):
```
- "spec/dummy/db/migrate/20260330000001_create_test_entities.rb adds `versioned_workspace_id` column to projects table (or new table) for plan 04-02's per-entity opt-in integration test — OR no dummy schema change here and plan 04-02 reuses Contact (Lead must pin the choice in §Plan-time decisions)"
```
Replace with the single-branch wording:
```
- "No dummy schema change shipped this plan: spec/dummy/db/migrate/20260330000001_create_test_entities.rb is unchanged. Plan 04-02 reuses the existing Contact (tenant_id) and Project (workspace_id) test entities for per-entity opt-in integration tests — no new column required."
```

**Edit 3 — Task P04 spec_helper / dummy app section.** Search for any P-task body or §Plan-time decisions paragraph that still references the two-branch decision (look for the strings "OR no dummy schema change", "Lead must pin the choice", "versioned_workspace_id"). For each such reference inside the Task `<action>`/`<verify>`/`<done>` blocks, rewrite to the single-branch language ("no dummy schema change shipped; plan 04-02 reuses Contact/Project"). Do not introduce new tasks; only edit existing prose.

**Edit 4 — `must_haves.artifacts` block.** If `spec/dummy/db/migrate/20260330000001_create_test_entities.rb` appears as a `path:` entry under `artifacts:`, remove that artifact entry. (Not currently expected based on the frontmatter read; verify before editing.)
  </action>
  <verify>
- `grep -n "20260330000001_create_test_entities" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns no hits inside `files_modified:`, no hits inside `must_haves.truths`, and no hits inside `must_haves.artifacts`. (References inside the §Plan-time decisions paragraph as historical context are fine if reworded; in-scope edits target the binding fields.)
- `grep -n "OR no dummy schema change\|Lead must pin\|versioned_workspace_id" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns zero hits.
- `grep -n "no dummy schema change shipped" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns at least one hit (the new single-branch wording).
- `git diff .vbw-planning/phases/04-versioning/04-01-PLAN.md` shows ONLY removals of the two-branch language and additions of the single-branch language. No edits outside the targeted regions.
  </verify>
  <done>
- The DEV-01 must_have (verifier row 21) would now PASS: the file is no longer claimed in `files_modified` and the must_have is single-branch matching the shipped commits.
  </done>
</task>

<task type="auto">
  <name>T2 — DEV-02 plan-amendment: document the exact rubocop-compliant validator approach in 04-01 model task</name>
  <files>
.vbw-planning/phases/04-versioning/04-01-PLAN.md
  </files>
  <action>
Amend 04-01-PLAN.md so the ValueVersion model must_haves and Task body match the shipped `app/models/typed_eav/value_version.rb` (verified in 04-01-SUMMARY.md ac_results criteria 4-6 and DEVN-01 deviations).

**Edit 1 — `must_haves.truths` belongs_to bullet.** Locate the bullet (around line 28):
```
- "ValueVersion has: belongs_to :value (optional: true, class_name TypedEAV::Value), belongs_to :field (optional: true, class_name TypedEAV::Field::Base), belongs_to :entity (polymorphic: true)"
```
Replace with:
```
- "ValueVersion has: belongs_to :value (optional: true, class_name TypedEAV::Value); belongs_to :field (optional: true, class_name TypedEAV::Field::Base, inverse_of: false because Field::Base does not declare a reverse has_many :versions in this plan); belongs_to :entity (polymorphic: true). NO redundant `foreign_key:` argument on any of the three (defaults match the association name; satisfies rubocop Rails/RedundantForeignKey). The has_many :versions on TypedEAV::Value is also declared without a redundant `foreign_key: :value_id` for the same reason."
```

**Edit 2 — `must_haves.truths` validations bullet.** Locate the bullet (around line 29):
```
- "ValueVersion validates: change_type inclusion in %w[create update destroy], entity_type presence, entity_id presence, changed_at presence"
```
Replace with:
```
- "ValueVersion validates: change_type inclusion in %w[create update destroy] WITH a custom message (\"must be one of: create, update, destroy\") so the failure mode is self-documenting; entity_type presence; entity_id presence retained as a named validator with inline `# rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo` plus justification (preserves the grep contract on the named validator alongside the implicit belongs_to enforcement); changed_at presence. The spec asserts the change_type validator via shoulda-matchers `validate_inclusion_of(:change_type).in_array(%w[create update destroy]).with_message(\"must be one of: create, update, destroy\")`."
```

**Edit 3 — Task body P02 / P03 (whichever defines the model code block).** Locate the embedded ruby code block in Task `<action>` that shows the `TypedEAV::ValueVersion` model definition (around line 350-370). Confirm the inline code matches:
- `belongs_to :value, optional: true, class_name: "TypedEAV::Value"` (no `foreign_key:`)
- `belongs_to :field, optional: true, class_name: "TypedEAV::Field::Base", inverse_of: false`
- `belongs_to :entity, polymorphic: true`
- `validates :change_type, inclusion: { in: CHANGE_TYPES, message: "must be one of: #{CHANGE_TYPES.join(\", \")}" }`
- `validates :entity_id, presence: true # rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo -- preserves the named-validator grep contract alongside implicit belongs_to enforcement`

If any line in the task's ruby snippet still shows `foreign_key: :value_id` or `foreign_key: :field_id` on a belongs_to, or shows the change_type inclusion validator without the `message:` key, edit it to match the shipped code (cross-checked against `app/models/typed_eav/value_version.rb` lines 79-90 and the same file's belongs_to declarations).

**Edit 4 — `app/models/typed_eav/value.rb` has_many :versions snippet.** In Task P02's value.rb snippet (around line 400), the shown declaration uses `foreign_key: :value_id`. Per DEVN-01 the shipped code removes that argument. Edit the snippet to:
```ruby
has_many :versions,
         class_name: "TypedEAV::ValueVersion",
         inverse_of: :value
```
Add a one-sentence comment above the change explaining: `# No redundant foreign_key: :value_id (Rails/RedundantForeignKey — default matches the association inverse).`

**Edit 5 — Task `<verify>` block for the model task.** If `<verify>` lists rubocop expectations (e.g., "rubocop --only Rails/Redundant…"), confirm the expected outcome aligns with the shipped state (no offenses on these cops). No new rubocop invocations needed — keep verification scope unchanged from the original plan.
  </action>
  <verify>
- `grep -n "redundant" .vbw-planning/phases/04-versioning/04-01-PLAN.md -i` returns at least one hit referencing Rails/RedundantForeignKey rationale and at least one referencing Rails/RedundantPresenceValidationOnBelongsTo justification.
- `grep -n "with_message\|must be one of: create, update, destroy" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns hits in both the must_haves block and the spec snippet of the model task.
- `grep -n "inverse_of: false" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns hits in the `belongs_to :field` description and in any embedded ruby snippet showing the model.
- The Task body's ruby snippet for ValueVersion belongs_to declarations does NOT contain `foreign_key: :value_id` or `foreign_key: :field_id`.
- `git diff .vbw-planning/phases/04-versioning/04-01-PLAN.md` shows additions describing the rubocop-disable justifications, the custom message, and the inverse_of: false; removals of any redundant `foreign_key:` arguments. No edits to other tasks.
  </verify>
  <done>
- The DEV-02 must_have (verifier row 22) would now PASS: the plan documents the exact validator approach the shipped model uses (custom message, with_message in spec, entity_id rubocop-disable with justification, no redundant FK args).
  </done>
</task>

<task type="auto">
  <name>T3 — DEV-03 process-exception: record P05 scratch-app smoke-test deferral</name>
  <files>
.vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md
.vbw-planning/phases/04-versioning/04-01-PLAN.md
  </files>
  <action>
DEV-03 is classified as a process-exception (not a plan-amendment). The shipped behavior is correct; the deferral is permitted by Plan §P05 step 7 ("If the smoke test is impractical to run … document the deviation in SUMMARY.md and note that plan 04-02 must run an equivalent smoke test"). Round-01 makes the exception explicit and durable.

**Edit 1 — Append a §Process Exceptions block to THIS file (R01-PLAN.md).** Add a `<process_exceptions>` section between `<success_criteria>` and `<known_issue_workflow>` (or as a top-level section if the orchestrator's renderer prefers; see body below). The block contents:

```
<process_exceptions>
DEV-03 — P05 install-generator scratch-app smoke test (Plan 04-01).

CLASSIFICATION: process-exception (not a code or plan defect; the plan
explicitly permits documented deferral at §P05 step 7).

WHAT WAS DEFERRED: The /tmp scratch-app smoke flow (`rails new
versioning_smoke --skip-bundle --skip-test` followed by interactive
`bundle install`, `bin/rails generate typed_eav:install`, and
`bin/rails db:create db:migrate`).

WHY: An autonomous agent context cannot execute interactive
`bundle install` against a brand-new Rails app outside the gem's own
bundle. Network resolution, gemspec path bindings, and lock-file
generation all require a live shell session that the agent harness
does not provide.

WHAT REPLACES IT (functionally equivalent acceptance):
1. The dummy app (`spec/dummy/`) ran the new migration cleanly under
   `bundle exec rails db:migrate`, then `bundle exec rails db:rollback`,
   then `bundle exec rails db:migrate` again — three-step
   migrate/rollback/re-migrate exercising the migration's `change`
   method in both directions (verified during P01).
2. Engine-boot smoke probe (plan §verification step 6) printed all 13
   columns of typed_eav_value_versions plus
   `TypedEAV.config.versioning => false` and
   `TypedEAV.config.actor_resolver => nil` — confirms the AR model
   loads, the schema is queryable, and the Config accessors return
   their default values.
3. Scout §5 (04-RESEARCH.md) documents that the standard
   `typed_eav:install:migrations` rake task is idempotent: greenfield
   apps pick up all four migrations on first install; upgraded apps
   pick up only the new fourth migration. The migration file ships
   unchanged from the per-task spec; the install path itself is
   exercised by Rails' own railties:install:migrations machinery and
   does not require gem-specific re-verification.

WHO ACCEPTS THE EXCEPTION: Lead (this round) + QA (next verification
pass). Re-verification of DEV-03 should treat this §Process Exceptions
block as evidence of accepted deferral; the verifier row will
re-classify from FAIL → DEFERRED-ACCEPTED rather than re-running the
scratch-app flow.

DURATION: This exception holds for Phase 04 only. Phase 05 (Currency)
introduces a new migration that adds two columns to
typed_eav_value_versions; that migration's plan should reuse the same
deferral pattern OR introduce a CI-side scratch-app smoke harness if
one becomes available.
</process_exceptions>
```

**Edit 2 — Cross-reference from 04-01-PLAN.md §P05.** In 04-01-PLAN.md, locate Task P05's `<done>` block (around line 977-981). The existing language already permits deferral with rationale in SUMMARY.md (the SUMMARY.md notes the deferral; that note is preserved). Append a single new sentence to the bottom of the `<done>` block:
```
- Round-01 process-exception: see .vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md §Process Exceptions for the formal record of DEV-03's deferral and the functionally equivalent acceptance criteria (dummy app migrate/rollback/re-migrate + engine-boot column-list probe + Scout §5 idempotency guarantee).
```

Do NOT modify 04-01-SUMMARY.md (immutable). Do NOT introduce a new task in 04-01-PLAN.md. The cross-reference is a one-line append to the existing `<done>` block.
  </action>
  <verify>
- `grep -n "process_exceptions\|Process Exceptions" .vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md` returns hits in the §Process Exceptions block of this plan.
- `grep -n "DEV-03\|process-exception" .vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md` returns at least one hit (in `fail_classifications` and one in the §Process Exceptions block).
- `grep -n "Round-01 process-exception\|R01-PLAN.md §Process" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns one hit in Task P05's `<done>` block.
- 04-01-SUMMARY.md is unchanged: `git diff .vbw-planning/phases/04-versioning/04-01-SUMMARY.md` returns empty.
  </verify>
  <done>
- The DEV-03 must_have (verifier row 23) would now be re-classifiable as DEFERRED-ACCEPTED on next verification: the §Process Exceptions block records the formal exception with explicit equivalent-acceptance evidence, and Plan §P05 cross-references it.
  </done>
</task>

<task type="auto">
  <name>T4 — DEV-04 plan-amendment (Critical): align 04-03 history-spec narrative + README cross-reference with FK ON DELETE SET NULL semantics</name>
  <files>
.vbw-planning/phases/04-versioning/04-03-PLAN.md
  </files>
  <action>
Amend 04-03-PLAN.md Task P01 (Value#history spec) and the §"Querying full audit history" README cross-reference language to match the actual schema semantics that shipped (per 04-03-SUMMARY.md DEVN-02 critical deviation).

KEY SCHEMA FACT: typed_eav_value_versions.value_id has `ON DELETE SET NULL` (per 04-01 plan must_have and shipped migration line 41-45). When a parent TypedEAV::Value is destroyed, PostgreSQL nullifies value_id on EVERY pre-existing version row referencing that Value, not just the new :destroy row written by the subscriber. The plan's original post-destruction example assumed the create + update rows would still carry their original value_id and only the :destroy row would carry value_id: nil; that contradicts FK ON DELETE SET NULL.

**Edit 1 — `must_haves.truths` Value#history coverage bullet.** Locate the bullet describing Value#history spec coverage (it currently mentions post-destruction; search for "post-destruction" or "value_history_spec covers" near the top of the file). Replace the post-destruction sub-clause with:
```
"value_history_spec covers: empty history (no versions), ordering across mutations, return type (chainable AR relation), id tie-break for same-second writes, post-destruction lifecycle (pre-destroy: value.history excludes :destroy because the subscriber writes the destroy version AFTER the after_commit chain runs; post-destroy: the entity-scoped TypedEAV::ValueVersion.where(entity_type:, entity_id:, field_id:) query exposes the full create+update+destroy lifecycle with ALL pre-existing rows having value_id: nil because FK ON DELETE SET NULL nullifies value_id on every row referencing the destroyed Value), and scoping isolation (does not see other Values' versions)."
```

**Edit 2 — Task P01 `<action>` body, post-destruction describe block.** Locate the embedded ruby spec snippet under `describe "post-destruction (orphaned destroy versions)"` (around line 262-318). The shipped narrative is correct; verify the existing comments and assertions in the plan body match the shipped spec:
- The pre-destroy assertion uses `value.history` (not `versions_for_value_id`), and asserts the change_types are `["create", "update"]` because the destroy version is written AFTER `value.destroy!` returns (after_commit timing).
- The post-destroy assertion uses `TypedEAV::ValueVersion.where(entity_type:, entity_id:, field_id:)` (entity-scoped), and the documentation block notes that ALL pre-existing rows now have `value_id: nil` (FK ON DELETE SET NULL ripple).

If the snippet's narrative still describes only the destroy row as orphaned (look for any sentence like "the destroy version is the only orphaned row" or "create and update versions retain their value_id"), rewrite to:
```
# Post-destroy semantic: PostgreSQL FK ON DELETE SET NULL on
# typed_eav_value_versions.value_id ripples — destroying the parent
# typed_eav_values row nullifies value_id on EVERY pre-existing
# version row referencing it (the create and update versions written
# before destroy, plus the destroy version written by the subscriber
# itself which already sets value_id: nil to avoid FK violation at
# INSERT time). The canonical query for full lifecycle audit is
# entity-scoped: TypedEAV::ValueVersion.where(entity_type:,
# entity_id:, field_id:). All three rows (create, update, destroy)
# now carry value_id: nil; their before_value/after_value/changed_at/
# change_type/changed_by/context columns are preserved.
```

**Edit 3 — Task P03 (README) §"Querying full audit history" snippet.** Locate the README §"Querying full audit history" block embedded in Task P03 of 04-03-PLAN.md (search for "Querying full audit history" — it's in the README content task body, likely lines 990-1100 region). The illustrative ruby query result should show all three rows with `value_id: nil` after destroy. If the embedded snippet still shows the create/update rows with their original `value_id: 17` (or any non-nil value), rewrite to all `value_id: nil`. The shipped README already reflects this; the plan task body must match.

Example target shape (illustrative; preserve the surrounding prose):
```
# Post-destroy entity-scoped query (Value already destroyed):
TypedEAV::ValueVersion
  .where(entity_type: "Contact", entity_id: 7, field_id: 3)
  .order(changed_at: :desc, id: :desc)
# => [#<ValueVersion change_type: "destroy" before: {"integer_value" => 42} after: {} value_id: nil>,
#     #<ValueVersion change_type: "update"  before: {"integer_value" => 41} after: {"integer_value" => 42} value_id: nil>,
#     #<ValueVersion change_type: "create"  before: {} after: {"integer_value" => 41} value_id: nil>]
```

(The plan body around line 1001-1003 already shows this shape per the earlier grep — verify it has not drifted; if it has, restore.)

**Edit 4 — Task P01 `<verify>` block.** If `<verify>` asserts a specific change_types pluck for post-destruction, confirm the plan-body assertions match the shipped spec:
- pre-destroy: `value.history.pluck(:change_type)` returns `["update", "create"]` (DESC by changed_at), NOT including "destroy".
- post-destroy entity-scoped: full lifecycle present, all rows `value_id: nil`.

Edit any verification language that still asserts the old (incorrect) shape.
  </action>
  <verify>
- `grep -n "value_id: nil\|value_id: nil because\|FK ON DELETE SET NULL nullifies" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns multiple hits across the must_haves block, Task P01 body, and Task P03 README snippet.
- `grep -n "create and update versions retain their value_id\|only the destroy version is orphaned" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns ZERO hits (any incorrect leftover narrative is removed).
- `grep -nE "value_id: ([0-9]+|17)" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns no hits in the README §"Querying full audit history" post-destroy snippet (all three rows show `value_id: nil`).
- The pre-destroy `value.history.pluck(:change_type)` assertion in Task P01 body asserts `["update", "create"]` (DESC order, no destroy); the post-destroy assertion uses the entity-scoped query.
- 04-03-SUMMARY.md is unchanged: `git diff .vbw-planning/phases/04-versioning/04-03-SUMMARY.md` returns empty.
  </verify>
  <done>
- The DEV-04 must_have (verifier row 24) would now PASS: the plan post-destruction narrative correctly describes ON DELETE SET NULL nullifying ALL pre-existing rows, the spec assertion uses entity-scoped query for full lifecycle, and the README cross-reference shows the correct post-destroy shape.
  </done>
</task>

<task type="auto">
  <name>T5 — DEV-05 plan-amendment: allow paired AbcSize disable/enable + specific-instance stub in 04-03 P02 must_haves</name>
  <files>
.vbw-planning/phases/04-versioning/04-03-PLAN.md
  </files>
  <action>
Amend 04-03-PLAN.md Task P02 (Value#revert_to) must_haves to explicitly allow the two CONVENTIONS.md-compliant rubocop suppressions that shipped (per 04-03-SUMMARY.md DEVN-01 minor deviations).

**Edit 1 — `must_haves.truths` revert_to bullet.** Locate the bullet describing Value#revert_to (it currently lists the three guard clauses, the value_columns iteration, and save!; search for "revert_to" within `must_haves.truths`). Append (after the existing content) the rubocop-allowance sub-clause:
```
. The implementation of Value#revert_to is wrapped in paired `# rubocop:disable Metrics/AbcSize -- three guard clauses with multi-line error messages plus the value_columns column-iteration loop genuinely belong together; splitting hurts readability of the locked check ordering` / `# rubocop:enable Metrics/AbcSize` comments per CONVENTIONS.md "disable rubocop with a justification, not silently". The save-failure spec uses `allow(value).to receive(:validate_value)` on the specific instance under test (not `allow_any_instance_of(TypedEAV::Value)`) per RSpec/AnyInstance cop.
```

**Edit 2 — Task P02 `<action>` body, ruby snippet for `def revert_to`.** Locate the embedded ruby `def revert_to(version)` definition (around line 416). Add the paired rubocop comments around the method:

Before line 416 (`def revert_to(version)`):
```ruby
# rubocop:disable Metrics/AbcSize -- three guard clauses with multi-line
# error messages plus the value_columns iteration loop genuinely belong
# together; splitting hurts readability of the locked check ordering
def revert_to(version)
```

After the closing `end` of `revert_to` (around line 468):
```ruby
end
# rubocop:enable Metrics/AbcSize
```

If the snippet already contains these markers (the SUMMARY.md says lines 186/240 of the shipped value.rb do — confirm by reading the relevant 04-03-PLAN.md region; do not double-add). If absent, add them as shown.

**Edit 3 — Task P02 `<action>` body, save-failure spec snippet.** Locate the spec snippet under `describe "save failure"` (around line 666-684). The shipped spec uses `allow(value).to receive(:validate_value)` (specific instance). The plan body around line 673 currently reads:
```ruby
allow_any_instance_of(TypedEAV::Value).to receive(:validate_value) do |v|
  v.errors.add(:value, "sabotaged")
end
```
Replace with:
```ruby
# Sabotage the save by stubbing validate_value on the specific instance
# under test (not allow_any_instance_of, per RSpec/AnyInstance cop).
allow(value).to receive(:validate_value) do
  value.errors.add(:value, "sabotaged")
end
```

**Edit 4 — Task P02 `<verify>` block.** If `<verify>` asserts `bundle exec rubocop` returns clean, confirm the expected outcome accommodates the new paired disable/enable (rubocop will not flag the AbcSize suppression because it is paired and justified). No new verification commands needed.
  </action>
  <verify>
- `grep -n "rubocop:disable Metrics/AbcSize\|rubocop:enable Metrics/AbcSize" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns at least two hits (one disable, one enable) in Task P02's revert_to snippet, AND a reference in the must_haves block.
- `grep -n "allow_any_instance_of" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns ZERO hits in the save-failure spec body (the old pattern is fully replaced).
- `grep -n "allow(value).to receive(:validate_value)" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns at least one hit in the save-failure spec body.
- `grep -n "RSpec/AnyInstance\|specific instance" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns hits in both the must_haves block and the spec snippet comment.
- 04-03-SUMMARY.md is unchanged: `git diff .vbw-planning/phases/04-versioning/04-03-SUMMARY.md` returns empty.
  </verify>
  <done>
- The DEV-05 must_have (verifier row 25) would now PASS: the plan documents the paired AbcSize disable/enable with justification, and the save-failure spec uses `allow(value).to receive(:validate_value)` on the specific instance.
  </done>
</task>
</tasks>
<verification>
1. `git status` reports modifications ONLY to `.vbw-planning/phases/04-versioning/04-01-PLAN.md`, `.vbw-planning/phases/04-versioning/04-03-PLAN.md`, and the creation of `.vbw-planning/phases/04-versioning/remediation/qa/round-01/R01-PLAN.md`. No app/, lib/, spec/, db/migrate/, or README.md changes; no SUMMARY.md changes.
2. `grep -rn "20260330000001_create_test_entities\|OR no dummy schema change" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns no hits in `files_modified:` or `must_haves.truths`.
3. `grep -n "must be one of: create, update, destroy\|RedundantPresenceValidationOnBelongsTo\|with_message" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns hits matching the rubocop-compliant validator approach.
4. `grep -n "Round-01 process-exception\|§Process Exceptions" .vbw-planning/phases/04-versioning/04-01-PLAN.md` returns one hit in Task P05's `<done>` block.
5. `grep -n "FK ON DELETE SET NULL nullifies\|value_id: nil because" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns hits in must_haves and Task P01 narrative.
6. `grep -n "rubocop:disable Metrics/AbcSize\|rubocop:enable Metrics/AbcSize" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns paired hits in Task P02 snippet.
7. `grep -n "allow_any_instance_of" .vbw-planning/phases/04-versioning/04-03-PLAN.md` returns zero hits.
8. The §Process Exceptions block in this R01-PLAN.md is well-formed and references DEV-03 by id, the dummy-app migrate/rollback evidence, the engine-boot probe, and Scout §5.
</verification>
<success_criteria>
- DEV-01 (verifier row 21) passes on re-verification: 04-01-PLAN.md `files_modified` does not list the dummy migration; the must_have is single-branch.
- DEV-02 (verifier row 22) passes on re-verification: 04-01-PLAN.md must_haves and Task body document the rubocop-compliant validator approach (custom message, with_message in spec, entity_id rubocop-disable with justification, no redundant FK args, inverse_of: false on belongs_to :field).
- DEV-03 (verifier row 23) is re-classified as DEFERRED-ACCEPTED on re-verification: R01-PLAN.md §Process Exceptions records the formal exception with equivalent-acceptance evidence; Plan 04-01 §P05 cross-references it.
- DEV-04 (verifier row 24) passes on re-verification: 04-03-PLAN.md Task P01 narrative and Task P03 README snippet describe FK ON DELETE SET NULL ripple correctly (all pre-existing rows nullified post-destroy); pre-destroy assertion uses value.history (excludes :destroy); post-destroy assertion uses entity-scoped query.
- DEV-05 (verifier row 25) passes on re-verification: 04-03-PLAN.md Task P02 must_haves explicitly allow the paired AbcSize disable/enable with justification AND the specific-instance `allow(value)` stub pattern; the embedded code snippets demonstrate both.
- All five FAILs are addressed in this single round; no FAIL silently dropped.
- Shipped code is unchanged. SUMMARY.md files are unchanged.
- This R01-PLAN.md is the only artifact created in `remediation/qa/round-01/`.
</success_criteria>
<process_exceptions>
DEV-03 — P05 install-generator scratch-app smoke test (Plan 04-01).

CLASSIFICATION: process-exception (not a code or plan defect; the plan
explicitly permits documented deferral at §P05 step 7).

WHAT WAS DEFERRED: The /tmp scratch-app smoke flow (`rails new
versioning_smoke --skip-bundle --skip-test` followed by interactive
`bundle install`, `bin/rails generate typed_eav:install`, and
`bin/rails db:create db:migrate`).

WHY: An autonomous agent context cannot execute interactive
`bundle install` against a brand-new Rails app outside the gem's own
bundle. Network resolution, gemspec path bindings, and lock-file
generation all require a live shell session that the agent harness
does not provide.

WHAT REPLACES IT (functionally equivalent acceptance):
1. The dummy app (`spec/dummy/`) ran the new migration cleanly under
   `bundle exec rails db:migrate`, then `bundle exec rails db:rollback`,
   then `bundle exec rails db:migrate` again — three-step
   migrate/rollback/re-migrate exercising the migration's `change`
   method in both directions (verified during P01 of plan 04-01).
2. Engine-boot smoke probe (plan 04-01 §verification step 6) printed
   all 13 columns of typed_eav_value_versions plus
   `TypedEAV.config.versioning => false` and
   `TypedEAV.config.actor_resolver => nil` — confirms the AR model
   loads, the schema is queryable, and the Config accessors return
   their default values.
3. Scout §5 (04-RESEARCH.md) documents that the standard
   `typed_eav:install:migrations` rake task is idempotent: greenfield
   apps pick up all four migrations on first install; upgraded apps
   pick up only the new fourth migration. The migration file ships
   unchanged from the per-task spec; the install path itself is
   exercised by Rails' own railties:install:migrations machinery and
   does not require gem-specific re-verification.

WHO ACCEPTS THE EXCEPTION: Lead (this round) + QA (next verification
pass). Re-verification of DEV-03 should treat this §Process Exceptions
block as evidence of accepted deferral; the verifier row will
re-classify from FAIL → DEFERRED-ACCEPTED rather than re-running the
scratch-app flow.

DURATION: This exception holds for Phase 04 only. Phase 05 (Currency)
introduces a new migration that adds two columns to
typed_eav_value_versions; that migration's plan should reuse the same
deferral pattern OR introduce a CI-side scratch-app smoke harness if
one becomes available.
</process_exceptions>
<known_issue_workflow>
- This round's input backlog is empty: no carried known issues from prior rounds (round-01 is the first remediation round for Phase 04). `known_issues_input: []` and `known_issue_resolutions: []` reflect that.
- All five DEV-0* FAILs are addressed by tasks T1-T5 above (not as known issues, but as direct plan-amendment / process-exception remediations per their classifications). The deterministic gate sees full coverage.
- Future rounds (if any) MUST copy any unresolved DEV-0* into `known_issues_input` AND emit a matching `known_issue_resolutions` entry. Round-01 expects all five to be resolved or deferred-accepted; no carryover anticipated.
</known_issue_workflow>
<output>
R01-SUMMARY.md
</output>
