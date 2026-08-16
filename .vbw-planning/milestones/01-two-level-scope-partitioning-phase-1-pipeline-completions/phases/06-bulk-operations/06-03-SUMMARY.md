---
phase: 6
plan: 03
title: CSV mapper (TypedEAV::CSVMapper.row_to_attributes)
status: complete
completed: 2026-05-06
tasks_completed: 3
tasks_total: 3
commit_hashes:
  - f03311b
  - c5a6334
  - 043347b
files_modified:
  - typed_eav.gemspec
  - Gemfile.lock
  - lib/typed_eav.rb
  - lib/typed_eav/csv_mapper.rb
  - spec/lib/typed_eav/csv_mapper_spec.rb
deviations:
  - "DEVN-04 architectural prerequisite: declared `csv` (~> 3.3) as a runtime dependency in typed_eav.gemspec (and Gemfile.lock recorded it). The plan's must_haves stated `csv` was always available in Ruby >= 3.0 with no gemspec change required. Reality: Ruby 3.4 removed `csv` from the default gems list, so under bundler the existing `require \"csv\"` would `LoadError` on Ruby 3.4+. Fix is surgical and additive — one `add_dependency` line. Pinned to `~> 3.3` (the version Rails 8.x already pulls in transitively). Required_ruby_version (`>= 3.1`) is unchanged. Committed as commit f03311b BEFORE the implementation commit so the new module's `require \"csv\"` resolves cleanly at autoload time. Without this dep declaration, `bundle exec rspec spec/lib/typed_eav/csv_mapper_spec.rb` failed with `LoadError: cannot load such file -- csv` on the Ruby 3.4.4 dev environment. The plan author's `csv stdlib always available` assumption was correct at plan-write time but did not hold in the execution environment."
