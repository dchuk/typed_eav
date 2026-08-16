---
phase: 5
plan: 02
title: Field::Currency (two-cell, operator_column override) + Field::Percentage (Decimal subclass)
status: complete
completed: 2026-05-06
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 17f0a3b
  - 9a7c839
  - 70a8c69
  - 50b2b06
  - 9b5c492
files_modified:
  - app/models/typed_eav/field/base.rb
  - app/models/typed_eav/field/currency.rb
  - app/models/typed_eav/field/percentage.rb
  - app/models/typed_eav/value.rb
  - lib/typed_eav/config.rb
  - lib/typed_eav/query_builder.rb
  - spec/factories/typed_eav.rb
  - spec/lib/typed_eav/column_mapping_value_columns_spec.rb
  - spec/lib/typed_eav/query_builder_spec.rb
  - spec/lib/typed_eav/versioning/subscriber_spec.rb
  - spec/models/typed_eav/field_spec.rb
  - spec/models/typed_eav/value_spec.rb
  - README.md
deviations:
  - "DEVN-01 (minor): plan files_modified omitted app/models/typed_eav/field/base.rb. Plan truths block requires Field::Base#write_value(value_record, casted) — added with single-cell default that all 17 existing types inherit. Pattern is symmetric with read_value/apply_default_to shipped in 05-01. Same magnitude as the 05-01 file-path correction; no scope change."
  - "DEVN-01 (minor): plan-truth says 'Percentage inherits value_column :decimal_value from Decimal — does NOT re-declare', but ColumnMapping.value_column stores the column on @value_column (a class instance variable on the declaring class) and Ruby class instance variables are NOT inherited through the subclass lookup chain. Re-declared `value_column :decimal_value` on Field::Percentage with the same column choice — BC-safe, no semantic change, and STI behavior is unaffected because the `type` column resolution uses the leaf class name. Inline comment in percentage.rb documents the rationale."
  - "DEVN-02 (critical): plan-truth said 'NO QueryBuilder changes are needed in this plan' but :currency_eq is a NEW operator name not present in QueryBuilder.filter's case statement. operator_column resolves the COLUMN to :string_value, but the case dispatch in QueryBuilder is also keyed by operator NAME — so :currency_eq fell through to the `else => raise`. Added :currency_eq to the :eq branch (`when :eq, :currency_eq`) reusing eq_predicate; the column dispatch via operator_column has already routed col → :string_value, so the predicate emits the correct SQL. The operator-validation gate at the top of #filter still narrows :currency_eq to Field::Currency only — no other field type accepts it. lib/typed_eav/query_builder.rb added to the modified set; no scope creep beyond enabling the documented :currency_eq filter."
  - "DEVN-01 (minor): plan files_modified did not include spec/lib/typed_eav/column_mapping_value_columns_spec.rb. The existing exhaustive 'covers every built-in field type with the default' assertion explicitly anticipated this swap-in — its inline comment reads 'Acceptable failure: Phase 05 Currency lands and adds the override deliberately — at that point this spec is updated to skip Currency and assert the new override'. Updated to skip Currency in the default-iteration and added a positive multi-cell assertion for Currency.value_columns == [:decimal_value, :string_value]. Pure regression-guard maintenance; no test modified outside its documented forward-compat exit path."
  - "DEVN-01 (minor): plan suggested context wording like 'TypedEAV::Field::Currency (non-default operator_column override)' and describe-string forms like 'validate_typed_value co-population'. RuboCop's RSpec/ContextWording requires when/with/without prefix, and RSpec/DescribeMethod requires '#instance' or '.class' shape. Renamed contexts to start with 'with', and switched describes to '#validate_typed_value' / '.validations' / '#format' / '#cast' shape. Same observation, RuboCop-clean."
