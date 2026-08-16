---
phase: 6
plan_count: 5
status: complete
started: 2026-05-07
completed: 2026-05-07
total_tests: 5
passed: 5
skipped: 0
issues: 0
---

UAT for Phase 06 (bulk-operations). Five lightweight checkpoints — one per plan — covering the as-shipped API surface. QA already verified 914 specs pass and contract checks are green; UAT here is the human eyeball pass on developer ergonomics and end-to-end behavior of the new public APIs.

## Tests

### P01-T01: version_group_id column + subscriber injection

- **Plan:** 06-01 -- version_group_id migration + subscriber injection point
- **Scenario:** Migration `db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb` adds a nullable `:uuid` column and the `idx_te_vvs_group` index. Subscriber forwards `context[:version_group_id]` into `ValueVersion.create!` only when the key is present. Open the gem source and skim the migration + `lib/typed_eav/versioning/subscriber.rb` change.
- **Expected:** Migration looks like a clean, additive ALTER following the canonical safety pattern (disable_ddl_transaction! + concurrent index). Subscriber change is the documented one-line `version_group_id: context[:version_group_id]` in the existing `ValueVersion.create!` call. Confidence the foundation is right for Plan 06-05 to layer on.
- **Result:** pass

### P02-T01: Field.export_schema / Field.import_schema developer ergonomics

- **Plan:** 06-02 -- Schema export/import
- **Scenario:** Read the new public API in `app/models/typed_eav/field/base.rb` (look for `def self.export_schema` and `def self.import_schema`) and the spec coverage at `spec/models/typed_eav/field_schema_spec.rb`. Imagine using these from your own Rails app: round-tripping schemas across environments, syncing dev → staging schema, etc.
- **Expected:** API signatures are intuitive (entity_type/scope/parent_scope tuple matches the gem's partition model). Conflict-policy options (`:error|:skip|:replace`) cover the common cases. Type-swap guard and schema-version validation feel reasonable. The 5-key result hash is useful.
- **Result:** pass

### P03-T01: TypedEAV::CSVMapper.row_to_attributes ergonomics

- **Plan:** 06-03 -- CSV mapper
- **Scenario:** Read `lib/typed_eav/csv_mapper.rb` and its spec at `spec/lib/typed_eav/csv_mapper_spec.rb`. Note the dual mode (passthrough vs typed) and the `Result` value object with frozen hashes. Also spot-check that `csv ~> 3.3` is now declared in `typed_eav.gemspec` (the Ruby 3.4 default-gem fix is properly in place).
- **Expected:** Mapper API is ergonomic for the common CSV-import case. Dual-mode signature (`mapping`, `fields_by_name:`) reads naturally. The `Result` shape is sensible. The gemspec dependency on `csv ~> 3.3` is present and `bundle install` resolves cleanly.
- **Result:** pass

### P04-T01: typed_eav_hash_for bulk read

- **Plan:** 06-04 -- Bulk read (Entity.typed_eav_hash_for)
- **Scenario:** Read `ClassQueryMethods.typed_eav_hash_for(records)` in `lib/typed_eav/has_typed_eav.rb` (around line 360). Spec at `spec/models/typed_eav/bulk_read_spec.rb` asserts `≤ 2 + unique_partition_tuples` queries regardless of record count. Mentally walk through calling it on a 100-record Contact relation.
- **Expected:** API name and signature feel right. Returned shape `{record_id => {field_name => value}}` is what you'd want for bulk read. N+1 bound is real (verifiable by glancing at the implementation — partition-grouped lookup, single Value query per partition tuple).
- **Result:** pass

### P05-T01: bulk_set_typed_eav_values + version_grouping integration

- **Plan:** 06-05 -- Bulk write (Entity.bulk_set_typed_eav_values) with version_grouping integration
- **Scenario:** Read `ClassQueryMethods.bulk_set_typed_eav_values` in `lib/typed_eav/has_typed_eav.rb` (around line 536) plus the snapshot mechanism (`Value#pending_version_group_id`) and the subscriber amendment (`value.pending_version_group_id || context[:version_group_id]`). Spec at `spec/lib/typed_eav/bulk_operations_spec.rb` covers `:none`, `:per_record`, `:per_field` modes plus disabled-versioning ArgumentError + atomicity.
- **Expected:** End-to-end story makes sense — outer transaction + per-record savepoints, snapshot lets the after_commit subscriber see the right version_group_id even though `with_context` has unwound. Public API surface (positional records + keyword `version_grouping:`) is ergonomic. The fact that 06-04's `typed_eav_hash_for` and 06-05's `bulk_set_typed_eav_values` coexist cleanly as additive members of `ClassQueryMethods` reads well.
- **Result:** pass

## Summary

- Passed: 5
- Skipped: 0
- Issues: 0
