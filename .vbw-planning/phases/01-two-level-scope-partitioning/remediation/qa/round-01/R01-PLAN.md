---
phase: 1
round: 1
plan: R01
title: "QA remediation: plan-amendment for tracked deviations"
type: remediation
autonomous: true
effort_override: balanced
skills_used: []
files_modified:
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md
  - .vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md
forbidden_commands:
  - "scripts/bump-version.sh"
  - "git push"
fail_classifications:
  - {id: "DEVIATION-01-01-A", type: "plan-amendment", source_plan: "01-01-PLAN.md", rationale: "Migration class name AddParentScopeToTypedEavPartitions in plan task 1 fails Rails String#constantize at load time because lib/typed_eav.rb registers EAV as an inflector acronym. The actual class name AddParentScopeToTypedEAVPartitions is the only spelling that loads. Plan was authored before researcher confirmed the inflector registration; amend plan to specify the acronym-aware class name with rationale."}
  - {id: "DEVIATION-01-01-B", type: "plan-amendment", source_plan: "01-01-PLAN.md", rationale: "Plan must_haves and task 5 prescribed commit type 'db(migration):'. The project's PostToolUse commit-format hook enforces feat|fix|test|refactor|perf|docs|style|chore as the only accepted type tokens — 'db' is rejected. Dev correctly used feat(migration). Amend plan to specify feat(migration) and cite the commit hook constraint."}
  - {id: "DEVIATION-01-02", type: "plan-amendment", source_plan: "01-02-PLAN.md", rationale: "8 scoping_spec failures after commit 52014a3 were explicitly anticipated by the plan: verify gate documents 'Many tests will FAIL at this point... that is EXPECTED — those failures get fixed in plan 06.' Plan 06 (commit e5e78a4) resolved all 8. SUMMARY's pre_existing_issues block was over-conservative reporting; the plan body already declared this as expected. Amend plan to clarify these are anticipated cross-plan handoffs to 01-06, not deviations from this plan's intent."}
  - {id: "DEVIATION-01-03", type: "plan-amendment", source_plan: "01-03-PLAN.md", rationale: "Plan task 4 explicitly directed 'Single commit. One file changed.' Tasks 1-3 each modify the same small validations/scopes block in app/models/typed_eav/field/base.rb; splitting them would require three sequential commits to the same hunk neighborhood, contradicting the plan's stated commit shape. Dev followed the directive. Amend plan to clarify that the single-commit consolidation is the prescribed execution model, not a deviation."}
  - {id: "DEVIATION-01-04", type: "plan-amendment", source_plan: "01-04-PLAN.md", rationale: "Same as 01-03: plan task 4 explicitly directed 'Single commit, one file' for app/models/typed_eav/section.rb. Tasks 1-3 modify adjacent regions of the same file; splitting them contradicts the plan's commit shape. Dev followed the directive. Amend plan to clarify the single-commit consolidation is prescribed."}
  - {id: "DEVIATION-01-05-A", type: "plan-amendment", source_plan: "01-05-PLAN.md", rationale: "Plan task 5 explicitly directed 'Single commit' for the four-file integration commit (has_typed_eav.rb, value.rb, test_models.rb, create_test_entities.rb). Tasks 1-4 are tightly interdependent (macro change, resolver change, query path change, Value validator change) and the integration is meaningful only in combination. Dev followed the single-commit directive. Amend plan to clarify the consolidation is prescribed."}
  - {id: "DEVIATION-01-05-B", type: "plan-amendment", source_plan: "01-05-PLAN.md", rationale: "8 scoping_spec failures continued after commit c628372. These were already documented in 01-02-SUMMARY's pre_existing_issues as anticipated breakage owned by plan 06. Plan 05's verify gate explicitly stated 'pre-existing assertion-mismatch failures from plan 02 are still there (unchanged), but no NEW failures are introduced.' Plan 06 (commit e5e78a4) resolved all 8. Amend plan to clarify the carryover is anticipated, not a deviation from plan 05's intent."}
  - {id: "DEVIATION-01-06-A", type: "plan-amendment", source_plan: "01-06-PLAN.md", rationale: "Plan task 5 explicitly directed 'Single commit. Seven files modified.' Tasks 1-4 spread across seven spec files, but each task's done criteria were independently verified via per-file rspec runs before staging. Dev followed the directive. Amend plan to clarify the single-commit consolidation is prescribed."}
  - {id: "DEVIATION-01-06-B", type: "plan-amendment", source_plan: "01-06-PLAN.md", rationale: "Plan task 3 prescribed assertion contain_exactly(project_scope_only, project_global) for Project.typed_eav_definitions(parent_scope: nil) inside with_scope(['tenant_a', 'w1']) block. This contradicts production semantics: resolve_scope (lib/typed_eav/has_typed_eav.rb:340) gates ambient resolution off whenever EITHER kwarg is passed explicitly — passing parent_scope: nil collapses to (scope: nil, parent_scope: nil) and returns globals only. Dev caught the planning error and rewrote the test to match actual resolve_scope behavior (contain_exactly(project_global)). No production code touched. Amend plan to reflect the corrected assertion and document the any-explicit-disables-ambient rule."}
  - {id: "DEVIATION-01-07-A", type: "plan-amendment", source_plan: "01-07-PLAN.md", rationale: "Commit b8fbc91 includes Gemfile.lock as a 4th source file. This is mechanical fallout from the version bump: Bundler auto-rewrites Gemfile.lock to match lib/typed_eav/version.rb on the next bundle exec invocation. Leaving the lock at 0.1.0 against a 0.2.0 version pin produces a self-inconsistent repo where every subsequent bundler call dirties a tracked file. The plan's files_modified list omitted Gemfile.lock as an oversight; including it is correct hygiene. Amend plan to add Gemfile.lock to expected files_modified with the Bundler-mechanical-rewrite rationale."}
  - {id: "DEVIATION-01-07-B", type: "process-exception", rationale: "5 rubocop Layout/HashAlignment offenses in typed_eav.gemspec lines 22-26 are pre-existing. Verified at HEAD e5e78a4 before plan 01-07 started: bundle exec rubocop typed_eav.gemspec reproduced the same 5 offenses on the unmodified file. No file in any phase 01 plan touched typed_eav.gemspec. ROADMAP already flags these for separate housekeeping along with the existing typed_eav-0.1.0.gem cleanup item. Genuinely non-fixable retroactively in this phase's scope; no PLAN.md edit warranted."}
