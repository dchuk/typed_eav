---
phase: 5
plan: 01
title: Field::Base extension points (read_value, apply_default_to, operator_column) + dispatch wiring
status: complete
completed: 2026-05-06
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 49de75f
  - 8a7f142
  - 224f78d
  - 0753326
  - a5048b7
files_modified:
  - lib/typed_eav/column_mapping.rb
  - app/models/typed_eav/field/base.rb
  - app/models/typed_eav/value.rb
  - lib/typed_eav/query_builder.rb
  - spec/lib/typed_eav/column_mapping_spec.rb
  - spec/lib/typed_eav/query_builder_spec.rb
  - spec/models/typed_eav/field_spec.rb
  - spec/models/typed_eav/value_spec.rb
  - README.md
deviations:
  - "DEVN-01 (minor): plan files_modified listed `spec/lib/typed_eav/field_spec.rb` but the actual codebase location is `spec/models/typed_eav/field_spec.rb` (research §RQ-7 already flagged the path discrepancy in research notes; plan context block restated the colocation but did not update the path). Edited the actual file at `spec/models/typed_eav/field_spec.rb`. No content drift; the BC regression block is exactly as specified."
  - "DEVN-01 (minor): plan-suggested `expect(field).to receive(:read_value).with(value).and_call_original` and `expect_any_instance_of(field.class).to receive(:apply_default_to).and_call_original` patterns conflict with the codebase's `allow + have_received` convention (RSpec/MessageSpies, RSpec/AnyInstance cops). Refactored to `allow(...).to receive(...).and_call_original` + `expect(...).to have_received(...)` matching the precedent in spec/models/typed_eav/field_event_spec.rb and spec/lib/typed_eav/event_dispatcher_spec.rb. Same observation, rubocop clean. The `field` AR association resolves to the same instance passed via `field:` so spying on the local instance captures the dispatch."
  - "DEVN-01 (minor): context wording renamed from `value dispatches through field.read_value` / `apply_field_default dispatches through field.apply_default_to` to `when value reads dispatch through field.read_value` / `when apply_field_default dispatches through field.apply_default_to` to satisfy the codebase's RSpec/ContextWording cop (must start with when/with/without)."
