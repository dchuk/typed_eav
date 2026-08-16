---
phase: 01
tier: standard
result: PARTIAL
passed: 30
failed: 11
total: 41
date: 2026-04-29
verified_at_commit: b8fbc91297a28a4af197ab23a4d04047449f15e1
writer: write-verification.sh
plans_verified:
  - 01-01
  - 01-02
  - 01-03
  - 01-04
  - 01-05
  - 01-06
  - 01-07
---

## Must-Have Checks

| # | ID | Truth/Condition | Status | Evidence |
|---|-----|-----------------|--------|----------|
| 1 | DEVIATION-01-01-A | DEVN-01-A (plan 01-01): Migration class name was corrected from plan-specified AddParentScopeToTypedEavPartitions to AddParentScopeToTypedEAVPartitions. Plan task 1 explicitly prescribed the class name 'AddParentScopeToTypedEavPartitions'; actual class is 'AddParentScopeToTypedEAVPartitions'. | FAIL | Plan 01-01-PLAN.md task 1: 'Create the migration with class name AddParentScopeToTypedEavPartitions'. Actual file line 1: 'class AddParentScopeToTypedEAVPartitions'. Deviation documented in 01-01-SUMMARY.md DEVN-01. |
| 2 | DEVIATION-01-01-B | DEVN-01-B (plan 01-01): Commit type changed from plan-literal 'db(migration)' to 'feat(migration)'. Plan must_haves specified 'Single commit: db(migration): add parent_scope to typed_eav fields and sections partition tuple'; actual commit is 5ff7c30 with type 'feat(migration)'. | FAIL | Plan 01-01-PLAN.md must_haves: 'Single commit: db(migration): add parent_scope...'. git log shows: 'feat(migration): add parent_scope to typed_eav fields and sections partition tuple' (5ff7c30). Deviation documented in 01-01-SUMMARY.md DEVN-01. |
| 3 | DEVIATION-01-02 | DEVN-05 (plan 01-02): 8 examples in spec/lib/typed_eav/scoping_spec.rb failed after commit 52014a3. The plan acknowledged these as anticipated breakage owned by plan 06, but they represent a deviation from a green suite state after this plan's commit. Per deviation protocol, declared deviations are FAIL checks. | FAIL | 01-02-SUMMARY.md pre_existing_issues lists 8 spec failures (assertion-shape mismatches and ArgumentError raises) from scoping_spec.rb. Plan 02 explicitly anticipated this breakage. Plan 06 (commit e5e78a4) subsequently resolved all 8 failures — final suite: 440 examples, 0 failures. |
| 4 | DEVIATION-01-03 | DEVN-01 (plan 01-03): Tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) were implemented as a single coordinated edit rather than as separate sequential edits as implied by the plan's task structure. Plan had distinct task blocks for each of the three file edits. | FAIL | 01-03-SUMMARY.md DEVN-01: 'tasks 1-3 implemented as a single coordinated edit per the plan's explicit Single commit, one file directive in task 4.' Plan tasks 1-3 each specify separate <action> blocks for separate line edits; these were consolidated. Deviation documented in SUMMARY frontmatter. |
| 5 | DEVIATION-01-04 | DEVN-01 (plan 01-04): Tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant for Section) were implemented as a single coordinated edit, parallel to the plan 01-03 pattern. | FAIL | 01-04-SUMMARY.md DEVN-01: 'tasks 1-3 implemented as a single coordinated edit per the plan's explicit Single commit, one file directive in task 4. Each task's done criterion was independently verified before commit.' Deviation documented in SUMMARY frontmatter. |
| 6 | DEVIATION-01-05-A | DEVN-01 (plan 01-05): All 5 tasks were coordinated into a single atomic commit per the plan's explicit 'Single commit' directive in task 5, rather than being implemented as sequential edits with independent staging. | FAIL | 01-05-SUMMARY.md DEVN-01: 'all 5 tasks coordinated into a single atomic commit per the plan's explicit Single commit directive in task 5.' Deviation documented in SUMMARY frontmatter. |
| 7 | DEVIATION-01-05-B | DEVN-05 (plan 01-05): 8 examples in spec/lib/typed_eav/scoping_spec.rb continued to fail after commit c628372. These were pre-existing anticipated breakage from plan 02, carried through plan 05 and documented as owned by plan 06. | FAIL | 01-05-SUMMARY.md DEVN-05 and pre_existing_issues: 8 scoping_spec failures continued after this commit. Deviation documented in SUMMARY frontmatter. These failures were resolved by plan 06 (commit e5e78a4), final suite: 440 examples, 0 failures. |
| 8 | DEVIATION-01-06-A | DEVN-01 (plan 01-06): All 5 tasks consolidated into a single atomic commit per the plan's explicit 'Single commit. Seven files modified.' directive in task 5. | FAIL | 01-06-SUMMARY.md DEVN-01: 'all 5 tasks consolidated into a single atomic commit per the plan's explicit Single commit. Seven files modified. directive in task 5.' Deviation documented in SUMMARY frontmatter. |
| 9 | DEVIATION-01-06-B | DEVN-02 (plan 01-06): Plan task 3 prescribed assertion 'expect(fields).to contain_exactly(project_scope_only, project_global)' for parent_scope: nil kwarg inside with_scope block. This contradicts production semantics; test was rewritten to assert actual behavior (contain_exactly(project_global)) with explanatory comment. No production code was touched. | FAIL | 01-06-SUMMARY.md DEVN-02: plan prescribed contain_exactly(project_scope_only, project_global) but actual resolve_scope gates ambient off whenever EITHER kwarg is explicit — passing parent_scope: nil collapses to globals only. Test rewritten to assert contain_exactly(project_global). Confirmed in spec/lib/typed_eav/scoping_spec.rb. |
| 10 | DEVIATION-01-07-A | DEVN-02 (plan 01-07): Commit b8fbc91 includes Gemfile.lock as a 4th source file in addition to the plan-prescribed README.md, CHANGELOG.md, and lib/typed_eav/version.rb. The plan did not include Gemfile.lock in its files_modified list. | FAIL | 01-07-SUMMARY.md DEVN-02: 'commit includes Gemfile.lock as a 4th source file'. Plan 01-07 files_modified lists only README.md, CHANGELOG.md, lib/typed_eav/version.rb. git show b8fbc91 --stat shows 4 source files (CHANGELOG.md, Gemfile.lock, README.md, lib/typed_eav/version.rb). Deviation documented in SUMMARY frontmatter. |
| 11 | DEVIATION-01-07-B | DEVN-05 (plan 01-07): rubocop reports 5 Layout/HashAlignment offenses in typed_eav.gemspec lines 22-26. Verified pre-existing before this plan; no file in this plan touched typed_eav.gemspec. Flagged for separate housekeeping. | FAIL | 01-07-SUMMARY.md DEVN-05: '5 Layout/HashAlignment offenses in typed_eav.gemspec lines 22-26. Verified pre-existing at HEAD e5e78a4 before plan 01-07 started.' bundle exec rubocop typed_eav.gemspec confirms: 1 file inspected, 5 offenses detected at lines 22-26. Deviation documented in SUMMARY frontmatter. |
| 12 | MH-01 | parent_scope column exists on typed_eav_fields and typed_eav_sections, both nullable strings | PASS | 01-01-SUMMARY.md ac_results: psql information_schema.columns confirms parent_scope &#124; character varying &#124; YES on both tables. Migration file add_column :typed_eav_fields, :parent_scope confirmed. |
| 13 | MH-02 | All 5 original scope indexes dropped and new triple-partial unique indexes created (3 per table: _scoped_full, _scoped_only, _global) plus refreshed lookup indexes | PASS | 01-01-SUMMARY.md ac_results: pg_indexes shows all six new partial unique indexes with correct WHERE predicates. idx_te_fields_lookup and idx_te_sections_lookup both exist with parent_scope in the column tuple. |
| 14 | MH-03 | Migration uses disable_ddl_transaction! and algorithm: :concurrently; uses up/down (not change) for reversibility; idempotent guards present | PASS | db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb line 8: disable_ddl_transaction!. grep confirms algorithm: :concurrently on all index ops and if_exists:/if_not_exists: guards confirmed. |
| 15 | MH-04 | TypedEAV.current_scope returns a [scope, parent_scope] two-element Array (never a bare scalar) | PASS | 01-02-SUMMARY.md ac_results: lib/typed_eav.rb:70-100 verified. with_scope('t1') { current_scope } => ['t1', nil]; with_scope(['t1','ps1']) { current_scope } => ['t1','ps1']. |
| 16 | MH-05 | Config.scope_resolver contract strictly enforced: non-nil non-2-Array returns raise ArgumentError with .inspect in message | PASS | lib/typed_eav.rb:83-92: raise ArgumentError unless raw.is_a?(Array) && raw.size == 2. Message includes Got: #{raw.inspect}. scoping_spec 44 examples, 0 failures confirms resolver contract coverage. |
| 17 | MH-06 | Config::DEFAULT_SCOPE_RESOLVER returns [ActsAsTenant.current_tenant, nil] tuple (not scalar) | PASS | lib/typed_eav/config.rb:38-42: returns nil unless defined?(::ActsAsTenant); else [::ActsAsTenant.current_tenant, nil]. 01-02-SUMMARY.md ac_results verified. |
| 18 | MH-07 | Field::Base.for_entity accepts parent_scope: kwarg; AR uniqueness validator uses scope: %i[entity_type scope parent_scope]; validate_parent_scope_invariant rejects orphan parents | PASS | app/models/typed_eav/field/base.rb line 35: validates :name, uniqueness: { scope: %i[entity_type scope parent_scope] }. Line 41: validate :validate_parent_scope_invariant. Line 62: scope :for_entity lambda accepts parent_scope:. |
| 19 | MH-08 | Section.for_entity accepts parent_scope: kwarg; AR uniqueness on :code uses %i[entity_type scope parent_scope]; validate_parent_scope_invariant present and symmetric to Field::Base | PASS | app/models/typed_eav/section.rb line 15: validate :validate_parent_scope_invariant. Line 25: for_entity lambda accepts parent_scope:. Line 13: uniqueness scope includes parent_scope. spec/models/typed_eav/section_and_option_spec.rb: 12 examples, 0 failures. |
| 20 | MH-09 | has_typed_eav macro accepts parent_scope_method: kwarg; macro-time guard rejects parent_scope_method: without scope_method: | PASS | lib/typed_eav/has_typed_eav.rb:96 declares kwarg; lines 102-108: raises ArgumentError if parent_scope_method && !scope_method. 01-05-SUMMARY.md ac_results: Live REPL confirms ArgumentError raised. |
| 21 | MH-10 | resolve_scope returns [scope, parent_scope] tuple or ALL_SCOPES; where_typed_eav and with_field accept parent_scope: kwarg defaulting to UNSET_SCOPE | PASS | lib/typed_eav/has_typed_eav.rb:177: def where_typed_eav(*filters, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE). Line 280: with_field signature. Line 330: resolve_scope. 01-05-SUMMARY.md ac_results confirmed. |
| 22 | MH-11 | definitions_by_name three-way precedence: sort_by [scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1] preserves most-specific-wins via index_by last-wins | PASS | lib/typed_eav/has_typed_eav.rb:57-61. 01-05-SUMMARY.md: Live REPL confirms forward/reverse input both surface most-specific row. spec/regressions/review_round_3_collision_spec.rb 0 failures. |
| 23 | MH-12 | Value#validate_field_scope_matches_entity extended with parent_scope axis: field.parent_scope mismatch => errors.add(:field, :invalid) | PASS | app/models/typed_eav/value.rb:147-176. Line 166: return if field.parent_scope.blank?. Lines 168-171: entity.typed_eav_parent_scope check. spec/models/typed_eav/value_spec.rb: 0 failures. |
| 24 | MH-13 | scoping_spec assertions updated to expect [scope, parent_scope] tuples; resolver-callable contract violation coverage added; all 8 anticipated failures from plans 02/05 resolved | PASS | bundle exec rspec spec/lib/typed_eav/scoping_spec.rb => 44 examples, 0 failures. File contains with_scope(%w[t1 w1]) and tuple assertions. All 8 pre-existing scoping_spec failures resolved. |
| 25 | MH-14 | review_round_4_parent_scope_spec.rb created with 14 examples covering orphan-parent (Field+Section) and cross-axis Value rejection | PASS | spec/regressions/review_round_4_parent_scope_spec.rb exists, 156 lines. bundle exec rspec spec/regressions/ => 81 examples, 0 failures. |
| 26 | MH-15 | Full spec suite green after plan 06: 440 examples, 0 failures (52 new examples added from 388 base with 8 anticipated failures) | PASS | bundle exec rspec => 440 examples, 0 failures (verified in QA run). Suite grew from 388+8-failures to 440+0-failures. |
| 27 | MH-16 | README gains Two-level scoping subsection covering parent_scope_method:, tuple with_scope, breaking resolver contract, and Migrating from v0.1.x section | PASS | README.md contains parent_scope_method at lines 400 and 410. File grew +93/-5 lines. Two-level scoping subsection, migration guide, and orphan-parent invariant sections confirmed. |
| 28 | MH-17 | lib/typed_eav/version.rb bumped from 0.1.0 to 0.2.0; CHANGELOG [0.2.0] section present with BREAKING marker and Migration Steps | PASS | lib/typed_eav/version.rb line 4: VERSION = "0.2.0". CHANGELOG.md line 8: ## [0.2.0] - 2026-04-29. BREAKING marker in Changed section confirmed. |

