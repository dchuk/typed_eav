# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Rails/IndexWith, Rails/SquishedSQLHeredocs, Style/OneClassPerFile -- standalone benchmark evidence is intentionally cohesive.
require "digest"
require "date"
require "json"
require "open3"
require "optparse"
require "pg"
require "securerandom"
require "time"

class PlannerStatisticsBenchmark
  DB_PREFIX = "typed_eav_phase4_stats_"
  SMOKE_ENTITIES = 10_000
  REPRESENTATIVE_ENTITIES = 300_000
  REPRESENTATIVE_MIN_FREE_BYTES = 20 * (1024**3)
  REPRESENTATIVE_RESERVE_BYTES = 8 * (1024**3)
  FIELD_IDS = { int_uniform: 101, int_skewed: 102, string_uniform: 201, string_skewed: 202, date_uniform: 301, date_skewed: 302 }.freeze
  CANDIDATES = {
    "baseline" => [],
    "dependencies" => ["dependencies"],
    "mcv" => ["mcv"],
    "ndistinct" => ["ndistinct"],
    "dependencies_mcv_ndistinct" => %w[dependencies mcv ndistinct],
  }.freeze
  TYPE_COLUMNS = { "integer" => "integer_value", "string" => "string_value", "date" => "date_value" }.freeze
  QUERY_SPECS = [
    ["integer_uniform_eq", :int_uniform, "integer_value = 42"],
    ["integer_skewed_common_eq", :int_skewed, "integer_value = 1"],
    ["integer_skewed_rare_eq", :int_skewed, "integer_value = 997"],
    ["integer_skewed_range", :int_skewed, "integer_value BETWEEN 1 AND 3"],
    ["string_uniform_eq", :string_uniform, "string_value = 'code-0042'"],
    ["string_skewed_common_eq", :string_skewed, "string_value = 'popular'"],
    ["string_skewed_rare_eq", :string_skewed, "string_value = 'code-0997'"],
    ["date_uniform_eq", :date_uniform, "date_value = DATE '2024-02-12'"],
    ["date_skewed_common_eq", :date_skewed, "date_value = DATE '2024-01-01'"],
    ["date_skewed_rare_eq", :date_skewed, "date_value = DATE '2026-09-24'"],
    ["date_skewed_range", :date_skewed, "date_value BETWEEN DATE '2024-01-01' AND DATE '2024-01-03'"],
  ].freeze

  def self.run(argv)
    options = { tier: nil, seed: nil, output: nil }
    OptionParser.new do |parser|
      parser.on("--tier TIER", %w[smoke representative]) { |value| options[:tier] = value }
      parser.on("--seed SEED", Integer) { |value| options[:seed] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!(argv)
    abort "--tier, --seed, and --output are required" unless options.values.all?
    abort "representative tier requires TYPED_EAV_REPRESENTATIVE_OK=1" if options[:tier] == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
    new(**options).call
  end

  def initialize(tier:, seed:, output:)
    @tier = tier
    @seed = seed
    @output = output
    @entities = tier == "smoke" ? SMOKE_ENTITIES : Integer(ENV.fetch("TYPED_EAV_REPRESENTATIVE_ENTITIES", REPRESENTATIVE_ENTITIES.to_s))
    @order = ENV.fetch("TYPED_EAV_CANDIDATE_ORDER", CANDIDATES.keys.join(",")).split(",")
    abort "invalid candidate order" unless @order.sort == CANDIDATES.keys.sort
    @database = "#{DB_PREFIX}#{Process.pid}_#{Time.now.utc.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
    @admin = PG.connect(connection.merge(dbname: ENV.fetch("PGMAINTENANCE_DB", "postgres")))
    @cleanup = { "created_by_run" => false, "attempted" => false, "database_prefix_validated" => false, "dropped" => false }
  end

  def call
    qualify!
    @admin.exec("CREATE DATABASE #{@admin.quote_ident(@database)}")
    @cleanup["created_by_run"] = true
    @db = PG.connect(connection.merge(dbname: @database))
    result = run_all
    cleanup
    result["environment"]["cleanup"] = @cleanup
    File.write(@output, "#{JSON.pretty_generate(result)}\n")
  ensure
    cleanup
    @admin&.close
  end

  private

  def connection
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", nil), user: ENV.fetch("PGUSER", nil), password: ENV.fetch("PGPASSWORD", nil) }.compact
  end

  def qualify!
    projected = @entities * 6 * 180
    abort "smoke footprint exceeds 500 MiB" if @tier == "smoke" && projected > 500 * 1024 * 1024
    return if @tier == "smoke"

    free = free_bytes(@admin.exec("SHOW data_directory").getvalue(0, 0))
    abort "representative storage is not qualified" if free < [REPRESENTATIVE_MIN_FREE_BYTES, projected + REPRESENTATIVE_RESERVE_BYTES].max
  end

  def cleanup
    return unless @admin && @cleanup["created_by_run"]

    @cleanup["attempted"] = true
    @cleanup["database_prefix_validated"] = @database.start_with?(DB_PREFIX)
    return unless @cleanup["database_prefix_validated"]

    @db.close if @db && !@db.finished?
    @admin.exec("DROP DATABASE IF EXISTS #{@admin.quote_ident(@database)}")
    @cleanup["dropped"] = @admin.exec_params("SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=$1)", [@database]).getvalue(0, 0) == "t"
    @cleanup["created_by_run"] = false
  end

  def run_all
    create_table
    checksum = load_rows
    create_indexes
    configure_targets
    blocks = @order.each_with_index.map { |candidate, position| run_block(candidate, position + 1) }
    {
      "schema_version" => 2,
      "generated_at_utc" => Time.now.utc.iso8601,
      "trial" => ENV.fetch("TYPED_EAV_TRIAL", "1").to_i,
      "candidate_order" => @order,
      "environment" => environment,
      "dataset" => dataset(checksum),
      "candidate_definitions" => candidate_definitions,
      "statistics_targets" => statistics_targets,
      "blocks" => blocks,
      "limitations" => limitations,
    }
  end

  def create_table
    @db.exec <<~SQL
      CREATE TABLE typed_eav_values_bench (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        entity_id integer NOT NULL,
        entity_type text NOT NULL DEFAULT 'BenchmarkEntity',
        field_id integer NOT NULL,
        integer_value integer,
        string_value text,
        date_value date
      )
    SQL
  end

  def load_rows
    digest = Digest::SHA256.new
    @db.copy_data("COPY typed_eav_values_bench (entity_id,field_id,integer_value,string_value,date_value) FROM STDIN WITH (FORMAT csv, NULL '\\N')") do
      @entities.times do |entity|
        rows_for(entity).each do |row|
          digest << row.join("|") << "\n"
          @db.put_copy_data("#{row.join(",")}\n")
        end
      end
    end
    digest.hexdigest
  end

  def rows_for(entity)
    uniform = mixed(entity) % 1_000
    bucket = mixed(entity ^ @seed) % 100
    skewed = case bucket
             when 0...60 then 1
             when 60...80 then 2
             when 80...90 then 3
             else 900 + (mixed(entity + 17) % 100)
             end
    date_uniform = Date.new(2024, 1, 1) + (uniform % 365)
    date_skewed = Date.new(2024, 1, 1) + skewed
    [
      [entity, FIELD_IDS[:int_uniform], uniform, "\\N", "\\N"],
      [entity, FIELD_IDS[:int_skewed], skewed, "\\N", "\\N"],
      [entity, FIELD_IDS[:string_uniform], "\\N", format("code-%04d", uniform), "\\N"],
      [entity, FIELD_IDS[:string_skewed], "\\N", skewed <= 3 ? %w[unused popular common frequent][skewed] : format("code-%04d", skewed), "\\N"],
      [entity, FIELD_IDS[:date_uniform], "\\N", "\\N", date_uniform.iso8601],
      [entity, FIELD_IDS[:date_skewed], "\\N", "\\N", date_skewed.iso8601],
    ]
  end

  def mixed(value)
    x = (value + @seed) & 0xffffffff
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
    x ^ (x >> 16)
  end

  def create_indexes
    TYPE_COLUMNS.each_value do |column|
      @db.exec("CREATE INDEX idx_bench_#{column} ON typed_eav_values_bench (field_id, #{column}) INCLUDE (entity_id) WHERE #{column} IS NOT NULL")
    end
  end

  def configure_targets
    @db.exec("SET default_statistics_target=100")
    %w[field_id integer_value string_value date_value].each do |column|
      @db.exec("ALTER TABLE typed_eav_values_bench ALTER COLUMN #{column} SET STATISTICS 100")
    end
  end

  def run_block(candidate, position)
    drop_statistics
    ddl = create_statistics(candidate)
    analyze = analyze_evidence
    before = pg_stats_snapshot
    candidate_queries = query_suite
    metadata = statistics_metadata
    drop_statistics
    after = pg_stats_snapshot
    abort "pg_stats changed after DROP STATISTICS without ANALYZE" unless before.fetch("sha256") == after.fetch("sha256")
    paired_queries = query_suite
    {
      "position" => position,
      "candidate" => candidate,
      "ddl" => ddl,
      "analyze" => analyze,
      "statistics_metadata" => metadata,
      "dataset_checksum" => dataset_checksum,
      "pg_stats_before_drop" => before,
      "drop_statistics_without_analyze" => candidate == "baseline" ? [] : metadata.map { |row| "DROP STATISTICS #{row.fetch("name")}" },
      "pg_stats_after_drop" => after,
      "pg_stats_unchanged" => true,
      "candidate_queries" => candidate_queries,
      "paired_base_queries" => paired_queries,
    }
  end

  def query_suite
    QUERY_SPECS.to_h { |name, field, predicate| [name, query_evidence(field, predicate)] }
  end

  def create_statistics(candidate)
    kinds = CANDIDATES.fetch(candidate)
    return [] if kinds.empty?

    TYPE_COLUMNS.map do |type, column|
      sql = "CREATE STATISTICS stats_#{candidate}_#{type} (#{kinds.join(", ")}) ON field_id, #{column} FROM typed_eav_values_bench"
      @db.exec(sql)
      target_sql = "ALTER STATISTICS stats_#{candidate}_#{type} SET STATISTICS 100"
      @db.exec(target_sql)
      [sql, target_sql]
    end
    .flatten
  end

  def drop_statistics
    @db.exec("SELECT stxname FROM pg_statistic_ext WHERE stxnamespace=current_schema()::regnamespace").each do |row|
      @db.exec("DROP STATISTICS #{@db.quote_ident(row.fetch("stxname"))}")
    end
  end

  def analyze_evidence
    started = clock
    @db.exec("ANALYZE (VERBOSE) typed_eav_values_bench")
    { "ddl" => "ANALYZE (VERBOSE) typed_eav_values_bench", "elapsed_ms" => elapsed(started), "table_rows" => @db.exec("SELECT count(*) FROM typed_eav_values_bench").getvalue(0, 0).to_i }
  end

  def query_evidence(field, predicate)
    sql = "SELECT entity_id FROM typed_eav_values_bench WHERE field_id=#{FIELD_IDS.fetch(field)} AND #{predicate}"
    document = JSON.parse(@db.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{sql}").getvalue(0, 0)).first
    root = document.fetch("Plan")
    estimated = root.fetch("Plan Rows").to_f
    actual = root.fetch("Actual Rows").to_f
    {
      "sql" => sql,
      "estimated_rows" => estimated,
      "actual_rows" => actual,
      "metrics" => estimation_metrics(estimated, actual),
      "planning_time_ms" => document.fetch("Planning Time"),
      "execution_time_ms" => document.fetch("Execution Time"),
      "plan_signature" => plan_signature(root),
      "has_sequential_scan" => plan_nodes(root).any? { |node| node["Node Type"] == "Seq Scan" },
      "has_index_only_scan" => plan_nodes(root).any? { |node| node["Node Type"] == "Index Only Scan" },
      "plan" => document,
      "buffer_summary" => buffer_summary(root),
    }
  end

  def estimation_metrics(estimated, actual)
    zero_class = if actual.zero? && estimated.zero?
                   "exact_zero"
                 elsif actual.zero?
                   "zero_actual_overestimate"
                 elsif estimated.zero?
                   "catastrophic_underestimate"
                 else
                   "nonzero"
                 end
    relative = actual.zero? ? nil : (estimated - actual) / actual
    raw_log = estimated.positive? && actual.positive? ? Math.log2(estimated / actual) : nil
    corrected = Math.log2((estimated + 0.5) / (actual + 0.5))
    {
      "zero_class" => zero_class,
      "signed_row_error" => estimated - actual,
      "absolute_row_error" => (estimated - actual).abs,
      "signed_relative_error" => relative,
      "absolute_relative_error" => relative&.abs,
      "raw_signed_log2_error" => raw_log,
      "raw_log2_conceptual" => zero_class == "catastrophic_underestimate" ? "-Infinity" : nil,
      "corrected_signed_log2_error" => corrected,
      "absolute_corrected_log2_error" => corrected.abs,
    }
  end

  def plan_nodes(root)
    [root, *Array(root["Plans"]).flat_map { |child| plan_nodes(child) }]
  end

  def plan_signature(node)
    keys = ["Node Type", "Join Type", "Relation Name", "Index Name", "Scan Direction", "Index Cond", "Filter"]
    own = keys.filter_map { |key| "#{key}=#{node[key]}" if node.key?(key) }.join("|")
    children = Array(node["Plans"]).map { |child| plan_signature(child) }
    "(#{own}#{children.join})"
  end

  def buffer_summary(root)
    nodes = plan_nodes(root)
    %w[Shared Hit Blocks Shared Read Blocks Shared Dirtied Blocks Shared Written Blocks].to_h do |key|
      [key.downcase.tr(" ", "_"), nodes.sum { |node| node.fetch(key, 0) }]
    end
  end

  def statistics_metadata
    @db.exec(<<~SQL).map do |row|
      SELECT e.stxname, e.stxkeys::text, e.stxkind::text, e.stxstattarget,
             COALESCE(pg_column_size(d.stxdndistinct),0) ndistinct_bytes,
             COALESCE(pg_column_size(d.stxddependencies),0) dependencies_bytes,
             COALESCE(pg_column_size(d.stxdmcv),0) mcv_bytes
      FROM pg_statistic_ext e LEFT JOIN pg_statistic_ext_data d ON d.stxoid=e.oid
      WHERE e.stxnamespace=current_schema()::regnamespace ORDER BY e.stxname
    SQL
      { "name" => row.fetch("stxname"), "keys" => row.fetch("stxkeys"), "kinds" => row.fetch("stxkind"), "target" => row.fetch("stxstattarget").to_i, "ndistinct_bytes" => row.fetch("ndistinct_bytes").to_i, "dependencies_bytes" => row.fetch("dependencies_bytes").to_i, "mcv_bytes" => row.fetch("mcv_bytes").to_i }
    end
  end

  def pg_stats_snapshot
    rows = @db.exec(<<~SQL).map { |row| row.sort.to_h }
      SELECT attname, inherited, null_frac, avg_width, n_distinct,
             most_common_vals::text, most_common_freqs::text,
             histogram_bounds::text, correlation
      FROM pg_stats WHERE schemaname=current_schema() AND tablename='typed_eav_values_bench'
      ORDER BY attname, inherited
    SQL
    { "rows" => rows, "sha256" => Digest::SHA256.hexdigest(JSON.generate(rows)) }
  end

  def dataset_checksum
    @db.exec("SELECT md5(count(*)::text||':'||sum(entity_id)::text||':'||sum(field_id)::text||':'||sum(hashtextextended(concat_ws(':',id,entity_id,field_id,integer_value,string_value,date_value),4601))::text) FROM typed_eav_values_bench").getvalue(0, 0)
  end

  def dataset(stream_checksum)
    counts = @db.exec("SELECT field_id,count(*) rows,count(integer_value) integer_nonnull,count(string_value) string_nonnull,count(date_value) date_nonnull FROM typed_eav_values_bench GROUP BY field_id ORDER BY field_id").map { |row| row.transform_values { |value| value.match?(/\A\d+\z/) ? value.to_i : value } }
    { "seed" => @seed, "entities" => @entities, "rows" => @entities * 6, "stream_sha256" => stream_checksum, "database_checksum" => dataset_checksum, "field_counts" => counts, "distribution" => "Deterministic uniform modulo-1000 and skewed 60/20/10/10 buckets; typed columns are NULL on unrelated field-family rows." }
  end

  def candidate_definitions
    CANDIDATES.transform_values { |kinds| { "statistics_kinds" => kinds, "ddl_template" => kinds.empty? ? [] : TYPE_COLUMNS.map { |type, column| "CREATE STATISTICS stats_<candidate>_#{type} (#{kinds.join(", ")}) ON field_id, #{column} FROM typed_eav_values_bench" } } }
  end

  def statistics_targets
    rows = @db.exec("SELECT attname,attstattarget FROM pg_attribute WHERE attrelid='typed_eav_values_bench'::regclass AND attname IN ('field_id','integer_value','string_value','date_value') ORDER BY attname").map { |row| { "column" => row.fetch("attname"), "target" => row.fetch("attstattarget").to_i } }
    { "default_statistics_target" => @db.exec("SHOW default_statistics_target").getvalue(0, 0).to_i, "columns" => rows, "extended_target" => 100 }
  end

  def environment
    { "tier" => @tier, "postgresql_version" => @db.exec("SHOW server_version").getvalue(0, 0), "postgresql_version_num" => @db.exec("SHOW server_version_num").getvalue(0, 0).to_i, "ruby_version" => RUBY_VERSION, "database" => @database, "table_bytes" => @db.exec("SELECT pg_total_relation_size('typed_eav_values_bench')").getvalue(0, 0).to_i }
  end

  def limitations
    ["PostgreSQL 17 is the sole planner-performance evidence; no cross-major planner generalization is made.", "Absolute timing on the co-tenant host is diagnostic; estimation ratios and plan selection are the primary evidence.", "This benchmark creates statistics only in a disposable database and makes no production policy decision.", "Extended statistics describe same-row field/value correlation; unrelated field-family rows deliberately retain NULL typed cells."]
  end

  def free_bytes(path)
    output, status = Open3.capture2("df", "-Pk", path)
    abort "unable to inspect PostgreSQL volume" unless status.success?
    output.lines.last.split.fetch(3).to_i * 1024
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed(started)
    ((clock - started) * 1_000).round(3)
  end
end

# Aggregates the preregistered T049 blocked crossover without touching PostgreSQL.
class PlannerStatisticsAggregate
  CANDIDATES = %w[dependencies mcv ndistinct dependencies_mcv_ndistinct].freeze
  SCHEDULE = [
    %w[baseline dependencies dependencies_mcv_ndistinct mcv ndistinct],
    %w[dependencies mcv baseline ndistinct dependencies_mcv_ndistinct],
    %w[mcv ndistinct dependencies dependencies_mcv_ndistinct baseline],
    %w[ndistinct dependencies_mcv_ndistinct mcv baseline dependencies],
    %w[dependencies_mcv_ndistinct baseline ndistinct dependencies mcv],
    %w[ndistinct mcv dependencies_mcv_ndistinct dependencies baseline],
    %w[dependencies_mcv_ndistinct ndistinct baseline mcv dependencies],
    %w[baseline dependencies_mcv_ndistinct dependencies ndistinct mcv],
    %w[dependencies baseline mcv dependencies_mcv_ndistinct ndistinct],
    %w[mcv dependencies ndistinct baseline dependencies_mcv_ndistinct],
  ].freeze
  PRIMARY_MARGIN = 0.25
  SECONDARY_MARGIN = 0.10
  BOOTSTRAPS = 20_000

  def self.run(argv)
    output = argv.shift
    abort "aggregate requires OUTPUT and ten trial paths" unless output && argv.size == 10
    result = new(argv).call
    File.write(output, "#{JSON.pretty_generate(result)}\n")
  end

  def initialize(paths)
    @trials = paths.map { |path| JSON.parse(File.read(path)) }.sort_by { |trial| trial.fetch("trial") }
    rng = Random.new(4601)
    @bootstrap_matrix = Array.new(BOOTSTRAPS) { Array.new(10) { rng.rand(10) } }
  end

  def call
    mechanical = mechanical_validation
    abort "preregistered protocol is mechanically incomplete" unless mechanical.values.all?

    {
      "schema_version" => 2,
      "generated_at_utc" => Time.now.utc.iso8601,
      "protocol" => protocol,
      "mechanical_validation" => mechanical.merge("accepted" => true),
      "trials" => @trials,
      "inference" => CANDIDATES.to_h { |candidate| [candidate, candidate_inference(candidate)] },
      "plan_stability" => plan_stability,
      "raw_summary" => raw_summary,
    }
  end

  private

  def mechanical_validation
    blocks = @trials.flat_map { |trial| trial.fetch("blocks") }
    plans = blocks.sum { |block| block.fetch("candidate_queries").size + block.fetch("paired_base_queries").size }
    {
      "ten_trials" => @trials.map { |trial| trial.fetch("trial") } == (1..10).to_a,
      "exact_williams_schedule" => @trials.map { |trial| trial.fetch("candidate_order") } == SCHEDULE,
      "fifty_blocks" => blocks.size == 50,
      "one_analyze_per_block" => blocks.all? { |block| block.dig("analyze", "ddl") == "ANALYZE (VERBOSE) typed_eav_values_bench" },
      "eleven_hundred_raw_plans" => plans == 1_100,
      "paired_pg_stats_unchanged" => blocks.all? { |block| block.fetch("pg_stats_unchanged") && block.dig("pg_stats_before_drop", "sha256") == block.dig("pg_stats_after_drop", "sha256") },
      "targets_are_100" => @trials.all? { |trial| trial.dig("statistics_targets", "default_statistics_target") == 100 && trial.dig("statistics_targets", "extended_target") == 100 && trial.dig("statistics_targets", "columns").all? { |row| row.fetch("target") == 100 } && trial.fetch("blocks").all? { |block| block.fetch("statistics_metadata").all? { |row| row.fetch("target") == 100 } } },
      "seed_and_cardinality" => @trials.all? { |trial| trial.dig("dataset", "seed") == 4601 && trial.dig("dataset", "entities") == 300_000 },
      "dataset_checksums_equal" => @trials.map { |trial| trial.dig("dataset", "database_checksum") }.uniq.one? && blocks.map { |block| block.fetch("dataset_checksum") }.uniq.one?,
      "shared_bootstrap_matrix" => @bootstrap_matrix.size == BOOTSTRAPS && @bootstrap_matrix.all? { |sample| sample.size == 10 },
    }
  end

  def candidate_inference(candidate)
    trial_rows = @trials.map do |trial|
      block = trial.fetch("blocks").find { |item| item.fetch("candidate") == candidate }
      deltas = block.fetch("candidate_queries").map do |query, evidence|
        paired = block.dig("paired_base_queries", query)
        metric_delta(query, evidence, paired)
      end
      {
        "trial" => trial.fetch("trial"),
        "primary_median_delta" => median(deltas.map { |row| row.fetch("primary_delta") }),
        "secondary_median_delta" => median(deltas.filter_map { |row| row["secondary_delta"] }),
        "query_deltas" => deltas,
      }
    end
    query_names = trial_rows.first.fetch("query_deltas").map { |row| row.fetch("query") }
    primary = endpoint(trial_rows.map { |row| row.fetch("primary_median_delta") }, 0.00625, 0.99375, PRIMARY_MARGIN)
    secondary = endpoint(trial_rows.map { |row| row.fetch("secondary_median_delta") }, 0.00625, 0.99375, SECONDARY_MARGIN)
    {
      "trial_statistics" => trial_rows,
      "candidate_wide" => { "primary" => primary, "secondary" => secondary, "combined_classification" => combined(primary, secondary) },
      "queries" => query_names.to_h do |query|
        rows = trial_rows.map { |row| row.fetch("query_deltas").find { |item| item.fetch("query") == query } }
        p_endpoint = endpoint(rows.map { |row| row.fetch("primary_delta") }, 0.025, 0.975, PRIMARY_MARGIN)
        secondary_values = rows.filter_map { |row| row["secondary_delta"] }
        s_endpoint = secondary_values.size == 10 ? endpoint(secondary_values, 0.025, 0.975, SECONDARY_MARGIN) : { "classification" => "inconclusive", "reason" => "relative error undefined when actual rows are zero" }
        [query, { "primary" => p_endpoint, "secondary" => s_endpoint, "combined_classification" => combined(p_endpoint, s_endpoint) }]
      end,
    }
  end

  def metric_delta(query, candidate, paired)
    candidate_metrics = candidate.fetch("metrics")
    paired_metrics = paired.fetch("metrics")
    secondary = candidate_metrics.fetch("absolute_relative_error") - paired_metrics.fetch("absolute_relative_error") if candidate_metrics["absolute_relative_error"] && paired_metrics["absolute_relative_error"]
    {
      "query" => query,
      "primary_delta" => candidate_metrics.fetch("absolute_corrected_log2_error") - paired_metrics.fetch("absolute_corrected_log2_error"),
      "secondary_delta" => secondary,
      "candidate_zero_class" => candidate_metrics.fetch("zero_class"),
      "paired_zero_class" => paired_metrics.fetch("zero_class"),
    }
  end

  def endpoint(values, lower_probability, upper_probability, margin)
    bootstrapped = @bootstrap_matrix.map { |indices| median(indices.map { |index| values.fetch(index) }) }
    interval = [type7(bootstrapped, lower_probability), type7(bootstrapped, upper_probability)]
    { "point_median" => median(values), "interval" => interval, "margin" => margin, "classification" => classify(interval, margin) }
  end

  def classify(interval, margin)
    lower, upper = interval
    return "improvement" if upper <= -margin
    return "worsening" if lower >= margin
    return "practical_equivalence" if lower >= -margin && upper <= margin

    "inconclusive"
  end

  def combined(primary, secondary)
    pair = [primary["classification"], secondary["classification"]]
    return "mixed" if pair.sort == %w[improvement worsening]

    primary.fetch("classification")
  end

  def plan_stability
    CANDIDATES.to_h do |candidate|
      queries = @trials.first.fetch("blocks").first.fetch("candidate_queries").keys
      [candidate, queries.to_h { |query| [query, plan_endpoint(candidate, query)] }]
    end
  end

  def plan_endpoint(candidate, query)
    pairs = @trials.map do |trial|
      block = trial.fetch("blocks").find { |item| item.fetch("candidate") == candidate }
      [block.dig("candidate_queries", query), block.dig("paired_base_queries", query)]
    end
    frequencies = pairs.map { |pair| pair.first.fetch("plan_signature") }.tally
    modal_signature, modal_count = frequencies.max_by { |_signature, count| count }
    paired_changes = pairs.count { |candidate_plan, base_plan| candidate_plan.fetch("plan_signature") != base_plan.fetch("plan_signature") }
    base_modal_count = pairs.map { |pair| pair.last.fetch("plan_signature") }.tally.values.max
    {
      "signature_frequencies" => frequencies,
      "modal_signature" => modal_signature,
      "modal_share" => modal_count / 10.0,
      "modal_share_wilson_95" => wilson(modal_count, 10),
      "stability" => stability_label(modal_count),
      "paired_shape_changes" => paired_changes,
      "consistent_candidate_shift" => paired_changes >= 9 && modal_count >= 9,
      "paired_base_modal_count" => base_modal_count,
      "sequential_scan_count" => pairs.count { |pair| pair.first.fetch("has_sequential_scan") },
      "index_only_loss_count" => pairs.count { |candidate_plan, base_plan| base_plan.fetch("has_index_only_scan") && !candidate_plan.fetch("has_index_only_scan") },
    }
  end

  def stability_label(modal_count)
    return "stable" if modal_count == 10
    return "near_stable" if modal_count == 9

    "sampling_variable"
  end

  def wilson(successes, total)
    z = 1.959963984540054
    proportion = successes.to_f / total
    denominator = 1 + ((z**2) / total)
    center = (proportion + ((z**2) / (2 * total))) / denominator
    half = (z * Math.sqrt((proportion * (1 - proportion) / total) + ((z**2) / (4 * (total**2))))) / denominator
    [center - half, center + half]
  end

  def raw_summary
    %w[baseline dependencies mcv ndistinct dependencies_mcv_ndistinct].to_h do |candidate|
      rows = @trials.map { |trial| trial.fetch("blocks").find { |block| block.fetch("candidate") == candidate } }.flat_map { |block| block.fetch("candidate_queries").values }
      primary = rows.map { |row| row.dig("metrics", "absolute_corrected_log2_error") }
      secondary = rows.filter_map { |row| row.dig("metrics", "absolute_relative_error") }
      [candidate, { "primary" => distribution(primary), "secondary" => distribution(secondary), "zero_classes" => rows.map { |row| row.dig("metrics", "zero_class") }.tally }]
    end
  end

  def distribution(values)
    center = median(values)
    { "count" => values.size, "median" => center, "mad" => median(values.map { |value| (value - center).abs }), "p90" => type7(values, 0.90) }
  end

  def median(values)
    type7(values, 0.5)
  end

  def type7(values, probability)
    sorted = values.sort
    h = (sorted.size - 1) * probability
    lower = h.floor
    upper = h.ceil
    sorted.fetch(lower) + ((h - lower) * (sorted.fetch(upper) - sorted.fetch(lower)))
  end

  def protocol
    { "seed" => 4601, "trials" => 10, "blocks" => 50, "schedule" => SCHEDULE, "statistics_target" => 100, "bootstrap_replicates" => BOOTSTRAPS, "bootstrap_unit" => "complete trial", "bootstrap_rng" => "Ruby Random.new(4601), shared matrix", "quantile" => "Type-7", "candidate_interval" => [0.00625, 0.99375], "query_interval" => [0.025, 0.975], "primary_margin_log2" => PRIMARY_MARGIN, "secondary_margin_absolute_relative" => SECONDARY_MARGIN, "acceptance" => "mechanical completeness independent of inferential classification" }
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "aggregate"
    ARGV.shift
    PlannerStatisticsAggregate.run(ARGV)
  else
    PlannerStatisticsBenchmark.run(ARGV)
  end
end
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Rails/IndexWith, Rails/SquishedSQLHeredocs, Style/OneClassPerFile
