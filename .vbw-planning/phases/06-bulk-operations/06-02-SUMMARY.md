---
phase: 6
plan: 02
title: Schema export/import (Field.export_schema / Field.import_schema)
status: complete
completed: 2026-05-06
tasks_completed: 3
tasks_total: 3
commit_hashes:
  - c62081f
  - 8cb279e
  - 352247c
files_modified:
  - app/models/typed_eav/field/base.rb
  - spec/models/typed_eav/field_schema_spec.rb
deviations: []
pre_existing_issues: []
ac_results:
  - criterion: "Field::Base.export_schema(entity_type:, scope:, parent_scope:) class method exists; returns a frozen-shape Hash with string keys schema_version=1, entity_type, scope, parent_scope, fields, sections"
    verdict: pass
    evidence: "commit c62081f; spec 'returns a hash with the schema_version envelope and partition keys' + 'exposes exactly the documented top-level keys' (asserts keys.sort == %w[entity_type fields parent_scope schema_version scope sections])"
  - criterion: "Each field entry has exactly: name, type (STI class string), entity_type, scope, parent_scope, required, sort_order, field_dependent, options, default_value_meta; select/multi_select also adds options_data ordered by sort_order"
    verdict: pass
    evidence: "_export_field_entry projection in field/base.rb:481-510; specs 'emits options_data for select fields, ordered by sort_order' + 'does not emit options_data for non-optionable fields' + 'emits the literal STI type column string (not a symbol form)'"
  - criterion: "Each section entry has exactly: name, code, entity_type, scope, parent_scope, sort_order, active"
    verdict: pass
    evidence: "_export_section_entry in field/base.rb:518-528; spec 'exports sections with all the documented keys' asserts keys.sort exactly"
  - criterion: "Export query is partition-tuple-precise (no for_entity widening) — Field::Base.where(entity_type:, scope:, parent_scope:).order(:sort_order); same for Section"
    verdict: pass
    evidence: "field/base.rb:451-459 uses literal where(...) not for_entity; spec 'scopes the query to the exact partition tuple — no leakage' creates rows in t1/t2/global and confirms only t1 returns when scope: 't1' passed"
  - criterion: "Field::Base.import_schema(hash, on_conflict: :error) class method with three policies (:error default, :skip, :overwrite); equality short-circuit applies under any flag"
    verdict: pass
    evidence: "commit 8cb279e; specs under 'equality-no-op short-circuit' confirm result['unchanged'] == fields_count + sections_count and ZERO INSERT/UPDATE/DELETE under each of :error/:skip/:overwrite via sql.active_record subscription"
  - criterion: "Schema-version validation: hash['schema_version'] != 1 raises ArgumentError with 'Unsupported schema_version' + remediation hint about re-export"
    verdict: pass
    evidence: "field/base.rb:564-568; specs 'raises ArgumentError when schema_version is not 1' + 'raises ArgumentError when schema_version key is absent' + 'includes a remediation hint pointing to a re-export'"
  - criterion: "Idempotence keys: (name, entity_type, scope, parent_scope) for fields; (code, entity_type, scope, parent_scope) for sections; (field_id, value) for option rows; equality-no-op rule applies symmetrically"
    verdict: pass
    evidence: "field/base.rb:597-602 + 685-690 use these find_by tuples; section equality test 'section equality short-circuit applies under :error policy' confirms unchanged=1 under :error for a bit-equal section"
  - criterion: "Row-equality helpers: _field_export_row_equal? + _section_export_row_equal? compare via the same projection, excluding timestamps; private class methods"
    verdict: pass
    evidence: "field/base.rb:744-758; declared private_class_method; reuse _export_field_entry / _export_section_entry directly so projection symmetry is enforced by construction"
  - criterion: "STI type-swap: existing.type != incoming['type'] raises ArgumentError UNCONDITIONALLY across all on_conflict values; takes priority over equality short-circuit"
    verdict: pass
    evidence: "field/base.rb:608-614 raises before the equality check; spec 'STI type-swap raise raises ArgumentError under EVERY on_conflict policy' iterates :error/:skip/:overwrite and confirms each raises with the data-loss-guard message"
  - criterion: ":overwrite for select/multi_select with divergent existing row DELETES then RECREATES field_options; :skip leaves options untouched; :error raises before touching options; equality-no-op skips options entirely"
    verdict: pass
    evidence: "field/base.rb:642-656 destroy_all + create! loop under :overwrite branch only; spec 'deletes and recreates field_options for select fields under :overwrite' confirms (new_ids & original_option_ids).empty?; equality short-circuit spec confirms zero DELETE statements against typed_eav_options"
  - criterion: "Import returns Hash with string keys: created, updated, skipped, unchanged, errors (always empty on success); all four counts asserted in specs"
    verdict: pass
    evidence: "field/base.rb:578 declares the result hash; specs assert each count under each branch (round-trip → created=N+sections; equality → unchanged=N; :skip divergent → skipped=1, created=N; :overwrite divergent → updated=1)"
  - criterion: "default_value_meta exported as WHOLE jsonb hash; imported via direct assignment to bypass default_value= re-cast"
    verdict: pass
    evidence: "_export_field_entry includes 'default_value_meta' => field.default_value_meta verbatim; _import_field_entry :overwrite branch uses existing.default_value_meta = entry['default_value_meta']; spec 'emits default_value_meta as the WHOLE jsonb hash' confirms {'v' => 42, 'future_key' => 'preserved'} round-trips"
  - criterion: "options jsonb (per-type configuration) exported and imported as WHOLE hash"
    verdict: pass
    evidence: "_export_field_entry emits 'options' => field.options; :overwrite assigns options: entry['options']; spec 'updates the field's non-key attributes' confirms options round-trip including {'min' => 0, 'max' => 100}"
  - criterion: "Spec coverage at spec/models/typed_eav/field_schema_spec.rb covers every required scenario (empty target round-trip, two-axis partition, equality-no-op under each policy, :error raise, :skip leave-unchanged, :overwrite update, type-swap raise, schema_version raise, options round-trip, section coverage, JSON serialization)"
    verdict: pass
    evidence: "commit 352247c; 30 examples in 11 describe blocks; bundle exec rspec spec/models/typed_eav/field_schema_spec.rb returns 30 passed"
  - criterion: "Implementation lives in app/models/typed_eav/field/base.rb directly — no new file; reuses existing class-level Metrics/ClassLength disable; inline disables on _export_field_entry / _import_field_entry / _import_section_entry justify Metrics/AbcSize and Metrics/MethodLength tolerances"
    verdict: pass
    evidence: "git diff confirms no new files in app/; field/base.rb additions are inside the existing class block; new disables at 481, 595, 683 each carry inline -- justifications per CONVENTIONS.md"
  - criterion: "Foundational principle: NO HARDCODED ATTRIBUTE REFERENCES beyond what AR already exposes; STI subclass resolved via type column string; default_value_meta direct-jsonb"
    verdict: pass
    evidence: "create! path uses entry.except('options_data') so AR resolves the STI subclass; no Config.field_class_for symbol round-trip; default_value_meta is column-direct, not via default_value=; no new attribute introspection introduced"
  - criterion: "frozen_string_literal: true magic comment on every modified .rb file"
    verdict: pass
    evidence: "field/base.rb retains existing magic comment; spec/models/typed_eav/field_schema_spec.rb opens with # frozen_string_literal: true"
  - criterion: "bin/rspec spec/models/typed_eav/field_schema_spec.rb runs green; bin/rspec spec/models/typed_eav/ runs green; bundle exec rubocop on the two files reports no offenses"
    verdict: pass
    evidence: "rspec field_schema_spec.rb: 30 passed; rspec spec/models/typed_eav/: 508 passed; rubocop on the two plan-touched files: 'rubocop (2 files)' clean; full suite (854 specs) green"
  - criterion: "Manual check: Field::Base.export_schema(entity_type: 'Contact').keys.sort == %w[entity_type fields parent_scope schema_version scope sections]"
    verdict: pass
    evidence: "spec 'exposes exactly the documented top-level keys' encodes this exact assertion"
  - criterion: "No N+1 regression: includes(:field_options) preload on the export query"
    verdict: pass
    evidence: "field/base.rb:452 .includes(:field_options) on the field query before .order; in-memory branch in _export_field_entry uses field.field_options.loaded? to avoid per-field reads"
