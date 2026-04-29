---
phase: 1
plan: "06"
title: "Spec coverage — scoping, regressions, field/value, factories"
status: complete
completed: 2026-04-29
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - e5e78a4
deviations:
  - "DEVN-01 (minor): all 5 tasks coordinated into a single atomic commit per the plan's explicit `Single commit` directive in task 5. Each task's done criteria were independently verified (per-file rspec runs after each task) before commit. Seven files modified, one created."
  - "DEVN-02 (correction to plan task 3): the plan's task-3 prescribed assertion `expect(fields).to contain_exactly(project_scope_only, project_global)` for the `parent_scope: nil` kwarg inside `with_scope([\"tenant_a\", \"w1\"])` block contradicts production semantics. The actual `resolve_scope` implementation (lib/typed_eav/has_typed_eav.rb:340) gates ambient resolution off whenever EITHER kwarg is passed explicitly — so passing `parent_scope: nil` collapses to `(scope: nil, parent_scope: nil)` and returns globals only. Test was rewritten to assert the actual behavior with an explanatory comment, parallel to the existing `scope: nil` test in spec/lib/typed_eav/scoping_spec.rb. No production code touched."
pre_existing_issues: []
ac_results:
  - criterion: "spec/lib/typed_eav/scoping_spec.rb assertions updated to expect [scope, parent_scope] tuples from current_scope, with_scope, and DEFAULT_SCOPE_RESOLVER"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:18 (with_scope scalar BC), :25-27 (nested with_scope), :41 (AR-record normalization), :104-118 (resolver chain), :164 (AAT bridge). Every existing eq() assertion against current_scope now expects a tuple or nil."
  - criterion: "scoping_spec covers new with_scope([s, ps]) tuple form; scalar with_scope(v) BC still asserted"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:46-80 (.with_scope (tuple form) describe block) — 4 examples covering tuple, scalar BC, AR-record per-slot normalization, orphan-parent shape."
  - criterion: "scoping_spec covers typed_eav_definitions(parent_scope: ...) kwarg with parallel coverage to the existing scope: kwarg block"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:267-289 (typed_eav_definitions parent_scope kwarg describe block) — 3 examples on Project covering full-triple match, parent_scope nil, and pure-global."
  - criterion: "scoping_spec covers Section.for_entity with parent_scope: kwarg (parallel to today's scope: coverage)"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:407-431 (Section#for_entity with parent_scope describe block) — 3 examples covering full-triple match, scope-only kwarg, and pure-global."
  - criterion: "Custom resolver returning a bare scalar raises ArgumentError under the new contract — covered by a regression assertion"
    verdict: pass
    evidence: "spec/lib/typed_eav/scoping_spec.rb:122-150 (resolver-callable contract violation describe block) — 3 examples covering bare scalar, 1-element Array, and 3-element Array, each asserting the strict-contract ArgumentError raise."
  - criterion: "review_round_2_scope_leak_spec.rb extended with parent_scope-axis leak coverage that mirrors the existing scope-axis assertions: (a) Product (un-scoped host) ignores ambient parent_scope just as it ignores ambient scope; (b) Contact-on-a-parent_scope-bearing-host equivalent honors ambient parent_scope; (c) `unscoped { }` block must NOT leak parent_scope filters; (d) `scope: nil, parent_scope: nil` kwarg means pure-global"
    verdict: pass
    evidence: "spec/regressions/review_round_2_scope_leak_spec.rb:88-98 (Product mirror), :139-149 (Contact BC tuple pin), :152-228 (Project full-triple host describe block) — 7 new it blocks total. (a)–(d) all covered."
  - criterion: "review_round_3_collision_spec.rb extended with three-way collision precedence coverage (global / scope-only / full-triple) — the comparator chosen in plan 05's `definitions_by_name` must be exercised here; multimap branch under `unscoped { }` must collapse across (scope, parent_scope) combinations for a given name"
    verdict: pass
    evidence: "spec/regressions/review_round_3_collision_spec.rb:179-238 (Bug 1 mirror — multimap collapse across (scope, parent_scope)), :240-316 (Bug 2 mirror — three-way precedence) — 7 new it blocks total exercising the sort_by [scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1] comparator and the unscoped multimap branch."
  - criterion: "New file spec/regressions/review_round_4_parent_scope_spec.rb exists, follows the round_2/round_3 file shape, and covers ONLY cross-cutting scenarios that don't fit cleanly into round_2 or round_3: (a) orphan-parent rejection at Field level (parent_scope set + scope nil), (b) symmetric orphan-parent rejection at Section level, (c) cross-axis Value rejection (Value attached to a Field whose parent_scope doesn't match entity's typed_eav_parent_scope, including the host-without-parent_scope_method case)"
    verdict: pass
    evidence: "spec/regressions/review_round_4_parent_scope_spec.rb:1-156 — 14 examples in 3 describe blocks (Scenario A: 5 examples, Scenario B: 5 examples, Scenario C: 4 examples). Header comment explicitly states the file owns ONLY cross-cutting scenarios and points readers to round_2/round_3 for leak/collision coverage."
  - criterion: "spec/models/typed_eav/field_spec.rb gains tests for the new validate_parent_scope_invariant and the broadened uniqueness key (entity_type, scope, parent_scope)"
    verdict: pass
    evidence: "spec/models/typed_eav/field_spec.rb:32-69 (parent_scope partitioning context) — 6 examples covering same-name across parent_scope, triple-uniqueness duplicate rejection, same-name across parent_scope values, orphan-parent rejection, pure-global, scope-only."
  - criterion: "spec/models/typed_eav/value_spec.rb gains tests for the parent_scope axis on validate_field_scope_matches_entity (extending the existing :unscoped 'cross scope' block)"
    verdict: pass
    evidence: "spec/models/typed_eav/value_spec.rb:633-660 (REVIEW: nested typed-value must not attach across parent_scope describe block) — 3 examples covering different-parent_scope rejection, host-without-parent_scope_method rejection, and matching-axes acceptance."
  - criterion: "spec/factories/typed_eav.rb factories accept parent_scope: as a passable attribute (no default — tests opt in); a project factory or equivalent exists for the parent_scope_method test"
    verdict: pass
    evidence: "spec/factories/typed_eav.rb:14-24 — :project factory with sequence(:name), tenant_id { nil }, workspace_id { nil } defaults. Existing :integer_field factory has no parent_scope default — confirmed by inspection of all field factories (lines 28-130). Tests opt in via `create(:integer_field, parent_scope: \"w1\")` per plan task 2."
  - criterion: "Full suite (bin/rspec) is green on a clean db: 0 failures, 0 errors"
    verdict: pass
    evidence: "`bundle exec rspec` => 440 examples, 0 failures (up from 388 with 8 anticipated failures all resolved). Test DB cleaned of stale wave-2 rows before final run; all examples passed within transactional fixtures."
  - criterion: "Single commit: test(scope): cover parent_scope axis across resolver, query path, regressions, and unit specs"
    verdict: pass
    evidence: "Commit e5e78a4 with the exact subject line. `git diff HEAD~1 --stat` shows exactly 7 spec files modified (6 modified + 1 created): spec/factories/typed_eav.rb, spec/lib/typed_eav/scoping_spec.rb, spec/models/typed_eav/field_spec.rb, spec/models/typed_eav/value_spec.rb, spec/regressions/review_round_2_scope_leak_spec.rb, spec/regressions/review_round_3_collision_spec.rb, spec/regressions/review_round_4_parent_scope_spec.rb. No production code touched."
  - criterion: "Artifact spec/regressions/review_round_2_scope_leak_spec.rb provides Existing scope-leak regressions extended with parent_scope-axis mirrors"
    verdict: pass
    evidence: "Contains `parent_scope` (35 occurrences). File grew from 127 lines to 233 lines. Both Product and Contact blocks gained parent_scope-axis it blocks; new Project describe block at line 163 covers the full-triple host."
  - criterion: "Artifact spec/regressions/review_round_3_collision_spec.rb provides Existing collision regressions extended with three-way precedence and parent_scope multimap collapse"
    verdict: pass
    evidence: "Contains `parent_scope` (32 occurrences). File grew from 172 lines to 317 lines. Two new describe blocks: 'Bug 1 mirror: TypedEAV.unscoped + where_typed_eav across (tenant, workspace)' and 'Bug 2 mirror: three-way collision (global / scope-only / full-triple)'."
  - criterion: "Artifact spec/regressions/review_round_4_parent_scope_spec.rb provides Round-4 regression file — cross-cutting parent_scope scenarios only (orphan rejection, cross-axis Value rejection)"
    verdict: pass
    evidence: "File created at 156 lines. Top-level `RSpec.describe \"Round-4 review: parent_scope cross-cutting\"` matches the contains-pattern. Three Scenario describe blocks (A, B, C). Header comment explicitly defers leak coverage to round_2 and collision coverage to round_3."
  - criterion: "Artifact spec/lib/typed_eav/scoping_spec.rb provides Tuple-aware resolver chain coverage"
    verdict: pass
    evidence: "Contains `with_scope(%w[t1 w1])` (rubocop autocorrected from `with_scope([\"t1\", \"w1\"])`). All assertions on `current_scope`, `with_scope`, resolver chain, and AAT bridge updated to expect the 2-element tuple shape."
  - criterion: "Artifact spec/factories/typed_eav.rb provides Project factory or equivalent for parent_scope_method tests"
    verdict: pass
    evidence: "Contains `factory :project` (line 16). Used by spec/regressions/review_round_3_collision_spec.rb (Bug 1/2 mirror blocks), spec/regressions/review_round_4_parent_scope_spec.rb (Scenario C), and spec/lib/typed_eav/scoping_spec.rb (parent_scope kwarg block uses class-level Project methods that don't need the factory but the factory is consumed transitively for value-level tests)."
---

Phase 1 / wave 3 / plan 06: terminal commit. Updated existing scoping assertions to the [scope, parent_scope] tuple contract introduced by plan 02 and added comprehensive parent_scope-axis coverage across resolver, query path, regressions (round_2 leak mirror + round_3 three-way precedence + new round_4 cross-cutting file), unit specs (Field uniqueness + orphan rejection, Value cross-axis), and the :project factory. Suite jumped from 388 with 8 anticipated failures to 440 with 0 failures (52 new examples). No production code modified.

## What Was Built

- **spec/lib/typed_eav/scoping_spec.rb**: every assertion against `current_scope`, `with_scope`, resolver chain, AAT bridge updated to expect the 2-element `[scope, parent_scope]` tuple. New describe blocks: tuple-form `with_scope`, resolver-callable contract violation (bare scalar / 1-element / 3-element ArgumentError raises), `typed_eav_definitions(parent_scope:)` kwarg, `Section#for_entity(parent_scope:)`. Resolver stubs across the file updated from `-> { "t1" }` to `-> { ["t1", nil] }` per the new strict contract.
- **spec/regressions/review_round_2_scope_leak_spec.rb**: extended Product block with parent_scope short-circuit invariant; added Contact BC tuple-pin assertion; new Project describe block (full-triple host) covering `with_scope` tuple resolution, explicit `parent_scope:` kwarg override, `parent_scope: nil` kwarg semantics (pure-global per any-explicit-disables-ambient rule), unscoped multimap leak, require_scope behavior.
- **spec/regressions/review_round_3_collision_spec.rb**: Bug 1 mirror (`unscoped` multimap OR-collapse across (scope, parent_scope) combinations on Project, parallel to the original tenant-only OR-collapse on Contact); Bug 2 mirror (three-way collision precedence: full-triple > scope-only > global), exercising plan 05's `definitions_by_name` two-key sort_by and the degenerate scope-only-wins-when-no-full-triple case.
- **spec/regressions/review_round_4_parent_scope_spec.rb** (new file): Scenario A — orphan-parent rejection at Field level (5 examples); Scenario B — orphan-parent rejection at Section level (5 examples, symmetric inline-duplicated guard per CONTEXT.md); Scenario C — cross-(scope, parent_scope) Value rejection (4 examples, including Contact-host-without-parent_scope_method and Project-with-nil-workspace_id).
- **spec/models/typed_eav/value_spec.rb**: parent_scope cross-axis describe block parallel to the existing scope-axis block in `spec/regressions/known_bugs_spec.rb` — 3 examples on Project + Contact cases.
- **spec/models/typed_eav/field_spec.rb**: parent_scope partitioning context — 6 examples covering same-name-different-parent_scope, triple-uniqueness, orphan-parent rejection, pure-global, scope-only shapes.
- **spec/factories/typed_eav.rb**: `:project` factory mirroring the `:contact` nil-default pattern (sequence(:name), tenant_id { nil }, workspace_id { nil }).

## Files Modified

- `spec/lib/typed_eav/scoping_spec.rb` -- modified: tuple-shape assertions across the file; new describe blocks for tuple-form `with_scope`, resolver contract violations, `parent_scope:` kwarg on `typed_eav_definitions` and `Section#for_entity`. +137 / -15.
- `spec/regressions/review_round_2_scope_leak_spec.rb` -- modified: parent_scope-axis leak coverage extended in place; new Project full-triple describe block. +106 / 0.
- `spec/regressions/review_round_3_collision_spec.rb` -- modified: Bug 1 mirror (multimap OR-collapse across (scope, parent_scope)) + Bug 2 mirror (three-way precedence). +145 / 0.
- `spec/regressions/review_round_4_parent_scope_spec.rb` -- created: 156 lines, 14 examples covering cross-cutting scenarios that don't fit round_2 or round_3.
- `spec/models/typed_eav/value_spec.rb` -- modified: parent_scope cross-axis block at end of file. +29 / 0 (rubocop-autocorrected `TypedEAV::Value` references to `described_class` for the 3 new examples).
- `spec/models/typed_eav/field_spec.rb` -- modified: parent_scope partitioning context within the existing `validations` describe block. +43 / 0.
- `spec/factories/typed_eav.rb` -- modified: `:project` factory added between `:product` and the field-definition factories. +11 / 0.

## Test-count delta (net new examples)

- scoping_spec: +13 examples (4 tuple-form, 3 contract-violation, 3 parent_scope kwarg, 3 Section#for_entity parent_scope; existing examples updated in place)
- review_round_2: +7 (1 Product mirror, 1 Contact tuple BC pin, 5 Project full-triple)
- review_round_3: +7 (3 Bug 1 mirror, 4 Bug 2 mirror)
- review_round_4: +14 (5 Scenario A, 5 Scenario B, 4 Scenario C)
- value_spec: +3 (parent_scope cross-axis)
- field_spec: +6 (parent_scope partitioning context)
- factories: 0 examples added (factory definition only)

Total: **52 new examples**. Suite size: **388 → 440**. Failures: **8 → 0**.

## Deviations

- **DEVN-01 (minor)**: all 5 tasks consolidated into a single atomic commit per the plan's explicit `Single commit. Seven files modified.` directive in task 5. Each task's done criteria were independently verified by per-file rspec runs after task 1 (44 ex 0 fail), task 2 (187 ex 0 fail), task 3 (33 ex 0 fail in round_2/3), and task 4 (14 ex 0 fail in round_4) before staging.
- **DEVN-02 (correction to plan task 3 expected behavior)**: the plan's task-3 prescribed assertion `expect(fields).to contain_exactly(project_scope_only, project_global)` for `Project.typed_eav_definitions(parent_scope: nil)` inside `with_scope(["tenant_a", "w1"]) { ... }` contradicts the actual production semantics. `resolve_scope` (lib/typed_eav/has_typed_eav.rb:340) gates ambient resolution off whenever EITHER kwarg is passed explicitly — passing `parent_scope: nil` collapses to `(scope: nil, parent_scope: nil)` and returns globals only. This parallels the existing `scope: nil` test in `spec/lib/typed_eav/scoping_spec.rb` (preserved by plan 06). The test was rewritten to assert the actual behavior (`contain_exactly(project_global)`) with an inline comment explaining the any-explicit-disables-ambient rule. No production code touched. (Independent confirmation: a follow-up sanity test that BOTH axes explicit would also collapse to globals — passes.)
