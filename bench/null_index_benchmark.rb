# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/MethodLength, Rails/IndexWith -- SQL-heavy standalone benchmark evidence stays cohesive.
require "date"
require "digest"
require "json"
require "open3"
require "optparse"
require "pg"
require "securerandom"
require "time"

class NullIndexBenchmark
  TYPES = %w[integer decimal boolean date datetime string].freeze
  DISTRIBUTIONS = { "low_null" => 0.01, "high_null" => 0.50 }.freeze
  CANDIDATES = %w[partial_covering partial_covering_with_integer_null].freeze
  DB_PREFIX = "typed_eav_phase2_null_"
  ENTITIES = 100_000
  RESERVE_BYTES = 8 * (1024**3)
  MIN_FREE_BYTES = 30 * (1024**3)
  QUERY_REPETITIONS = 3

  def self.run(argv)
    options = { seed: nil, output: nil }
    OptionParser.new do |parser|
      parser.on("--seed SEED", Integer) { |value| options[:seed] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!(argv)
    abort "--seed and --output are required" unless options.values.all?
    abort "representative execution requires TYPED_EAV_NULL_REPRESENTATIVE_OK=1" unless ENV["TYPED_EAV_NULL_REPRESENTATIVE_OK"] == "1"
    new(**options).call
  end

  def initialize(seed:, output:)
    @seed = seed
    @output = output
    @database = "#{DB_PREFIX}#{Process.pid}_#{Time.now.utc.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
    @admin = PG.connect(connection_options.merge(dbname: ENV.fetch("PGMAINTENANCE_DB", "postgres")))
    @db = nil
    @created = false
    @cleanup = { "created_by_run" => false, "attempted" => false, "database_prefix_validated" => false, "dropped" => false }
    @candidate_order = ENV.fetch("TYPED_EAV_NULL_CANDIDATE_ORDER", CANDIDATES.join(",")).split(",")
    abort "invalid candidate order" unless @candidate_order.sort == CANDIDATES.sort
  end

  def call
    qualify_environment!
    create_database
    @db = PG.connect(connection_options.merge(dbname: @database))
    result = build_result
    cleanup
    result["environment"]["cleanup"] = @cleanup
    File.write(@output, "#{JSON.pretty_generate(result)}\n")
  ensure
    cleanup unless @cleanup["attempted"]
  end

  private

  def connection_options
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", "5432"), user: ENV.fetch("PGUSER", ENV.fetch("USER", "postgres")) }
  end

  def qualify_environment!
    @data_directory = @admin.exec("SHOW data_directory").getvalue(0, 0)
    observed = free_bytes(@data_directory)
    abort "representative storage gate failed: #{observed} bytes free" if observed < MIN_FREE_BYTES
  end

  def ensure_reserve!
    observed = free_bytes(@data_directory)
    abort "representative reserve breached: #{observed} bytes free" if observed < RESERVE_BYTES
  end

  def free_bytes(path)
    output, status = Open3.capture2("df", "-Pk", path)
    abort "unable to inspect PostgreSQL data volume" unless status.success?
    output.lines.last.split.fetch(3).to_i * 1024
  end

  def create_database
    @admin.exec("CREATE DATABASE #{@admin.quote_ident(@database)}")
    @created = true
    @cleanup["created_by_run"] = true
  end

  def cleanup
    return unless @admin && @created

    @cleanup["attempted"] = true
    @cleanup["database_prefix_validated"] = @database.start_with?(DB_PREFIX)
    return unless @cleanup["database_prefix_validated"]

    @db.close if @db && !@db.finished?
    @admin.exec("DROP DATABASE IF EXISTS #{@admin.quote_ident(@database)}")
    @cleanup["dropped"] = @admin.exec_params("SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", [@database]).getvalue(0, 0) == "t"
  end

  def build_result
    measurements = {}
    plans = {}
    checksums = {}
    DISTRIBUTIONS.each do |distribution, null_rate|
      measurements[distribution] = {}
      plans[distribution] = {}
      @candidate_order.each do |candidate|
        ensure_reserve!
        table = table_name(distribution, candidate)
        create_table(table, candidate)
        insertion = insert_rows(table, null_rate)
        checksums["#{distribution}/#{candidate}"] = insertion.delete("checksum")
        @db.exec("VACUUM (ANALYZE) #{table}")
        measurements[distribution][candidate] = insertion.merge(measure_table(table))
        plans[distribution][candidate] = explain_queries(table)
      end
      distribution_checksums = CANDIDATES.map { |candidate| checksums.fetch("#{distribution}/#{candidate}") }
      abort "candidate dataset checksum mismatch for #{distribution}" unless distribution_checksums.uniq.one?
    end
    {
      "generated_at_utc" => Time.now.utc.iso8601,
      "environment" => environment_metadata,
      "dataset" => dataset_metadata.merge("candidate_checksums" => checksums, "checksum_equal_within_distribution" => true),
      "candidates" => candidate_metadata,
      "measurements" => measurements,
      "explain_plans" => plans,
      "trial" => ENV.fetch("TYPED_EAV_TRIAL", "1").to_i,
      "candidate_order" => @candidate_order,
      "caveats" => [
        "The six-type table shape is intentional: a current-query-compatible integer IS NULL index also indexes every non-integer logical row because integer_value is NULL there.",
        "Repeated co-tenant evidence supports relative plan, buffer, storage, and WAL comparisons only; absolute latency is not a clean-room claim.",
        "include_missing is measured as the existing set-complement query over a generated complete host-id set.",
      ],
    }
  end

  def environment_metadata
    settings = %w[server_version server_encoding shared_buffers work_mem maintenance_work_mem].to_h { |setting| [setting, @admin.exec("SHOW #{setting}").getvalue(0, 0)] }
    settings.merge("ruby" => RUBY_VERSION, "pg" => PG.library_version, "database" => @database, "data_directory" => @data_directory,
                   "observed_free_bytes" => free_bytes(@data_directory), "required_free_bytes" => MIN_FREE_BYTES,
                   "reserve_bytes" => RESERVE_BYTES, "cleanup" => @cleanup)
  end

  def dataset_metadata
    {
      "seed" => @seed, "entities" => ENTITIES,
      "rows_per_candidate" => ENTITIES - (ENTITIES / 20) + (ENTITIES * (TYPES.length - 1)),
      "missing_integer_rows" => ENTITIES / 20, "types" => TYPES,
      "distributions" => DISTRIBUTIONS.transform_values { |rate| { "integer_explicit_null_rate_among_present" => rate } },
      "generation" => "streaming deterministic same-seed six-type rows; identical logical data within each distribution"
    }
  end

  def candidate_metadata
    {
      "partial_covering" => { "integer_index_ddl" => "(field_id, integer_value) INCLUDE (entity_id) WHERE integer_value IS NOT NULL" },
      "partial_covering_with_integer_null" => {
        "integer_index_ddl" => "(field_id, integer_value) INCLUDE (entity_id) WHERE integer_value IS NOT NULL",
        "additional_null_index_ddl" => "(field_id, entity_id) WHERE integer_value IS NULL",
        "warning" => "The predicate necessarily includes logical rows stored in decimal/boolean/date/datetime/string columns under current query semantics.",
      },
    }
  end

  def table_name(distribution, candidate)
    @db.quote_ident("null_values_#{distribution}_#{candidate}")
  end

  def create_table(table, candidate)
    @db.exec("CREATE TABLE #{table} (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, entity_type text NOT NULL, entity_id integer NOT NULL, field_id integer NOT NULL, integer_value integer, decimal_value numeric(12, 2), boolean_value boolean, date_value date, datetime_value timestamptz, string_value text)")
    @db.exec("CREATE INDEX ON #{table} (field_id, integer_value) INCLUDE (entity_id) WHERE integer_value IS NOT NULL")
    @db.exec("CREATE INDEX ON #{table} (entity_id, field_id)")
    @db.exec("CREATE INDEX ON #{table} (field_id, entity_id) WHERE integer_value IS NULL") if candidate == "partial_covering_with_integer_null"
  end

  def insert_rows(table, null_rate)
    checksum = Digest::SHA256.new
    inserted = 0
    wal_start = current_wal_lsn
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @db.copy_data("COPY #{table} (entity_type, entity_id, field_id, integer_value, decimal_value, boolean_value, date_value, datetime_value, string_value) FROM STDIN WITH (FORMAT csv, NULL '\\N')") do
      each_generated_row(null_rate) do |row|
        checksum << row.inspect
        @db.put_copy_data("#{row.map { |value| value.nil? ? '\\N' : value }.join(",")}\n")
        inserted += 1
        ensure_reserve! if (inserted % 100_000).zero?
      end
    end
    elapsed_ms = elapsed_since(started)
    { "inserted_rows" => inserted, "insert_elapsed_ms" => elapsed_ms,
      "insert_rows_per_second" => inserted / ([elapsed_ms, 0.001].max / 1_000),
      "insert_wal_bytes" => wal_delta(wal_start), "checksum" => checksum.hexdigest }
  end

  def each_generated_row(null_rate)
    rng = Random.new(@seed)
    ENTITIES.times do |entity|
      TYPES.each_with_index do |type, index|
        next if type == "integer" && (entity % 20).zero?

        row = Array.new(9)
        row[0, 3] = ["Contact", entity, index + 1]
        case type
        when "integer" then row[3] = rng.rand < null_rate ? nil : rng.rand(100)
        when "decimal" then row[4] = format("%.2f", rng.rand * 1_000)
        when "boolean" then row[5] = rng.rand(2).zero?
        when "date" then row[6] = Date.new(2020, 1, 1).next_day(rng.rand(365))
        when "datetime" then row[7] = (Time.utc(2020, 1, 1) + (rng.rand(365) * 86_400)).iso8601
        when "string" then row[8] = "value-#{rng.rand(31)}"
        end
        yield row
      end
    end
  end

  def measure_table(table)
    counts = @db.exec("SELECT COUNT(*) FILTER (WHERE field_id = 1 AND integer_value IS NULL) explicit_null, COUNT(*) FILTER (WHERE field_id = 1 AND integer_value IS NOT NULL) non_null, COUNT(*) FILTER (WHERE integer_value IS NULL) null_index_eligible FROM #{table}").first.transform_values(&:to_i)
    raw_name = table.delete('"')
    index_sizes = @db.exec("SELECT indexrelname, pg_relation_size(indexrelid) bytes FROM pg_stat_user_indexes WHERE relname = #{literal(raw_name)} ORDER BY indexrelname").to_a.to_h { |row| [row["indexrelname"], row["bytes"].to_i] }
    {
      "counts" => counts.merge("missing" => ENTITIES / 20),
      "relation_bytes" => @db.exec("SELECT pg_total_relation_size(#{literal(raw_name)})").getvalue(0, 0).to_i,
      "index_bytes" => @db.exec("SELECT pg_indexes_size(#{literal(raw_name)})").getvalue(0, 0).to_i,
      "individual_index_bytes" => index_sizes,
    }.merge(measure_null_transition(table))
  end

  def measure_null_transition(table)
    wal_start = current_wal_lsn
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    changed = @db.exec("UPDATE #{table} SET integer_value = CASE WHEN integer_value IS NULL THEN 42 ELSE NULL END WHERE field_id = 1 AND entity_id % 19 = 1")
    forward = { "rows" => changed.cmd_tuples, "elapsed_ms" => elapsed_since(started), "wal_bytes" => wal_delta(wal_start) }
    wal_start = current_wal_lsn
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @db.exec("UPDATE #{table} SET integer_value = CASE WHEN integer_value IS NULL THEN 42 ELSE NULL END WHERE field_id = 1 AND entity_id % 19 = 1")
    reverse = { "elapsed_ms" => elapsed_since(started), "wal_bytes" => wal_delta(wal_start) }
    { "null_transition_update" => { "forward" => forward, "reverse" => reverse } }
  end

  def explain_queries(table)
    queries = {
      "explicit_stored_null" => "SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NULL",
      "eq_nil" => "SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NULL",
      "null_inclusive_not_eq" => "SELECT entity_id FROM #{table} WHERE field_id = 1 AND (integer_value <> 42 OR integer_value IS NULL)",
      "is_not_null" => "SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NOT NULL",
      "include_missing" => "SELECT entity_id FROM generate_series(0, #{ENTITIES - 1}) entity_id WHERE entity_id NOT IN (SELECT entity_id FROM #{table} WHERE field_id = 1 AND integer_value IS NOT NULL)",
    }
    queries.to_h do |label, sql|
      repetitions = Array.new(QUERY_REPETITIONS) do
        plan = JSON.parse(@db.exec("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}").getvalue(0, 0)).first
        plan.merge("observed_node_types" => plan_nodes(plan), "heap_fetches" => plan_heap_fetches(plan))
      end
      [label, repetitions]
    end
  end

  def plan_nodes(plan)
    walk_plan(plan["Plan"]).filter_map { |node| node["Node Type"] }
  end

  def plan_heap_fetches(plan)
    walk_plan(plan["Plan"]).filter_map { |node| node["Heap Fetches"] if node.key?("Heap Fetches") }
  end

  def walk_plan(root)
    nodes = []
    visit = lambda do |node|
      nodes << node
      node.fetch("Plans", []).each { |child| visit.call(child) }
    end
    visit.call(root)
    nodes
  end

  def current_wal_lsn
    @db.exec("SELECT pg_current_wal_lsn()").getvalue(0, 0)
  end

  def wal_delta(start_lsn)
    @db.exec_params("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), $1)", [start_lsn]).getvalue(0, 0).to_i
  rescue PG::Error
    nil
  end

  def elapsed_since(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3)
  end

  def literal(value)
    @db.escape_literal(value)
  end
end

NullIndexBenchmark.run(ARGV) if $PROGRAM_NAME == __FILE__
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/MethodLength, Rails/IndexWith