known_issues_input:
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — plan 06 owns rewriting assertions to expect tuples"}'
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — pre-existing plan-02 leftover, plan 06 owns rewriting assertions to expect tuples"}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142) — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142); plan 06 owns updating resolver stubs"}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple) — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple); plan 06 owns updating resolver stubs"}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the Phase 1 strict contract requires a tuple — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the new Phase 1 strict contract requires a tuple — plan 06 owns updating resolver stubs"}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"rubocop","file":"typed_eav.gemspec:22-26","error":"Layout/HashAlignment: hash literal keys not aligned in metadata{} block (5 occurrences). Verified pre-existing at HEAD e5e78a4 before plan 01-07 started; no file in this plan touched typed_eav.gemspec."}'
  - '{"test":"rubocop Layout/HashAlignment (5 offenses)","file":"typed_eav.gemspec:22-26","error":"5 Layout/HashAlignment offenses in metadata{} block hash keys. Confirmed pre-existing: bundle exec rubocop typed_eav.gemspec reports 5 offenses at lines 22-26. No file in this phase touched typed_eav.gemspec. Flagged for housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 1)","file":"typed_eav.gemspec:22","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 2)","file":"typed_eav.gemspec:23","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 3)","file":"typed_eav.gemspec:24","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 4)","file":"typed_eav.gemspec:25","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 5)","file":"typed_eav.gemspec:26","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec."}'