pre_existing_issues: []
ac_results:
  - criterion: "Phase 5 ships FIVE field types (deferred to plans 05-02/03/04); this plan ships only the extension-point infrastructure"
    verdict: pass
    evidence: "no field classes added; only Field::Base, ColumnMapping, Value, QueryBuilder dispatch wiring"
  - criterion: "Field::Base#read_value(value_record) instance method, default returns value_record[self.class.value_column]"
    verdict: pass
    evidence: "commit 8a7f142; app/models/typed_eav/field/base.rb#read_value at line 275"
  - criterion: "Field::Base#apply_default_to(value_record) instance method, default writes value_record[self.class.value_column] = default_value"
    verdict: pass
    evidence: "commit 8a7f142; app/models/typed_eav/field/base.rb#apply_default_to at line 292"
  - criterion: "ColumnMapping.operator_column(operator) class method, default returns value_column"
    verdict: pass
    evidence: "commit 49de75f; lib/typed_eav/column_mapping.rb class method alongside value_column/value_columns/supported_operators"
  - criterion: "QueryBuilder.filter uses field.class.operator_column(operator) AFTER the supported_operators validation gate"
    verdict: pass
    evidence: "commit 0753326; lib/typed_eav/query_builder.rb line 53; new spec example 'validates operator support BEFORE calling operator_column' proves gate-first ordering"
  - criterion: "Value#value reads through field.read_value(self); return nil unless field guard preserved"
    verdict: pass
    evidence: "commit 224f78d; app/models/typed_eav/value.rb#value preserves guard; new spec context 'when value reads dispatch through field.read_value' covers Text/Integer/Boolean and orphan-field paths"
  - criterion: "Value#apply_field_default delegates to field.apply_default_to(self); private visibility unchanged"
    verdict: pass
    evidence: "commit 224f78d; app/models/typed_eav/value.rb#apply_field_default body now `field.apply_default_to(self)`; private section retained"
  - criterion: "Value#value=(val) write path UNCHANGED in this plan (Currency write-side override deferred to 05-02)"
    verdict: pass
    evidence: "diff confirms value= body intact: `casted, invalid = field.cast(val); self[value_column] = casted` retained; value_column private helper at line 106 retained"
  - criterion: "No hardcoded attribute references introduced in QueryBuilder#filter, Value, or new Field::Base methods"
    verdict: pass
    evidence: "grep ':integer_value|:string_value|:decimal_value|:boolean_value' lib/typed_eav/query_builder.rb returns only doc-comment matches outside def filter; new methods route through self.class.value_column"
  - criterion: "BC verification: shared example asserts klass.operator_column(op) == klass.value_column for every supported operator across all 17 built-in types"
    verdict: pass
    evidence: "commit a5048b7; spec/models/typed_eav/field_spec.rb 'Field type operator_column BC across all built-in types' runs 17 contexts (one per built-in) all green"
  - criterion: "Value#value dispatch coverage spec invokes field.read_value via allow+have_received for Text/Integer/Boolean"
    verdict: pass
    evidence: "commit 224f78d; spec/models/typed_eav/value_spec.rb 'when value reads dispatch through field.read_value' three matching examples + orphan-field control"
  - criterion: "Value#apply_field_default dispatch coverage spec invokes field.apply_default_to via allow+have_received"
    verdict: pass
    evidence: "commit 224f78d; spec/models/typed_eav/value_spec.rb 'when apply_field_default dispatches through field.apply_default_to' Text + Integer default cases both green"
  - criterion: "QueryBuilder dispatch coverage spec asserts operator_column returns value_column for Text/Integer/Boolean"
    verdict: pass
    evidence: "commit 0753326; spec/lib/typed_eav/query_builder_spec.rb 'column dispatch through field.class.operator_column' four examples green (three positive types + gate-before-dispatch ordering)"
  - criterion: "frozen_string_literal: true magic comment preserved on every modified .rb file"
    verdict: pass
    evidence: "all 8 modified .rb files retain `# frozen_string_literal: true` line 1; rubocop clean across the suite"
  - criterion: "README §Custom Field Types gains a Multi-cell field types (Phase 5) bullet documenting read_value / apply_default_to / operator_column"
    verdict: pass
    evidence: "commit a5048b7; README.md §'Custom Field Types' subsection 'Multi-cell field types (Phase 5)' lists all three extension-point methods with the canonical Currency example referenced"
  - criterion: "read_value / apply_default_to are INSTANCE methods on Field::Base; operator_column is a CLASS method on ColumnMapping"
    verdict: pass
    evidence: "Field::Base public instance methods (lines 275, 292); ColumnMapping class method via class_methods do block; column_mapping_spec assertion 'is a class method (not instance method)' green"
  - criterion: "Acceptance gate: full bundle exec rspec passes with NO new failures and NO test modifications outside the four listed spec files"
    verdict: pass
    evidence: "bundle exec rspec → 683 passed; only column_mapping_spec/query_builder_spec/field_spec/value_spec touched (the four explicitly allowed); rubocop 79 files clean"
---

Phase 5 plan 01 ships the three Field::Base extension points (read_value, apply_default_to instance methods on Field::Base; operator_column class method on ColumnMapping) plus their consumer-site wiring at Value (read side) and QueryBuilder (column-selection site), preserving BC for all 17 existing built-in field types. Five tasks, five atomic commits, 683 examples green, rubocop clean. No new field classes added; that work lands in plans 05-02 (Currency + Percentage), 05-03 (Image + File), and 05-04 (Reference).

## What Was Built

