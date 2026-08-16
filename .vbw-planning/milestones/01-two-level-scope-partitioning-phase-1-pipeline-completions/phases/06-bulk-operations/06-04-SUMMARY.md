---
phase: 6
plan: 04
title: Bulk read (Entity.typed_eav_hash_for)
status: complete
completed: 2026-05-06
tasks_completed: 2
tasks_total: 2
commit_hashes:
  - 136e773
  - e8ea3bd
files_modified:
  - lib/typed_eav/has_typed_eav.rb
  - spec/models/typed_eav/bulk_read_spec.rb
deviations: []
pre_existing_issues: []
ac_results:
  - criterion: "`Entity.typed_eav_hash_for(records)` is a class method on the host model — added to `module ClassQueryMethods` in `lib/typed_eav/has_typed_eav.rb`. Available on every model declaring `has_typed_eav` because `extend ClassQueryMethods` is called inside `has_typed_eav`."
    verdict: pass
    evidence: "commit 136e773; lib/typed_eav/has_typed_eav.rb:360 `def typed_eav_hash_for(records)` is defined inside `module ClassQueryMethods` (opened at line 151). The `extend ClassQueryMethods` call inside `has_typed_eav` (line 132) propagates the method onto every host model. Verified by spec calls `Contact.typed_eav_hash_for(...)`, `Product.typed_eav_hash_for(...)`, and `Project.typed_eav_hash_for(...)` all resolving without method_missing."
  - criterion: "Signature `def typed_eav_hash_for(records)` — single positional argument; returns `{ integer_record_id => { string_field_name => value } }`."
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:360 declares the single positional arg signature. Spec 'returns { record_id => { name => value } } for each record' (bulk_read_spec.rb:69-79) asserts `result == {alice.id => {\"name\" => \"Alice\", \"age\" => 30}, ...}` with integer keys + string field names."
  - criterion: "Empty input → `{}`; nil input → `ArgumentError, 'typed_eav_hash_for requires an Enumerable of records, got nil'`."
    verdict: pass
    evidence: "has_typed_eav.rb:363 raises ArgumentError with the exact message; line 369 `return {} if records.empty?`. Spec 'empty input' (bulk_read_spec.rb:238-242) asserts `Contact.typed_eav_hash_for([]) == {}`. Spec 'nil input' (bulk_read_spec.rb:247-252) asserts `raise_error(ArgumentError, /requires an Enumerable.*got nil/)`."
  - criterion: "Records-of-different-class handling: when classes mix, raise ArgumentError with the documented message shape; STI subclasses pass via covariant `is_a?`."
    verdict: pass
    evidence: "has_typed_eav.rb:377-382 `unless records.all?(self)` then raises ArgumentError listing offending classes. `all?(self)` uses `Class#===` which dispatches to `is_a?` (covariant). Spec 'mixed-class records' (bulk_read_spec.rb:269-277) asserts ArgumentError with /expects records of class Contact/."
  - criterion: "Records-of-wrong-class handling: ANY record failing `is_a?(self)` raises ArgumentError with the same message shape (defensive partition-leak guard)."
    verdict: pass
    evidence: "Same code path as mixed-class — `records.all?(self)` rejects single-class wrong input too. Spec 'wrong-class records' (bulk_read_spec.rb:257-264) asserts `Contact.typed_eav_hash_for([product])` raises ArgumentError with /expects records of class Contact/."
  - criterion: "Single preload query: one query for all values, one query for all fields (preloaded via `includes`). Uses `entity_type: name` (host class name) NOT `records.first.class.name`."
    verdict: pass
    evidence: "has_typed_eav.rb:411-414: `TypedEAV::Value.includes(:field).where(entity_type: name, entity_id: records.map(&:id)).to_a`. The `entity_type: name` form uses the AR class-name string (the receiver of the class method), not `records.first.class.name`, so empty/STI cases are unambiguous. The `includes(:field)` triggers the standard Rails preload as a second query."
  - criterion: "Partition-tuple grouping: records grouped by `[typed_eav_scope, typed_eav_parent_scope]` BEFORE field-definition lookup; one `typed_eav_definitions` call per unique tuple; `HasTypedEAV.definitions_by_name(...)` builds the per-tuple `winning_ids_by_name` map."
    verdict: pass
    evidence: "has_typed_eav.rb:387 `groups = records.group_by { |r| [r.typed_eav_scope, r.typed_eav_parent_scope] }`; lines 394-397 iterate `groups.keys`, call `typed_eav_definitions(scope: s, parent_scope: ps)` once per tuple, and feed through `HasTypedEAV.definitions_by_name(defs).transform_values(&:id)`. Spec 'two-axis Project records' (bulk_read_spec.rb:120-156) seeds a same-name field in a different parent_scope and asserts it does NOT leak into the (tenant_1, ws_1) result."
  - criterion: "Collision-safe value resolution: orphan-skip + winning-id precedence mirrored from instance method `typed_eav_hash` (has_typed_eav.rb:584-606). Skip nil-field rows; when winning_id registered, only matching field_id included; when no winning_id, fall back to first-wins."
    verdict: pass
    evidence: "has_typed_eav.rb:424-444 implements the three-branch logic: line 428 `next unless tv.field` (orphan skip), lines 439-440 `if winning_id ... inner[field_name] = tv.value if effective_id == winning_id`, lines 441-443 fallback `unless inner.key?(field_name)`. Spec 'global+scoped name collision' (bulk_read_spec.rb:175-206) inserts a value attached to the shadowed global field via raw SQL and asserts only the scoped value (99) surfaces, not 11. Spec 'orphan values' (bulk_read_spec.rb:211-233) deletes the field row via raw SQL and asserts the orphan is silently skipped."
  - criterion: "Records with NO values produce `{}` inner hash (not absent), so callers can uniformly index by record.id."
    verdict: pass
    evidence: "has_typed_eav.rb:419-446: `records.each_with_object({}) do |record, result| ... result[record.id] = inner end` — every record always lands a key, even when `values_by_record_id.fetch(record.id, [])` returns `[]`. Spec 'records with no typed values' (bulk_read_spec.rb:161-170) asserts `result == {p1.id => {}}`."
  - criterion: "N+1 enforcement: 2 SQL queries (value preload + field preload via includes) PLUS one `typed_eav_definitions` query per unique partition tuple. Bound is `2 + unique_partition_tuples`, INDEPENDENT of record count."
    verdict: pass
    evidence: "Spec 'N+1 prevention' (bulk_read_spec.rb:325-378) builds 5 contacts across 2 partitions (tenant_1 with 3 records, tenant_2 with 2 records), calls `Contact.typed_eav_hash_for(records)` inside `count_sql_queries`, asserts `queries.size <= (2 + 2) == 4`. Test passes (`bundle exec rspec spec/models/typed_eav/bulk_read_spec.rb` → 12 examples, 0 failures). The bound holds independent of record count: adding more records per tuple cannot increase the query count."
  - criterion: "Phase 7 cache integration NOT in scope. Method ships preload-only; does not call any cache primitive; does not collide with future `with_all_typed_values` scope or `typed_eav_hash_cached` alias."
    verdict: pass
    evidence: "has_typed_eav.rb:351-354 inline rationale comment explicitly cites '06-CONTEXT.md §Open Questions' and confirms 'preload-only; does not call any cache primitive'. The implementation has no reference to `cache_key_for`, `cache_version`, or `Rails.cache`. Method name `typed_eav_hash_for` is distinct from the future Phase 7 surface."
  - criterion: "Spec coverage at `spec/models/typed_eav/bulk_read_spec.rb` covers: single-tenant Contact (scoped), Product (unscoped), Project (two-axis), no-values, collision, orphan, query-count bound, wrong-class, mixed-class, empty, nil, AR Relation."
    verdict: pass
    evidence: "commit e8ea3bd; spec/models/typed_eav/bulk_read_spec.rb has 12 `describe` blocks covering every bullet: 'single-tenant scoped Contact records' (line 48), 'unscoped Product records' (line 85), 'two-axis Project records' (line 120), 'records with no typed values' (line 161), 'global+scoped name collision' (line 175), 'orphan values' (line 211), 'empty input' (line 238), 'nil input' (line 247), 'wrong-class records' (line 257), 'mixed-class records' (line 269), 'AR Relation input' (line 282), 'N+1 prevention' (line 325). `bundle exec rspec spec/models/typed_eav/bulk_read_spec.rb` → 12 passed."
  - criterion: "frozen_string_literal: true on every modified .rb file."
    verdict: pass
    evidence: "lib/typed_eav/has_typed_eav.rb:1 and spec/models/typed_eav/bulk_read_spec.rb:1 both open with `# frozen_string_literal: true`. Rubocop reports clean on both files."
  - criterion: "Foundational principle: NO HARDCODED ATTRIBUTE REFERENCES. All access via `record.typed_eav_scope`, `record.typed_eav_parent_scope`, `value.field.name`. Field definitions resolved at runtime via `typed_eav_definitions(scope:, parent_scope:)`."
    verdict: pass
    evidence: "has_typed_eav.rb:387 reads `r.typed_eav_scope`/`r.typed_eav_parent_scope` (the macro-generated accessors). Line 395 calls `typed_eav_definitions(scope: s, parent_scope: ps)` to resolve definitions per-tuple. Line 430 reads `tv.field.name` (never assumes a hard-coded attribute name). No grep hits for record-class-specific attribute names anywhere in the method body."
  - criterion: "Reuses `HasTypedEAV.definitions_by_name` for collision precedence — parity with instance method `typed_eav_hash`."
    verdict: pass
    evidence: "has_typed_eav.rb:396 `HasTypedEAV.definitions_by_name(defs).transform_values(&:id)` uses the SAME shared helper that `InstanceMethods#typed_eav_defs_by_name` (line 759-761) uses. Single source of truth — class-query path and instance path cannot drift on collision precedence."
  - criterion: "Method-length / metrics inline disable: paired `# rubocop:disable Metrics/...` / `# rubocop:enable ...` with justification per CONVENTIONS.md."
    verdict: pass
    evidence: "The Metrics/* disable at has_typed_eav.rb:185 (which spans `where_typed_eav` through `typed_eav_hash_for`) is referenced by an inline comment at lines 356-359: 'The Metrics/* disables at the top of where_typed_eav (line 185) cover this method too — the partition-tuple grouping + single preload + collision-precedence loop genuinely belong together, same rationale as the where_typed_eav disable.' The matching `# rubocop:enable` lands at line 629 after `typed_eav_attributes=`. `bundle exec rubocop lib/typed_eav/has_typed_eav.rb` reports clean."
  - criterion: "`bin/rspec spec/models/typed_eav/bulk_read_spec.rb` runs green; `bin/rspec spec/models/typed_eav/ spec/lib/typed_eav/` runs green (no regression); `bin/rubocop` reports no offenses."
    verdict: pass
    evidence: "bundle exec rspec spec/models/typed_eav/bulk_read_spec.rb → 12 passed. bundle exec rspec spec/models/typed_eav/ spec/lib/typed_eav/ → 786 passed. bundle exec rubocop lib/typed_eav/has_typed_eav.rb spec/models/typed_eav/bulk_read_spec.rb → clean (2 files)."
