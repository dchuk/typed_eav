---
phase: 1
plan: "05"
title: "has_typed_eav macro + resolve_scope + where_typed_eav + Value cross-axis guard"
status: complete
completed: 2026-04-29
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - c628372
deviations:
  - "DEVN-01 (minor): all 5 tasks coordinated into a single atomic commit per the plan's explicit `Single commit` directive in task 5. Each task's done criteria were independently verified (live REPL macro guard, three-way precedence on OpenStruct fixtures, generated SQL inspection on Project, Value-level cross-axis matrix) before commit. No content was merged or omitted."
  - "DEVN-05 (pre-existing / anticipated): 8 examples in spec/lib/typed_eav/scoping_spec.rb continue to fail after this commit. These were already documented as anticipated breakage in 01-02-SUMMARY.md (plan 02's pre_existing_issues frontmatter) and are owned by plan 06. 5 are assertion-shape mismatches (`expected \"t1\", got [\"t1\", nil]`); 3 are ArgumentError raises from the strict resolver-callable contract because the spec stubs Config.scope_resolver with bare scalars (the new Phase 1 contract requires tuple). No NEW failures introduced by this plan — all 8 failures pre-date the commit."
pre_existing_issues:
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — pre-existing plan-02 leftover, plan 06 owns rewriting assertions to expect tuples"}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the Phase 1 strict contract requires a tuple — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple) — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — pre-existing plan-02 leftover"}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142) — pre-existing plan-02 leftover"}'
ac_results:
  - criterion: "has_typed_eav macro accepts new parent_scope_method: kwarg (defaults to nil); class_attribute :typed_eav_parent_scope_method holds it"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:96 declares the kwarg; lib/typed_eav/has_typed_eav.rb:117-118 declares class_attribute. Live REPL: `Project.typed_eav_parent_scope_method == :workspace_id`."
  - criterion: "InstanceMethods#typed_eav_parent_scope returns send(self.class.typed_eav_parent_scope_method)&.to_s when configured, else nil"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:425-429. Live REPL: Project.new(tenant_id: 't1', workspace_id: 'w1').typed_eav_parent_scope == 'w1'; Contact.new(tenant_id: 't1').typed_eav_parent_scope == nil."
  - criterion: "ClassQueryMethods#resolve_scope returns a [scope, parent_scope] tuple OR ALL_SCOPES OR raises ScopeRequired (signature change — internal method, not public API)"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:330-396. Returns ALL_SCOPES inside TypedEAV.unscoped (line 334); returns [s, ps] tuple from explicit-overrides path (line 356); returns [nil, nil] for non-scoped models (line 374); returns ambient tuple from current_scope when present (line 395); raises ScopeRequired when require_scope=true and ambient is nil (lines 384-388)."
  - criterion: "where_typed_eav single-scope branch passes both scope and parent_scope into Field::Base.for_entity"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:218-219: `s, ps = resolved; TypedEAV::Field::Base.for_entity(name, scope: s, parent_scope: ps)`. Live SQL on Project.where_typed_eav(...): for_entity emits `(scope = 't1' OR scope IS NULL) AND (parent_scope = 'w1' OR parent_scope IS NULL)`."
  - criterion: "where_typed_eav accepts new parent_scope: kwarg (defaults to UNSET_SCOPE — same sentinel as scope: per CONTEXT.md decision)"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:177: `def where_typed_eav(*filters, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)`. No new sentinel introduced."
  - criterion: "with_field passes parent_scope: through to where_typed_eav"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:280: `def with_field(name, ..., scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)`. Both branches forward via `where_typed_eav(..., scope: scope, parent_scope: parent_scope)` (lines 285, 290)."
  - criterion: "typed_eav_definitions class method accepts parent_scope: kwarg and forwards to resolve_scope"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:301-309. Calls `resolve_scope(scope, parent_scope)` and unpacks the tuple for `for_entity(name, scope: s, parent_scope: ps)`."
  - criterion: "Multimap (unscoped) branch is structurally unchanged: where(entity_type: name).group_by(&:name) — atomic-bypass per CONTEXT.md"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:216 inside the if-all_scopes branch unchanged. The pre-existing definitions_multimap_by_name helper (line 68) is untouched. resolve_scope returns ALL_SCOPES for unscoped (line 334) and the where_typed_eav branch consumes that sentinel without touching parent_scope."
  - criterion: "definitions_by_name three-way precedence: most-specific (both set) > scope-only > global; sort_by [scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1] preserves index_by-last-wins semantics"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:57-61. Live REPL: input [(nil,nil), ('t1',nil), ('t1','p1')] => index_by['x'].parent_scope == 'p1'. Same input reversed [('t1','p1'), ('t1',nil), (nil,nil)] => index_by['x'].parent_scope == 'p1' (most-specific still wins because the sort is order-stable on the precedence key)."
  - criterion: "Value#validate_field_scope_matches_entity extended: when field.parent_scope.present?, entity.typed_eav_parent_scope MUST match (else errors[:field] = :invalid)"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:147-176. Live REPL test matrix: matching full triple => valid; parent_scope mismatch => invalid (errors[:field]=['is invalid']); Contact (no parent_scope_method) + full-triple field => invalid; Contact + scoped-only => valid; Project + global => valid; Project + scoped-only => valid."
  - criterion: "Value-side validator preserves today's `field.scope.nil?` short-circuit (global fields shared) AND adds the parent_scope axis check"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:152: `if field.scope.present?` block scopes the scope-axis check. app/models/typed_eav/value.rb:165 onward: `return if field.parent_scope.blank?` short-circuits the parent_scope-axis check when the field is not partitioned by parent_scope. Global fields (scope nil + parent_scope nil) skip both checks and pass — verified Test 5 in REPL matrix."
  - criterion: "spec/dummy adds a Project model declaring has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id (Option A)"
    verdict: pass
    evidence: "spec/dummy/app/models/test_models.rb:11-14. spec/dummy/db/migrate/20260330000001_create_test_entities.rb:18-23 adds the projects table with name, tenant_id, workspace_id columns. Migration applied cleanly on a fresh `dropdb && createdb` cycle."
  - criterion: "Resolver-callable tuple-contract violation (a custom resolver returning a bare scalar) raises ArgumentError inside TypedEAV.current_scope (plan 02 owns the raise); resolve_scope can rely on current_scope's return being already-validated as nil | [a, b] — no shape check duplicated here"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:376-379 documents the trust on current_scope's contract; line 395 returns the tuple verbatim. No shape check in resolve_scope. Plan 02's strict-contract raise lives in lib/typed_eav.rb:87."
  - criterion: "Macro-time configuration check: `has_typed_eav parent_scope_method: X` without `scope_method:` raises ArgumentError at class-load time"
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:102-108. Live REPL: defining anonymous class with `has_typed_eav parent_scope_method: :workspace_id` (no scope_method) raises ArgumentError with message starting 'has_typed_eav: `parent_scope_method:` requires `scope_method:` to also be set. ...'."
  - criterion: "Single commit: feat(scope): wire parent_scope through resolver chain, query path, and Value cross-axis guard"
    verdict: pass
    evidence: "Commit c628372 with the exact subject line. `git show --stat c628372` shows 4 files changed (lib/typed_eav/has_typed_eav.rb, app/models/typed_eav/value.rb, spec/dummy/app/models/test_models.rb, spec/dummy/db/migrate/20260330000001_create_test_entities.rb)."
  - criterion: "Artifact lib/typed_eav/has_typed_eav.rb provides Tuple-aware resolve_scope and where_typed_eav with parent_scope kwarg"
    verdict: pass
    evidence: "Contains parent_scope_method (lines 79, 102, 117); contains parent_scope: kwarg in where_typed_eav (line 177), with_field (line 280), typed_eav_definitions (line 301)."
  - criterion: "Artifact lib/typed_eav/has_typed_eav.rb provides Three-way precedence in definitions_by_name"
    verdict: pass
    evidence: "Line 59: `sort_by { |d| [d.scope.nil? ? 0 : 1, d.parent_scope.nil? ? 0 : 1] }`. Two-key sort with index_by(&:name) preserves last-wins semantics. Live REPL verifies forward-and-reverse-order inputs both surface the most-specific row."
  - criterion: "Artifact app/models/typed_eav/value.rb provides Cross-(scope, parent_scope) Value-write guard"
    verdict: pass
    evidence: "Lines 147-176 contain `typed_eav_parent_scope` (line 169) reference. Validator adds errors.add(:field, :invalid) for both axis mismatches. Verified against the 6-row matrix in REPL."
  - criterion: "Artifact spec/dummy/app/models/test_models.rb provides Test model exercising parent_scope_method"
    verdict: pass
    evidence: "Line 13 contains `parent_scope_method: :workspace_id`. Project ActiveRecord class declared at lines 11-14. Migration support added at spec/dummy/db/migrate/20260330000001_create_test_entities.rb:18-23."
  - criterion: "Test database migrates cleanly with the added Project table"
    verdict: pass
    evidence: "Drop/create/migrate flow verified: dropdb typed_eav_test && createdb typed_eav_test && bundle exec ruby -e '...migrate...' produced the migration log including `-- create_table(:projects)` and `== 20260430000000 AddParentScopeToTypedEAVPartitions: migrated`. spec_helper's maintain_test_schema! passes after migration."
  - criterion: "Full spec suite produces ONLY the anticipated 8 wave-1 failures from scoping_spec, no new failures from Project's introduction"
    verdict: pass
    evidence: "`bundle exec rspec` => 388 examples, 8 failures. All 8 failures are in spec/lib/typed_eav/scoping_spec.rb at the same line numbers documented in 01-02-SUMMARY.md's pre_existing_issues. No NoMethodError, TypeError, or new ArgumentError from gem code paths. No regressions introduced by Project's addition or the parent_scope wiring."
  - criterion: "rubocop clean on the four files modified"
    verdict: pass
    evidence: "`bundle exec rubocop lib/typed_eav/has_typed_eav.rb app/models/typed_eav/value.rb spec/dummy/app/models/test_models.rb spec/dummy/db/migrate/20260330000001_create_test_entities.rb` => 4 files inspected, no offenses detected. (One Metrics/AbcSize warning on validate_field_scope_matches_entity was silenced with paired disable/enable comments and a `--` justification per CONVENTIONS.md, mirroring the codebase pattern in has_typed_eav.rb and query_builder.rb.)"
  - criterion: "No spec files modified by this plan (specs deferred to plan 06)"
    verdict: pass
    evidence: "git show --stat c628372 lists no files under spec/ except spec/dummy/* (test models and migration, which are spec/dummy infrastructure, not actual rspec spec files). spec/lib/, spec/models/, spec/integration/, spec/regressions/ are untouched."
  - criterion: "No version bump or CHANGELOG edit"
    verdict: pass
    evidence: "git show c628372 -- lib/typed_eav/version.rb CHANGELOG.md returns no diff. Both deferred to plan 07 per the plan's explicit instruction."
