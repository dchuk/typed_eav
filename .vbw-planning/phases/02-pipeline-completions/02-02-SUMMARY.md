---
phase: 2
plan: 02
title: Display ordering helpers (Field + Section) — partition-aware, partition-row-locked, normalized
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - 58703f4
deviations:
  - "Renamed insert_at parameter from `n` to `position` in both Field::Base and Section. Plan specified `insert_at(n)` literally, but rubocop's Naming/MethodParameterName cop rejects single-letter parameter names. `position` matches acts_as_list's canonical naming, preserves the foundational principle (no attribute-name parameter), and keeps both files byte-equivalent."
  - "Replaced `[[n, 1].max, siblings.size].min - 1` with `position.clamp(1, siblings.size) - 1` in both files. Style/ComparableClamp required this; `Comparable#clamp` is the canonical Ruby idiom and produces identical semantics."
  - "Field-spec ordering describe block uses `RSpec.describe \"TypedEAV::Field::Base ordering helpers\"` (string-only) rather than `RSpec.describe TypedEAV::Field::Base, \"ordering helpers\"`. Avoids RSpec/DescribeMethod (which expects a `#instance` or `.class` second arg) and RSpec/RepeatedExampleGroupDescription against the existing class-level describe blocks at the top of the file. Same testing surface, lint-clean."
  - "Concurrency context renamed from \"partition-level concurrency\" to \"with concurrent moves on the same partition\" to satisfy RSpec/ContextWording (when/with/without prefix)."
pre_existing_issues:
  - "{\"test\": null, \"file\": \"typed_eav.gemspec\", \"error\": \"Layout/HashAlignment offenses on lines 22-26 (5 occurrences in metadata literal). File is not in this plan's task list and the offenses pre-date this commit (last touched in 7d843be chore(rename)!). Out of scope.\"}"
ac_results:
  - criterion: "Field::Base instances expose move_higher, move_lower, move_to_top, move_to_bottom, insert_at(n) public methods"
    verdict: pass
    evidence: "app/models/typed_eav/field/base.rb (commit 58703f4); 13-example ordering describe block green in spec/models/typed_eav/field_spec.rb"
  - criterion: "Section instances expose the same five methods with byte-equivalent semantics (inline-duplicated per Phase 01 precedent)"
    verdict: pass
    evidence: "app/models/typed_eav/section.rb (commit 58703f4); 9-example ordering describe block green in spec/models/typed_eav/section_and_option_spec.rb; diff confirms helper bodies byte-equivalent except for Field's inline rationale comments and the in-memory-sort comment block"
  - criterion: "All move operations are partitioned by (entity_type, scope, parent_scope) — they never cross partitions"
    verdict: pass
    evidence: "Field spec 'partition isolation' examples (scope axis and parent_scope axis); Section spec 'isolates partitions across (entity_type, scope, parent_scope)'"
  - criterion: "Each move runs inside ActiveRecord::Base.transaction; the partition siblings are loaded with `for_entity(...).order(:id).lock(\"FOR UPDATE\").to_a` BEFORE computing the new ordering"
    verdict: pass
    evidence: "reorder_within_partition private helper in field/base.rb and section.rb; Field spec 'SQL emission' example asserts SELECT ... FOR UPDATE on typed_eav_fields"
  - criterion: "Cross-partition moves never block each other (different (entity_type, scope, parent_scope) tuples lock disjoint row sets)"
    verdict: pass
    evidence: "Implicit from for_entity scope: WHERE entity_type/scope/parent_scope filtered before the FOR UPDATE; partition isolation specs prove the row sets are disjoint"
  - criterion: "After every move, sort_order is normalized to consecutive integers 1..N within the partition (no gaps); records with sort_order: nil are positioned after all positioned rows during normalization"
    verdict: pass
    evidence: "normalize_partition_sort_order private helper; Field spec 'nil sort_order normalization' and Section spec 'places nil sort_order rows after positioned rows during normalization'"
  - criterion: "Boundary moves are no-ops, not errors: move_higher on the top item returns without raising; move_lower on the bottom item returns without raising"
    verdict: pass
    evidence: "Field spec 'is a no-op at the top boundary' and 'is a no-op at the bottom boundary'; Section mirror specs"
  - criterion: "insert_at(n) clamps n to [1, partition_count]: insert_at(0) acts as move_to_top; insert_at(999) on a 5-item partition acts as move_to_bottom"
    verdict: pass
    evidence: "Field spec '#insert_at clamps n=0 (and any non-positive value) to position 1' and 'clamps n above the partition size to the last position'; Section spec '#insert_at clamps n to [1, partition_count]'"
  - criterion: "Field.sorted scope (line 70) is unchanged — additive-only API, full BC"
    verdict: pass
    evidence: "git show 58703f4 -- app/models/typed_eav/field/base.rb confirms scope :sorted body unchanged; full RSpec suite (474 examples) green proves no regression"
  - criterion: "Section.sorted scope (line 32) is unchanged — additive-only API, full BC"
    verdict: pass
    evidence: "git show 58703f4 -- app/models/typed_eav/section.rb confirms scope :sorted body unchanged; existing '.sorted scope' test green"
  - criterion: "Foundational principle: helpers take no attribute-name parameter; they operate on the record's own sort_order column"
    verdict: pass
    evidence: "Public method signatures in field/base.rb and section.rb take zero positional args (or 1 numeric position for insert_at); no column-name kwarg or arg"
  - criterion: "Single atomic commit covering both files and both spec files"
    verdict: pass
    evidence: "git log --oneline -1 → 58703f4; git show 58703f4 --stat → exactly 4 files, 598 insertions"