known_issue_resolutions:
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — plan 06 owns rewriting assertions","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) rewrote this assertion to expect [\"42\", nil] tuple shape. Verified: full suite at 440 examples, 0 failures."}'
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Duplicate carryover from plan 05 SUMMARY of the same plan-02-anticipated leftover. Resolved by plan 06 (commit e5e78a4) — assertion now expects tuple shape. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — plan 06 owns rewriting assertions","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) rewrote the assertion to expect [\"inner\", nil] tuple. Verified: full suite at 440/0."}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Duplicate carryover from plan 05 SUMMARY of the same plan-02-anticipated leftover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — plan 06 owns rewriting assertions to expect tuples","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) rewrote assertion to expect [\"t1\", nil] tuple. Verified: full suite at 440/0."}'
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — pre-existing plan-02 leftover, plan 06 owns rewriting assertions to expect tuples","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — plan 06 owns rewriting assertions","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) rewrote AAT-bridge assertion to expect [\"99\", nil] tuple matching the new DEFAULT_SCOPE_RESOLVER contract. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142) — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) updated the resolver stub to return [\"value\", nil] tuple matching the new strict contract. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142); plan 06 owns updating resolver stubs","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple) — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) updated the resolver stub to return [ar_record, nil] tuple. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple); plan 06 owns updating resolver stubs","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the Phase 1 strict contract requires a tuple — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) updated the resolver stub to return a tuple per the new strict contract. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the new Phase 1 strict contract requires a tuple — plan 06 owns updating resolver stubs","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — plan 06 owns rewriting assertions","disposition":"resolved","rationale":"Plan 06 (commit e5e78a4) rewrote assertion to expect [\"from_block\", nil] tuple. Suite green at 440/0."}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — pre-existing plan-02 leftover","disposition":"resolved","rationale":"Duplicate carryover. Resolved by plan 06 (commit e5e78a4). Suite green at 440/0."}'
  - '{"test":"rubocop","file":"typed_eav.gemspec:22-26","error":"Layout/HashAlignment: hash literal keys not aligned in metadata{} block (5 occurrences). Verified pre-existing at HEAD e5e78a4 before plan 01-07 started; no file in this plan touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offenses verified at HEAD e5e78a4 (before phase 01 started). No file in any phase 01 plan touched typed_eav.gemspec. ROADMAP already flags these for separate housekeeping along with the typed_eav-0.1.0.gem cleanup. Out-of-scope for phase 01; no PLAN.md edit warranted."}'
  - '{"test":"rubocop Layout/HashAlignment (5 offenses)","file":"typed_eav.gemspec:22-26","error":"5 Layout/HashAlignment offenses in metadata{} block hash keys. Confirmed pre-existing: bundle exec rubocop typed_eav.gemspec reports 5 offenses at lines 22-26. No file in this phase touched typed_eav.gemspec. Flagged for housekeeping per ROADMAP.","disposition":"accepted-process-exception","rationale":"Aggregated form of the 5 individual line offenses; same pre-existing root cause. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 1)","file":"typed_eav.gemspec:22","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offense at typed_eav.gemspec:22. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 2)","file":"typed_eav.gemspec:23","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offense at typed_eav.gemspec:23. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 3)","file":"typed_eav.gemspec:24","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offense at typed_eav.gemspec:24. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 4)","file":"typed_eav.gemspec:25","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offense at typed_eav.gemspec:25. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
  - '{"test":"rubocop Layout/HashAlignment (offense 5)","file":"typed_eav.gemspec:26","error":"Layout/HashAlignment: Align the keys of a hash literal if they span more than one line. Pre-existing at HEAD e5e78a4 before plan 01-07; no phase file touched typed_eav.gemspec.","disposition":"accepted-process-exception","rationale":"Pre-existing rubocop offense at typed_eav.gemspec:26. Verified at HEAD e5e78a4. Out-of-scope housekeeping per ROADMAP."}'
must_haves:
  truths:
    - "Every plan-amendment FAIL has a corresponding rationale block appended to its source PLAN.md so future maintainers reading the plan see the deviation history without ghost-divergence between plan and shipped code"
    - "01-01-PLAN.md task 1 specifies AddParentScopeToTypedEAVPartitions (acronym-aware) and cites the lib/typed_eav.rb inflector acronym registration as the rationale"
    - "01-01-PLAN.md must_haves and task 5 specify feat(migration) commit type and cite the project commit-format hook constraint (feat|fix|test|refactor|perf|docs|style|chore only)"
    - "01-02-PLAN.md notes that the 8 anticipated scoping_spec failures it produces are an explicit cross-plan handoff to 01-06 (resolved by commit e5e78a4), not deviations"
    - "01-03-PLAN.md, 01-04-PLAN.md, 01-05-PLAN.md, 01-06-PLAN.md each clarify that the single-commit consolidation prescribed by their final task IS the prescribed execution model — task numbering is for organizational decomposition, not commit boundaries"
    - "01-05-PLAN.md notes that the 8 scoping_spec carryover failures from 01-02 are anticipated cross-plan handoffs to 01-06, not deviations from plan 05"
    - "01-06-PLAN.md task 3 reflects the corrected assertion (contain_exactly(project_global)) and documents the any-explicit-disables-ambient resolve_scope rule"
    - "01-07-PLAN.md files_modified list includes Gemfile.lock with rationale citing Bundler's mechanical lock-file rewrite on version constant change"
    - "All 23 carried known issues from R01-KNOWN-ISSUES.json are accounted for in known_issues_input and known_issue_resolutions: 16 scoping_spec entries marked resolved (plan 06 fixed via commit e5e78a4), 7 rubocop entries marked accepted-process-exception (pre-existing, ROADMAP housekeeping)"
    - "No production code (lib/, app/, db/, spec/, README, CHANGELOG, version.rb) is modified — this remediation operates exclusively on .vbw-planning/ planning artifacts"
  artifacts:
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md"
      provides: "Amendment notes for class name (acronym) and commit type (feat) deviations"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md"
      provides: "Amendment note clarifying 8 scoping_spec failures are anticipated handoffs to 01-06"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md"
      provides: "Amendment note clarifying single-commit consolidation is prescribed"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md"
      provides: "Amendment note clarifying single-commit consolidation is prescribed"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md"
      provides: "Amendment notes for single-commit consolidation and DEVN-05 anticipated leftover"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md"
      provides: "Amendment notes for single-commit consolidation and corrected task 3 assertion"
      contains: "Plan amendment (R01)"
    - path: ".vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md"
      provides: "Amendment note adding Gemfile.lock to expected files_modified"
      contains: "Plan amendment (R01)"
  key_links:
    - {from: ".vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md", to: "lib/typed_eav.rb", via: "Amendment cites EAV inflector acronym registration as the constraint forcing the AddParentScopeToTypedEAVPartitions class name"}
    - {from: ".vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md", to: "lib/typed_eav/has_typed_eav.rb", via: "Amendment cites resolve_scope's any-explicit-disables-ambient rule as the production semantic that contradicts the plan's original assertion"}
    - {from: ".vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md", to: "lib/typed_eav/version.rb", via: "Amendment cites Bundler's mechanical Gemfile.lock rewrite as the consequence of editing the VERSION constant"}