---

Phase 1 / wave 2 / plan 05: integrating commit. The macro now accepts `parent_scope_method:`, the resolver chain returns and propagates `[scope, parent_scope]` tuples end-to-end, the query path (`where_typed_eav`, `with_field`, `typed_eav_definitions`) is parent_scope-aware, the collision-precedence helper applies three-way most-specific-wins, and the Value-side cross-axis write guard enforces the parent_scope axis. Single atomic commit; spec/dummy adds a `Project` model exercising the full triple.

## What Was Built

- `has_typed_eav` macro: new `parent_scope_method:` kwarg + class_attribute `typed_eav_parent_scope_method`; macro-time configuration guard rejects `parent_scope_method:` without `scope_method:` with `ArgumentError` at class load (closes silent dead-letter mode).
- `InstanceMethods#typed_eav_parent_scope`: defined unconditionally, returns `send(self.class.typed_eav_parent_scope_method)&.to_s` or nil. Mirrors the existing `typed_eav_scope`. Instance-level `typed_eav_definitions` forwards both axes.
- `ClassQueryMethods#resolve_scope`: signature change (private method, not public API) to take both halves; returns `[scope, parent_scope]` | `ALL_SCOPES`, raises `ScopeRequired` when ambient is nil and `require_scope=true`. No duplicate shape check on the resolver-callable return (plan 02 owns that raise).
- `where_typed_eav`, `with_field`, class-level `typed_eav_definitions`: all accept `parent_scope:` kwarg defaulting to `UNSET_SCOPE`. Single-scope branch passes both into `Field::Base.for_entity`. Multimap (unscoped) branch structurally unchanged — atomic-bypass per CONTEXT.md.
- `definitions_by_name`: three-way precedence via `sort_by [scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` + `index_by(&:name)` last-wins; full triple > scope-only > global.
- `Value#validate_field_scope_matches_entity`: extended with the parent_scope axis. Same `errors.add(:field, :invalid)` symbol; trusts the Field-level orphan-parent invariant from plan 03.
- `spec/dummy`: `Project` test model (`scope_method: :tenant_id, parent_scope_method: :workspace_id`); existing test-entities migration edited in-place to add the `:projects` table with `name`, `tenant_id`, `workspace_id` columns.