---

Adds inline-duplicated, partition-aware ordering helpers (move_higher / move_lower / move_to_top / move_to_bottom / insert_at) to Field::Base and Section, gated by a partition-level FOR UPDATE row lock acquired in deterministic :id order so concurrent reorders within a partition serialize without deadlocks.

## What Was Built

- Public ordering helpers on Field::Base (move_higher, move_lower, move_to_top, move_to_bottom, insert_at) inserted between the existing scopes and default-value-handling sections; private `reorder_within_partition` and `normalize_partition_sort_order` appended to the existing private block after Plan 02-01's `dispatch_field_dependent`.
- Byte-equivalent mirror of the same helpers on Section (public block placed between `scope :sorted` and `private`; private helpers appended after `validate_parent_scope_invariant`).
- 13-example RSpec ordering block in field_spec.rb covering swap, boundary no-ops, top/bottom relocation, insert_at clamping at both ends, partition isolation across scope and parent_scope, nil-sort_order normalization, SQL emission (SELECT … FOR UPDATE on typed_eav_fields), and a partition-level concurrency test (two threads moving different records in the same partition, with `use_transactional_tests = false` and explicit cleanup, asserts no row lost and sort_order normalized to 1..5).
- 9-example RSpec mirror block in section_and_option_spec.rb confirming the symmetric Section behavior.

## Files Modified

- `app/models/typed_eav/field/base.rb` -- modify: add public ordering helpers and private `reorder_within_partition` + `normalize_partition_sort_order` (135 insertions)
- `app/models/typed_eav/section.rb` -- modify: mirror the same helpers byte-equivalently (88 insertions)
- `spec/models/typed_eav/field_spec.rb` -- modify: append "ordering helpers" describe block with 13 examples including SQL emission and concurrency (255 insertions)
- `spec/models/typed_eav/section_and_option_spec.rb` -- modify: append "ordering helpers" describe block with 9 examples mirroring Field coverage (120 insertions)

## Deviations

See frontmatter `deviations` for the four lint-driven adjustments (parameter name `n` → `position`, manual min/max → `Comparable#clamp`, describe-block string form, context wording). All preserve plan semantics and byte-equivalence between Field and Section. Pre-existing rubocop offenses in `typed_eav.gemspec` (5 Layout/HashAlignment) are unrelated and out of scope (DEVN-05).