---
<objective>
Reconcile the seven phase 01 PLAN.md files with what was actually shipped. The QA gate flagged 11 deviations as FAIL checks. The implementation is correct (440 examples, 0 failures) and CONTEXT.md decisions hold; only the plan documents drifted from the as-shipped reality. This remediation appends "Plan amendment (R01)" notes to the affected sections of each PLAN.md so future maintainers see the deviation rationale without divergence between plan-as-written and code-as-shipped.

Ten of the eleven deviations are plan-amendments (the plan should reflect what shipped). One — DEVIATION-01-07-B (5 pre-existing rubocop offenses in typed_eav.gemspec) — is a process-exception with no PLAN.md edit warranted; it is recorded in fail_classifications and known_issue_resolutions only.

Critical constraint: this remediation does NOT modify any production code, spec, or release artifact. It operates exclusively on planning artifacts under .vbw-planning/phases/01-two-level-scope-partitioning/. Original plan content is preserved verbatim — amendment notes are appended, never replace.
</objective>
<context>
@.vbw-planning/phases/01-two-level-scope-partitioning/01-CONTEXT.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-VERIFICATION.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-01-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-02-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-03-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-04-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-05-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-06-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md
@.vbw-planning/phases/01-two-level-scope-partitioning/01-07-SUMMARY.md
@.vbw-planning/phases/01-two-level-scope-partitioning/remediation/qa/round-01/R01-KNOWN-ISSUES.json

Amendment style — append a clearly delimited block to the relevant section. Use this exact header format so amendments are greppable:

  ## Plan amendment (R01) — {short-title}

  {prose explaining what shipped, why it differs from the plan above, and the constraint that forced the difference. 3-8 lines.}

Place each amendment block at the END of the PLAN.md file, after the closing </success_criteria>/<output> block. Do NOT edit existing <objective>, <tasks>, <verification>, <success_criteria>, or frontmatter content. Original plan content is preserved verbatim so the amendment trail is auditable.
</context>
<tasks>
<!-- Sequential — each task amends one or more PLAN.md files. -->

<task type="auto">
  <name>Amend 01-01-PLAN.md with class name and commit type rationale (DEVIATION-01-01-A, DEVIATION-01-01-B)</name>
  <files>
    .vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
  </files>
  <action>
Append a "Plan amendment (R01)" block at the end of the file (after the closing &lt;output&gt; tag). The block must contain TWO sub-amendments under one header.

