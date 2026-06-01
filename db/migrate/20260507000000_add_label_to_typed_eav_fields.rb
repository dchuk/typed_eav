# frozen_string_literal: true

class AddLabelToTypedEAVFields < ActiveRecord::Migration[7.1]
  # Additive, nullable, free-text display label distinct from the machine
  # slug `name` (issue #21). No index, no default, no backfill: `label` never
  # participates in uniqueness, lookup, partitioning, or ordering, so an index
  # would be dead weight. Reversible via `change` because `add_column`
  # auto-inverts. Existing rows keep label NULL and render unchanged through
  # the new `Field#display_name` (label.presence || name.humanize).
  def change
    add_column :typed_eav_fields, :label, :string, null: true
  end
end
