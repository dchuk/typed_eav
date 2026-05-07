class AddVersionGroupIdToTypedEAVValueVersions < ActiveRecord::Migration[7.1]
  # Phase 06 — Bulk operations correlation tag.
  #
  # Adds a nullable, indexed `version_group_id` UUID column to
  # `typed_eav_value_versions`. A bulk-write API (Plan 06-03) will inject
  # the correlation tag via `TypedEAV.with_context(version_group_id: uuid)
  # { ... }` and the Phase 04 versioning subscriber forwards it onto each
  # ValueVersion row written during the bulk operation. Non-bulk writes
  # leave the column NULL — backward-compatible with every row written
  # by Phase 04's initial migration (`20260505000000_create_typed_eav_value_versions.rb`).
  #
  # ## Type rationale (uuid, not bigint or string)
  #
  # The correlation tag has no shared sequence — there's no parent
  # `bulk_operations` row to FK to, and we deliberately do NOT introduce
  # one (locked at 06-CONTEXT.md §version_group_id mechanism). UUID is the
  # idiomatic choice for an unkeyed correlation token: 16 bytes vs 36 for
  # a `:string` UUID, native Postgres equality / btree, and
  # `SecureRandom.uuid` is the canonical Ruby generator. Postgres-only
  # commitment is binding (ROADMAP §Cross-cutting requirements) so the
  # `:uuid` column type is portable across all supported deployments.
  #
  # ## Nullability rationale
  #
  # Every existing version row was written without this column. Adding
  # `null: false` would force a backfill, but there is no defensible
  # value to backfill with — a per-row UUID would create a misleading
  # signal that those historical rows were part of a bulk operation when
  # they were not. Locked at 06-CONTEXT.md §version_grouping default:
  # non-bulk writes leave the column NULL.
  #
  # ## Concurrent index DDL
  #
  # Mirrors the production-safety pattern from
  # `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb:1-8`:
  # `algorithm: :concurrently` cannot run inside a DDL transaction, so we
  # `disable_ddl_transaction!` and implement explicit `up` / `down`
  # methods (the auto-reverse from a `change` block does not understand
  # `algorithm: :concurrently`). `if_not_exists:` / `if_exists:` keep
  # re-runs idempotent on partial-failure recovery.
  #
  # ## Index naming
  #
  # `idx_te_vvs_group` joins the existing `idx_te_vvs_*` family on this
  # table (CONVENTIONS.md §Naming line 117 — `vvs` = "value versions"
  # keeps the four-character partition fits in Postgres' 63-byte limit).
  disable_ddl_transaction!

  def up
    # 1. Add the nullable `version_group_id` UUID column. Postgres treats
    #    `ADD COLUMN ... NULL` as a catalog-only change — no table rewrite,
    #    instantaneous regardless of row count, safe outside a transaction.
    add_column :typed_eav_value_versions, :version_group_id, :uuid

    # 2. Concurrent btree index. The dominant read pattern (Plan 06+ /
    #    consumer queries) is `WHERE version_group_id = ?` to fetch all
    #    rows produced by a single bulk operation; a plain btree on the
    #    column suffices. Composite indexes (e.g., `[entity_type,
    #    version_group_id]`) are deferred until a workload justifies them.
    add_index :typed_eav_value_versions,
              :version_group_id,
              name: "idx_te_vvs_group",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    # Drop the index first, then the column — inverse of `up` order.
    remove_index :typed_eav_value_versions,
                 name: "idx_te_vvs_group",
                 if_exists: true,
                 algorithm: :concurrently

    remove_column :typed_eav_value_versions, :version_group_id
  end
end
