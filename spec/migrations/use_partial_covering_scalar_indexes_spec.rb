# frozen_string_literal: true

# The ordering assertions wrap the migration's private removal seam so they can
# inspect the live catalog at the exact safety boundary. The invalid-index test
# stubs catalog state because PostgreSQL offers no safe public DDL for creating
# an invalid non-unique index deterministically.
# rubocop:disable RSpec/SubjectStub, RSpec/MessageSpies, Metrics/MethodLength, Rails/Delegate

require "spec_helper"
require TypedEAV::Engine.root.join("db/migrate/20260816000000_use_partial_covering_scalar_indexes")

RSpec.describe UsePartialCoveringScalarIndexes, type: :model do
  self.use_transactional_tests = false

  subject(:migration) { described_class.new }

  before { migration.migrate(:down) }
  after { restore_legacy_indexes }

  it "creates six exact valid partial-covering indexes before removing legacy indexes" do
    expect(migration).to receive(:remove_expected_index!).exactly(6).times.and_wrap_original do |method, expected|
      expect(replacement_catalogs).to all(include(valid: true, ready: true))
      method.call(expected)
    end

    migration.migrate(:up)

    expect(replacement_catalogs).to all(
      include(
        valid: true,
        ready: true,
        unique: false,
        method: "btree",
        key_count: 2,
        include: ["entity_id"],
      ),
    )
    expect(replacement_catalogs.map { |index| index.fetch(:predicate) })
      .to match_array(described_class::INDEXES.map { |index| "#{index.fetch(:column)} IS NOT NULL" })
    expect(replacement_catalogs.map { |index| index.fetch(:keys) })
      .to eq(described_class::INDEXES.map { |index| ["field_id", index.fetch(:column).to_s] })
    expect(replacement_catalogs.find { |index| index.fetch(:column) == "string_value" }.fetch(:opclasses))
      .to eq(%w[int8_ops text_pattern_ops])
    expect(index_names & legacy_names).to be_empty
  end

  it "recreates six exact valid legacy indexes before removing replacements on rollback" do
    migration.migrate(:up)
    expect(migration).to receive(:remove_expected_index!).exactly(6).times.and_wrap_original do |method, expected|
      expect(legacy_catalogs).to all(include(valid: true, ready: true))
      method.call(expected)
    end

    migration.migrate(:down)

    expect(legacy_catalogs).to all(
      include(
        valid: true,
        ready: true,
        unique: false,
        method: "btree",
        key_count: 2,
        include: %w[entity_id entity_type],
        predicate: nil,
      ),
    )
    expect(legacy_catalogs.find { |index| index.fetch(:column) == "string_value" }.fetch(:opclasses))
      .to eq(%w[int8_ops text_pattern_ops])
    expect(legacy_catalogs.map { |index| index.fetch(:keys) })
      .to eq(described_class::INDEXES.map { |index| ["field_id", index.fetch(:column).to_s] })
    expect(index_names & replacement_names).to be_empty
  end

  it "resumes a partial upgrade without disturbing exact valid replacements" do
    first = described_class::INDEXES.first
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY #{first.fetch(:replacement)}
      ON typed_eav_values (field_id, #{first.fetch(:column)})
      INCLUDE (entity_id)
      WHERE #{first.fetch(:column)} IS NOT NULL
    SQL
    original_oid = index_oid(first.fetch(:replacement))

    migration.migrate(:up)

    expect(index_oid(first.fetch(:replacement))).to eq(original_oid)
    expect(replacement_catalogs).to all(include(valid: true, ready: true))
  end

  it "repairs an exact invalid interrupted index concurrently" do
    expected = migration.send(:replacement_definition, described_class::INDEXES.first)
    invalid = exact_state(expected).merge("valid" => false, "ready" => false)
    allow(migration).to receive(:catalog_index).and_call_original
    allow(migration).to receive(:catalog_index).with(expected.fetch(:name)).and_return(invalid, exact_state(expected))

    expect(migration).to receive(:remove_index)
      .with(:typed_eav_values, name: expected.fetch(:name), algorithm: :concurrently)
    expect(migration).to receive(:add_index) do |table, columns, **options|
      expect(table).to eq(:typed_eav_values)
      expect(columns).to eq(%i[field_id integer_value])
      expect(options).to include(algorithm: :concurrently)
    end

    migration.send(:ensure_index!, expected)
  end

  it "rejects unexpected same-name DDL before removing any legacy index" do
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY idx_te_values_field_int_present
      ON typed_eav_values (field_id, integer_value)
      INCLUDE (entity_id, entity_type)
    SQL

    expect { migration.migrate(:up) }
      .to raise_error(ActiveRecord::MigrationError, /unexpected definition/)
    expect(index_names).to include(*legacy_names)
  ensure
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_te_values_field_int_present"
  end

  def replacement_catalogs
    described_class::INDEXES.map do |definition|
      catalog(definition.fetch(:replacement), definition.fetch(:column).to_s)
    end
  end

  def legacy_catalogs
    described_class::INDEXES.map do |definition|
      catalog(definition.fetch(:legacy), definition.fetch(:column).to_s)
    end
  end

  def catalog(name, column)
    row = connection.select_one(<<~SQL.squish).symbolize_keys
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
            ON attribute.attrelid = index_state.indrelid AND attribute.attnum = index_column.attnum
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
      JOIN pg_am access_method ON access_method.oid = index_relation.relam
      WHERE table_relation.relname = 'typed_eav_values'
        AND index_relation.relname = #{connection.quote(name)}
    SQL
    {
      valid: row.fetch(:valid),
      ready: row.fetch(:ready),
      unique: row.fetch(:unique),
      method: row.fetch(:method),
      key_count: row.fetch(:key_count),
      column: column,
      keys: row.fetch(:columns).split(",").first(2),
      include: row.fetch(:columns).split(",").drop(2),
      predicate: normalize_predicate(row.fetch(:predicate)),
      opclasses: row.fetch(:opclasses).split(","),
    }
  end

  def normalize_predicate(predicate)
    predicate&.delete("()")
  end

  def exact_state(expected)
    {
      "valid" => true,
      "ready" => true,
      "unique" => false,
      "method" => "btree",
      "key_count" => 2,
      "columns" => ["field_id", expected.fetch(:column).to_s, *expected.fetch(:include)],
      "opclasses" => ["int8_ops", expected.fetch(:value_opclass)],
      "predicate" => expected.fetch(:predicate),
    }
  end

  def index_names
    connection.indexes(:typed_eav_values).map(&:name)
  end

  def replacement_names
    described_class::INDEXES.map { |definition| definition.fetch(:replacement) }
  end

  def legacy_names
    described_class::INDEXES.map { |definition| definition.fetch(:legacy) }
  end

  def index_oid(name)
    connection.select_value("SELECT to_regclass(#{connection.quote(name)})::oid").to_i
  end

  def execute(sql)
    connection.execute(sql)
  end

  def connection
    ActiveRecord::Base.connection
  end

  def restore_legacy_indexes
    described_class.new.migrate(:down)
  rescue ActiveRecord::StatementInvalid, ActiveRecord::MigrationError
    replacement_names.each { |name| execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}" }
    described_class.new.migrate(:down)
  end
end
# rubocop:enable RSpec/SubjectStub, RSpec/MessageSpies, Metrics/MethodLength, Rails/Delegate
