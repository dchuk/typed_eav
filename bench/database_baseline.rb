# frozen_string_literal: true

# Read-only PostgreSQL baseline. It intentionally uses the application's
# existing Active Record connection and PostgreSQL catalogs only: no DDL,
# ANALYZE, VACUUM, statistics reset, or application-row mutation occurs.
require "json"
require "optparse"
require_relative "../spec/dummy/config/environment"

class TypedEAVDatabaseBaseline
  RELATIONS = %w[
    typed_eav_sections
    typed_eav_fields
    typed_eav_options
    typed_eav_values
    typed_eav_value_versions
  ].freeze

  VALUE_COLUMNS = %w[
    string_value text_value boolean_value integer_value decimal_value
    date_value datetime_value json_value
  ].freeze
  STAT_COLUMNS = %w[idx_scan idx_tup_read idx_tup_fetch].freeze

  def initialize(connection = ActiveRecord::Base.connection)
    @connection = connection
  end

  def call
    {
      "generated_at_utc" => Time.now.utc.iso8601,
      "environment" => environment,
      "caveats" => caveats,
      "relations" => relations,
      "indexes" => indexes,
      "row_counts" => row_counts,
      "typed_column_non_null_counts" => typed_column_non_null_counts,
      "bytes_per_logical_value" => bytes_per_logical_value,
      "pg_stat_user_indexes" => pg_stat_user_indexes,
    }
  end

  private

  attr_reader :connection

  def environment
    settings = %w[server_version server_encoding shared_buffers work_mem].index_with do |name|
      connection.select_value("SHOW #{name}")
    end
    settings.merge(
      "ruby" => RUBY_VERSION,
      "rails" => Rails.version,
      "adapter" => connection.adapter_name,
      "database" => connection.current_database,
    )
  end

  def caveats
    # rubocop:disable Layout/LineEndStringConcatenationIndentation -- prose is wrapped for the source without changing emitted text.
    [
      "Counts and sizes are a point-in-time read of the configured database.",
      "An empty database is valid baseline evidence: zero rows, zero logical values, and " \
        "NULL bytes_per_logical_value are reported rather than inferred.",
      "Ordinary PostgreSQL B-tree indexes include rows whose indexed key is NULL; " \
        "INCLUDE columns do not determine participation. Partial predicates do.",
      "bytes_per_logical_value divides typed_eav_values total relation bytes by rows with " \
        "at least one non-NULL typed value; it is a coarse footprint, not an allocation cost.",
      "pg_stat_user_indexes is cumulative for this database and is not reset by this helper; " \
        "NULL statistics are preserved when PostgreSQL has no observation.",
    ]
    # rubocop:enable Layout/LineEndStringConcatenationIndentation
  end

  def relations
    rows = select(<<~SQL.squish)
      SELECT c.relname AS relation,
             pg_total_relation_size(c.oid) AS total_bytes,
             pg_relation_size(c.oid) AS heap_bytes,
             pg_indexes_size(c.oid) AS index_bytes
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relname IN (#{quoted_names(RELATIONS)})
      ORDER BY c.relname
    SQL
    rows.to_h { |row| [row["relation"], numeric_fields(row, %w[total_bytes heap_bytes index_bytes])] }
  end

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize -- catalog projection is kept together so the emitted inventory mirrors pg_index.
  def indexes
    rows = select(<<~SQL.squish)
      SELECT t.relname AS relation, i.relname AS index_name,
             am.amname AS access_method, ix.indisunique AS unique,
             ix.indnkeyatts AS key_column_count, ix.indnatts AS column_count,
             pg_get_indexdef(ix.indexrelid) AS definition,
             pg_get_expr(ix.indpred, ix.indrelid) AS predicate,
             pg_size_pretty(pg_relation_size(i.oid)) AS size_pretty,
             pg_relation_size(i.oid) AS size_bytes,
             array_to_json(ARRAY(
               SELECT a.attname
               FROM unnest(ix.indkey::smallint[]) WITH ORDINALITY AS key(attnum, n)
               JOIN pg_attribute a
                 ON a.attrelid = ix.indrelid AND a.attnum = key.attnum
               ORDER BY key.n
             )) AS indexed_columns,
             array_to_json(ARRAY(
               SELECT a.attname
               FROM unnest(ix.indkey::smallint[]) WITH ORDINALITY AS key(attnum, n)
               JOIN pg_attribute a
                 ON a.attrelid = ix.indrelid AND a.attnum = key.attnum
               WHERE key.n > ix.indnkeyatts
               ORDER BY key.n
             )) AS catalog_include_columns
      FROM pg_index ix
      JOIN pg_class i ON i.oid = ix.indexrelid
      JOIN pg_class t ON t.oid = ix.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_am am ON am.oid = i.relam
      WHERE n.nspname = current_schema()
        AND t.relname IN (#{quoted_names(RELATIONS)})
      ORDER BY t.relname, i.relname
    SQL
    rows.map do |row|
      relation = row["relation"]
      keys = parse_json_array(row["indexed_columns"])
      row.merge(
        "size_bytes" => row["size_bytes"].to_i,
        "key_columns" => keys.first(row["key_column_count"].to_i),
        "include_columns" => parse_json_array(row["catalog_include_columns"]),
        "row_participation" => index_participation(
          relation,
          keys.first(row["key_column_count"].to_i),
          row["predicate"],
        ),
        "likely_write_cost" => likely_write_cost(row["index_name"]),
        "dependent_query_paths" => dependent_query_paths(row["index_name"]),
      ).except("indexed_columns", "key_column_count", "column_count", "catalog_include_columns")
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

  def row_counts
    RELATIONS.index_with do |relation|
      connection.select_value("SELECT COUNT(*) FROM #{quote_table(relation)}").to_i
    end
  end

  def typed_column_non_null_counts
    VALUE_COLUMNS.index_with do |column|
      connection.select_value(
        "SELECT COUNT(*) FROM typed_eav_values WHERE #{quote_column(column)} IS NOT NULL",
      ).to_i
    end
  end

  def bytes_per_logical_value
    values = row_counts.fetch("typed_eav_values")
    logical = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM typed_eav_values
      WHERE #{VALUE_COLUMNS.map { |column| "#{quote_column(column)} IS NOT NULL" }.join(" OR ")}
    SQL
    { "relation_total_bytes" => relations.dig("typed_eav_values", "total_bytes"),
      "logical_value_rows" => logical,
      "value_rows" => values,
      "bytes_per_logical_value" => if logical.zero?
                                     nil
                                   else
                                     relations.dig("typed_eav_values",
                                                   "total_bytes").to_f / logical
                                   end }
  end

  def pg_stat_user_indexes
    select(<<~SQL.squish).map do |row|
      SELECT schemaname, relname AS relation, indexrelname AS index_name,
             idx_scan, idx_tup_read, idx_tup_fetch
      FROM pg_stat_user_indexes
      WHERE schemaname = current_schema()
        AND relname IN (#{quoted_names(RELATIONS)})
      ORDER BY relname, indexrelname
    SQL
      STAT_COLUMNS.each_with_object(row) do |key, result|
        result[key] = result[key]&.to_i
      end
    end
  end

  def index_participation(relation, keys, partial_predicate)
    table = quote_table(relation)
    all_keys_non_null = keys.map { |column| "#{quote_column(column)} IS NOT NULL" }.join(" AND ")
    any_key_null = keys.map { |column| "#{quote_column(column)} IS NULL" }.join(" OR ")
    indexed_where = partial_predicate ? " WHERE #{partial_predicate}" : ""
    indexed_rows = connection.select_value("SELECT COUNT(*) FROM #{table}#{indexed_where}").to_i
    { "indexed_rows" => indexed_rows,
      "rows_with_all_key_columns_non_null" => count_where(table, all_keys_non_null),
      "rows_with_any_key_null" => count_where(table, any_key_null) }
  end

  def count_where(table, predicate)
    return row_count_for(table) if predicate.empty?

    connection.select_value("SELECT COUNT(*) FROM #{table} WHERE #{predicate}").to_i
  end

  def row_count_for(table)
    connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  def likely_write_cost(name)
    name == "idx_te_values_json_gin" ? "high (GIN maintenance; partial)" : "medium (B-tree maintenance; nullable key)"
  end

  def dependent_query_paths(name)
    return ["QueryBuilder :any_eq/:all_eq on json_value"] if name == "idx_te_values_json_gin"
    if name.start_with?("idx_te_values_field_")
      return ["QueryBuilder typed column comparisons and null checks",
              "EntityQuery/FilterQuery entity-id subqueries"]
    end
    return ["Value uniqueness and entity/field lookup"] if name == "idx_te_values_entity_field"

    ["Field/Section/Option association and partition lookup"]
  end

  def select(sql)
    connection.select_all(sql).to_a
  end

  def quoted_names(names)
    names.map { |name| connection.quote(name) }.join(", ")
  end

  def quote_table(name)
    connection.quote_table_name(name)
  end

  def quote_column(name)
    connection.quote_column_name(name)
  end

  def numeric_fields(row, fields)
    fields.index_with { |field| row[field].to_i }
  end

  def parse_json_array(value)
    value ? JSON.parse(value) : []
  end
end

options = { output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/database_baseline.rb [--output PATH]"
  parser.on("--output PATH", "Write JSON to PATH (stdout by default)") { |path| options[:output] = path }
end.parse!

json = "#{JSON.pretty_generate(TypedEAVDatabaseBaseline.new.call)}\n"
if options[:output]
  File.write(options[:output], json)
else
  $stdout.write(json)
end