Suggested content:

  ## Plan amendment (R01) — class name + commit type

  **DEVIATION-01-01-A (class name)**: Task 1 prescribes the migration class name `AddParentScopeToTypedEavPartitions`. As shipped (commit 5ff7c30), the class is `AddParentScopeToTypedEAVPartitions` with the acronym-aware spelling. Reason: `lib/typed_eav.rb` registers `EAV` as an inflector acronym (ActiveSupport::Inflector.inflections.acronym). Without the acronym-aware spelling, Rails' `String#constantize` on the migration filename raises `NameError: uninitialized constant AddParentScopeToTypedEAVPartitions` at migration load. The acronym-aware spelling is the only one that loads. Treat the task-1 spelling as a typo in this plan; the shipped class name is correct.

  **DEVIATION-01-01-B (commit type)**: Must-haves and task 5 prescribe the commit subject `db(migration): add parent_scope to typed_eav fields and sections partition tuple`. As shipped (commit 5ff7c30), the subject is `feat(migration): add parent_scope to typed_eav fields and sections partition tuple`. Reason: the project's PostToolUse commit-format hook (CLAUDE.md "Commit format" rule) only accepts the type tokens feat|fix|test|refactor|perf|docs|style|chore. The token `db` is rejected at commit time. The shipped subject keeps scope (`migration`), body, and intent identical; only the type token changed to satisfy the hook. Treat `feat(migration)` as the canonical subject for this plan.

Do NOT modify the original objective, tasks, verification, success_criteria, or frontmatter. Append the amendment block below the closing tags.
  </action>
  <verify>
File contains the literal string "## Plan amendment (R01)" and both sub-headings ("class name" and "commit type"). Original `<tasks>` and frontmatter remain byte-for-byte unchanged (use `git diff` to confirm only additions, no deletions).
  </verify>
  <done>
01-01-PLAN.md has the appended amendment block with both DEVIATION-01-01-A and DEVIATION-01-01-B rationales; original content is intact.
  </done>
</task>

<task type="auto">
  <name>Amend 01-02-PLAN.md with anticipated-handoff clarification (DEVIATION-01-02)</name>
  <files>
    .vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md
  </files>
  <action>
Append a "Plan amendment (R01)" block at the end of the file.

Suggested content:

  ## Plan amendment (R01) — anticipated cross-plan handoff to 01-06

  **DEVIATION-01-02**: After commit 52014a3, 8 examples in `spec/lib/typed_eav/scoping_spec.rb` failed (5 assertion-shape mismatches + 3 ArgumentError raises from the strict resolver-callable contract). The QA gate flagged these as a deviation. They are NOT deviations from this plan's intent — task 4's verify gate explicitly stated: "Many tests will FAIL at this point because they assert `current_scope` returns a scalar string. That is EXPECTED — those failures get fixed in plan 06." The failures are anticipated cross-plan handoffs from plan 02 (resolver tuple shape change) to plan 06 (spec assertion rewrites + resolver stub updates). Plan 06 (commit e5e78a4) resolved all 8 — final suite at 440 examples, 0 failures. The SUMMARY's `pre_existing_issues` block was over-conservative reporting; the plan body already declared these as expected. Future readers should treat the "DEVN-05 anticipated breakage" entry in 01-02-SUMMARY.md as a designed handoff, not a defect.

Do NOT modify the original objective, tasks, verification, success_criteria, or frontmatter.
  </action>
  <verify>
File contains the literal string "## Plan amendment (R01)" and the anticipated-handoff rationale. Original sections unchanged.
  </verify>
  <done>
01-02-PLAN.md has the appended amendment block clarifying the cross-plan handoff status.
  </done>
</task>

<task type="auto">
  <name>Amend 01-03 + 01-04 + 01-05 + 01-06 PLAN.md with single-commit + DEVN-05 + plan-vs-production correction notes (DEVIATION-01-03, -01-04, -01-05-A, -01-05-B, -01-06-A, -01-06-B)</name>
  <files>
    .vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md
  </files>
  <action>
Append a "Plan amendment (R01)" block to each of the four files. The single-commit theme is identical across all four; only the file-specific specifics change.

For 01-03-PLAN.md:

  ## Plan amendment (R01) — single-commit consolidation is prescribed

  **DEVIATION-01-03**: The QA gate flagged that tasks 1-3 (for_entity expansion, uniqueness expansion, validate_parent_scope_invariant) shipped as a single coordinated edit rather than three sequential commits. This IS the prescribed execution model: task 4 explicitly directs "Single commit. One file changed." Tasks 1-3 each modify the same small validations/scopes block in `app/models/typed_eav/field/base.rb`; splitting them would require three sequential commits to the same hunk neighborhood, contradicting task 4's directive. Each task's done criterion was independently verified before the single commit (commit 6c3afb5). Future readers: task numbering in this plan is for organizational decomposition, not commit boundaries — the entire plan ships as one atomic commit.