pre_existing_issues: []
ac_results:
  - criterion: "New file lib/typed_eav/csv_mapper.rb defines module TypedEAV::CSVMapper with one public class method self.row_to_attributes(row, mapping, fields_by_name: nil); 2-arg form honors CONTEXT line 13 + ROADMAP §Phase 6; returns TypedEAV::CSVMapper::Result; never raises on per-row errors"
    verdict: pass
    evidence: "commit c5a6334; lib/typed_eav/csv_mapper.rb defines module CSVMapper with self.row_to_attributes(row, mapping, fields_by_name: nil) and returns Result. Specs 'with header-mapped CSV::Row (typed mode)', 'with passthrough mode (2-arg form, no fields_by_name)', and the cast-failure path all confirm the method does not raise on row-level errors."
  - criterion: "TypedEAV::CSVMapper::Result is a simple value object (NOT AR) with attr_reader :attributes, :errors; success? returns errors.empty?; failure? returns !success?; both readers always return frozen Hashes; constructor freezes both Hashes"
    verdict: pass
    evidence: "csv_mapper.rb:60-79 defines Result with attr_reader :attributes, :errors; constructor calls .freeze on both. No AR inheritance — Result is a plain Ruby class. Specs 'Result frozen invariants', 'is success when errors is empty', 'is failure when errors has any entry', 'freezes attributes and errors on construction', and 'exposes attr_readers for attributes and errors' all green."
  - criterion: "Mapping shape: single Hash. String keys map CSV header names to field name symbols/strings; Integer keys map column indexes to field names; mixed String + Integer keys raise ArgumentError"
    verdict: pass
    evidence: "csv_mapper.rb:138-150 validate_mapping_keys! enforces homogeneous String OR Integer keys. Specs 'raises ArgumentError immediately with a remediation message' (typed mode) and 'raises in passthrough mode (2-arg form) too' confirm both code paths raise."
  - criterion: "row accepts CSV::Row (header lookup) OR Array (Integer index lookup); unified read via row[source_key]"
    verdict: pass
    evidence: "csv_mapper.rb:107 uses row[source_key] uniformly. Specs 'with header-mapped CSV::Row (typed mode)' and 'with index-mapped Array (typed mode)' (and their passthrough counterparts) prove both row representations work."
  - criterion: "fields_by_name: keyword argument is OPTIONAL (default nil). Two operating modes: typed-coercion (non-nil) and passthrough (nil). Passthrough has no errors possible; typed mode runs field.cast per cell"
    verdict: pass
    evidence: "csv_mapper.rb:91 default `fields_by_name: nil`. Branch at 119: `if fields_by_name.nil?` → passthrough; else typed. Specs 'with passthrough mode (2-arg form, no fields_by_name)' and 'preserves raw values for index-mapped Array passthrough' confirm passthrough; 'with header-mapped CSV::Row (typed mode)' and 'with cast failure (typed mode)' confirm typed coercion."
  - criterion: "Per-cell coercion (typed mode) goes through field.cast(raw); invalid? == true → errors[name] gets ['is invalid'] appended; otherwise attributes[name] = casted; passthrough mode places raw cell directly with no field.cast invocation"
    verdict: pass
    evidence: "csv_mapper.rb:128-135 implements the cast tuple consumption (calls field.cast, branches on invalid). Spec 'adds is invalid under the field name in errors and marks failure' confirms invalid path; 'casts each cell through field.cast and returns success' confirms valid path; passthrough specs confirm raw_cell is used with no field.cast invocation."
  - criterion: "Result#errors is { 'field_name' => ['error message'] } plain Hash with String field-name keys; matches AR's errors.messages shape"
    verdict: pass
    evidence: "csv_mapper.rb:131 `(errors[name] ||= []) << \"is invalid\"` produces this exact shape. Specs 'aggregates one error entry per failing field' asserts `result.errors == {\"age\" => [\"is invalid\"], \"price\" => [\"is invalid\"]}` and 'adds is invalid under the field name in errors and marks failure' asserts `{\"age\" => [\"is invalid\"]}`."
  - criterion: "Empty cell handling (typed mode): nil and empty string pass through field.cast → [nil, false]; produce attributes[name] = nil and NO error; passthrough mode preserves the raw cell value verbatim"
    verdict: pass
    evidence: "Specs 'treats nil cells as nil with no error', 'treats empty-string cells as nil with no error' (typed mode), and 'preserves nil cell verbatim' (passthrough mode) all green. The implementation makes no special branch for empty cells in typed mode — the field.cast contract handles it."
  - criterion: "Unknown field in mapping (typed mode): mapping value not in fields_by_name → cell SKIPPED (no error, no attribute); passthrough mode: every mapped cell flows through unconditionally"
    verdict: pass
    evidence: "csv_mapper.rb:124-125 `field = fields_by_name[name]; next if field.nil?`. Spec 'silently skips cells whose mapped name has no matching Field' confirms `result.attributes == {\"name\" => \"Alice\"}` (Unknown skipped, no error)."
  - criterion: "Mixed-key mapping raises ArgumentError immediately BEFORE row processing with: 'CSVMapper mapping must use either all String keys (CSV headers) or all Integer keys (column indexes), not both. Got: ...'"
    verdict: pass
    evidence: "csv_mapper.rb:142-149 raises with the exact message structure. Specs 'raises ArgumentError immediately with a remediation message' and 'raises in passthrough mode (2-arg form) too' assert via regex /must use either all String keys.*or all Integer keys/m."
  - criterion: "Add `autoload :CSVMapper` to lib/typed_eav.rb autoload block; placed AFTER EventDispatcher and BEFORE ValueVersion (logical grouping with other lib-level utilities)"
    verdict: pass
    evidence: "commit c5a6334; lib/typed_eav.rb line 19 inserts `autoload :CSVMapper` between `autoload :EventDispatcher` (line 18) and `autoload :ValueVersion` (line 20). Final order: Config, Registry, HasTypedEAV, QueryBuilder, EventDispatcher, CSVMapper, ValueVersion, Versioned, Versioning."
  - criterion: "require \"csv\" is included in lib/typed_eav/csv_mapper.rb at the top (after the magic comment); csv stdlib loaded lazily via the autoload registration"
    verdict: pass
    evidence: "csv_mapper.rb:3 `require \"csv\"`. The file is only parsed when `TypedEAV::CSVMapper` is first const-resolved (autoload in lib/typed_eav.rb). Note: the gemspec also declares `csv (~> 3.3)` as a runtime dependency to make this require resolvable on Ruby 3.4+ where csv was removed from default gems — see Deviations section."
  - criterion: "Spec coverage at spec/lib/typed_eav/csv_mapper_spec.rb covers: header CSV::Row, index Array, empty cell, cast failure, unknown field skip, mixed-key ArgumentError, multiple errors per row, AND 2-arg passthrough mode"
    verdict: pass
    evidence: "commit 043347b; 19 examples in 11 contexts under RSpec.describe TypedEAV::CSVMapper. `bundle exec rspec spec/lib/typed_eav/csv_mapper_spec.rb` returns 19 passed. All bullet points covered: header CSV::Row (typed) ✓, index Array (typed) ✓, passthrough mode (header + index Array) ✓, empty cell (nil + empty string) ✓, cast failure ✓, multiple errors per row ✓, unknown-field-skip ✓, mixed-key ArgumentError (typed + passthrough) ✓, symbol-vs-string mapping value ✓, Result frozen invariants ✓."
  - criterion: "frozen_string_literal: true on lib/typed_eav/csv_mapper.rb and spec/lib/typed_eav/csv_mapper_spec.rb"
    verdict: pass
    evidence: "csv_mapper.rb:1 and csv_mapper_spec.rb:1 both open with `# frozen_string_literal: true`. rubocop on both files: clean."
  - criterion: "Foundational principle: NO HARDCODED ATTRIBUTE REFERENCES. Mapper resolves field metadata via fields_by_name: kwarg supplied by caller; never inspects record attributes; every field touch goes through field.cast"
    verdict: pass
    evidence: "csv_mapper.rb has no reference to any specific record class, no record.partition lookup, no attribute introspection. Every field touch is `field.cast(raw_cell)` (line 128). Specs build Field instances via plain `.new` (no AR persistence), proving the mapper does not require host-record context."
  - criterion: "Module shape: module TypedEAV; module CSVMapper; ...; end; end. Result class is TypedEAV::CSVMapper::Result. Both live in the same file (utility module + value object share a file per CONVENTIONS.md)"
    verdict: pass
    evidence: "csv_mapper.rb:5 `module TypedEAV`, line 53 `module CSVMapper`, line 60 `class Result`. Single file."
  - criterion: "bin/rspec spec/lib/typed_eav/csv_mapper_spec.rb runs green; bin/rspec spec/lib/typed_eav/ runs green; bundle exec rubocop on the three plan-touched files reports no offenses"
    verdict: pass
    evidence: "csv_mapper_spec.rb: 19 passed. spec/lib/typed_eav/: 266 passed. Full suite (873 specs): 873 passed. Rubocop on lib/typed_eav.rb + lib/typed_eav/csv_mapper.rb + spec/lib/typed_eav/csv_mapper_spec.rb + typed_eav.gemspec: clean."