---

Phase 06 plan 02 lands `TypedEAV::Field::Base.export_schema` and `Field::Base.import_schema` as class methods on `Field::Base`. Three tasks, three atomic commits; 30 new specs cover round-trip, conflict policies, equality short-circuit, STI type-swap raise, and schema_version validation. Full suite (854 specs) green, rubocop clean.

## What Was Built

- `Field::Base.export_schema(entity_type:, scope: nil, parent_scope: nil)` — partition-tuple-precise class method that emits a JSON-serializable Hash with `schema_version: 1` envelope, all fields in the partition (preloaded with `field_options`), and all sections in the partition. Each field entry projects exactly `{name, type, entity_type, scope, parent_scope, required, sort_order, field_dependent, options, default_value_meta}`; Select / MultiSelect fields additionally carry `options_data` (an array of `{label, value, sort_order}` ordered by sort_order).
- `Field::Base.import_schema(hash, on_conflict: :error)` — three-policy importer with equality-no-op short-circuit and STI type-swap guard. The whole import runs inside a single AR transaction so any mid-import failure (`:error`-policy collision, type-swap raise, validation failure on `:overwrite`) rolls back ALL prior writes. Returns `{"created", "updated", "skipped", "unchanged", "errors"}` counts.
- Equality-no-op short-circuit: when the existing row matches the incoming entry on the same projection `export_schema` emits (excluding timestamps), the import increments `unchanged` and skips entirely — ZERO AR writes regardless of policy. Verified via `sql.active_record` notification capture in the test suite.
- Type-swap unconditional raise: `existing.type != entry["type"]` raises `ArgumentError` regardless of `on_conflict:` policy, with a data-loss-guard message recommending manual destroy+recreate. Takes priority over the equality short-circuit.
- Section import symmetry: same decision tree (existing? → equality → on_conflict dispatch → create) over the section projection; sections have no nested options to delete-and-recreate.
- `_field_export_row_equal?` / `_section_export_row_equal?` private class methods reuse `_export_field_entry` / `_export_section_entry` for the comparison projection, so equality is symmetric with `export_schema` by construction (no drift risk).