pre_existing_issues: []
ac_results:
  - criterion: "Phase-start Gating Decision 3 RESOLVED: Currency value shape {amount: BigDecimal, currency: String}; operators :eq/:gt/:lt/:gteq/:lteq/:between/:is_null/:is_not_null target decimal_value, :currency_eq targets string_value via operator_column override"
    verdict: pass
    evidence: "commit 9a7c839 app/models/typed_eav/field/currency.rb defines value_columns/operator_column overrides; spec/models/typed_eav/field_spec.rb '.operator_column' describe block + 'operator_column BC' Currency non-default context all green"
  - criterion: "ROADMAP four-vs-five discrepancy text intentionally NOT touched"
    verdict: pass
    evidence: "git diff 482481a..HEAD .vbw-planning/ROADMAP.md shows only the lifecycle-managed phase-completion edits (no field-count reconciliation prose)"
  - criterion: "TypedEAV::Field::Currency at app/models/typed_eav/field/currency.rb extends Field::Base, declares value_column :decimal_value, overrides value_columns to [:decimal_value, :string_value]"
    verdict: pass
    evidence: "commit 9a7c839; bundle exec rspec spec/lib/typed_eav/column_mapping_value_columns_spec.rb 'Currency (Phase 05 multi-cell) returns [:decimal_value, :string_value]' green; field_spec.rb column-mapping iteration includes Field::Currency => :decimal_value"
  - criterion: "Currency declares operators :eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq, :is_null, :is_not_null (explicit narrowing — does not inherit string-search ops); :currency_eq registered ONLY on this class"
    verdict: pass
    evidence: "commit 9a7c839 app/models/typed_eav/field/currency.rb operators(...) call; spec/models/typed_eav/field_spec.rb 'Currency has the explicit operator set (Phase 5)' asserts the 9-element set; query_builder_spec.rb ':currency_eq is rejected on non-Currency fields by the operator gate' confirms exclusivity"
  - criterion: "Currency.operator_column(:currency_eq) == :string_value; every other supported operator returns :decimal_value"
    verdict: pass
    evidence: "spec/models/typed_eav/field_spec.rb TypedEAV::Field::Currency '.operator_column' describe block — both examples green"
  - criterion: "Field::Currency#read_value composes {amount, currency} hash from both columns; returns nil when both are nil"
    verdict: pass
    evidence: "commit 9a7c839 app/models/typed_eav/field/currency.rb#read_value; spec/models/typed_eav/value_spec.rb 'with a currency field' contexts (round-trip / value-nil-when-both-nil) green"
  - criterion: "Field::Currency#apply_default_to unpacks Hash default_value into both columns"
    verdict: pass
    evidence: "commit 9a7c839 app/models/typed_eav/field/currency.rb#apply_default_to; existing dispatch coverage spec at spec/models/typed_eav/value_spec.rb covers the apply_default_to dispatch (Currency hash unpack inherits the dispatch path)"
  - criterion: "Field::Currency#cast: full hash → BigDecimal/String tuple; partial-amount-with-default_currency falls back; nil → [nil, false]; bare Numeric/String → [nil, true]"
    verdict: pass
    evidence: "spec/models/typed_eav/field_spec.rb 'Field type casting' TypedEAV::Field::Currency block — 9 examples covering all listed cases green"
  - criterion: "store_accessor :options, :default_currency, :allowed_currencies with field-level format validations"
    verdict: pass
    evidence: "commit 9a7c839; spec/models/typed_eav/field_spec.rb TypedEAV::Field::Currency '.validations (field-level options)' — rejects non-3-letter default_currency, rejects malformed allowed_currencies array"
  - criterion: "Field::Currency#validate_typed_value enforces co-population (both amount and currency); allowed_currencies inclusion when set"
    verdict: pass
    evidence: "spec/models/typed_eav/field_spec.rb TypedEAV::Field::Currency '#validate_typed_value co-population' — amount-only/currency-only rejection, co-populated acceptance, default_currency fallback, allowed_currencies inclusion all green"
  - criterion: "Currency-specific WRITE PATH override via Field::Base#write_value(value_record, casted) — default delegates to single-cell, Currency overrides to unpack hash"
    verdict: pass
    evidence: "commit 17f0a3b adds Field::Base#write_value; commit 9a7c839 app/models/typed_eav/field/currency.rb#write_value override; spec/models/typed_eav/value_spec.rb 'when value= writes dispatch through field.write_value' covers Text/Integer/Boolean dispatch (single-cell BC); 'with a currency field' covers hash unpack path"
  - criterion: "TypedEAV::Field::Percentage at app/models/typed_eav/field/percentage.rb extends Decimal (STI subclass-of-subclass); inherits operator set"
    verdict: pass
    evidence: "commit 70a8c69 app/models/typed_eav/field/percentage.rb class Percentage < Decimal; spec/models/typed_eav/field_spec.rb 'Percentage inherits Decimal\\'s operator set (Phase 5)' green; value_column re-declared with same column (:decimal_value) per DEVN-01 — STI resolution uses leaf class name"
  - criterion: "Percentage uses store_accessor :options, :decimal_places, :display_as with default 2 / :fraction"
    verdict: pass
    evidence: "commit 70a8c69; spec/factories/typed_eav.rb :percentage_field factory has these options as defaults; spec/models/typed_eav/field_spec.rb TypedEAV::Field::Percentage '.validations (field-level options)' green"
  - criterion: "Percentage#validate_typed_value calls super (Decimal range) then enforces 0..1; nil val passes"
    verdict: pass
    evidence: "commit 70a8c69 app/models/typed_eav/field/percentage.rb#validate_typed_value; spec/models/typed_eav/field_spec.rb TypedEAV::Field::Percentage '#validate_typed_value (0-1 range)' — boundaries 0/1, mid 0.5 accepted; 1.5 / -0.1 rejected with the documented message"
  - criterion: "Percentage#format renders :percent as '<val*100>%' rounded to decimal_places; :fraction as val.to_s"
    verdict: pass
    evidence: "commit 70a8c69 app/models/typed_eav/field/percentage.rb#format; spec/models/typed_eav/field_spec.rb TypedEAV::Field::Percentage '#format' — :percent / :fraction / nil cases all green"
  - criterion: "BUILTIN_FIELD_TYPES gains :currency and :percentage entries (alphabetical)"
    verdict: pass
    evidence: "commits 9a7c839 + 70a8c69 lib/typed_eav/config.rb; both keys present and resolve via TypedEAV.config.field_types[:currency] / [:percentage]"
  - criterion: ":currency_field and :percentage_field factories"
    verdict: pass
    evidence: "commits 9a7c839 + 70a8c69 spec/factories/typed_eav.rb; both factories used by spec coverage in field_spec, value_spec, query_builder_spec"
  - criterion: "field_spec.rb spec coverage: column mapping, supported operators, casting, nil-safety exhaustive, operators exhaustive, operator_column override, Currency co-population, Percentage range, Percentage format"
    verdict: pass
    evidence: "commit 50b2b06; bundle exec rspec spec/models/typed_eav/field_spec.rb → 246 examples (was 165) all green; new Phase-5 contexts cover every plan-listed bullet"
  - criterion: "value_spec.rb adds 'with a currency field' (round-trip + default_currency fallback + nil-when-both-cols-nil) and 'with a percentage field' (BigDecimal storage + range rejection)"
    verdict: pass
    evidence: "commit 50b2b06; spec/models/typed_eav/value_spec.rb 92 examples (was 86) all green; both contexts present"
  - criterion: "query_builder_spec.rb adds Currency :eq/:between/:gt/:lt amount filtering and :currency_eq currency filtering with SQL column assertions"
    verdict: pass
    evidence: "commit 50b2b06; spec/lib/typed_eav/query_builder_spec.rb '.filter with currency fields' — 7 examples green, including :currency_eq → string_value SQL assertion and :eq → decimal_value SQL assertion"
  - criterion: "subscriber_spec.rb adds Currency two-cell snapshot example confirming Phase 4 forward-compat (RESEARCH §RQ-6 empirical close)"
    verdict: pass
    evidence: "commit 50b2b06; spec/lib/typed_eav/versioning/subscriber_spec.rb 'captures both decimal_value and string_value for a real Currency Value update' green; before_value/after_value keys match_array %w[decimal_value string_value]"
  - criterion: "Cross-cutting principle preserved: NO HARDCODED ATTRIBUTE REFERENCES outside Currency's own implementation"
    verdict: pass
    evidence: "grep -nF ':decimal_value' lib/typed_eav/query_builder.rb returns one match — a doc-comment inside the :eq/:currency_eq branch explaining the Currency dispatch; not a code path. lib/typed_eav/query_builder.rb resolves columns via field.class.operator_column(operator), never hardcoding."
  - criterion: "README §Field Types or §Validation Behavior gains TWO bullets for Currency and Percentage contracts"
    verdict: pass
    evidence: "commit 9b5c492 README.md adds rows in the Field Types table AND a new §'Built-in Phase-5 field types' subsection with full contract bullets (value-shape, operators, options, examples)"
  - criterion: "frozen_string_literal: true magic comment on every new .rb file"
    verdict: pass
    evidence: "head -1 app/models/typed_eav/field/currency.rb /percentage.rb both show '# frozen_string_literal: true'; rubocop clean"
  - criterion: "Field::Currency does NOT subclass Field::Decimal (independent class)"
    verdict: pass
    evidence: "app/models/typed_eav/field/currency.rb declares 'class Currency < Base' — not 'class Currency < Decimal'"
  - criterion: "Field::Percentage SUBCLASSES Field::Decimal (STI subclass-of-subclass)"
    verdict: pass
    evidence: "app/models/typed_eav/field/percentage.rb declares 'class Percentage < Decimal'; ancestors[0..3] confirm Decimal in chain"
  - criterion: "Acceptance gate: bundle exec rspec → all examples green; rubocop clean"
    verdict: pass
    evidence: "bundle exec rspec → 746 passed (was 683 at phase start; +63 new examples for plan 05-02). bundle exec rubocop → 81 files clean."