## Artifact Checks

| # | ID | Artifact | Status | Evidence |
|---|-----|----------|--------|----------|
| 1 | ART-01 | db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb exists and contains disable_ddl_transaction!, add_column :typed_eav_fields :parent_scope, algorithm: :concurrently | PASS | File exists. Line 8: disable_ddl_transaction!. add_column :typed_eav_fields, :parent_scope present. Multiple algorithm: :concurrently occurrences confirmed by grep. |
| 2 | ART-02 | spec/regressions/review_round_4_parent_scope_spec.rb created (new file, 156 lines, 14 examples) | PASS | File exists at spec/regressions/review_round_4_parent_scope_spec.rb, 156 lines confirmed. bundle exec rspec spec/regressions/ confirms 81 examples, 0 failures including round_4 examples. |
| 3 | ART-03 | CHANGELOG.md contains ## [0.2.0] section with BREAKING tag | PASS | CHANGELOG.md line 8: ## [0.2.0] - 2026-04-29. Line 28: **BREAKING** Config.scope_resolver callables MUST return a 2-element Array. +80 lines added. |

## Key Link Checks

| # | ID | Link | Status | Evidence |
|---|-----|------|--------|----------|
| 1 | KL-01 | Migration follows idx_te_* prefix convention and paired-partial-index pattern from initial migration | PASS | New migration uses idx_te_* prefix on all index names. Follows paired-partial-index split convention from db/migrate/20260330000000_create_typed_eav_tables.rb, extended to (scope, parent_scope) triple via Option B. |
| 2 | KL-02 | CHANGELOG.md Migration steps cross-reference README migration section; version 0.2.0 matches CHANGELOG heading | PASS | CHANGELOG.md references README migration section. lib/typed_eav/version.rb VERSION = "0.2.0" matches CHANGELOG ## [0.2.0] - 2026-04-29 heading. |
| 3 | KL-03 | Field::Base validate_parent_scope_invariant is byte-for-byte symmetric to Section#validate_parent_scope_invariant (inline duplication per CONTEXT.md, no Scopable concern) | PASS | 01-03-SUMMARY.md and 01-04-SUMMARY.md confirm: 'validate_parent_scope_invariant body is byte-for-byte identical between Field::Base and Section'. CONTEXT.md decision: inline-duplicate, defer Scopable extraction. |

