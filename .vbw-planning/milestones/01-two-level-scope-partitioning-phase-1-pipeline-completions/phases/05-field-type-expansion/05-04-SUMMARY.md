---
phase: 5
plan: 04
title: Field::Reference (target-scope validation, :references operator) + ROADMAP four-vs-five doc fix
status: complete
started: 2026-05-06
completed: 2026-05-06
tasks_completed: 4
tasks_total: 5
commit_hashes:
  - 12b8f5c
  - 6ba33cd
  - ce6f92e
  - 6bd087d
files_modified:
  - app/models/typed_eav/field/reference.rb
  - lib/typed_eav/config.rb
  - lib/typed_eav/query_builder.rb
  - spec/factories/typed_eav.rb
  - spec/models/typed_eav/field_spec.rb
  - spec/models/typed_eav/value_spec.rb
  - spec/lib/typed_eav/query_builder_spec.rb
  - .vbw-planning/ROADMAP.md
  - README.md
deviations:
  - "DEVN-01 (minor): P01 (Verify dummy app has unscoped entity type) produced no commit because no file changes were needed — Product is registered with `has_typed_eav types: %i[text integer decimal boolean]` (NO `scope_method:`), so `Product.respond_to?(:typed_eav_scope_method)` is true but `Product.typed_eav_scope_method` is nil — exactly the unscoped-target shape Gating Decision 2's negative path needs (validator requires BOTH respond_to AND non-nil). Per protocol, no empty commits; the verification finding is documented in this SUMMARY and used in P04's Gating Decision 2 negative-path examples (target_entity_type: 'Product' + target_scope: 99 → field invalid). tasks_completed=4/5 because P01 was a no-op verification."
  - "DEVN-03 (blocking, RESOLVED in P03): Field::Reference#cast as initially shipped in P02 (commit 12b8f5c) had a constant-shadow bug — inside `module TypedEAV; module Field; class Reference`, the bare `Integer` constant resolves to `TypedEAV::Field::Integer` (a Field subclass), not the Ruby Integer class — so `raw.is_a?(Integer)` always returned false and every Integer/String input fell through to the AR-record branch returning [nil, true]. Same hazard with `String`. The `Integer(raw, exception: false)` call form routes through Kernel#Integer (method-call syntax, NOT constant lookup) so it was unaffected. The fix shipped in P03's commit (6ba33cd) anchors both `is_a?` checks to ::Object via leading `::` (`raw.is_a?(::Integer)`, `raw.is_a?(::String)`). P02's commit was NOT amended (per protocol: 'Prefer to create a new commit rather than amending'); the fix lives in P03's commit which also adds the QueryBuilder :references branch — the two changes are inextricable (the cast contract powers the operator dispatch). Inline comment in reference.rb#cast documents the namespace-shadow rationale."
  - "DEVN-01 (minor): P03 plan listed `lib/typed_eav/column_mapping.rb` in files_modified for 'verify or extend; OR Reference declares operators explicitly (preferred)'. Reference declares operators explicitly (the preferred path); column_mapping.rb required NO change — verified via `grep 'references' lib/typed_eav/column_mapping.rb` returning zero matches. Removed from this SUMMARY's files_modified to reflect actual edits."
  - "DEVN-01 (minor): P02 plan suggested `app/models/typed_eav/field/base.rb` in files_modified for 'verify only — likely no change needed' and `app/models/typed_eav/value.rb` for 'verify only'. Both verified, no edits required (Reference's validate_typed_value runs through the existing field.validate_typed_value dispatch wired in plan 05-01). Removed from this SUMMARY's files_modified to reflect actual edits."
  - "DEVN-01 (minor): P01 plan suggested verifying via `cd spec/dummy && bundle exec rails runner '...'` — the dummy app has no bin/rails (it's an engine test rig). Verified via a transient RSpec example (Contact / Product / Project respond_to?(:typed_eav_scope_method) and their typed_eav_scope_method values). Same observation, different tooling."
  - "DEVN-01 (minor): P04 plan-suggested describe shape `RSpec.describe TypedEAV::Field::Reference, '#cast' do` triggered RSpec/DescribeMethod (second arg should be `#instance` or `.class` shape). Renamed to `describe TypedEAV::Field::Reference do` (matches the existing Image/File describe shape at field_spec.rb:422) and field-save validations describe to `'.validations (field-level options)'` matching the Currency / Percentage precedents. Same coverage, RuboCop clean."
  - "DEVN-01 (minor): P04 plan-suggested query_builder spec used `scope: 1` on the reference_field with default-scope-nil source contacts — would fail Phase 1's source-entity scope match validator. Set field scope to nil to match the spec's `contact_a/b/c` (tenant_id: nil) shape; the cross-scope coverage lives in field_spec / value_spec where it's the focus. Same coverage; no test gap."