For 01-04-PLAN.md:

  ## Plan amendment (R01) — single-commit consolidation is prescribed

  **DEVIATION-01-04**: Same shape as 01-03 (the symmetric Section change). Task 4 directs "Single commit, one file." Tasks 1-3 modify adjacent regions of `app/models/typed_eav/section.rb` and ship as a single atomic commit (commit 9c7e916). Each task's done criterion was independently verified before commit. Task numbering is organizational, not a commit-boundary specification.

For 01-05-PLAN.md (TWO sub-amendments):

  ## Plan amendment (R01) — single-commit consolidation + anticipated DEVN-05 leftover

  **DEVIATION-01-05-A (single-commit consolidation)**: Task 5 explicitly directs "Single commit." Tasks 1-4 (macro extension, resolve_scope rewrite, query path forwarding, Value cross-axis guard) are tightly interdependent — the integration is meaningful only in combination, and each task touches code that the subsequent task assumes is already in place. Shipped as a single atomic commit (commit c628372) covering 4 files (lib/typed_eav/has_typed_eav.rb, app/models/typed_eav/value.rb, spec/dummy/app/models/test_models.rb, spec/dummy/db/migrate/20260330000001_create_test_entities.rb). Each task's done criterion was independently verified (live REPL macro guard, three-way precedence on OpenStruct fixtures, generated SQL inspection on Project, Value-level cross-axis matrix) before commit. Task numbering is organizational.

  **DEVIATION-01-05-B (anticipated 8-failure carryover from plan 02)**: 8 scoping_spec failures persisted after commit c628372. These were already documented in 01-02-SUMMARY.md's `pre_existing_issues` as anticipated breakage handed off to plan 06. Task 5's verify gate explicitly stated the expected counts ("pre-existing assertion-mismatch failures from plan 02 are still there (unchanged), but no NEW failures are introduced"). Plan 06 (commit e5e78a4) resolved all 8 — final suite at 440 examples, 0 failures. Treat the 01-05-SUMMARY DEVN-05 carryover entry as a designed handoff, not a defect.

For 01-06-PLAN.md (TWO sub-amendments):

  ## Plan amendment (R01) — single-commit consolidation + corrected task 3 assertion

  **DEVIATION-01-06-A (single-commit consolidation)**: Task 5 explicitly directs "Single commit. Seven files modified." Tasks 1-4 spread across seven spec files (scoping_spec, round_2, round_3, round_4 new, value_spec, field_spec, factories), but each task's done criteria were independently verified via per-file rspec runs before staging (task 1: 44 ex 0 fail; task 2: 187 ex 0 fail; task 3: 33 ex 0 fail in round_2/3; task 4: 14 ex 0 fail in round_4). Shipped as a single atomic commit (commit e5e78a4). Task numbering is organizational decomposition, not commit boundaries.

  **DEVIATION-01-06-B (corrected task 3 assertion)**: Task 3 prescribed assertion `expect(fields).to contain_exactly(project_scope_only, project_global)` for `Project.typed_eav_definitions(parent_scope: nil)` inside a `with_scope(["tenant_a", "w1"]) { ... }` block. This contradicts production semantics. The actual `resolve_scope` implementation (`lib/typed_eav/has_typed_eav.rb:340`) gates ambient resolution off whenever EITHER kwarg is passed explicitly — passing `parent_scope: nil` is an explicit pass, so the resolver collapses to `(scope: nil, parent_scope: nil)` and returns globals only. Dev caught the planning error and rewrote the test to assert actual behavior (`contain_exactly(project_global)`) with an explanatory inline comment, parallel to the existing `scope: nil` test in `spec/lib/typed_eav/scoping_spec.rb`. No production code was touched. The corrected assertion is the canonical plan-task-3 expectation; the original assertion was a planning error. Future readers: when in doubt about the "any-explicit-disables-ambient" rule, see the inline comment in spec and `resolve_scope` line 340.

Do NOT modify the original objective, tasks, verification, success_criteria, or frontmatter of any of the four files.
  </action>
  <verify>
All four files contain a "## Plan amendment (R01)" header with the appropriate sub-amendments. Original `<tasks>` blocks and frontmatter unchanged in all four. `git diff` shows only additions, no deletions.
  </verify>
  <done>
01-03, 01-04, 01-05, 01-06 PLAN.md files each have appended amendment blocks; 01-05 and 01-06 each have two sub-amendments; original plan content intact across all four.
  </done>
</task>

<task type="auto">
  <name>Amend 01-07-PLAN.md with Gemfile.lock files_modified rationale (DEVIATION-01-07-A)</name>
  <files>
    .vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md
  </files>
  <action>