---

Phase 06 plan 04 lands `Entity.typed_eav_hash_for(records)` as a class method on `ClassQueryMethods` (extended onto every host model declaring `has_typed_eav`) — the bulk variant of the per-record `InstanceMethods#typed_eav_hash`. Two atomic commits (one feat, one test); 12 new specs cover functional shape (Contact/Product/Project), edge cases (empty/nil/wrong-class/mixed/AR Relation), collision precedence (global+scoped, orphan), and the N+1 query-count bound (`≤ 2 + unique_partition_tuples`); adjacent suite (786 specs) green; rubocop clean.

## What Was Built

- `Entity.typed_eav_hash_for(records)` — class-method bulk-read API in `lib/typed_eav/has_typed_eav.rb` `ClassQueryMethods`. Returns `{ integer_record_id => { string_field_name => value } }`. Single positional argument accepts Array, AR Relation, or any Enumerable. Empty input returns `{}`; nil input raises ArgumentError with recovery hint; wrong-class or mixed-class input raises ArgumentError listing the offending classes. STI subclasses pass via covariant `is_a?`.
- N+1-free preload pattern: one `SELECT typed_eav_values WHERE entity_type=? AND entity_id IN (?)` + one `SELECT typed_eav_fields WHERE id IN (?)` (via `includes(:field)`) + one `SELECT typed_eav_fields WHERE entity_type=? AND scope=? AND parent_scope=?` per unique partition tuple. Total: `2 + unique_partition_tuples` queries, INDEPENDENT of record count. Records grouped by `[typed_eav_scope, typed_eav_parent_scope]` BEFORE field-definition lookup so per-tuple collision precedence applies correctly.
- Reuses `HasTypedEAV.definitions_by_name` for global+scoped name-collision precedence — same source of truth as the instance method `typed_eav_hash`. Orphan-safe (`tv.field` nil rows silently skipped) and winning-id-safe (when a partition has both a global and scoped field with the same name, only the scoped value surfaces). When a definition is deleted while values remain, falls back to first-wins so the hash is not lossy. Phase 7 cache integration deferred per CONTEXT.
- Spec coverage at `spec/models/typed_eav/bulk_read_spec.rb` — 12 `describe` blocks covering single-tenant Contact (scoped), Product (unscoped), two-axis Project (parent_scope partition isolation), records with no values, global+scoped collision (raw INSERT to bypass uniqueness validation), orphan values (raw DELETE on the field row), empty input, nil input, wrong-class, mixed-class, AR Relation input, and an N+1 query-count bound assertion using inline `ActiveSupport::Notifications` subscription filtering SCHEMA / TRANSACTION / CACHE rows.

## Files Modified

- `lib/typed_eav/has_typed_eav.rb` -- added: `def typed_eav_hash_for(records)` in `module ClassQueryMethods` (lines 320-448) — bulk-read API with input validation, partition-tuple grouping, single-shot value preload, per-tuple winning-id resolution, orphan-skip + winning-id precedence loop, and inline rationale block (lines 320-359) explaining query-count bound, partition-tuple grouping rationale, instance-method parity, and Phase 7 deferral. Method covered by the existing Metrics/* paired-disable on `where_typed_eav` (line 185 / line 629) per the inline comment.
- `spec/models/typed_eav/bulk_read_spec.rb` -- new: 379-line spec file with frozen_string_literal magic comment, inline `count_sql_queries` helper, and 12 describe blocks covering the full plan.must_haves matrix. All examples green.
