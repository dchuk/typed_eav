---
phase: 1
plan: "01"
title: "Migration — add parent_scope column and triple-aware indexes"
status: complete
completed: 2026-04-29
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 5ff7c30
deviations:
  - "DEVN-01 (minor): migration class name corrected from plan-suggested AddParentScopeToTypedEavPartitions to AddParentScopeToTypedEAVPartitions to match the EAV acronym registered in lib/typed_eav.rb. Without the acronym-aware spelling Rails' String#constantize on the file basename raises uninitialized-constant during load. Inline fix; not architectural."
  - "DEVN-01 (minor): commit subject changed from plan-literal `db(migration): ...` to `feat(migration): ...` because the project commit-message hook only accepts feat|fix|test|refactor|perf|docs|style|chore as the type token. The commit body, scope (`migration`), and intent are unchanged."
pre_existing_issues: []
ac_results:
  - criterion: "typed_eav_fields.parent_scope column exists, type=string, nullable"
    verdict: pass
    evidence: "psql information_schema.columns: parent_scope | character varying | YES"
  - criterion: "typed_eav_sections.parent_scope column exists, type=string, nullable"
    verdict: pass
    evidence: "psql information_schema.columns: parent_scope | character varying | YES"
  - criterion: "Old indexes idx_te_fields_unique_scoped, idx_te_fields_unique_global, idx_te_sections_unique_scoped, idx_te_sections_unique_global, idx_te_fields_lookup are dropped"
    verdict: pass
    evidence: "pg_indexes after migrate: none of the five legacy index names appear; rollback restores them verbatim"
  - criterion: "New triple-partial unique indexes for fields: idx_te_fields_uniq_scoped_full, idx_te_fields_uniq_scoped_only, idx_te_fields_uniq_global all exist with correct WHERE predicates"
    verdict: pass
    evidence: "pg_indexes shows all three with WHERE clauses: scope IS NOT NULL AND parent_scope IS NOT NULL / scope IS NOT NULL AND parent_scope IS NULL / scope IS NULL"
  - criterion: "New triple-partial unique indexes for sections: idx_te_sections_uniq_scoped_full, idx_te_sections_uniq_scoped_only, idx_te_sections_uniq_global all exist with correct WHERE predicates"
    verdict: pass
    evidence: "pg_indexes shows all three with WHERE clauses matching the fields shape"
  - criterion: "Six paired-partial unique indexes total (3 per table); _scoped_only variant defends against Postgres NULL-distinct semantics"
    verdict: pass
    evidence: "Direct SQL INSERT bypassing the model validator: second row with (entity_type='X', name='f', scope='t1', parent_scope=NULL) raised ActiveRecord::RecordNotUnique against idx_te_fields_uniq_scoped_only"
  - criterion: "idx_te_fields_lookup recreated with columns entity_type, scope, parent_scope, sort_order, name"
    verdict: pass
    evidence: "pg_indexes: btree (entity_type, scope, parent_scope, sort_order, name)"
  - criterion: "New idx_te_sections_lookup created with columns entity_type, scope, parent_scope, sort_order, name (parity with fields)"
    verdict: pass
    evidence: "pg_indexes: btree (entity_type, scope, parent_scope, sort_order, name)"
  - criterion: "Migration uses disable_ddl_transaction! and algorithm: :concurrently for all index DROP/CREATE; uses up/down (not change) for reversibility"
    verdict: pass
    evidence: "db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb declares disable_ddl_transaction! at class top; every remove_index and add_index passes algorithm: :concurrently; up and down methods implemented (no `change` block)"
  - criterion: "Every remove_index uses if_exists: true; every add_index uses if_not_exists: true"
    verdict: pass
    evidence: "Migration file: all 13 remove_index calls carry if_exists: true; all 13 add_index calls carry if_not_exists: true (idempotent re-runs)"
  - criterion: "All new index names <= 63 bytes (Postgres identifier limit)"
    verdict: pass
    evidence: "Longest new name idx_te_sections_uniq_scoped_full = 32 bytes; longest restored-on-down name idx_te_sections_unique_global = 29 bytes"
  - criterion: "spec/dummy db migrates cleanly: bin/rails db:drop db:create db:migrate from spec/dummy succeeds"
    verdict: pass
    evidence: "Verified via ActiveRecord::MigrationContext#migrate against typed_eav_test (no Rails CLI binary in spec/dummy; ran the equivalent ruby invocation matching the CI workflow). Migrate→rollback→re-migrate round trip is clean."
  - criterion: "Single commit: feat(migration): add parent_scope to typed_eav fields and sections partition tuple"
    verdict: partial
    evidence: "Commit 5ff7c30 with type `feat` instead of plan-literal `db`. See deviations: project commit-format hook does not accept `db` as a type. Scope, body, and intent are unchanged. One file changed (188 insertions)."
  - criterion: "Artifact db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb contains disable_ddl_transaction!"
    verdict: pass
    evidence: "Line 8 of the migration file"
  - criterion: "Artifact contains add_column :typed_eav_fields, :parent_scope"
    verdict: pass
    evidence: "Line 17 of the migration file"
  - criterion: "Artifact contains algorithm: :concurrently"
    verdict: pass
    evidence: "Used on every remove_index and add_index in both up and down"
  - criterion: "Key link: establishes phase-1 schema follow-on; mirrors paired-partial-index pattern from initial migration"
    verdict: pass
    evidence: "Migration follows the same idx_te_* prefix and partial-unique-index split convention from db/migrate/20260330000000_create_typed_eav_tables.rb, extended to the (scope, parent_scope) tuple via Option B's three-way split"
---

Foundation Phase 1 schema migration: adds nullable `parent_scope` to `typed_eav_fields` and `typed_eav_sections`, drops the five legacy scope-only partition indexes, and creates eight new triple-aware indexes (six Option B paired-partial uniques + two refreshed lookup indexes).

## What Was Built

- Engine migration `20260430000000_add_parent_scope_to_typed_eav_partitions.rb` with `disable_ddl_transaction!`, `algorithm: :concurrently`, idempotent guards (`if_exists` / `if_not_exists`), and a fully-symmetric `down` that restores the original schema verbatim.
- Six new paired-partial unique indexes (`idx_te_{fields,sections}_uniq_{scoped_full,scoped_only,global}`) implementing Option B's NULL-distinct hardening — verified by a direct-SQL duplicate insert that the schema rejected with `ActiveRecord::RecordNotUnique` against `idx_te_fields_uniq_scoped_only`.
- Refreshed `idx_te_fields_lookup` with `parent_scope` in the column tuple, plus a new `idx_te_sections_lookup` for parity (Phase 2 will rely on it for section ordering helpers).
- Round-trip validated: migrate → rollback → migrate runs cleanly; existing `spec/lib/typed_eav/scoping_spec.rb` (31 examples) and the full suite (388 examples) pass with zero regressions.

## Files Modified

- `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb` -- created: engine migration adding `parent_scope` column and the triple-aware paired-partial unique + lookup indexes for both partition tables.

## Deviations

- DEVN-01 (minor): class name uses `TypedEAV` (acronym-aware) rather than `TypedEav` because `lib/typed_eav.rb` registers `EAV` as an inflector acronym; without the corrected spelling Rails' migration loader raises `NameError: uninitialized constant AddParentScopeToTypedEAVPartitions`. Trivial inline correction.
- DEVN-01 (minor): commit type is `feat` rather than the plan's literal `db` because the project's PostToolUse commit-format hook only accepts `feat|fix|test|refactor|perf|docs|style|chore`. Scope (`migration`), body, and intent are unchanged.