## Anti-Pattern Scan

| # | ID | Pattern | Status | Evidence |
|---|-----|---------|--------|----------|
| 1 | ANTI-01 | No silent scalar coercion of custom resolver returns (the rejected BC-shim alternative) | PASS | lib/typed_eav.rb:87-92: raises ArgumentError before any normalization for non-nil non-2-Array resolver returns. CONTEXT.md explicitly rejects the auto-coerce shim. scoping_spec resolver-contract-violation block confirms 3 examples all raise. |
| 2 | ANTI-02 | No nulls_not_distinct: true option used (PG 15+ only, incompatible with PG 12-14 deployments) | PASS | Migration uses the paired-partial split (Option B) instead of NULLS NOT DISTINCT. No nulls_not_distinct in migration file. PLAN.md explicitly documents why Option B chosen over Option A. |
| 3 | ANTI-03 | No Scopable concern extracted prematurely (CONTEXT.md: defer until third caller or divergence) | PASS | No Scopable module exists in lib/ or app/. Field::Base and Section each have their own implementations. CONTEXT.md decision documented: inline-duplicate, no extraction this phase. |

## Convention Compliance

| # | ID | Convention | Status | Evidence |
|---|-----|------------|--------|----------|
| 1 | CONV-01 | Index names use idx_te_* prefix (<=63 bytes Postgres limit) | PASS | All new indexes use idx_te_* prefix. Longest names: idx_te_sections_uniq_scoped_full (32b), idx_te_sections_uniq_scoped_only (32b). All well under 63-byte limit confirmed in 01-01-SUMMARY.md. |
| 2 | CONV-02 | Commit format: type(scope): description — conventional commits pattern honored across all 7 plans | PASS | git log shows: feat(migration), refactor(scope), feat(field), feat(section), feat(scope), test(scope), docs(release). All use valid types per project CONVENTIONS.md commit types list. |
| 3 | CONV-03 | rubocop:disable comments include justification text per CONVENTIONS.md pattern (paired disable/enable with '--' rationale) | PASS | app/models/typed_eav/value.rb line 146: # rubocop:disable Metrics/AbcSize -- two axis-checks (scope + parent_scope) with respond_to? + match guards belong in one validator. Follows the paired disable/enable with '--' justification pattern. |
| 4 | CONV-04 | frozen_string_literal magic comment convention honored in production Ruby files | PASS | rubocop on modified production files reports no offenses (01-03-SUMMARY.md: rubocop app/models/typed_eav/field/base.rb -- 1 file, no offenses; 01-04-SUMMARY.md: rubocop app/models/typed_eav/section.rb -- 1 file, no offenses). |

## Pre-existing Issues

| Test | File | Error |
|------|------|-------|
| rubocop Layout/HashAlignment (offense 1) | typed_eav.gemspec:22 | Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec. |
| rubocop Layout/HashAlignment (offense 2) | typed_eav.gemspec:23 | Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec. |
| rubocop Layout/HashAlignment (offense 3) | typed_eav.gemspec:24 | Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec. |
| rubocop Layout/HashAlignment (offense 4) | typed_eav.gemspec:25 | Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec. |
| rubocop Layout/HashAlignment (offense 5) | typed_eav.gemspec:26 | Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec. |

## Summary

**Tier:** standard
**Result:** PARTIAL
**Passed:** 30/41
**Failed:** DEVIATION-01-01-A, DEVIATION-01-01-B, DEVIATION-01-02, DEVIATION-01-03, DEVIATION-01-04, DEVIATION-01-05-A, DEVIATION-01-05-B, DEVIATION-01-06-A, DEVIATION-01-06-B, DEVIATION-01-07-A, DEVIATION-01-07-B
