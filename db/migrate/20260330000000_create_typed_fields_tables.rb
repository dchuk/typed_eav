# frozen_string_literal: true

class CreateTypedFieldsTables < ActiveRecord::Migration[7.1]
  def change
    # ──────────────────────────────────────────────────
    # Sections: optional UI grouping for fields
    # ──────────────────────────────────────────────────
    create_table :typed_field_sections do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :entity_type, null: false
      t.string :scope
      t.integer :sort_order
      t.boolean :active, null: false, default: true

      t.timestamps

      # Paired partial unique indexes. PostgreSQL treats NULLs as distinct in
      # a plain unique index, so a single `[entity_type, code, scope]` index
      # would allow duplicate global (scope IS NULL) rows. Split into
      # (scope NOT NULL) and (scope IS NULL) partials to protect both.
      t.index %i[entity_type code scope],
              unique: true,
              where: "scope IS NOT NULL",
              name: "idx_tf_sections_unique_scoped"
      t.index %i[entity_type code],
              unique: true,
              where: "scope IS NULL",
              name: "idx_tf_sections_unique_global"
      t.index %i[entity_type active], name: "idx_tf_sections_entity_active"
    end

    # ──────────────────────────────────────────────────
    # Field definitions (STI via `type` column)
    # ──────────────────────────────────────────────────
    create_table :typed_fields do |t|
      t.string :name, null: false
      t.string :type, null: false # STI: TypedFields::Field::Integer, etc.
      t.string :entity_type, null: false     # polymorphic target model name
      t.string :scope                        # optional tenant/context scoping

      t.references :section, foreign_key: { to_table: :typed_field_sections, on_delete: :nullify }

      t.boolean :required, null: false, default: false
      t.integer :sort_order

      # Field-type-specific configuration (min/max/precision/allowed_values/etc.)
      t.jsonb :options, null: false, default: {}

      # Default value stored in the matching typed column format
      t.jsonb :default_value_meta, null: false, default: {}

      t.timestamps

      # Paired partial unique indexes — see sections table comment for why
      # scope=NULL rows need their own partial index on PostgreSQL.
      t.index %i[name entity_type scope],
              unique: true,
              where: "scope IS NOT NULL",
              name: "idx_tf_fields_unique_scoped"
      t.index %i[name entity_type],
              unique: true,
              where: "scope IS NULL",
              name: "idx_tf_fields_unique_global"
      t.index :entity_type
      t.index %i[entity_type scope sort_order name], name: "idx_tf_fields_lookup"
    end

    # ──────────────────────────────────────────────────
    # Options for select/enum fields
    # ──────────────────────────────────────────────────
    create_table :typed_field_options do |t|
      t.references :field, null: false, foreign_key: { to_table: :typed_fields, on_delete: :cascade }
      t.string :label, null: false
      t.string :value, null: false
      t.integer :sort_order

      t.timestamps

      t.index %i[field_id value], unique: true, name: "idx_tf_options_field_value"
    end

    # ──────────────────────────────────────────────────
    # Values: one row per entity+field, typed columns
    # ──────────────────────────────────────────────────
    create_table :typed_field_values do |t|
      t.references :entity, polymorphic: true, null: false, index: true
      t.references :field, null: false, foreign_key: { to_table: :typed_fields, on_delete: :cascade }

      # ── Typed storage columns ──
      # All value columns are nullable on purpose: only one is populated per
      # row (the one matching the field's type), and a NULL in the others is
      # the "this column doesn't apply" marker. The Rails/ThreeStateBooleanColumn
      # warning doesn't apply to EAV-style tables.
      t.text     :string_value
      t.text     :text_value
      t.boolean  :boolean_value # rubocop:disable Rails/ThreeStateBooleanColumn
      t.bigint   :integer_value
      t.decimal  :decimal_value, precision: 30, scale: 10
      t.date     :date_value
      t.datetime :datetime_value
      t.jsonb    :json_value

      t.timestamps

      # Uniqueness: one value per entity per field
      t.index %i[entity_type entity_id field_id],
              unique: true,
              name: "idx_tf_values_entity_field"

      # Query performance: field + typed column indexes (covering for index-only scans)
      t.index %i[field_id integer_value],  name: "idx_tf_values_field_int",  include: %i[entity_id entity_type]
      t.index %i[field_id decimal_value],  name: "idx_tf_values_field_dec",  include: %i[entity_id entity_type]
      t.index %i[field_id date_value],     name: "idx_tf_values_field_date", include: %i[entity_id entity_type]
      t.index %i[field_id datetime_value], name: "idx_tf_values_field_dt",   include: %i[entity_id entity_type]
      t.index %i[field_id boolean_value],  name: "idx_tf_values_field_bool", include: %i[entity_id entity_type]
      t.index %i[field_id string_value],
              name: "idx_tf_values_field_str",
              using: :btree,
              opclass: { string_value: :text_pattern_ops },
              include: %i[entity_id entity_type]

      # Partial GIN index for JSONB containment (`@>`) used by :any_eq /
      # :all_eq on array/multi-select fields. NULL-heavy rows (scalar field
      # values) stay out of the index.
      t.index :json_value,
              using: :gin,
              where: "json_value IS NOT NULL",
              name: "idx_tf_values_json_gin"
    end
  end
end