Append a "Plan amendment (R01)" block at the end of the file. NOTE: only DEVIATION-01-07-A gets a plan amendment. DEVIATION-01-07-B (the 5 pre-existing rubocop offenses) is a process-exception and is handled in this plan's `fail_classifications` and `known_issue_resolutions` frontmatter — no PLAN.md edit is warranted because no file in phase 01 touched typed_eav.gemspec.

Suggested content:

  ## Plan amendment (R01) — Gemfile.lock added to files_modified

  **DEVIATION-01-07-A**: The plan's `files_modified` frontmatter lists only `README.md`, `CHANGELOG.md`, `lib/typed_eav/version.rb`. As shipped (commit b8fbc91), the commit also includes `Gemfile.lock`. Reason: Bundler auto-rewrites `Gemfile.lock` to match `lib/typed_eav/version.rb` on the next `bundle exec` invocation. Leaving the lock at 0.1.0 against a 0.2.0 version pin produces a self-inconsistent repo where every subsequent bundler call dirties a tracked file. The version-bump task in this plan implicitly covers this — Gemfile.lock change is mechanical fallout from the version constant edit, not a scope expansion. Treat the canonical files_modified for this plan as the four files: README.md, CHANGELOG.md, lib/typed_eav/version.rb, Gemfile.lock.

  **DEVIATION-01-07-B (recorded for completeness, no plan amendment)**: 5 rubocop Layout/HashAlignment offenses in `typed_eav.gemspec:22-26` were pre-existing at HEAD `e5e78a4` before this plan started. No file in any phase 01 plan touched `typed_eav.gemspec`. ROADMAP already flags these for separate housekeeping. Classified as `process-exception` in R01-PLAN.md's `fail_classifications` and `accepted-process-exception` in `known_issue_resolutions`. No PLAN.md edit is warranted because the offenses are out-of-scope for this phase.

Do NOT modify the original objective, tasks, verification, success_criteria, or frontmatter.
  </action>
  <verify>
File contains the literal string "## Plan amendment (R01)" and the Gemfile.lock rationale. Original sections unchanged. The DEVIATION-01-07-B note is informational only — it does NOT propose any PLAN.md edit (it lives in this remediation plan's frontmatter, not in 01-07-PLAN.md's files_modified or tasks).
  </verify>
  <done>
01-07-PLAN.md has the appended amendment block documenting Gemfile.lock as expected files_modified, with the process-exception note recorded for completeness; original content intact.
  </done>
</task>

<task type="auto">
  <name>Final consistency pass — verify all amendments grep cleanly and known-issues coverage is complete</name>
  <files>
    .vbw-planning/phases/01-two-level-scope-partitioning/01-01-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-02-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-03-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-04-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-05-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-06-PLAN.md
    .vbw-planning/phases/01-two-level-scope-partitioning/01-07-PLAN.md
  </files>
  <action>
Cross-validation pass. No file edits in this task — verification only:

1. Run `grep -l "Plan amendment (R01)" .vbw-planning/phases/01-two-level-scope-partitioning/01-*-PLAN.md` and confirm all 7 PLAN.md files appear in the result.

2. For each FAIL ID in this remediation plan's `fail_classifications`, confirm the corresponding rationale block exists in the named source_plan PLAN.md:
   - DEVIATION-01-01-A → 01-01-PLAN.md mentions "AddParentScopeToTypedEAVPartitions" and "inflector acronym"
   - DEVIATION-01-01-B → 01-01-PLAN.md mentions "feat(migration)" and the commit-format hook constraint
   - DEVIATION-01-02 → 01-02-PLAN.md mentions "anticipated cross-plan handoff" and plan 06
   - DEVIATION-01-03 → 01-03-PLAN.md mentions "single-commit consolidation"
   - DEVIATION-01-04 → 01-04-PLAN.md mentions "single-commit consolidation"
   - DEVIATION-01-05-A → 01-05-PLAN.md mentions "single-commit consolidation"
   - DEVIATION-01-05-B → 01-05-PLAN.md mentions "anticipated 8-failure carryover" or equivalent
   - DEVIATION-01-06-A → 01-06-PLAN.md mentions "single-commit consolidation"
   - DEVIATION-01-06-B → 01-06-PLAN.md mentions "any-explicit-disables-ambient" or "contain_exactly(project_global)"
   - DEVIATION-01-07-A → 01-07-PLAN.md mentions "Gemfile.lock" and "Bundler auto-rewrites"
   - DEVIATION-01-07-B → recorded in 01-07-PLAN.md's amendment block AS process-exception note (no PLAN edit beyond that note)