## Files Modified

- `app/models/typed_eav/field/base.rb` -- modify: add `Field::Base.export_schema` + `Field::Base.import_schema` class methods, plus four private class helpers (`_export_field_entry`, `_export_section_entry`, `_import_field_entry`, `_import_section_entry`, `_field_export_row_equal?`, `_section_export_row_equal?`)
- `spec/models/typed_eav/field_schema_spec.rb` -- create: 30 examples covering empty-target round-trip, two-axis partition (Project) round-trip with no leakage, equality-no-op under each `on_conflict:` policy with zero-write assertion, divergent-row dispatch (`:error` raise + transaction rollback, `:skip` leave-unchanged, `:overwrite` update + option delete-and-recreate), STI type-swap raise across all policies, schema_version validation, section round-trip and equality symmetry, JSON serialization safety

## Commits

- `c62081f` feat(field): add Field::Base.export_schema for partition-tuple-precise schema export
- `8cb279e` feat(field): add Field::Base.import_schema with conflict policy + type-swap guard
- `352247c` test(field): cover Field::Base.export_schema / import_schema round-trips

## Deviations

None. The implementation followed the plan must_haves exactly; the rubocop disable directives on `_export_field_entry` (Metrics/AbcSize), `_import_field_entry` (Metrics/MethodLength + Metrics/AbcSize), and `_import_section_entry` (Metrics/MethodLength) all carry inline `--` justifications per CONVENTIONS.md, and the file-level Metrics/ClassLength disable on `Field::Base` already documented in the existing source covers the additional method count.

## Acceptance Criteria

All 20 acceptance criteria pass. See `ac_results` frontmatter for per-criterion evidence.
