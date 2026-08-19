# frozen_string_literal: true

class UsePartialCoveringScalarIndexes < ActiveRecord::Migration[7.1]
  # Concurrent create-before-drop keeps the replacement indexes available
  # throughout the upgrade and leaves rollback able to recreate legacy DDL.
  disable_ddl_transaction!

  TABLE = :typed_eav_values

  INDEXES = [
    {
      column: :integer_value,
      replacement: "idx_te_values_field_int_present",
      legacy: "idx_te_values_field_int",
      value_opclass: "int8_ops",
    },
    {
      column: :decimal_value,
      replacement: "idx_te_values_field_dec_present",
      legacy: "idx_te_values_field_dec",
      value_opclass: "numeric_ops",
    },
    {
      column: :date_value,
      replacement: "idx_te_values_field_date_present",
      legacy: "idx_te_values_field_date",
      value_opclass: "date_ops",
    },
    {
      column: :datetime_value,
      replacement: "idx_te_values_field_dt_present",
      legacy: "idx_te_values_field_dt",
      value_opclass: "timestamp_ops",
    },
    {
      column: :boolean_value,
      replacement: "idx_te_values_field_bool_present",
      legacy: "idx_te_values_field_bool",
      value_opclass: "bool_ops",
    },
    {
      column: :string_value,
      replacement: "idx_te_values_field_str_present",
      legacy: "idx_te_values_field_str",
      value_opclass: "text_pattern_ops",
    },
  ].freeze

  def up
    INDEXES.each { |definition| ensure_index!(replacement_definition(definition)) }
    assert_all_valid!(INDEXES.map { |definition| replacement_definition(definition) })
    INDEXES.each { |definition| remove_expected_index!(legacy_definition(definition)) }
  end

  def down
    INDEXES.each { |definition| ensure_index!(legacy_definition(definition)) }
    assert_all_valid!(INDEXES.map { |definition| legacy_definition(definition) })
    INDEXES.each { |definition| remove_expected_index!(replacement_definition(definition)) }
  end

  private

  def replacement_definition(definition)
    definition.merge(
      name: definition.fetch(:replacement),
      include: ["entity_id"],
      predicate: "#{definition.fetch(:column)} IS NOT NULL",
    )
  end

  def legacy_definition(definition)
    definition.merge(
      name: definition.fetch(:legacy),
      include: %w[entity_id entity_type],
      predicate: nil,
    )
  end

  def ensure_index!(expected)
    actual = catalog_index(expected.fetch(:name))
    return create_and_validate!(expected) unless actual
    return if exact_definition?(actual, expected) && usable?(actual)

    unless exact_definition?(actual, expected)
      raise ActiveRecord::MigrationError,
            "index #{expected.fetch(:name)} exists with unexpected definition: #{actual.inspect}"
    end

    say "repairing invalid interrupted index #{expected.fetch(:name)}"
    remove_index TABLE, name: expected.fetch(:name), algorithm: :concurrently
    create_and_validate!(expected)
  end

  def create_and_validate!(expected)
    options = {
      name: expected.fetch(:name),
      include: expected.fetch(:include),
      algorithm: :concurrently,
    }
    options[:where] = expected.fetch(:predicate) if expected.fetch(:predicate)
    if expected.fetch(:value_opclass) == "text_pattern_ops"
      options[:opclass] = { expected.fetch(:column) => :text_pattern_ops }
    end

    add_index TABLE, [:field_id, expected.fetch(:column)], **options
    actual = catalog_index(expected.fetch(:name))
    return if actual && exact_definition?(actual, expected) && usable?(actual)

    raise ActiveRecord::MigrationError,
          "concurrent index #{expected.fetch(:name)} was not created with its exact valid definition"
  end

  def assert_all_valid!(expected_indexes)
    invalid = expected_indexes.filter_map do |expected|
      actual = catalog_index(expected.fetch(:name))
      expected.fetch(:name) unless actual && exact_definition?(actual, expected) && usable?(actual)
    end
    return if invalid.empty?

    raise ActiveRecord::MigrationError,
          "refusing to remove existing indexes before all replacements are valid: #{invalid.join(", ")}"
  end

  def remove_expected_index!(expected)
    actual = catalog_index(expected.fetch(:name))
    return unless actual

    unless exact_definition?(actual, expected)
      raise ActiveRecord::MigrationError,
            "index #{expected.fetch(:name)} exists with unexpected definition: #{actual.inspect}"
    end

    remove_index TABLE, name: expected.fetch(:name), algorithm: :concurrently
  end

  def usable?(actual)
    actual.fetch("valid") && actual.fetch("ready")
  end

  def exact_definition?(actual, expected)
    actual.fetch("method") == "btree" &&
      !actual.fetch("unique") &&
      actual.fetch("columns") == ["field_id", expected.fetch(:column).to_s, *expected.fetch(:include)] &&
      actual.fetch("key_count") == 2 &&
      actual.fetch("opclasses") == ["int8_ops", expected.fetch(:value_opclass)] &&
      normalized_predicate(actual.fetch("predicate")) == normalized_predicate(expected.fetch(:predicate))
  end

  def normalized_predicate(predicate)
    predicate&.gsub(/[()\s"]/, "")&.downcase
  end

  def catalog_index(name)
    quoted_name = connection.quote(name)
    row = connection.select_one(<<~SQL.squish)
      SELECT
        index_state.indisvalid AS valid,
        index_state.indisready AS ready,
        index_state.indisunique AS unique,
        access_method.amname AS method,
        index_state.indnkeyatts AS key_count,
        pg_get_expr(index_state.indpred, index_state.indrelid) AS predicate,
        array_to_string(ARRAY(
          SELECT attribute.attname
          FROM unnest(index_state.indkey) WITH ORDINALITY AS index_column(attnum, position)
          JOIN pg_attribute attribute
            ON attribute.attrelid = index_state.indrelid
           AND attribute.attnum = index_column.attnum
          ORDER BY index_column.position
        ), ',') AS columns,
        array_to_string(ARRAY(
          SELECT operator_class.opcname
          FROM unnest(index_state.indclass) WITH ORDINALITY AS index_opclass(opcoid, position)
          JOIN pg_opclass operator_class ON operator_class.oid = index_opclass.opcoid
          WHERE index_opclass.position <= index_state.indnkeyatts
          ORDER BY index_opclass.position
        ), ',') AS opclasses
      FROM pg_class index_relation
      JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
      JOIN pg_class table_relation ON table_relation.oid = index_state.indrelid
      JOIN pg_namespace namespace ON namespace.oid = table_relation.relnamespace
      JOIN pg_am access_method ON access_method.oid = index_relation.relam
      WHERE namespace.nspname = ANY (current_schemas(false))
        AND table_relation.relname = 'typed_eav_values'
        AND index_relation.relname = #{quoted_name}
    SQL
    return unless row

    row.merge(
      "valid" => ActiveModel::Type::Boolean.new.cast(row.fetch("valid")),
      "ready" => ActiveModel::Type::Boolean.new.cast(row.fetch("ready")),
      "unique" => ActiveModel::Type::Boolean.new.cast(row.fetch("unique")),
      "key_count" => row.fetch("key_count").to_i,
      "columns" => row.fetch("columns").split(","),
      "opclasses" => row.fetch("opclasses").split(","),
    )
  end
end
