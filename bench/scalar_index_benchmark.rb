# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Rails/IndexWith, Style/HashConversion -- SQL-heavy benchmark evidence stays cohesive.
require "json"
require "optparse"
require "pg"
require "securerandom"
require "time"
require "date"
require "digest"
require "open3"

class ScalarIndexBenchmark
  CANDIDATES = {
    "current_covering" => "INCLUDE (entity_id, entity_type)",
    "partial_non_covering" => "WHERE %<column>s IS NOT NULL",
    "partial_covering" => "INCLUDE (entity_id) WHERE %<column>s IS NOT NULL",
  }.freeze
  TYPES = %w[integer decimal boolean date datetime string].freeze
  ROWS_PER_ENTITY = TYPES.length
  SMOKE_ENTITIES = 10_000
  MEASUREMENTS = 3
  LITERALS = { "integer" => "42", "decimal" => "42.00", "boolean" => "TRUE", "date" => "'2020-01-10'", "datetime" => "'2020-01-10T00:00:00Z'", "string" => "'value-10'" }.freeze
  DB_PREFIX = "typed_eav_phase2_smoke_"
  GIB = 1024**3
  SMOKE_MAX_BYTES = 500 * 1024 * 1024
  REPRESENTATIVE_MIN_FREE_BYTES = 30 * GIB
  REPRESENTATIVE_RESERVE_BYTES = 8 * GIB

  def self.run(argv)
    options = { tier: nil, seed: nil, output: nil }
    OptionParser.new do |p|
      p.on("--tier TIER", %w[smoke representative]) { |v| options[:tier] = v }
      p.on("--seed SEED", Integer) { |v| options[:seed] = v }
      p.on("--output PATH") { |v| options[:output] = v }
    end.parse!(argv)
    abort "--tier, --seed, and --output are required" unless options.values.all?
    abort "representative tier requires TYPED_EAV_REPRESENTATIVE_OK=1" if options[:tier] == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
    new(**options).call
  end

  def initialize(tier:, seed:, output:)
    @tier = tier
    @seed = seed
    @output = output
    @database = "#{DB_PREFIX}#{Process.pid}_#{Time.now.utc.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
    @admin = PG.connect(connection_options.merge(dbname: ENV.fetch("PGMAINTENANCE_DB", "postgres")))
    @db = nil
    @operation_metrics = {}
    @candidate_checksums = {}
    @created = false
    @cleanup = { created_by_run: false, attempted: false, database_prefix_validated: false, dropped: false }
    @candidate_order = ENV.fetch("TYPED_EAV_CANDIDATE_ORDER", CANDIDATES.keys.join(",")).split(",")
    abort "invalid candidate order" unless @candidate_order.sort == CANDIDATES.keys.sort
  end

  def call
    projected = projected_bytes
    abort "projected smoke footprint exceeds 500 MiB" if @tier == "smoke" && projected > SMOKE_MAX_BYTES
    qualify_environment!(projected)
    create_database
    @db = PG.connect(connection_options.merge(dbname: @database))
    result = build_result(projected)
    cleanup
    result["environment"]["cleanup"] = @cleanup
    File.write(@output, "#{JSON.pretty_generate(result)}\n")
  ensure
    cleanup
    @admin&.close
  end

  private

  def connection_options
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", nil), user: ENV.fetch("PGUSER", nil), password: ENV.fetch("PGPASSWORD", nil) }.compact
  end

  def create_database
    @admin.exec("CREATE DATABASE #{@admin.quote_ident(@database)}")
    @created = true
    @cleanup[:created_by_run] = true
  end

  def qualify_environment!(projected)
    metadata = environment_metadata(projected)
    return if @tier == "smoke" || metadata.dig("representative_storage", "qualified")

    File.write(@output, "#{JSON.pretty_generate("generated_at_utc" => Time.now.utc.iso8601,
                                                "environment" => metadata.merge("cleanup" => @cleanup),
                                                "dataset" => dataset_metadata.merge("tier" => @tier, "seed" => @seed, "projected_bytes" => projected),
                                                "caveats" => caveats,
                                                "refusal" => "Representative database creation refused before CREATE DATABASE.")}\n")
    abort "representative storage is not qualified: #{metadata.fetch("observed_free_bytes")} free bytes; #{metadata.fetch("required_free_bytes")} required"
  end

  def ensure_representative_reserve!
    return unless @tier == "representative"

    observed = free_bytes(@data_directory)
    abort "representative reserve breached: #{observed} free bytes" if observed < REPRESENTATIVE_RESERVE_BYTES
  end

  def cleanup
    return unless @admin && @database && @created

    @cleanup[:attempted] = true
    @cleanup[:database_prefix_validated] = @database.start_with?(DB_PREFIX)
    return unless @cleanup[:database_prefix_validated]

    @db.close if @db && !@db.finished?
    @admin.exec("DROP DATABASE IF EXISTS #{@admin.quote_ident(@database)}")
    @cleanup[:dropped] = @admin.exec_params("SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", [@database]).getvalue(0, 0) == "t"
  end

  def projected_bytes
    entities = @tier == "smoke" ? SMOKE_ENTITIES : Integer(ENV.fetch("TYPED_EAV_REPRESENTATIVE_ENTITIES", "100000"))
    # Conservative planning allowance: heap, three indexes, WAL, and maintenance headroom.
    entities * ROWS_PER_ENTITY * 1_000 * CANDIDATES.length
  end

  def build_result(projected)
    environment = environment_metadata(projected)
    dataset = dataset_metadata
    candidates = {}
    measurements = {}
    explain_plans = {}
    candidate_timestamps = {}
    @candidate_order.each do |name|
      ddl = CANDIDATES.fetch(name)
      candidate_timestamps[name] = { "started_at_utc" => Time.now.utc.iso8601 }
      ensure_representative_reserve!
      exact_ddl = TYPES.map do |type|
        column = "#{type}_value"
        indexed_column = type == "string" ? "#{column} text_pattern_ops" : column
        "CREATE INDEX #{name}_scalar_values_#{type}_idx ON scalar_values_#{name} (field_id, #{indexed_column}) #{format(ddl, column: column)}"
      end
      candidates[name] = { "ddl" => exact_ddl, "exact_ddl" => exact_ddl }
      create_table(name, ddl)
      rows = rows_for(name)
      dataset["rows_per_candidate"] = rows
      measurements[name] = measure(name, rows)
      @db.exec("VACUUM (ANALYZE) scalar_values_#{name}")
      explain_plans[name] = explain(name)
      candidate_timestamps[name]["ended_at_utc"] = Time.now.utc.iso8601
      candidates[name]["index_sizes"] = index_sizes("scalar_values_#{name}")
      candidates[name]["pg_stat_user_indexes"] = index_stats("scalar_values_#{name}")
      ensure_representative_reserve!
    end
    dataset["null_distribution"] = null_distribution
    dataset["cardinalities"] = cardinalities
    dataset["seed_checksum"] = @dataset_checksum
    dataset["candidate_checksums"] = @candidate_checksums
    dataset["checksum_equal_across_candidates"] = @candidate_checksums.values.uniq.one?
    abort "candidate dataset checksum mismatch" unless dataset["checksum_equal_across_candidates"]
    measurements.each_value do |measurement|
      abort "insert row count mismatch" unless measurement.fetch("inserted_rows") == dataset.fetch("rows_per_candidate")
      abort "invalid update evidence" unless measurement.fetch("update_rows").all?(&:positive?)
      abort "invalid WAL delta" unless [measurement.fetch("insert_wal_bytes"), *measurement.fetch("update_wal_bytes")].all? { |bytes| bytes.nil? || bytes >= 0 }
    end
    environment["actual_disposable_database_bytes"] = @db.exec("SELECT pg_database_size(current_database())").getvalue(0, 0).to_i
    abort "actual disposable database exceeds 500 MiB" if @tier == "smoke" && environment["actual_disposable_database_bytes"] > SMOKE_MAX_BYTES
    {
      "generated_at_utc" => Time.now.utc.iso8601,
      "environment" => environment.merge("database" => @database, "cleanup" => @cleanup),
      "dataset" => dataset.merge("tier" => @tier, "seed" => @seed, "projected_bytes" => projected),
      "candidates" => candidates,
      "measurements" => measurements,
      "explain_plans" => explain_plans,
      "caveats" => caveats,
      "candidate_timestamps" => candidate_timestamps,
      "trial" => ENV.fetch("TYPED_EAV_TRIAL", "1").to_i,
      "candidate_order" => @candidate_order,
    }
  end

  def environment_metadata(projected)
    settings = Hash[%w[server_version server_encoding shared_buffers work_mem maintenance_work_mem].map { |s| [s, @admin.exec("SHOW #{s}").getvalue(0, 0)] }]
    @data_directory = @admin.exec("SHOW data_directory").getvalue(0, 0)
    free = free_bytes(@data_directory)
    required = [REPRESENTATIVE_MIN_FREE_BYTES, projected + REPRESENTATIVE_RESERVE_BYTES].max
    settings.merge("ruby" => RUBY_VERSION, "pg" => PG.library_version, "tier" => @tier, "projected_bytes" => projected,
                   "data_directory" => @data_directory, "observed_free_bytes" => free,
                   "required_free_bytes" => @tier == "representative" ? required : nil,
                   "reserve_bytes" => @tier == "representative" ? REPRESENTATIVE_RESERVE_BYTES : 0,
                   "representative_storage" => { "data_directory" => @data_directory, "observed_free_bytes" => free,
                                                 "required_free_bytes" => required, "reserve_bytes" => REPRESENTATIVE_RESERVE_BYTES,
                                                 "qualified" => free >= required },
                   "host_free_space_note" => @tier == "smoke" ? "Smoke footprint is bounded below 500 MiB; representative storage qualification is informational." : "Representative execution requires the configured storage gate.")
  end

  def free_bytes(path)
    output, status = Open3.capture2("df", "-Pk", path)
    abort "unable to inspect PostgreSQL data volume free space" unless status.success?

    output.lines.last.split.fetch(3).to_i * 1024
  end

  def dataset_metadata
    { "entities" => @tier == "smoke" ? SMOKE_ENTITIES : Integer(ENV.fetch("TYPED_EAV_REPRESENTATIVE_ENTITIES", "100000")),
      "fields" => TYPES.each_with_index.to_h { |type, i| [type, i + 1] }, "rows_per_candidate" => nil,
      "value_types" => TYPES, "seed_checksum" => nil, "candidate_checksums" => {},
      "generation" => "streaming deterministic per seed; one identical logical dataset per candidate",
      "rows_materialized" => false,
      "checksum" => "incremental SHA-256 over each logical row's Ruby inspection" }
  end

  def create_table(name, ddl)
    table = @db.quote_ident("scalar_values_#{name}")
    @db.exec("CREATE TABLE #{table} (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, entity_type text NOT NULL, entity_id integer NOT NULL, field_id integer NOT NULL, integer_value integer, decimal_value numeric(12, 2), boolean_value boolean, date_value date, datetime_value timestamptz, string_value text)")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    TYPES.each do |type|
      index_name = "#{name}_scalar_values_#{type}_idx"
      column = "#{type}_value"
      indexed_column = type == "string" ? "#{column} text_pattern_ops" : column
      @db.exec("CREATE INDEX #{index_name} ON #{table} (field_id, #{indexed_column}) #{format(ddl, column: column)}")
    end
    @db.exec("CREATE INDEX #{table.delete('"')}_entity_idx ON #{table} (entity_id, field_id)")
    index_elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3)
    wal_start = current_wal_lsn
    insert_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    inserted = insert_rows(table)
    insert_elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - insert_started) * 1_000).round(3)
    @operation_metrics[name] = { "index_build_elapsed_ms" => index_elapsed, "inserted_rows" => inserted,
                                 "insert_elapsed_ms" => insert_elapsed, "insert_wal_bytes" => wal_delta(wal_start) }
  end

  def insert_rows(table)
    checksum = Digest::SHA256.new
    inserted_rows = 0
    @db.copy_data("COPY #{table} (entity_type, entity_id, field_id, integer_value, decimal_value, boolean_value, date_value, datetime_value, string_value) FROM STDIN WITH (FORMAT csv, NULL '\\N')") do
      each_generated_row do |values|
        checksum << values.inspect
        @db.put_copy_data("#{values.map { |v| v.nil? ? "\\N" : v }.join(",")}\n")
        inserted_rows += 1
        ensure_representative_reserve! if (inserted_rows % 100_000).zero?
      end
    end
    @candidate_checksums[table] = checksum.hexdigest
    @dataset_checksum ||= @candidate_checksums[table]
    abort "candidate dataset checksum mismatch" unless @candidate_checksums[table] == @dataset_checksum
    inserted_rows
  end

  def each_generated_row
    rng = Random.new(@seed)
    entities.times do |entity|
      TYPES.each_with_index do |type, index|
        next if type == "integer" && (entity % 20).zero?

        values = Array.new(9)
        values[0, 3] = ["Contact", entity, index + 1]
        case type
        when "integer" then values[3] = (entity % 97).zero? ? nil : rng.rand(100)
        when "decimal" then values[4] = format("%.2f", rng.rand * 1000)
        when "boolean" then values[5] = rng.rand(2).zero?
        when "date" then values[6] = Date.new(2020, 1, 1).next_day(rng.rand(365))
        when "datetime" then values[7] = (Time.utc(2020, 1, 1) + (rng.rand(365) * 86_400)).iso8601
        when "string" then values[8] = "value-#{rng.rand(31)}"
        end
        yield values
      end
    end
  end

  def entities
    @tier == "smoke" ? SMOKE_ENTITIES : Integer(ENV.fetch("TYPED_EAV_REPRESENTATIVE_ENTITIES", "100000"))
  end

  def rows_for(name)
    @db.exec("SELECT COUNT(*) FROM scalar_values_#{name}").getvalue(0, 0).to_i
  end

  def measure(name, _rows)
    table = "scalar_values_#{name}"
    operation = @operation_metrics.fetch(name)
    timings = operation.merge("update_elapsed_ms" => [], "update_rows" => [], "update_wal_bytes" => [], "equality_latency_ms" => [], "range_latency_ms" => [])
    timings["per_type_latency_ms"] = {}
    timings["per_type_range_latency_ms"] = {}
    TYPES.each_with_index do |type, index|
      column = "#{type}_value"
      literal = LITERALS.fetch(type)
      sql = "SELECT entity_id FROM #{table} WHERE field_id = #{index + 1} AND #{column} = #{literal}"
      timings["per_type_latency_ms"][type] = Array.new(MEASUREMENTS) { elapsed { @db.exec(sql) }.round(3) }
      range_predicate = range_predicate_for(type, column)
      range_sql = type == "boolean" ? nil : "SELECT entity_id FROM #{table} WHERE field_id = #{index + 1} AND #{range_predicate}"
      timings["per_type_range_latency_ms"][type] = range_sql ? Array.new(MEASUREMENTS) { elapsed { @db.exec(range_sql) }.round(3) } : []
    end
    MEASUREMENTS.times do |i|
      timings["equality_latency_ms"] << elapsed { @db.exec_params("SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value = $1", [i + 10]) }.round(3)
      timings["range_latency_ms"] << elapsed { @db.exec_params("SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value BETWEEN $1 AND $2", [20, 80]) }.round(3)
      wal_start = current_wal_lsn
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      updated = @db.exec("UPDATE #{table} SET integer_value = integer_value + #{i.even? ? 1 : -1} WHERE field_id = 1 AND integer_value IS NOT NULL")
      timings["update_elapsed_ms"] << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3)
      timings["update_rows"] << updated.cmd_tuples
      timings["update_wal_bytes"] << wal_delta(wal_start)
    end
    logical_rows = logical_value_rows(table)
    timings.merge("insert_rows_per_second" => operation.fetch("inserted_rows") / ([operation.fetch("insert_elapsed_ms"), 0.001].max / 1_000),
                  "update_rows_per_second" => timings["update_rows"].last / ([timings["update_elapsed_ms"].last, 0.001].max / 1_000),
                  "candidate_total_relation_bytes" => bytes(table), "index_bytes" => @db.exec("SELECT pg_indexes_size('#{table}')").getvalue(0, 0).to_i,
                  "logical_value_rows" => logical_rows, "bytes_per_live_logical_value" => bytes(table).to_f / [logical_rows, 1].max,
                  "index_sizes" => index_sizes(table), "pg_stat_user_indexes" => index_stats(table))
  end

  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1_000
  end

  def bytes(table)
    @db.exec("SELECT pg_total_relation_size('#{table}')").getvalue(0, 0).to_i
  end

  def range_predicate_for(type, column)
    case type
    when "string" then "#{column} LIKE 'value-%'"
    when "date", "datetime" then "#{column} BETWEEN '2020-01-02' AND '2020-06-01'"
    when "boolean" then nil
    else "#{column} BETWEEN 20 AND 80"
    end
  end

  def current_wal_lsn
    @db.exec("SELECT pg_current_wal_lsn()").getvalue(0, 0)
  end

  def wal_delta(start_lsn)
    @db.exec_params("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), $1)", [start_lsn]).getvalue(0, 0).to_i
  rescue PG::Error
    nil
  end

  def logical_value_rows(table)
    columns = TYPES.map { |type| "#{type}_value IS NOT NULL" }.join(" OR ")
    @db.exec("SELECT COUNT(*) FROM #{table} WHERE #{columns}").getvalue(0, 0).to_i
  end

  def index_sizes(table)
    @db.exec("SELECT indexrelname, pg_relation_size(indexrelid) AS bytes FROM pg_stat_user_indexes WHERE relname = '#{table}' ORDER BY indexrelname").to_a.to_h { |row| [row["indexrelname"], row["bytes"].to_i] }
  end

  def index_stats(table)
    @db.exec("SELECT indexrelname, idx_scan, idx_tup_read, idx_tup_fetch FROM pg_stat_user_indexes WHERE relname = '#{table}' ORDER BY indexrelname").to_a.map do |row|
      row.merge("idx_scan" => row["idx_scan"].to_i, "idx_tup_read" => row["idx_tup_read"].to_i, "idx_tup_fetch" => row["idx_tup_fetch"].to_i)
    end
  end

  def explain(name)
    table = "scalar_values_#{name}"
    queries = {}
    TYPES.each_with_index do |type, index|
      column = "#{type}_value"
      literal = LITERALS.fetch(type)
      queries["#{type}_equality"] = "SELECT entity_id FROM #{table} WHERE field_id = #{index + 1} AND #{column} = #{literal}"
      range = range_predicate_for(type, column)
      queries["#{type}_range"] = "SELECT entity_id FROM #{table} WHERE field_id = #{index + 1} AND #{range}" if range
    end
    queries["explicit_null_row"] = "SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NULL"
    queries["include_missing"] = "SELECT entity_id FROM generate_series(0, #{entities - 1}) entity_id WHERE entity_id NOT IN (SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NOT NULL)"
    queries.to_h do |label, sql|
      plan = JSON.parse(@db.exec("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}").getvalue(0, 0)).first
      [label, plan.merge("observed_node_types" => plan_nodes(plan), "heap_fetches" => plan_heap_fetches(plan))]
    end
  end

  def plan_nodes(plan)
    nodes = []
    walk = lambda do |node|
      nodes << node["Node Type"] if node["Node Type"]
      node.fetch("Plans", []).each { |child| walk.call(child) }
    end
    walk.call(plan["Plan"])
    nodes
  end

  def plan_heap_fetches(plan)
    fetches = []
    walk = lambda do |node|
      fetches << node["Heap Fetches"] if node.key?("Heap Fetches")
      node.fetch("Plans", []).each { |child| walk.call(child) }
    end
    walk.call(plan["Plan"])
    fetches
  end

  def cardinalities
    Hash[TYPES.map { |type| [type, @db.exec("SELECT COUNT(*) FROM scalar_values_current_covering WHERE field_id = #{TYPES.index(type) + 1}").getvalue(0, 0).to_i] }]
  end

  def null_distribution
    @db.exec("SELECT COUNT(*) FILTER (WHERE field_id = 1 AND integer_value IS NULL) AS explicit_null, COUNT(*) FILTER (WHERE field_id = 1) AS present FROM scalar_values_current_covering").first.transform_values(&:to_i).merge("missing_integer_rows" => entities - @db.exec("SELECT COUNT(*) FROM scalar_values_current_covering WHERE field_id = 1").getvalue(0, 0).to_i)
  end

  def caveats
    base = ["Each candidate receives the same deterministic seed/data and exact candidate DDL, but candidates are separate tables in one disposable database.", "WAL and pg_stat_user_indexes are PostgreSQL-local observations; planner behavior and visibility-map state are not cross-version evidence.", "Explicit NULL-row and missing-row/include_missing plans are reported separately."]
    return base + ["Smoke-tier evidence only; no layout winner or production recommendation is made.", "Latency is local single-session wall-clock timing, not representative workload evidence."] if @tier == "smoke"

    base + ["Representative evidence is a co-tenant relative comparison under continuously active host workloads; it must not be read as clean-room absolute latency.", "Three rotated same-seed trials and dispersion are recorded; no layout winner or production recommendation is made."]
  end
end

ScalarIndexBenchmark.run(ARGV) if $PROGRAM_NAME == __FILE__
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Rails/IndexWith, Style/HashConversion