3. Confirm known_issues_input has 23 entries and known_issue_resolutions has 23 entries with matching keys (test+file pair); 16 have disposition `resolved`, 7 have disposition `accepted-process-exception`, 0 have `unresolved`.

4. Confirm no file under app/, lib/, db/, spec/, README.md, CHANGELOG.md, lib/typed_eav/version.rb, Gemfile.lock was modified by this remediation. Run `git diff --stat` and confirm only `.vbw-planning/phases/01-two-level-scope-partitioning/*.md` paths appear.

5. Confirm final suite is still green: `bundle exec rspec` reports 440 examples, 0 failures (this remediation does not touch code, so the suite must remain at the same baseline).

If any of these checks fails, fix the issue inline (re-amend the affected PLAN.md to satisfy the missing constraint). Do NOT delete or rewrite original plan content.
  </action>
  <verify>
All 5 cross-validation steps pass. `git diff main -- .vbw-planning/` shows additions only; `git diff main -- .` (excluding `.vbw-planning/`) shows no changes. `bundle exec rspec` exits 0 with 440 examples, 0 failures.
  </verify>
  <done>
All 11 fail_classifications have corresponding rationale blocks in their source_plan files (or are recorded as process-exception in this plan's frontmatter); all 23 known issues have matching resolutions; no production code touched; suite green.
  </done>
</task>
</tasks>
<verification>
1. All 7 phase 01 PLAN.md files contain a "## Plan amendment (R01)" block (grep -l confirms).
2. Each of the 10 plan-amendment FAIL IDs has a corresponding rationale block in its source PLAN.md citing the constraint that forced the deviation.
3. DEVIATION-01-07-B (the only process-exception) is recorded in this remediation plan's `fail_classifications` and in 01-07-PLAN.md's amendment block as an informational note; no other PLAN.md edit was made for it.
4. `known_issues_input` has 23 entries; `known_issue_resolutions` has 23 entries with matching test+file keys; 16 are `resolved`, 7 are `accepted-process-exception`, 0 `unresolved`.
5. `git diff main -- .` excluding `.vbw-planning/` shows no changes — no production code, spec, or release artifact was modified.
6. `bundle exec rspec` from spec/dummy reports 440 examples, 0 failures (baseline preserved).
7. Original frontmatter, `<objective>`, `<tasks>`, `<verification>`, `<success_criteria>`, and `<output>` blocks of all 7 PLAN.md files are byte-for-byte unchanged from the pre-remediation state.
</verification>
<success_criteria>
- All 11 FAIL deviations from 01-VERIFICATION.md are accounted for in `fail_classifications`: 10 plan-amendment, 1 process-exception.
- Each of the 10 plan-amendment FAILs has a corresponding "Plan amendment (R01)" block appended to its source PLAN.md, citing the constraint that forced the deviation.
- All 23 carried known issues from R01-KNOWN-ISSUES.json appear in both `known_issues_input` and `known_issue_resolutions` with the canonical `{test, file, error}` shape; dispositions correctly reflect plan 06's resolution (16) and the rubocop process-exception (7).
- Original PLAN.md content is preserved verbatim — amendments are appended, never replace.
- No production code, spec file, or release artifact (README, CHANGELOG, version.rb, Gemfile.lock) is modified by this remediation.
- Full RSpec suite remains green at 440 examples, 0 failures.
- The plan-vs-shipped divergence is closed: a future maintainer reading any phase 01 PLAN.md will see both the original directive AND the amendment explaining what shipped and why.
</success_criteria>
<known_issue_workflow>
- All 23 carried known issues from R01-KNOWN-ISSUES.json are copied verbatim into `known_issues_input` using the canonical `{test, file, error}` shape — both registry duplicates from 01-02-SUMMARY/01-05-SUMMARY (16 scoping_spec entries) and the 7 rubocop entries (1 from 01-07-SUMMARY + 1 aggregate + 5 individual line entries from 01-VERIFICATION).
- All 16 scoping_spec entries are `resolved`: plan 06 (commit e5e78a4) updated assertion shapes to expect tuples and updated resolver stubs to return tuples, satisfying the new strict contract. Final suite at 440 examples, 0 failures verifies the resolution.
- All 7 rubocop entries are `accepted-process-exception`: pre-existing at HEAD e5e78a4 (before phase 01 started); no file in any phase 01 plan touched typed_eav.gemspec; ROADMAP already flags for separate housekeeping. Out-of-scope for this phase by construction.
- 0 entries are `unresolved` — nothing is intentionally carried into a future remediation round.
</known_issue_workflow>
<output>
R01-SUMMARY.md
</output>
