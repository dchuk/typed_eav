class AddParentScopeToTypedEAVPartitions < ActiveRecord::Migration[7.1]
  # Production deployments may carry millions of rows in `typed_eav_fields` /
  # `typed_eav_sections` by the time they upgrade. Concurrent index DDL keeps
  # writes online during the rebuild — but it cannot run inside a DDL
  # transaction, so we drop the implicit per-migration transaction and
  # explicitly implement `up`/`down` (since `algorithm: :concurrently` is
  # not auto-reversible from a `change` block).
  disable_ddl_transaction!

  def up
    # 1. Add the nullable `parent_scope` column on both partition tables.
    #    Postgres treats `ADD COLUMN ... NULL` as a catalog-only change — no
    #    table rewrite, instantaneous regardless of row count, safe outside a
    #    transaction.
    add_column :typed_eav_fields, :parent_scope, :string
    add_column :typed_eav_sections, :parent_scope, :string

    # 2. Drop the existing scope-only paired-partial indexes plus the fields
    #    lookup index. `if_exists: true` keeps re-runs idempotent (e.g., after
    #    a partial failure on a long index drop).
    remove_index :typed_eav_fields, name: :idx_te_fields_unique_scoped,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_fields, name: :idx_te_fields_unique_global,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_fields, name: :idx_te_fields_lookup,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_unique_scoped,
                                      if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_unique_global,
                                      if_exists: true, algorithm: :concurrently

    # 3. Create the new triple-aware paired-partial unique indexes
    #    (Option B split — see migration header) plus refreshed lookup
    #    indexes.
    #
    #    Why three partials per table instead of two: Postgres unique
    #    indexes treat NULL as distinct from NULL. A single partial
    #    `(name, entity_type, scope, parent_scope) WHERE scope IS NOT NULL`
    #    would NOT prevent two rows with `(name='f', entity_type='X',
    #    scope='t1', parent_scope=NULL)` from coexisting — both satisfy
    #    `scope IS NOT NULL` and `NULL ≠ NULL` keeps them distinct in the
    #    unique key. Splitting into `_scoped_full` (parent_scope set) and
    #    `_scoped_only` (parent_scope NULL) closes the hole using only
    #    standard semantics, so we don't need `NULLS NOT DISTINCT` (PG ≥ 15).
    #
    #    Option A (`nulls_not_distinct: true`) was rejected because the
    #    gemspec floor is `rails >= 7.1` and there is no PG-server-version
    #    pin — consumer apps may run PG 12/13/14 where the option does
    #    not exist.
    #
    #    The global partials (`scope IS NULL`) deliberately omit
    #    `parent_scope` from the column list: the orphan-parent invariant
    #    enforced at the model layer (plans 03/04) guarantees
    #    `parent_scope IS NULL` whenever `scope IS NULL`, so a fourth
    #    `(parent_scope NOT NULL, scope NULL)` partial would never be
    #    populated.

    # Fields — three partial unique indexes
    add_index :typed_eav_fields,
              %i[name entity_type scope parent_scope],
              unique: true,
              where: "scope IS NOT NULL AND parent_scope IS NOT NULL",
              name: :idx_te_fields_uniq_scoped_full,
              algorithm: :concurrently,
              if_not_exists: true

    add_index :typed_eav_fields,
              %i[name entity_type scope],
              unique: true,
              where: "scope IS NOT NULL AND parent_scope IS NULL",
              name: :idx_te_fields_uniq_scoped_only,
              algorithm: :concurrently,
              if_not_exists: true

    add_index :typed_eav_fields,
              %i[name entity_type],
              unique: true,
              where: "scope IS NULL",
              name: :idx_te_fields_uniq_global,
              algorithm: :concurrently,
              if_not_exists: true

    # Sections — three partial unique indexes
    add_index :typed_eav_sections,
              %i[entity_type code scope parent_scope],
              unique: true,
              where: "scope IS NOT NULL AND parent_scope IS NOT NULL",
              name: :idx_te_sections_uniq_scoped_full,
              algorithm: :concurrently,
              if_not_exists: true

    add_index :typed_eav_sections,
              %i[entity_type code scope],
              unique: true,
              where: "scope IS NOT NULL AND parent_scope IS NULL",
              name: :idx_te_sections_uniq_scoped_only,
              algorithm: :concurrently,
              if_not_exists: true

    add_index :typed_eav_sections,
              %i[entity_type code],
              unique: true,
              where: "scope IS NULL",
              name: :idx_te_sections_uniq_global,
              algorithm: :concurrently,
              if_not_exists: true

    # Lookup indexes — refreshed `idx_te_fields_lookup` with parent_scope and
    # a brand-new `idx_te_sections_lookup` for parity. Section ordering helpers
    # ship in Phase 2; adding the index now is one extra concurrent CREATE and
    # avoids a follow-on migration.
    add_index :typed_eav_fields,
              %i[entity_type scope parent_scope sort_order name],
              name: :idx_te_fields_lookup,
              algorithm: :concurrently,
              if_not_exists: true

    add_index :typed_eav_sections,
              %i[entity_type scope parent_scope sort_order name],
              name: :idx_te_sections_lookup,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    # 1. Drop the eight new indexes (six paired-partial + two lookup).
    remove_index :typed_eav_fields, name: :idx_te_fields_uniq_scoped_full,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_fields, name: :idx_te_fields_uniq_scoped_only,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_fields, name: :idx_te_fields_uniq_global,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_fields, name: :idx_te_fields_lookup,
                                    if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_uniq_scoped_full,
                                      if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_uniq_scoped_only,
                                      if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_uniq_global,
                                      if_exists: true, algorithm: :concurrently
    remove_index :typed_eav_sections, name: :idx_te_sections_lookup,
                                      if_exists: true, algorithm: :concurrently

    # 2. Restore the original five indexes verbatim from
    #    db/migrate/20260330000000_create_typed_eav_tables.rb (using
    #    `algorithm: :concurrently` for production safety; the original
    #    migration ran inside a transaction without it, but the resulting
    #    index definitions are identical).
    add_index :typed_eav_fields,
              %i[name entity_type scope],
              unique: true,
              where: "scope IS NOT NULL",
              name: :idx_te_fields_unique_scoped,
              algorithm: :concurrently,
              if_not_exists: true
    add_index :typed_eav_fields,
              %i[name entity_type],
              unique: true,
              where: "scope IS NULL",
              name: :idx_te_fields_unique_global,
              algorithm: :concurrently,
              if_not_exists: true
    add_index :typed_eav_fields,
              %i[entity_type scope sort_order name],
              name: :idx_te_fields_lookup,
              algorithm: :concurrently,
              if_not_exists: true
    add_index :typed_eav_sections,
              %i[entity_type code scope],
              unique: true,
              where: "scope IS NOT NULL",
              name: :idx_te_sections_unique_scoped,
              algorithm: :concurrently,
              if_not_exists: true
    add_index :typed_eav_sections,
              %i[entity_type code],
              unique: true,
              where: "scope IS NULL",
              name: :idx_te_sections_unique_global,
              algorithm: :concurrently,
              if_not_exists: true

    # 3. Drop the parent_scope columns last — sections first, then fields,
    #    matching the inverse of `add_column` order in `up`.
    remove_column :typed_eav_sections, :parent_scope
    remove_column :typed_eav_fields, :parent_scope
  end
end