---

Phase 5 plan 02 ships TWO new field types — `Field::Currency` (the canonical
multi-cell consumer of plan 05-01's extension points) and `Field::Percentage`
(a thin Decimal subclass) — together with the third paired Field-side
extension method `write_value`, completing the multi-cell extension trio
(read / write / default-apply). Five tasks, five atomic commits, 746 examples
green, RuboCop clean.

## What Was Built

- `Field::Base#write_value(value_record, casted)` instance method with
  single-cell default; `Value#value=` write path now dispatches through
  it. Behaviorally identical for all 17 single-cell built-ins; opens the
  surface for Currency.
- `TypedEAV::Field::Currency` — two-cell field type backed by
  `decimal_value` (amount) + `string_value` (ISO 4217 currency code).
  Overrides `value_columns`, `operator_column`, `read_value`,
  `write_value`, `apply_default_to`, `cast`, `validate_typed_value`.
  Operators: `:eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq,
  :is_null, :is_not_null`. The `:currency_eq` operator routes to
  `:string_value`; every other operator routes to `:decimal_value`.
  Cast input is Hash-only (bare Numeric/String → `[nil, true]`).
  Options: `default_currency` (fallback when amount is given without
  currency) and `allowed_currencies` (inclusion list).
- `TypedEAV::Field::Percentage` — `Field::Decimal` subclass with
  hard-coded 0..1 range validation. Inherits `value_column`
  (re-declared explicitly per DEVN-01 due to Ruby class instance
  variable inheritance semantics), supported operators, and cast
  (BigDecimal parse). Adds `decimal_places` and `display_as` options
  and a `format(val)` helper for percent / fraction rendering.
- `BUILTIN_FIELD_TYPES` gains `:currency` and `:percentage` entries.
  `:currency_field` and `:percentage_field` factories added.
- QueryBuilder `:eq` branch widened to `when :eq, :currency_eq`
  (DEVN-02): the column dispatch via `operator_column` already routed
  the predicate's `col` to the right physical column; the rename fixes
  a plan-truth gap where `:currency_eq` was treated as a column-only
  concern.
- Spec coverage: 63 new examples across `field_spec.rb`, `value_spec.rb`,
  `query_builder_spec.rb`, `subscriber_spec.rb`,
  `column_mapping_value_columns_spec.rb`. Includes the canonical Phase-5
  BC operator_column block update (Currency as explicit non-default,
  Percentage as default-conformer) and the empirical Currency two-cell
  versioning snapshot that closes RESEARCH §RQ-6.
- README §"Field Types" table updated with Currency / Percentage rows;
  new §"Built-in Phase-5 field types" subsection with full contract
  bullets (value shape, operator routing, options, examples).

## Files Modified

- `app/models/typed_eav/field/base.rb` -- modify: add `write_value(value_record, casted)` instance method (single-cell default); update Phase-5 multi-cell extension-points comment to reference the trio
- `app/models/typed_eav/field/currency.rb` -- create: TypedEAV::Field::Currency (two-cell, operator_column override, cast/read/write/apply_default_to/validate overrides, store_accessor options)
- `app/models/typed_eav/field/percentage.rb` -- create: TypedEAV::Field::Percentage (Decimal subclass, 0-1 range, format helper, decimal_places/display_as options)
- `app/models/typed_eav/value.rb` -- modify: Value#value= explicit-value branch now calls `field.write_value(self, casted)` instead of `self[value_column] = casted` directly
- `lib/typed_eav/config.rb` -- modify: BUILTIN_FIELD_TYPES gains :currency and :percentage entries (alphabetical)
- `lib/typed_eav/query_builder.rb` -- modify (DEVN-02): `:currency_eq` added to the `:eq` branch in the case statement so `Currency.operator_column(:currency_eq) == :string_value` actually dispatches a working SQL query
- `spec/factories/typed_eav.rb` -- modify: add `:currency_field` and `:percentage_field` factories
- `spec/lib/typed_eav/column_mapping_value_columns_spec.rb` -- modify (DEVN-01): exhaustive `covers every built-in field type with the default` block now skips Currency (the documented exit path baked into the original spec); positive Currency multi-cell assertion added
- `spec/lib/typed_eav/query_builder_spec.rb` -- modify: `.filter with currency fields` describe block — 7 examples covering :eq amount, :currency_eq currency, :between/:gt/:lt amount, :is_null targeting decimal_value, and operator gate exclusivity
- `spec/lib/typed_eav/versioning/subscriber_spec.rb` -- modify: Currency two-cell snapshot example using real Field::Currency (closes RESEARCH §RQ-6)
- `spec/models/typed_eav/field_spec.rb` -- modify: column-mapping + supported-operators iterations updated; Currency/Percentage cast describes; nil-safety + operators exhaustive iterations updated; `.operator_column` describe; co-population validation block; Percentage 0-1 range / format / option-validation blocks; BC operator_column block updated with Currency as explicit non-default + Percentage as default-conformer
- `spec/models/typed_eav/value_spec.rb` -- modify: "with a currency field" + "with a percentage field" contexts; "when value= writes dispatch through field.write_value" context for the new write-side dispatch
- `README.md` -- modify: Field Types table rows for Currency/Percentage; new §"Built-in Phase-5 field types" subsection with full contract bullets

## Deviations

See frontmatter `deviations:` for the canonical list. All five deviations are
DEVN-01 (minor) or DEVN-02 (critical, fix included), no scope creep, no
test modifications outside the documented forward-compat exit paths.