- `ColumnMapping.operator_column(operator)` class method — defaults to `value_column`. The static dispatch table that lets multi-cell types (Phase 5 Currency) route different operators to different physical columns without QueryBuilder hardcoding column names. Sibling to `value_column` / `value_columns` / `supported_operators`.
- `Field::Base#read_value(value_record)` instance method — defaults to `value_record[self.class.value_column]`. The single read-side surface that resolves Value#value semantics; multi-cell types override to compose a hash from multiple typed columns.
- `Field::Base#apply_default_to(value_record)` instance method — defaults to `value_record[self.class.value_column] = default_value`. Paired with read_value (multi-cell types must override both together — documented in source). Preserves the bypass-Value#value= contract end-to-end (default is already cast at field save time).
- `Value#value` rewired to dispatch through `field.read_value(self)`; `return nil unless field` guard preserved.
- `Value#apply_field_default` delegates to `field.apply_default_to(self)`; private visibility unchanged. Method-level comment updated to reference the dispatch and multi-cell forward-compat.
- `Value#value=(val)` write path INTENTIONALLY UNCHANGED in this plan; the `value_column` private helper at line 106 stays in place. Currency write-side override is deferred to plan 05-02 because no other field type needs it.
- `QueryBuilder.filter` rewired to call `field.class.operator_column(operator)` for column resolution. Column-resolution line moved to AFTER the `supported_operators.include?(operator)` validation gate so an unsupported operator raises ArgumentError before any column dispatch (proven by the `Operator :gt is not supported` regression example).
- BC regression spec — `spec/models/typed_eav/field_spec.rb` adds an exhaustive `operator_column BC across all built-in types` describe block iterating all 17 built-in classes and asserting `klass.operator_column(op) == klass.value_column` for every operator in `klass.supported_operators`. Mirrors the precedent set by `spec/lib/typed_eav/column_mapping_value_columns_spec.rb` (Phase 4's `value_columns` regression).
- Dispatch coverage specs in column_mapping_spec, value_spec, query_builder_spec — six new examples verifying the dispatch is invoked end-to-end for Text/Integer/Boolean representative single-cell types and that the gate-before-dispatch ordering holds.
- README §"Custom Field Types" subsection "Multi-cell field types (Phase 5)" documents the three extension-point methods with the canonical Currency consumer reference. The four-vs-five field-type-count discrepancy in the ROADMAP is intentionally NOT touched here — that touchup lands in plan 05-04 P-final once all five field classes are live.

## Files Modified

- `lib/typed_eav/column_mapping.rb` -- modify: add `operator_column(_operator)` class method (default delegates to `value_column`)
- `app/models/typed_eav/field/base.rb` -- modify: add `read_value(value_record)` and `apply_default_to(value_record)` instance methods with single-cell defaults; documented as paired multi-cell extension points
- `app/models/typed_eav/value.rb` -- modify: rewire `Value#value` to call `field.read_value(self)`; rewire `Value#apply_field_default` to call `field.apply_default_to(self)`; method comments updated; write-side `value=` path unchanged
- `lib/typed_eav/query_builder.rb` -- modify: rewire `filter` to call `field.class.operator_column(operator)` after the validation gate; column-resolution line reordered to run AFTER supported_operators.include? check
- `spec/lib/typed_eav/column_mapping_spec.rb` -- modify: add `.operator_column` describe block (default delegation, class-vs-instance contract, smoke regression for built-ins)
- `spec/lib/typed_eav/query_builder_spec.rb` -- modify: add `column dispatch through field.class.operator_column` describe block (Text/Integer/Boolean dispatch + gate-before-dispatch ordering)
- `spec/models/typed_eav/field_spec.rb` -- modify: add exhaustive `operator_column BC across all built-in types` describe block (17 contexts, one per built-in)
- `spec/models/typed_eav/value_spec.rb` -- modify: add dispatch-coverage describe block for `Value#value` (read_value) and `Value#apply_field_default` (apply_default_to) using allow+have_received pattern
- `README.md` -- modify: add "Multi-cell field types (Phase 5)" subsection under §"Custom Field Types" documenting the three extension-point methods
