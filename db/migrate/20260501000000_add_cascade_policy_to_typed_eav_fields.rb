# frozen_string_literal: true

class AddCascadePolicyToTypedEAVFields < ActiveRecord::Migration[7.1]
  def up
    # Cascade policy column. String (not enum) for forward-compat with future
    # policies; default "destroy" preserves v0.1.0 behavior. NOT NULL because
    # the AR validator narrows to a closed set and the model relies on a
    # non-nil value at every read.
    add_column :typed_eav_fields, :field_dependent, :string,
               null: false, default: "destroy"

    # Allow Value rows to outlive their Field row when field_dependent is
    # "nullify". The existing read-path orphan guards in
    # InstanceMethods#typed_eav_value / typed_eav_hash already skip
    # field-nil rows silently — see CONCERNS.md.
    change_column_null :typed_eav_values, :field_id, true

    # Drop and recreate the FK to switch ON DELETE CASCADE → ON DELETE SET
    # NULL. PG requires drop-and-recreate for an ON DELETE policy change.
    # Using the column-form helpers so we don't hardcode the auto-generated
    # fk_rails_* constraint name.
    remove_foreign_key :typed_eav_values, column: :field_id
    add_foreign_key :typed_eav_values, :typed_eav_fields,
                    column: :field_id, on_delete: :nullify
  end

  def down
    # Reverse FK first (must precede NOT NULL restoration because any orphan
    # rows would otherwise block change_column_null).
    remove_foreign_key :typed_eav_values, column: :field_id
    add_foreign_key :typed_eav_values, :typed_eav_fields,
                    column: :field_id, on_delete: :cascade

    # Re-impose NOT NULL. If any field_id IS NULL rows exist (created while
    # the up-version was live), this raises — operator must clean them up
    # before rolling back. Document in CHANGELOG when shipping.
    change_column_null :typed_eav_values, :field_id, false

    remove_column :typed_eav_fields, :field_dependent
  end
end