---

Phase 06 plan 03 lands `TypedEAV::CSVMapper.row_to_attributes` as a pure stateless module method on the new `lib/typed_eav/csv_mapper.rb`, registered for autoload in `lib/typed_eav.rb`. Three plan tasks, three atomic commits (plus one DEVN-04 prereq commit for the `csv` runtime dependency); 19 new specs cover both passthrough and typed-coercion modes, full suite (873 specs) green, rubocop clean.

## What Was Built

- `TypedEAV::CSVMapper.row_to_attributes(row, mapping, fields_by_name: nil)` — pure stateless single-row transform with two operating modes. Passthrough (2-arg form, honors CONTEXT line 13 + ROADMAP §Phase 6 public surface): raw cell values flow through verbatim; no coercion; no errors possible. Typed (3-arg form): per-cell `field.cast(raw)` via the existing `[casted, invalid?]` tuple contract; cast failures land in `Result#errors` keyed by string field name with the AR-symmetric `"is invalid"` message; never raises on row-level errors.
- `TypedEAV::CSVMapper::Result` value object — plain Ruby class (NOT AR), `attr_reader :attributes, :errors`; both Hashes are frozen on construction; `success?` is `errors.empty?`, `failure?` is `!success?`. No mutation API by design.
- Mapping-shape validation up front: single Hash with all-String keys (CSV headers) OR all-Integer keys (column indexes). Mixed-key mappings raise `ArgumentError` immediately BEFORE any row processing, with a remediation message per CONVENTIONS.md error-message convention.
- Foundational principle honored: NO HARDCODED ATTRIBUTE REFERENCES. The mapper has no record context — `fields_by_name:` is supplied by the caller, every cell touch goes through `field.cast`, and the field name is string-coerced to match the codebase convention. Mapping values may be Symbol or String; both are equivalent.
- Unknown field in mapping (typed mode) is silently skipped — the mapper is a pure transform, mapping misconfiguration is a caller concern. Documented in inline comments and the spec.
- Autoload registration: `autoload :CSVMapper` placed between `EventDispatcher` and `ValueVersion` in the existing `lib/typed_eav.rb` autoload block (logical grouping per RESEARCH §CSV mapper Anchor 4). Lazy-loaded — `require "csv"` only fires when `TypedEAV::CSVMapper` is first const-resolved.