## Files Modified

- `lib/typed_eav/has_typed_eav.rb` -- modified: macro extension + macro-time guard, `typed_eav_parent_scope_method` class_attribute, `typed_eav_parent_scope` instance method, tuple-returning `resolve_scope`, three-way `definitions_by_name`, parent_scope-aware `where_typed_eav` / `with_field` / `typed_eav_definitions`. Doc comments expanded throughout.
- `app/models/typed_eav/value.rb` -- modified: `validate_field_scope_matches_entity` extended with parent_scope axis check; paired AbcSize disable/enable with justification.
- `spec/dummy/app/models/test_models.rb` -- modified: added `Project < ActiveRecord::Base` declaring both `scope_method:` and `parent_scope_method:`.
- `spec/dummy/db/migrate/20260330000001_create_test_entities.rb` -- modified: added `:projects` table with `name`, `tenant_id`, `workspace_id` columns and timestamps.

## Anticipated Test Breakage (Plan 06)

Eight examples in `spec/lib/typed_eav/scoping_spec.rb` continue to fail after this commit. All eight were already documented as anticipated breakage in `01-02-SUMMARY.md`'s `pre_existing_issues` frontmatter (plan 02, the tuple-returning resolver). They fall into two patterns:

1. **Five assertion-shape mismatches** (`expected "t1", got ["t1", nil]`): the specs were written against the v0.1.x scalar-returning `current_scope`. Plan 06 will rewrite these to expect tuples.
2. **Three `ArgumentError` raises from `current_scope`**: the specs stub `Config.scope_resolver = -> { "scalar" }` (lines 67, 79, 140-142). The Phase 1 strict resolver-callable contract surfaces these as `ArgumentError` exactly as designed. Plan 06 owns updating the resolver stubs to return tuples.

No new failures were introduced by this plan. The 388-example suite produces exactly the 8 pre-existing failures and 380 passes — same shape as after plan 02. The `Project` model and parent_scope wiring did not surface any latent bugs at the integration boundary; live REPL verification of the macro guard, three-way precedence, generated SQL, and Value-level cross-axis validation matrix all behave as designed.

## Deviations

- DEVN-01 (minor): all 5 tasks coordinated into a single atomic commit per the plan's explicit `Single commit` directive (task 5). Each task's done criteria were independently verified before commit (live REPL macro guard test, three-way precedence on OpenStruct fixtures, generated `for_entity` SQL inspection, Value-level cross-axis validation matrix across 6 combinations). No content was merged or omitted.
- DEVN-05 (pre-existing / anticipated): 8 examples in `spec/lib/typed_eav/scoping_spec.rb` continue to fail. These pre-date this commit (documented in `01-02-SUMMARY.md` plan 02 SUMMARY's `pre_existing_issues` frontmatter) and are owned by plan 06. See `pre_existing_issues:` frontmatter above for the exact list.