pre_existing_issues: []
ac_results:
  - criterion: "Phase-start Gating Decision 2 RESOLVED: target_scope SET + target unscoped → field save FAILS with explicit error; target_scope NIL + any target → field saves; target_scope SET + target scoped + target.typed_eav_scope ≠ target_scope → value save FAILS"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb#target_scope_requires_scoped_target + #validate_typed_value; spec/models/typed_eav/field_spec.rb 'Gating Decision 2: target_scope requires a scoped target' 4 examples green; spec/models/typed_eav/value_spec.rb 'with a reference field (target_scope set)' 3 examples green"
  - criterion: "TypedEAV::Field::Reference at app/models/typed_eav/field/reference.rb extends Base, value_column :integer_value, operators :eq/:is_null/:is_not_null/:references"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb lines 64-66; spec/models/typed_eav/field_spec.rb 'Reference has the explicit operator set' green"
  - criterion: "store_accessor :options, :target_entity_type, :target_scope"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb line 68"
  - criterion: "Field-save validations: target_entity_type presence + constantize + target_scope_requires_scoped_target"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb lines 70-72; spec/models/typed_eav/field_spec.rb 'TypedEAV::Field::Reference .validations' describe block — 7 examples green"
  - criterion: "Value-save validation: target_partition_matches? helper enforces target.typed_eav_scope == field.target_scope when set"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb lines 119-145 (validate_typed_value) and 162-172 (target_partition_matches? helper, structurally parallel to Field::Base#entity_partition_axis_matches?); spec/models/typed_eav/value_spec.rb 'with a reference field (target_scope set)' rejects out-of-scope target green"
  - criterion: "Reference#cast: nil → [nil, false]; Integer → [int, false]; numeric String → [int, false]; AR record matching target_entity_type → [record.id, false]; class mismatch → [nil, true]; other → [nil, true]"
    verdict: pass
    evidence: "commits 12b8f5c (initial) + 6ba33cd (Integer/String namespace-shadow fix per DEVN-03); app/models/typed_eav/field/reference.rb#cast lines 87-118; spec/models/typed_eav/field_spec.rb 'TypedEAV::Field::Reference describe' 10 examples green"
  - criterion: ":references operator branch in QueryBuilder.filter casts via field.cast then emits where(integer_value=fk); empty-relation on invalid cast"
    verdict: pass
    evidence: "commit 6ba33cd lib/typed_eav/query_builder.rb new `when :references` branch; spec/lib/typed_eav/query_builder_spec.rb '.filter with reference fields' 4 examples green (Integer FK, AR record, class-mismatch returns base.none, gate rejects on non-Reference)"
  - criterion: "target_partition_matches? helper is private to Field::Reference, structurally parallel to Field::Base#entity_partition_axis_matches?; refactor to shared base helper out of scope"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb lines 162-172 — private helper with inline comment documenting parallel-pattern rationale + Phase 7 ergonomics-pass deferral"
  - criterion: "Config::BUILTIN_FIELD_TYPES gains :reference entry (alphabetic between :percentage and :integer_array; final hash size 22)"
    verdict: pass
    evidence: "commit 12b8f5c lib/typed_eav/config.rb line 70 (`reference: 'TypedEAV::Field::Reference'`); final smoke RSpec example confirms TypedEAV.config.field_types.keys.size == 22 and field_types[:reference] resolves to the class name"
  - criterion: ":reference_field factory matching the existing pattern; default target_entity_type: 'Contact'; no default target_scope"
    verdict: pass
    evidence: "commit 12b8f5c spec/factories/typed_eav.rb lines 165-172"
  - criterion: "spec/dummy has at least one unscoped entity for Gating Decision 2 negative-path testing"
    verdict: pass
    evidence: "Existing Product model (spec/dummy/app/models/test_models.rb line 7) is registered with `has_typed_eav types: [...]` but NO `scope_method:`, so Product.typed_eav_scope_method is nil — the negative-path trigger. P01 verification confirmed via transient RSpec; no migration change needed."
  - criterion: "field_spec.rb gains: column-mapping entry; operators-block entry; cast-block entries; operator_column BC entry; Gating Decision 2 negative + positive tests; nil-safety + operators exhaustive list adds reference_field"
    verdict: pass
    evidence: "commit ce6f92e spec/models/typed_eav/field_spec.rb +101 lines: column mapping (Reference → :integer_value), operator_column BC iteration extended, supported_operators assertion + non-leak guard, cast describe block (10 examples covering all branches), nil-safety exhaustive list adds :reference_field, exhaustive operator block adds Reference, .validations describe with target_entity_type presence/resolution + Gating Decision 2 (4 examples)"
  - criterion: "value_spec.rb gains 'with a reference field' contexts: integer_value FK round-trip + cross-scope rejection + unscoped-target acceptance"
    verdict: pass
    evidence: "commit ce6f92e spec/models/typed_eav/value_spec.rb +76 lines: target_scope nil context (3 examples — FK store, cross-tenant accepted, Integer FK direct) + target_scope set context (3 examples — in-scope accepted, out-of-scope rejected, missing target → :invalid)"
  - criterion: "query_builder_spec.rb gains :references operator dispatch examples: Integer FK + AR record both work; SQL targets integer_value"
    verdict: pass
    evidence: "commit ce6f92e spec/lib/typed_eav/query_builder_spec.rb '.filter with reference fields' 4 examples: Integer FK targets integer_value SQL, AR record returns matching values, class-mismatch returns base.none, operator gate rejects :references on non-Reference"
  - criterion: "ROADMAP §Phase 5 Goal text changed from 'four new field types' to 'five new field types'"
    verdict: pass
    evidence: "commit 6bd087d .vbw-planning/ROADMAP.md line 64; `grep -c 'four new field types' .vbw-planning/ROADMAP.md` returns 0"
  - criterion: "README §Field Types gains Reference bullet + closing summary listing all five Phase 5 types"
    verdict: pass
    evidence: "commit 6bd087d README.md: Field Types table gains Reference row, §'Built-in Phase-5 field types' gains Reference bullet (cast/options/operators/Gating-Decision-2 contracts + canonical query DSL example) + closing 'Phase 5 summary' bullet listing all five types"
  - criterion: "No hardcoded attribute references introduced in QueryBuilder, Value, or Field::Base"
    verdict: pass
    evidence: ":integer_value appears in lib/typed_eav/query_builder.rb only inside :references branch comments (doc-rationale, not code paths). Reference's value_column :integer_value declaration lives in its own field class (legitimate field-class column choice). Reference's target_partition_matches? reads target_record.typed_eav_scope (the public reader, not a hardcoded attribute name)."
  - criterion: "Plan-time decision: :references operator semantics ≡ :eq on integer_value but additionally accept AR records via field.cast"
    verdict: pass
    evidence: "commit 6ba33cd lib/typed_eav/query_builder.rb#filter `when :references` branch routes through field.cast → integer FK → where(integer_value = fk); spec/lib/typed_eav/query_builder_spec.rb '.filter with reference fields' AR-record example green"
  - criterion: "Plan-time decision: target_scope.to_s == target.typed_eav_scope.to_s (type-loose comparison, mirrors Phase 1 entity_partition_axis_matches? pattern)"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb#target_partition_matches? line 171 — `expected_scope.to_s == actual.to_s` with inline comment referencing field/base.rb:664 precedent"
  - criterion: "Plan-time decision: missing target at value-save → errors.add(:value, :invalid) (reuses cast-time invalidation symbol)"
    verdict: pass
    evidence: "commit 12b8f5c app/models/typed_eav/field/reference.rb#validate_typed_value line 138 — `record.errors.add(:value, :invalid)` when target_class.find_by(id: val) is nil"
  - criterion: "frozen_string_literal: true on every new .rb file"
    verdict: pass
    evidence: "head -1 app/models/typed_eav/field/reference.rb shows '# frozen_string_literal: true'; rubocop clean across 85 files"
  - criterion: "Acceptance gate: bundle exec rspec → all examples green; rubocop clean"
    verdict: pass
    evidence: "bundle exec rspec → 820 passed (was 789 at plan start; +31 new examples for plan 05-04). bundle exec rubocop → 85 files, no offenses."
  - criterion: "Phase 1 (scope), Phase 3 (events), Phase 4 (versioning) regression-clean"
    verdict: pass
    evidence: "Full suite passed including spec/lib/typed_eav/scoping_spec.rb, spec/lib/typed_eav/event_dispatcher_spec.rb, spec/lib/typed_eav/versioning/*, spec/models/typed_eav/value_event_spec.rb, spec/models/typed_eav/field_event_spec.rb"
---

Phase 5 plan 04 ships the FIFTH and final Phase 5 field type — `TypedEAV::Field::Reference` — with target-scope validation reusing the Phase 1 partition-matching structural pattern, the new `:references` operator with AR-record-or-Integer-FK ergonomics, and explicit Gating Decision 2 enforcement (target_scope set + unscoped target = field save rejection). Lands the ROADMAP four-vs-five wording fix and the README closing summary listing all five Phase 5 types. After this plan: Phase 5 is complete; BUILTIN_FIELD_TYPES holds 22 entries; ROADMAP and README agree on the type count. Four atomic commits (P01 was no-op verification — Product already satisfies the unscoped-target requirement); 820 examples green (+31 new); RuboCop clean across 85 files.

## What Was Built

- `TypedEAV::Field::Reference` — new STI field type at `app/models/typed_eav/field/reference.rb`. Extends `Field::Base`, declares `value_column :integer_value` (FK as Integer ID — String/UUID FKs are out of scope), narrows operators to `[:eq, :is_null, :is_not_null, :references]` (does NOT inherit `:integer_value`'s default `:gt`/`:lt`/`:between` since arithmetic comparisons on FKs lack semantic meaning). Options via `store_accessor :options, :target_entity_type, :target_scope`. Field-save validations: `target_entity_type` presence + constantize resolution + Gating Decision 2 enforcement. Value-save validation via `validate_typed_value` calls a new `target_partition_matches?` private helper structurally parallel to Phase 1's `Field::Base#entity_partition_axis_matches?` (file/base.rb:654-665) but reading the field's `target_scope` option rather than a `scope`/`parent_scope` class-attribute axis. Refactor to a shared base helper deferred per plan-time decision (Phase 7 ergonomics pass at most).
- `Field::Reference#cast` — accepts nil/blank → `[nil, false]`; Integer → `[int, false]`; numeric String → `[int, false]` (fractional Strings rejected as `[nil, true]` matching `Field::Integer#cast`'s pattern); AR record matching `target_entity_type` → `[record.id, false]`; AR record class mismatch → `[nil, true]`; everything else → `[nil, true]`. The Integer/String constant-shadow bug discovered during P03 dispatch testing (DEVN-03) is fixed via leading-`::` anchoring on the `is_a?` checks (`is_a?(::Integer)`, `is_a?(::String)`); the `Integer(raw, exception: false)` call form is unaffected because method-call syntax routes through `Kernel#Integer` not constant lookup.
- `:references` operator — new `when :references` branch in `QueryBuilder.filter` (lib/typed_eav/query_builder.rb). Casts the value through `field.cast` (normalizes AR record OR Integer ID to FK) then emits `where(integer_value = fk)`. Empty-relation semantics on invalid cast (e.g., class-mismatched record) — `base.none` rather than collapsing to `:is_null` which has different "no FK at all" semantics. The operator is registered ONLY on `Field::Reference`; the operator-validation gate at the top of `#filter` rejects it on every other field type with the canonical descriptive `ArgumentError`.
- Gating Decision 2 enforcement — when `target_scope` is set on a Reference field, the `target_scope_requires_scoped_target` validator fails the field save unless `target_entity_type` is registered with `has_typed_eav scope_method:` (i.e., `target_class.respond_to?(:typed_eav_scope_method) && target_class.typed_eav_scope_method` is non-nil). When `target_scope` is nil, no check fires — the field author is declaring "no cross-scope filtering" (any target type acceptable). Mirrors the existing `field.scope.present?` guard pattern in `Value#validate_field_scope_matches_entity` (value.rb:403-408).
- `BUILTIN_FIELD_TYPES` gains `:reference => "TypedEAV::Field::Reference"` (lib/typed_eav/config.rb). Hash now holds 22 entries (17 pre-Phase-5 + Currency + Percentage + Image + File + Reference). `:reference_field` factory at spec/factories/typed_eav.rb with default `target_entity_type: "Contact"` (no default `target_scope` — tests configure when exercising Gating Decision 2 paths).
- Spec coverage extensions in `field_spec.rb` (+101 lines): column-mapping iteration, operator_column BC iteration, supported_operators assertion + non-leak guard, cast describe block (10 examples covering all branches), nil-safety exhaustive list, exhaustive operator block, `.validations` describe with target_entity_type presence/resolution + Gating Decision 2 (4 examples covering both negative and positive paths). Uses `Product` (the dummy app's pre-existing unscoped target — registered with `has_typed_eav types: [...]` but no `scope_method:`) for the GD2 negative-path triggers.
- Spec coverage extensions in `value_spec.rb` (+76 lines): "with a reference field (target_scope nil)" context — FK round-trip, cross-tenant target accepted, Integer FK direct. "with a reference field (target_scope set)" context — in-scope accepted, out-of-scope rejected with "target's scope does not match" error, missing target FK marked `:invalid`.
- Spec coverage extensions in `query_builder_spec.rb` (+57 lines): `.filter with reference fields` describe block — `:references` with Integer FK targets `integer_value` SQL, `:references` with AR record returns matching values, class-mismatched record returns `base.none` (not a null filter), operator gate rejects `:references` on non-Reference field types.
- ROADMAP §Phase 5 Goal text changed from "four new field types" to "five new field types (Image, File, Reference, Currency, Percentage)" — single-word fix resolving the discrepancy noted in 05-RESEARCH.md §Risk 5 and Recommendation 1. The success criteria block already enumerated five.
- README §"Field Types" table gains a Reference row (`integer_value` FK + `target_entity_type` / `target_scope` options). README §"Built-in Phase-5 field types" gains a Reference bullet documenting cast contract, operator narrowing, options, Gating Decision 2, cross-scope value validation, and canonical query DSL examples (op: :references with both AR record and Integer FK). Closing summary bullet lists all five Phase 5 types and confirms preservation of the cast-tuple contract, operator-dispatch model, and no-hardcoded-attribute-references principle.

## Files Modified

- `app/models/typed_eav/field/reference.rb` -- create: TypedEAV::Field::Reference (integer_value FK, target_entity_type / target_scope options, :references operator narrowing, target-scope value-time validation via target_partition_matches? helper, Gating Decision 2 field-save enforcement)
- `lib/typed_eav/config.rb` -- modify: BUILTIN_FIELD_TYPES gains :reference entry between :percentage and :integer_array
- `lib/typed_eav/query_builder.rb` -- modify: new `when :references` branch in filter case statement (casts via field.cast → integer FK → where(integer_value = fk); empty-relation on invalid cast)
- `spec/factories/typed_eav.rb` -- modify: add :reference_field factory with default target_entity_type: "Contact"
- `spec/models/typed_eav/field_spec.rb` -- modify: column-mapping + operator_column BC + supported-operators iterations extended; new TypedEAV::Field::Reference cast describe block (10 examples); nil-safety + operators-exhaustive lists add :reference_field; new TypedEAV::Field::Reference .validations describe block (target_entity_type presence + resolution + Gating Decision 2 — 7 examples)
- `spec/models/typed_eav/value_spec.rb` -- modify: "with a reference field (target_scope nil)" + "with a reference field (target_scope set)" contexts (6 examples covering round-trip + cross-scope rejection + unscoped-target acceptance + missing-target invalid)
- `spec/lib/typed_eav/query_builder_spec.rb` -- modify: `.filter with reference fields` describe block (4 examples covering Integer FK + AR record dispatch + class-mismatch base.none + operator-gate rejection on non-Reference)
- `.vbw-planning/ROADMAP.md` -- modify: §Phase 5 Goal text "four new field types" → "five new field types (Image, File, Reference, Currency, Percentage)"
- `README.md` -- modify: Field Types table gains Reference row; §"Built-in Phase-5 field types" gains Reference bullet + closing "Phase 5 summary" bullet listing all five Phase 5 types

## Deviations

See frontmatter `deviations:` for the canonical list. P01 produced no commit (verification-only; Product already satisfies the unscoped-target requirement). Five DEVN-01 (minor) items: P01 verification tooling (no bin/rails in dummy app), P02/P03 plan files_modified path adjustments (column_mapping.rb / base.rb / value.rb required no edits — verified-only), P04 RSpec describe shape adjustments to satisfy RSpec/DescribeMethod and field-scope match for query_builder source contacts. ONE DEVN-03 (blocking, RESOLVED in P03's commit): Field::Reference#cast namespace shadow on `Integer` / `String` constants — fixed via leading-`::` anchoring; the cast-tuple contract for Integer/String inputs now works correctly, enabling :references operator dispatch with Integer FKs.
