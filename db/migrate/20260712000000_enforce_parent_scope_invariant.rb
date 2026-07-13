# frozen_string_literal: true

class EnforceParentScopeInvariant < ActiveRecord::Migration[7.1]
  CONSTRAINTS = {
    typed_eav_fields: :chk_te_fields_parent_scope_requires_scope,
    typed_eav_sections: :chk_te_sections_parent_scope_requires_scope,
  }.freeze

  INVARIANT_SQL = <<~SQL.squish.freeze
    parent_scope IS NULL
    OR BTRIM(parent_scope) = ''
    OR (scope IS NOT NULL AND BTRIM(scope) <> '')
  SQL

  ORPHAN_SQL = <<~SQL.squish.freeze
    parent_scope IS NOT NULL
    AND BTRIM(parent_scope) <> ''
    AND (scope IS NULL OR BTRIM(scope) = '')
  SQL

  def up
    assert_no_orphan_parent_rows!

    CONSTRAINTS.each do |table, name|
      add_check_constraint table, INVARIANT_SQL, name: name, validate: false, if_not_exists: true

      validate_check_constraint table, name: name
    end
  end

  def down
    CONSTRAINTS.each do |table, name|
      remove_check_constraint table, name: name, if_exists: true
    end
  end

  private

  def assert_no_orphan_parent_rows!
    violations = CONSTRAINTS.keys.filter_map do |table|
      count = select_value("SELECT COUNT(*) FROM #{quote_table_name(table)} WHERE #{ORPHAN_SQL}").to_i
      [table, count] if count.positive?
    end
    return if violations.empty?

    evidence = violations.map { |table, count| "#{count} #{table} row(s) have parent_scope without scope" }.join("; ")
    raise ActiveRecord::MigrationError,
          "Cannot enforce the typed_eav parent-scope invariant: #{evidence}. Repair these rows and retry."
  end
end