## Files Modified

- `typed_eav.gemspec` -- modify: declare `csv (~> 3.3)` as a runtime dependency to keep the gem usable on Ruby 3.4+ where `csv` was removed from default gems (DEVN-04 prereq; see Deviations)
- `Gemfile.lock` -- modify: bundler-recorded csv 3.3.5 lock entry from the gemspec change
- `lib/typed_eav.rb` -- modify: add `autoload :CSVMapper` to the existing autoload block between `EventDispatcher` and `ValueVersion`
- `lib/typed_eav/csv_mapper.rb` -- create: `TypedEAV::CSVMapper` module with `Result` value object and the `self.row_to_attributes` class method (dual-mode)
- `spec/lib/typed_eav/csv_mapper_spec.rb` -- create: 19 examples across 11 contexts covering header-mapped CSV::Row + index-mapped Array (both modes), empty cell handling, cast failure, multiple errors per row, unknown field skip, mixed-key ArgumentError, symbol-vs-string mapping value coercion, frozen-Result invariants, and Result predicate semantics

## Commits

- `f03311b` chore(deps): declare csv as runtime dependency
- `c5a6334` feat(csv): add TypedEAV::CSVMapper.row_to_attributes (dual-mode)
- `043347b` test(csv): cover TypedEAV::CSVMapper.row_to_attributes contract

## Deviations

DEVN-04 architectural prerequisite: declared `csv (~> 3.3)` as a runtime dependency in `typed_eav.gemspec` (one new `add_dependency` line) plus the corresponding `Gemfile.lock` entry. The plan's must_haves explicitly stated "no gemspec change" based on the assumption that the `csv` stdlib was always available in Ruby >= 3.0. That assumption was correct at plan-write time but does not hold in Ruby 3.4+ where `csv` was removed from default gems — under bundler, `require "csv"` raises `LoadError` even though the stdlib file is present on disk. The dev environment runs Ruby 3.4.4, so this was a real, blocking gap. The fix is surgical and additive (no Ruby version constraint change; `required_ruby_version` stays `>= 3.1`); it was committed BEFORE the implementation commit so the new `lib/typed_eav/csv_mapper.rb`'s `require "csv"` resolves cleanly at autoload time. Pinned to `~> 3.3` to match the version Rails 8.x already pulls in transitively and to keep the dependency window narrow.

## Acceptance Criteria

All 17 acceptance criteria pass. See `ac_results` frontmatter for per-criterion evidence.
