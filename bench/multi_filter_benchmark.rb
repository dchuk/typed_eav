# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity, Rails/IndexBy, Rails/IndexWith, Rails/SquishedSQLHeredocs -- a standalone evidence harness keeps its protocol and validation together.
require "base64"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pg"
require "securerandom"
require "time"
require "zlib"

class MultiFilterBenchmark
  DB_PREFIX = "typed_eav_phase4_multi_"
  REPRESENTATIVE_ENTITIES = 100_000
  SMOKE_ENTITIES = 2_000
  FIELD_COUNT = 60
  VALUES_PER_HOST = 20
  MEASURED_TIMEOUT_MS = 1_000
  SEMANTIC_TIMEOUT_MS = 5_000
  STRATEGIES = %w[current_chained_in intersect correlated_exists grouped_having].freeze
  ROTATIONS = [STRATEGIES, STRATEGIES.rotate(1), STRATEGIES.rotate(2)].freeze
  REQUIRED_FAMILIES = %w[high low mixed skewed].freeze
  LARGE_FILTER_COUNTS = [10, 20].freeze
  GROUPED_INELIGIBLE_SCENARIOS = %w[include_missing empty_filters].freeze
  SEMANTIC_CLASSIFICATIONS = %w[proven_equal unproved_timeout].freeze
  BUFFER_KEYS = [
    "Shared Hit Blocks", "Shared Read Blocks", "Shared Dirtied Blocks", "Shared Written Blocks",
    "Local Hit Blocks", "Local Read Blocks", "Local Dirtied Blocks", "Local Written Blocks",
    "Temp Read Blocks", "Temp Written Blocks"
  ].freeze
  CORRECTIVE_SCENARIOS = %w[high_10 high_20 low_10 low_20 mixed_10 mixed_20 skewed_10 skewed_20].freeze

  def self.run(argv)
    options = { tier: nil, seed: nil, output: nil, matrix: "historical" }
    OptionParser.new do |parser|
      parser.on("--tier TIER", %w[smoke representative]) { |value| options[:tier] = value }
      parser.on("--seed SEED", Integer) { |value| options[:seed] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
      parser.on("--matrix MATRIX", %w[historical corrective]) { |value| options[:matrix] = value }
    end.parse!(argv)
    abort "--tier, --seed, and --output are required" unless options.values.all?
    abort "representative tier requires TYPED_EAV_REPRESENTATIVE_OK=1" if options[:tier] == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
    new(**options).call
  end

  def initialize(tier:, seed:, output:, matrix:)
    @tier = tier
    @seed = seed
    @output = output
    @matrix = matrix
    @corrective = matrix == "corrective"
    @entities = tier == "representative" ? REPRESENTATIVE_ENTITIES : SMOKE_ENTITIES
    @repetitions = 10
    @trial_count = tier == "representative" ? 3 : 1
    @progress_dir = ENV.fetch("TYPED_EAV_PROGRESS_DIR", nil)
    @run_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
    File.write(@output, "#{JSON.pretty_generate(result, max_nesting: false)}\n")
  ensure
    cleanup
    @admin&.close
  end

  private

  def connection
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", nil), user: ENV.fetch("PGUSER", nil), password: ENV.fetch("PGPASSWORD", nil) }.compact
  end

  def qualify!
    return unless @tier == "representative"

    abort "representative entity count is fixed at 100,000" unless @entities == 100_000
    available = @admin.exec("SELECT pg_size_bytes(current_setting('shared_buffers'))").getvalue(0, 0).to_i
    abort "PostgreSQL shared_buffers must be at least 128 MiB" if available < 128 * 1024 * 1024
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
    create_schema
    load_dataset
    create_indexes
    @db.exec("ANALYZE hosts_bench")
    @db.exec("ANALYZE typed_eav_fields_bench")
    @db.exec("ANALYZE typed_eav_values_bench")
    definitions = resolved_definition_evidence
    scenarios = build_scenarios(definitions)
    @scenario_indexes = scenarios.each_with_index.to_h { |scenario, index| [scenario.fetch(:name), index] }
    trials = Array.new(@trial_count) { |index| run_trial(index + 1, scenarios) }
    result = {
      "schema_version" => 1,
      "generated_at_utc" => Time.now.utc.iso8601,
      "protocol" => protocol,
      "environment" => environment,
      "dataset" => dataset_evidence,
      "resolved_definitions" => definitions,
      "scenario_catalog" => scenarios.map { |scenario| scenario_metadata(scenario) },
      "error_controls" => error_controls(definitions),
      "trials" => trials,
      "semantic_smoke" => semantic_smoke_evidence,
      "corrective_smoke" => corrective_smoke_evidence,
      "summary" => summarize(trials),
      "practical_comparisons" => practical_comparisons(trials),
      "replacement_decision" => replacement_decision(trials),
      "validation" => validate_result(trials, scenarios),
      "limitations" => limitations,
    }
    abort "artifact validation failed" unless result.dig("validation", "accepted")

    result
  end

  def create_schema
    @db.exec <<~SQL
      CREATE TABLE hosts_bench (
        entity_type text NOT NULL,
        id integer NOT NULL,
        PRIMARY KEY (entity_type, id)
      );
      CREATE TABLE typed_eav_fields_bench (
        id integer PRIMARY KEY,
        entity_type text NOT NULL,
        name text NOT NULL,
        scope text,
        parent_scope text,
        value_kind text NOT NULL
      );
      CREATE TABLE typed_eav_values_bench (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        entity_type text NOT NULL,
        entity_id integer NOT NULL,
        field_id integer NOT NULL,
        integer_value integer,
        string_value text,
        date_value date
      );
    SQL
  end

  def load_dataset
    @db.exec_params("INSERT INTO hosts_bench SELECT 'BenchmarkHost', g FROM generate_series(1,$1) g", [@entities])
    @db.exec_params("INSERT INTO hosts_bench SELECT 'OtherHost', g FROM generate_series(1,$1) g", [[@entities / 20, 100].max])
    insert_definitions
    loaded_field_count = @corrective ? 30 : 20
    string_field_end = @corrective ? 30 : 15
    @db.exec_params(<<~SQL, [@entities, @seed, loaded_field_count, string_field_end])
      INSERT INTO typed_eav_values_bench (entity_type, entity_id, field_id, integer_value, string_value, date_value)
      SELECT 'BenchmarkHost', entity_id, 1000 + field_no,
             CASE WHEN field_no <= 10 THEN ((entity_id + $2) % 100) END,
             CASE WHEN field_no BETWEEN 11 AND $4 THEN
               CASE WHEN ((entity_id + $2) % 10) < 7 THEN 'popular-' || lpad((((entity_id + $2) % 100))::text, 2, '0')
                    ELSE 'rare-' || lpad((((entity_id + $2) % 100))::text, 2, '0') END
             END,
             CASE WHEN $3 = 20 AND field_no BETWEEN 16 AND 20 THEN DATE '2024-01-01' + ((entity_id + $2) % 100) END
      FROM generate_series(1,$1) entity_id
      CROSS JOIN generate_series(1,$3) field_no
    SQL
    # Explicit NULL rows and missing rows replace ordinary field-1001 values.
    @db.exec_params("UPDATE typed_eav_values_bench SET integer_value=NULL WHERE entity_type='BenchmarkHost' AND field_id=1001 AND entity_id % 20=0 AND entity_id <= $1", [@entities])
    @db.exec_params("DELETE FROM typed_eav_values_bench WHERE entity_type='BenchmarkHost' AND field_id=1001 AND entity_id % 20=1 AND entity_id <= $1", [@entities])
    @db.exec_params(<<~SQL, [[@entities / 20, 100].max, @seed])
      INSERT INTO typed_eav_values_bench (entity_type, entity_id, field_id, integer_value)
      SELECT 'OtherHost', entity_id, 3001, ((entity_id + $2) % 100)
      FROM generate_series(1,$1) entity_id
    SQL
    # ALL_SCOPES duplicate-producing rows for the same logical name.
    @db.exec_params(<<~SQL, [@entities, @seed])
      INSERT INTO typed_eav_values_bench (entity_type, entity_id, field_id, integer_value)
      SELECT 'BenchmarkHost', entity_id, field_id, ((entity_id + $2) % 100)
      FROM generate_series(1,$1) entity_id
      CROSS JOIN (VALUES (2101),(2102)) defs(field_id)
      WHERE (entity_id + $2) % 100 = 7
    SQL
  end

  def insert_definitions
    rows = []
    1.upto(FIELD_COUNT) do |number|
      kind = if number <= 10
               "integer"
             elsif number <= (@corrective ? 30 : 15)
               "string"
             else
               number <= 20 ? "date" : "integer"
             end
      rows << [1000 + number, "BenchmarkHost", "field_#{number}", nil, nil, kind]
    end
    rows.push(
      [2001, "BenchmarkHost", "shadow", nil, nil, "integer"],
      [2002, "BenchmarkHost", "shadow", "tenant-a", nil, "integer"],
      [2003, "BenchmarkHost", "shadow", "tenant-a", "parent-a", "integer"],
      [2101, "BenchmarkHost", "duplicate_name", nil, nil, "integer"],
      [2102, "BenchmarkHost", "duplicate_name", "tenant-a", nil, "integer"],
      [3001, "OtherHost", "field_1", nil, nil, "integer"],
    )
    @db.copy_data("COPY typed_eav_fields_bench (id,entity_type,name,scope,parent_scope,value_kind) FROM STDIN WITH (FORMAT csv, NULL '\\N')") do
      rows.each { |row| @db.put_copy_data("#{row.map { |value| value.nil? ? '\\N' : value }.join(",")}\n") }
    end
    # Winning shadow rows use distinct populations so resolution mistakes are observable.
    [[2001, 11], [2002, 13], [2003, 17]].each do |field_id, residue|
      @db.exec_params("INSERT INTO typed_eav_values_bench (entity_type,entity_id,field_id,integer_value) SELECT 'BenchmarkHost',g,$2,$3 FROM generate_series(1,$1) g WHERE g % 100=$3", [@entities, field_id, residue])
    end
  end

  def create_indexes
    @db.exec("CREATE UNIQUE INDEX idx_hosts_identity ON hosts_bench (entity_type,id)")
    @db.exec("CREATE INDEX idx_multi_entity_field ON typed_eav_values_bench (entity_type,entity_id,field_id)")
    @db.exec("CREATE INDEX idx_multi_int ON typed_eav_values_bench (field_id,integer_value) INCLUDE (entity_id) WHERE integer_value IS NOT NULL")
    @db.exec("CREATE INDEX idx_multi_str ON typed_eav_values_bench (field_id,string_value text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL")
    @db.exec("CREATE INDEX idx_multi_date ON typed_eav_values_bench (field_id,date_value) INCLUDE (entity_id) WHERE date_value IS NOT NULL")
  end

  def resolved_definition_evidence
    requests = [
      ["benchmark_default", "BenchmarkHost", nil, nil, (1..(@corrective ? 30 : 20)).map { |i| "field_#{i}" }],
      ["benchmark_full_tuple", "BenchmarkHost", "tenant-a", "parent-a", ["shadow"]],
      ["benchmark_scope_only", "BenchmarkHost", "tenant-a", nil, ["shadow"]],
      ["benchmark_global", "BenchmarkHost", nil, nil, ["shadow"]],
      ["other_polymorphic", "OtherHost", nil, nil, ["field_1"]],
      ["all_scopes_duplicate", "BenchmarkHost", :all, :all, ["duplicate_name"]],
    ]
    requests.to_h do |label, type, scope, parent, names|
      resolved = names.to_h { |name| [name, resolve_fields(type, name, scope, parent)] }
      [label, { "entity_type" => type, "scope" => scope, "parent_scope" => parent, "fields" => resolved }]
    end
  end

  def resolve_fields(entity_type, name, scope, parent_scope)
    rows = @db.exec_params("SELECT id,entity_type,value_kind,scope,parent_scope FROM typed_eav_fields_bench WHERE entity_type=$1 AND name=$2 ORDER BY id", [entity_type, name]).map(&:dup)
    chosen = if scope == :all
               rows
             else
               precedence = rows.group_by do |row|
                 if row["scope"] == scope && row["parent_scope"] == parent_scope && !scope.nil? && !parent_scope.nil?
                   3
                 elsif row["scope"] == scope && row["parent_scope"].nil? && !scope.nil?
                   2
                 elsif row["scope"].nil? && row["parent_scope"].nil?
                   1
                 else
                   0
                 end
               end
               Array(precedence[precedence.keys.max])
             end
    abort "definition resolution failed for #{entity_type}.#{name}" if chosen.empty?
    chosen.map { |row| { "id" => row.fetch("id").to_i, "entity_type" => row.fetch("entity_type"), "value_kind" => row.fetch("value_kind"), "scope" => row["scope"], "parent_scope" => row["parent_scope"] } }
  end

  def build_scenarios(definitions)
    return build_corrective_scenarios(definitions) if @corrective

    scenarios = []
    [1, 3, 10, 20].each do |count|
      scenarios << scenario("high_#{count}", "high", count, equality_filters(count, 7), definitions)
      scenarios << scenario("low_#{count}", "low", count, range_filters(count), definitions)
      scenarios << scenario("mixed_#{count}", "mixed", count, mixed_filters(count), definitions)
      scenarios << scenario("skewed_#{count}", "skewed", count, pattern_filters(count), definitions)
    end
    scenarios.push(
      scenario("full_tuple_shadow", "semantic", 1, [{ name: "shadow", operator: :eq, value: 17, resolution: "benchmark_full_tuple" }], definitions),
      scenario("scope_only_shadow", "semantic", 1, [{ name: "shadow", operator: :eq, value: 13, resolution: "benchmark_scope_only" }], definitions),
      scenario("global_shadow", "semantic", 1, [{ name: "shadow", operator: :eq, value: 11, resolution: "benchmark_global" }], definitions),
      scenario("polymorphic_other_host", "semantic", 1, [{ name: "field_1", operator: :eq, value: 7, resolution: "other_polymorphic" }], definitions, host_type: "OtherHost"),
      scenario("explicit_null", "semantic", 1, [{ name: "field_1", operator: :is_null, value: nil }], definitions),
      scenario("include_missing", "semantic", 1, [{ name: "field_1", operator: :is_null, value: nil, complement: true }], definitions),
      scenario("null_inclusive_not_eq", "semantic", 1, [{ name: "field_1", operator: :not_eq, value: 7 }], definitions),
      scenario("duplicate_internal_matches", "semantic", 1, [{ name: "duplicate_name", operator: :eq, value: 7, resolution: "all_scopes_duplicate" }], definitions),
      scenario("empty_filters", "semantic", 0, [], definitions),
    )
    scenarios
  end

  def build_corrective_scenarios(definitions)
    [10, 20].flat_map do |count|
      [
        scenario("high_#{count}", "high", count, corrective_high_filters(count), definitions),
        scenario("low_#{count}", "low", count, corrective_low_filters(count), definitions),
        scenario("mixed_#{count}", "mixed", count, corrective_mixed_filters(count), definitions),
        scenario("skewed_#{count}", "skewed", count, corrective_skewed_filters(count), definitions),
      ]
    end
  end

  def corrective_high_filters(count)
    Array.new(count) do |index|
      number = index + 1
      { name: "field_#{number}", operator: :eq, value: number <= 10 ? 7 : "rare-07" }
    end
  end

  def corrective_low_filters(count)
    Array.new(count) do |index|
      number = index + 1
      number <= 10 ? { name: "field_#{number}", operator: :between, value: [0, 89] } : { name: "field_#{number}", operator: :between, value: %w[popular-00 rare-99] }
    end
  end

  def corrective_mixed_filters(count)
    Array.new(count) do |index|
      number = index + 1
      if number == 1
        { name: "field_1", operator: :eq, value: 7 }
      elsif number <= 10
        { name: "field_#{number}", operator: :lteq, value: 89 }
      else
        { name: "field_#{number}", operator: :lteq, value: "rare-99" }
      end
    end
  end

  def corrective_skewed_filters(count)
    Array.new(count) { |index| { name: "field_#{index + 11}", operator: :starts_with, value: "popular-" } }
  end

  def equality_filters(count, value)
    Array.new(count) { |index| { name: "field_#{(index % 10) + 1}", operator: :eq, value: value } }
  end

  def range_filters(count)
    Array.new(count) { |index| { name: "field_#{(index % 10) + 1}", operator: :between, value: [0, 89] } }
  end

  def mixed_filters(count)
    Array.new(count) do |index|
      index.zero? ? { name: "field_1", operator: :eq, value: 7 } : { name: "field_#{(index % 10) + 1}", operator: :lteq, value: 89 }
    end
  end

  def pattern_filters(count)
    Array.new(count) { |index| { name: "field_#{11 + (index % 5)}", operator: :starts_with, value: "popular-" } }
  end

  def scenario(name, family, count, raw_filters, definitions, host_type: "BenchmarkHost")
    filters = raw_filters.each_with_index.map do |filter, index|
      resolution = filter.fetch(:resolution, "benchmark_default")
      fields = definitions.fetch(resolution).fetch("fields").fetch(filter.fetch(:name))
      resolved_filter(filter, index + 1, fields)
    end
    if @corrective
      names = filters.map { |filter| filter.fetch(:name) }
      ids = filters.flat_map { |filter| filter.fetch(:field_ids) }
      abort "corrective scenario #{name} does not have #{count} distinct names" unless names.length == count && names.uniq.length == count
      abort "corrective scenario #{name} does not resolve one definition per predicate" unless filters.all? { |filter| filter.fetch(:field_ids).length == 1 }
      abort "corrective scenario #{name} does not have #{count} distinct field IDs" unless ids.length == count && ids.uniq.length == count
    end
    { name: name, family: family, filter_count: count, host_type: host_type, filters: filters }
  end

  def resolved_filter(filter, ordinal, fields)
    kind = fields.first.fetch("value_kind")
    entity_type = fields.first.fetch("entity_type")
    abort "resolved fields cross entity types" unless fields.all? { |field| field.fetch("entity_type") == entity_type }
    column = { "integer" => "integer_value", "string" => "string_value", "date" => "date_value" }.fetch(kind)
    ids = fields.map { |field| field.fetch("id") }
    predicate = predicate_sql(column, filter.fetch(:operator), filter[:value])
    base = "SELECT DISTINCT entity_id FROM typed_eav_values_bench WHERE entity_type=#{quote(entity_type)} AND field_id IN (#{ids.join(",")}) AND #{predicate}"
    {
      ordinal: ordinal,
      name: filter.fetch(:name),
      operator: filter.fetch(:operator).to_s,
      raw_value: filter[:value],
      field_ids: ids,
      value_kind: kind,
      column: column,
      complement: filter.fetch(:complement, false),
      subquery_sql: base,
      bind_values: [],
    }
  end

  def predicate_sql(column, operator, value)
    case operator
    when :eq then "#{column}=#{literal(value)}"
    when :between then "#{column} BETWEEN #{literal(value[0])} AND #{literal(value[1])}"
    when :lteq then "#{column}<=#{literal(value)}"
    when :starts_with then "#{column} ILIKE #{quote("#{value}%")}"
    when :is_null then "#{column} IS NULL"
    when :not_eq then "(#{column}<>#{literal(value)} OR #{column} IS NULL)"
    else raise ArgumentError, "unsupported operator #{operator}"
    end
  end

  def literal(value)
    value.is_a?(Numeric) ? value.to_s : quote(value.to_s)
  end

  def quote(value)
    @db.escape_literal(value)
  end

  def run_trial(number, scenarios)
    order = ROTATIONS.fetch(number - 1)
    {
      "trial" => number,
      "strategy_order" => order,
      "dataset_checksum" => dataset_checksum,
      "scenarios" => scenarios.map { |scenario| run_scenario(number, scenario, order) },
    }
  end

  def run_scenario(trial, scenario, order)
    evidence = {}
    order.each_with_index do |strategy, strategy_position|
      eligible, reason = eligibility(strategy, scenario)
      result = eligible ? measure_strategy(strategy, scenario) : { "eligible" => false, "reason" => reason, "sql" => nil, "bind_values" => [] }
      write_progress_checkpoint(trial, scenario, strategy, strategy_position, result, evidence.values)
      evidence[strategy] = result
    end
    semantic_summary = assert_equivalence!(scenario, evidence)
    { "name" => scenario.fetch(:name), "family" => scenario.fetch(:family), "filter_count" => scenario.fetch(:filter_count), "host_type" => scenario.fetch(:host_type), "semantic_summary" => semantic_summary, "strategies" => evidence }
  end

  def write_progress_checkpoint(trial, scenario, strategy, strategy_position, evidence, preceding_evidence)
    return unless @progress_dir

    FileUtils.mkdir_p(@progress_dir)
    scenario_index = @scenario_indexes.fetch(scenario.fetch(:name))
    sequence = ((trial - 1) * @scenario_indexes.length * STRATEGIES.length) + (scenario_index * STRATEGIES.length) + strategy_position + 1
    result = evidence["result"]
    reference = preceding_evidence.find { |item| item.fetch("eligible") }
    checksum_status = if result.nil?
                        "ineligible"
                      elsif result.fetch("outcome") == "timeout"
                        "unproved_timeout"
                      elsif result.fetch("outcome") == "error"
                        "error"
                      elsif reference.nil?
                        "reference"
                      elsif reference.fetch("result").fetch("outcome") == "timeout"
                        "reference_unproved"
                      elsif result.slice("count", "checksum") == reference.fetch("result").slice("count", "checksum")
                        "match"
                      else
                        "mismatch"
                      end
    hash_status = if evidence.fetch("eligible") && reference
                    evidence["resolved_filter_sha256"] == reference["resolved_filter_sha256"] ? "match" : "mismatch"
                  elsif evidence.fetch("eligible")
                    "reference"
                  else
                    "ineligible"
                  end
    checkpoint = {
      "schema_version" => 1,
      "sequence" => sequence,
      "trial" => trial,
      "scenario" => scenario.fetch(:name),
      "strategy" => strategy,
      "eligible" => evidence.fetch("eligible"),
      "repetition_count" => Array(evidence["repetitions"]).length,
      "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - @run_started_at,
      "result_count" => result&.fetch("count", nil),
      "result_checksum" => result&.fetch("checksum", nil),
      "oracle_outcome" => result&.fetch("outcome", nil),
      "checksum_status" => checksum_status,
      "resolved_filter_sha256" => evidence["resolved_filter_sha256"],
      "resolved_filter_hash_status" => hash_status,
      "diagnostic_only" => true,
    }
    path = File.join(@progress_dir, format("%03d.json", sequence))
    temporary = "#{path}.tmp"
    File.write(temporary, "#{JSON.generate(checkpoint)}\n")
    File.rename(temporary, path)
  end

  def eligibility(strategy, scenario)
    return [false, "direct grouped HAVING requires at least one present-row predicate"] if strategy == "grouped_having" && scenario.fetch(:filters).empty?
    return [false, "direct grouped HAVING cannot represent host-universe complement/missing semantics"] if strategy == "grouped_having" && scenario.fetch(:filters).any? { |filter| filter.fetch(:complement) }

    [true, nil]
  end

  def measure_strategy(strategy, scenario)
    sql = strategy_sql(strategy, scenario)
    fallback_plan = nil
    decoded_plan_retained = false
    repetitions = Array.new(@repetitions) do |index|
      started = monotonic
      begin
        document = with_statement_timeout(MEASURED_TIMEOUT_MS) do
          JSON.parse(@db.exec("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}").getvalue(0, 0), max_nesting: false).first
        end
        plan = document.fetch("Plan")
        raw_plan_json = JSON.generate(document, max_nesting: false)
        evidence = {
          "repetition" => index + 1,
          "group_sequence" => index + 1,
          "completed" => true,
          "censored" => false,
          "statement_timeout_ms" => MEASURED_TIMEOUT_MS,
          "wall_elapsed_ms" => elapsed_ms(started),
          "planning_time_ms" => document.fetch("Planning Time"),
          "execution_time_ms" => document.fetch("Execution Time"),
          "buffers" => buffer_summary(plan),
          "rows_removed" => plan_nodes(plan).sum { |node| node.fetch("Rows Removed by Filter", 0) + node.fetch("Rows Removed by Join Filter", 0) + node.fetch("Rows Removed by Index Recheck", 0) },
          "heap_fetches" => plan_nodes(plan).sum { |node| node.fetch("Heap Fetches", 0) },
          "plan_sha256" => Digest::SHA256.hexdigest(raw_plan_json),
          "plan_zlib_base64" => Base64.strict_encode64(Zlib::Deflate.deflate(raw_plan_json, Zlib::BEST_COMPRESSION)),
          "raw_plan_retained" => !decoded_plan_retained,
        }
        unless decoded_plan_retained
          evidence["plan"] = document
          decoded_plan_retained = true
        end
        evidence
      rescue PG::QueryCanceled => e
        sqlstate = e.result&.error_field(PG::Result::PG_DIAG_SQLSTATE)
        abort "unexpected measured cancellation SQLSTATE #{sqlstate.inspect}" unless sqlstate == "57014"
        fallback_plan ||= capture_fallback_plan(sql)
        {
          "repetition" => index + 1,
          "group_sequence" => index + 1,
          "completed" => false,
          "censored" => true,
          "statement_timeout_ms" => MEASURED_TIMEOUT_MS,
          "censor_lower_bound_ms" => MEASURED_TIMEOUT_MS,
          "wall_elapsed_ms" => elapsed_ms(started),
          "sqlstate" => sqlstate,
          "planning_time_ms" => nil,
          "execution_time_ms" => nil,
          "buffers" => nil,
          "rows_removed" => nil,
          "heap_fetches" => nil,
        }
      end
    end
    identity = result_identity(sql)
    repetitions.each { |attempt| attempt["fallback_plan_sha256"] = fallback_plan.fetch("sha256") if attempt.fetch("censored") }
    completed_timings = repetitions.select { |item| item.fetch("completed") }.map { |item| item.fetch("planning_time_ms") + item.fetch("execution_time_ms") }
    {
      "eligible" => true,
      "reason" => nil,
      "sql" => sql,
      "bind_values" => [],
      "resolved_filter_sha256" => resolved_filter_checksum(scenario),
      "result" => identity,
      "statement_count" => 1 + @repetitions + (fallback_plan ? 1 : 0),
      "repetitions" => repetitions,
      "completed_count" => repetitions.count { |attempt| attempt.fetch("completed") },
      "censored_count" => repetitions.count { |attempt| attempt.fetch("censored") },
      "latency_ms" => censored_distribution(repetitions),
      "completed_dispersion" => completed_timings.empty? ? nil : relative_pstdev(completed_timings),
      "fallback_plan" => fallback_plan,
    }
  end

  def capture_fallback_plan(sql)
    document = with_statement_timeout(MEASURED_TIMEOUT_MS) do
      JSON.parse(@db.exec("EXPLAIN (SETTINGS, FORMAT JSON) #{sql}").getvalue(0, 0), max_nesting: false).first
    end
    raw = JSON.generate(document, max_nesting: false)
    {
      "analyze" => false,
      "statement_timeout_ms" => MEASURED_TIMEOUT_MS,
      "sql" => sql,
      "sha256" => Digest::SHA256.hexdigest(raw),
      "plan_zlib_base64" => Base64.strict_encode64(Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)),
      "plan" => document,
    }
  rescue PG::QueryCanceled => e
    abort "fallback plan timed out with SQLSTATE #{e.result&.error_field(PG::Result::PG_DIAG_SQLSTATE)}"
  end

  def strategy_sql(strategy, scenario)
    host = "SELECT h.entity_type,h.id FROM hosts_bench h WHERE h.entity_type=#{quote(scenario.fetch(:host_type))}"
    filters = scenario.fetch(:filters)
    return host if filters.empty?

    case strategy
    when "current_chained_in"
      filters.reduce(host) do |sql, filter|
        operator = filter.fetch(:complement) ? "NOT IN" : "IN"
        "#{sql} AND h.id #{operator} (#{filter.fetch(:subquery_sql)})"
      end
    when "intersect"
      sets = filters.map do |filter|
        if filter.fetch(:complement)
          "(SELECT id AS entity_id FROM hosts_bench WHERE entity_type=#{quote(scenario.fetch(:host_type))} EXCEPT #{filter.fetch(:subquery_sql)})"
        else
          "(#{filter.fetch(:subquery_sql)})"
        end
      end
      "#{host} AND h.id IN (#{sets.join(" INTERSECT ")})"
    when "correlated_exists"
      filters.reduce(host) do |sql, filter|
        keyword = filter.fetch(:complement) ? "NOT EXISTS" : "EXISTS"
        "#{sql} AND #{keyword} (SELECT 1 FROM (#{filter.fetch(:subquery_sql)}) resolved_#{filter.fetch(:ordinal)} WHERE resolved_#{filter.fetch(:ordinal)}.entity_id=h.id)"
      end
    when "grouped_having"
      branches = filters.map { |filter| "SELECT #{filter.fetch(:ordinal)} AS filter_ordinal,entity_id FROM (#{filter.fetch(:subquery_sql)}) resolved_#{filter.fetch(:ordinal)}" }
      "#{host} AND h.id IN (SELECT entity_id FROM (#{branches.join(" UNION ALL ")}) grouped_matches GROUP BY entity_id HAVING count(DISTINCT filter_ordinal)=#{filters.length})"
    else raise "unknown strategy #{strategy}"
    end
  end

  def result_identity(sql)
    wrapped = "SELECT count(*)::bigint AS count,coalesce(md5(string_agg(entity_type || ':' || id::text,',' ORDER BY entity_type,id)),md5('')) AS checksum FROM (#{sql}) identities"
    started = monotonic
    row = with_statement_timeout(SEMANTIC_TIMEOUT_MS) { @db.exec(wrapped).first }
    { "outcome" => "completed", "group_sequence" => @repetitions + 1, "identity_sql" => wrapped, "identity_sql_sha256" => Digest::SHA256.hexdigest(wrapped), "statement_timeout_ms" => SEMANTIC_TIMEOUT_MS, "elapsed_ms" => elapsed_ms(started), "sqlstate" => nil, "count" => row.fetch("count").to_i, "checksum" => row.fetch("checksum"), "timeout_lower_bound_ms" => nil, "completed" => true }
  rescue PG::QueryCanceled => e
    sqlstate = e.result&.error_field(PG::Result::PG_DIAG_SQLSTATE)
    abort "unexpected semantic cancellation SQLSTATE #{sqlstate.inspect}" unless sqlstate == "57014"
    { "outcome" => "timeout", "group_sequence" => @repetitions + 1, "identity_sql" => wrapped, "identity_sql_sha256" => Digest::SHA256.hexdigest(wrapped), "statement_timeout_ms" => SEMANTIC_TIMEOUT_MS, "elapsed_ms" => elapsed_ms(started), "sqlstate" => sqlstate, "count" => nil, "checksum" => nil, "timeout_lower_bound_ms" => SEMANTIC_TIMEOUT_MS, "completed" => false }
  rescue PG::Error => e
    sqlstate = e.result&.error_field(PG::Result::PG_DIAG_SQLSTATE)
    { "outcome" => "error", "group_sequence" => @repetitions + 1, "identity_sql" => wrapped, "identity_sql_sha256" => Digest::SHA256.hexdigest(wrapped), "statement_timeout_ms" => SEMANTIC_TIMEOUT_MS, "elapsed_ms" => elapsed_ms(started), "sqlstate" => sqlstate, "count" => nil, "checksum" => nil, "timeout_lower_bound_ms" => nil, "completed" => false, "error_class" => e.class.name, "error_message" => e.message }
  end

  def with_statement_timeout(milliseconds)
    @db.exec("SET statement_timeout=#{Integer(milliseconds)}")
    yield
  ensure
    @db.exec("SET statement_timeout=0") if @db && !@db.finished?
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started)
    (monotonic - started) * 1_000
  end

  def assert_equivalence!(scenario, evidence)
    eligible = evidence.values.select { |item| item.fetch("eligible") }
    filter_hashes = eligible.filter_map { |item| item["resolved_filter_sha256"] }.uniq
    abort "resolved-filter mismatch in #{scenario.fetch(:name)}" unless filter_hashes.size <= 1
    outcomes = eligible.map { |item| item.fetch("result") }
    errors = outcomes.select { |outcome| outcome.fetch("outcome") == "error" }
    abort "semantic oracle error in #{scenario.fetch(:name)}: #{errors.inspect}" unless errors.empty?
    completed = outcomes.select { |outcome| outcome.fetch("outcome") == "completed" }
    identities = completed.map { |outcome| outcome.slice("count", "checksum") }.uniq
    abort "semantic mismatch in #{scenario.fetch(:name)}: #{completed.inspect}" if identities.size > 1
    timeouts = outcomes.count { |outcome| outcome.fetch("outcome") == "timeout" }
    classification = timeouts.positive? ? "unproved_timeout" : "proven_equal"
    {
      "classification" => classification,
      "equivalence_proven" => classification == "proven_equal",
      "eligible_oracle_count" => outcomes.length,
      "completed_count" => completed.length,
      "timeout_count" => timeouts,
      "error_count" => errors.length,
      "identity" => classification == "proven_equal" ? identities.fetch(0) : nil,
      "resolved_filter_sha256" => filter_hashes.fetch(0),
    }
  end

  def resolved_filter_checksum(scenario)
    canonical = scenario.fetch(:filters).map { |filter| filter.slice(:ordinal, :name, :operator, :raw_value, :field_ids, :value_kind, :column, :complement, :subquery_sql, :bind_values) }
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  end

  def error_controls(definitions)
    controls = []
    begin
      definitions.fetch("benchmark_default").fetch("fields").fetch("does_not_exist")
    rescue KeyError => e
      controls << { "name" => "unknown_field", "accepted" => true, "error_class" => "ArgumentError", "message" => "Unknown typed field 'does_not_exist' for BenchmarkHost", "source_error" => e.message, "sql_generated" => false, "strategies_eligible" => [] }
    end
    begin
      predicate_sql("integer_value", :contains, "7")
    rescue ArgumentError => e
      controls << { "name" => "unsupported_operator", "accepted" => true, "error_class" => e.class.name, "message" => e.message, "sql_generated" => false, "strategies_eligible" => [] }
    end
    controls
  end

  def scenario_metadata(scenario)
    {
      "name" => scenario.fetch(:name), "family" => scenario.fetch(:family), "filter_count" => scenario.fetch(:filter_count), "host_type" => scenario.fetch(:host_type),
      "resolved_filter_sha256" => resolved_filter_checksum(scenario), "filters" => scenario.fetch(:filters),
      "grouped_having_eligibility" => eligibility("grouped_having", scenario).then { |eligible, reason| { "eligible" => eligible, "reason" => reason } }
    }
  end

  def dataset_checksum
    @dataset_checksum ||= @db.exec("SELECT md5(string_agg(part,',' ORDER BY part)) FROM (SELECT entity_type || ':' || id AS part FROM hosts_bench UNION ALL SELECT entity_type || ':' || entity_id || ':' || field_id || ':' || coalesce(integer_value::text,'NULL') || ':' || coalesce(string_value,'NULL') || ':' || coalesce(date_value::text,'NULL') FROM typed_eav_values_bench) x").getvalue(0, 0)
  end

  def dataset_evidence
    host_counts = @db.exec("SELECT entity_type,count(*) FROM hosts_bench GROUP BY entity_type ORDER BY entity_type").to_h { |row| [row.fetch("entity_type"), row.fetch("count").to_i] }
    value_count = @db.exec("SELECT count(*) FROM typed_eav_values_bench").getvalue(0, 0).to_i
    {
      "seed" => @seed,
      "primary_hosts" => @entities,
      "host_counts" => host_counts,
      "field_definitions" => @db.exec("SELECT count(*) FROM typed_eav_fields_bench").getvalue(0, 0).to_i,
      "values_per_primary_host_nominal" => @corrective ? 30 : VALUES_PER_HOST,
      "value_rows" => value_count,
      "explicit_null_rows" => @db.exec("SELECT count(*) FROM typed_eav_values_bench WHERE field_id=1001 AND integer_value IS NULL").getvalue(0, 0).to_i,
      "missing_field_1001_hosts" => @db.exec("SELECT count(*) FROM hosts_bench h WHERE entity_type='BenchmarkHost' AND NOT EXISTS (SELECT 1 FROM typed_eav_values_bench v WHERE v.entity_type=h.entity_type AND v.entity_id=h.id AND v.field_id=1001)").getvalue(0, 0).to_i,
      "checksum" => dataset_checksum,
    }
  end

  def environment
    {
      "tier" => @tier,
      "matrix" => @matrix,
      "ruby" => RUBY_DESCRIPTION,
      "pg_gem" => PG.library_version,
      "postgresql" => @db.exec("SHOW server_version").getvalue(0, 0),
      "server_settings" => %w[shared_buffers work_mem effective_cache_size max_parallel_workers_per_gather random_page_cost].to_h { |name| [name, @db.exec("SHOW #{name}").getvalue(0, 0)] },
      "relation_bytes" => relation_sizes,
      "index_usage_before_trials" => @db.exec("SELECT indexrelname,idx_scan,idx_tup_read,idx_tup_fetch FROM pg_stat_user_indexes ORDER BY indexrelname").map(&:dup),
      "cleanup" => @cleanup,
    }
  end

  def relation_sizes
    @db.exec("SELECT c.relname,pg_relation_size(c.oid)::bigint AS relation_bytes,pg_indexes_size(c.oid)::bigint AS index_bytes,pg_total_relation_size(c.oid)::bigint AS total_bytes FROM pg_class c WHERE c.relname IN ('hosts_bench','typed_eav_fields_bench','typed_eav_values_bench') ORDER BY c.relname").map do |row|
      row.transform_values.with_index { |value, index| index.zero? ? value : value.to_i }
    end
  end

  def protocol
    {
      "strategies" => STRATEGIES,
      "matrix" => @matrix,
      "trials" => @trial_count,
      "repetitions_per_strategy_scenario_trial" => @repetitions,
      "measured_statement_timeout_ms" => MEASURED_TIMEOUT_MS,
      "semantic_oracle_timeout_ms" => SEMANTIC_TIMEOUT_MS,
      "group_execution_order" => "ten uniform measured attempts, then exactly one non-retried semantic identity oracle",
      "semantic_timeout_policy" => "only SQLSTATE 57014 is retained as unproved_timeout with null identity and a >=5000ms bound; it never establishes equivalence or replacement eligibility",
      "censoring" => "Type-1 right censoring; every SQLSTATE 57014 attempt is retained at a >=1000ms lower bound without retry or imputation",
      "raw_plan_policy" => "every repetition retains its exact EXPLAIN JSON losslessly as zlib/base64 plus SHA-256 and extracted metrics; the first repetition is also retained decoded per strategy/scenario/trial",
      "progress_checkpoint_policy" => "diagnostic-only atomic files are written after each strategy group; final evidence neither reads nor depends on them",
      "rotations" => ROTATIONS.first(@trial_count),
      "identity" => "sorted (entity_type,id) count plus MD5 checksum",
      "mechanical_acceptance" => "equivalence, completeness, no-impact, and cleanup; timings are co-tenant diagnostics",
      "future_recommendation_threshold" => ">=20% p95 improvement at 10 and 20 filters in >=3 workload families, full semantic coverage, and no material planning/buffer regression",
    }
  end

  def summarize(trials)
    rows = Hash.new { |hash, key| hash[key] = [] }
    trials.each do |trial|
      trial.fetch("scenarios").each do |scenario|
        scenario.fetch("strategies").each do |strategy, evidence|
          next unless evidence.fetch("eligible")

          rows[[scenario.fetch("name"), strategy]].concat(evidence.fetch("repetitions"))
        end
      end
    end
    rows.map do |(scenario, strategy), attempts|
      completed = attempts.select { |attempt| attempt.fetch("completed") }
      timings = completed.map { |attempt| attempt.fetch("planning_time_ms") + attempt.fetch("execution_time_ms") }
      {
        "scenario" => scenario,
        "strategy" => strategy,
        "scheduled_attempts" => attempts.length,
        "completed_count" => completed.length,
        "censored_count" => attempts.count { |attempt| attempt.fetch("censored") },
        "latency_ms" => censored_distribution(attempts),
        "completed_dispersion" => timings.empty? ? nil : relative_pstdev(timings),
      }
    end
  end

  def practical_comparisons(trials)
    pooled = summarize(trials).to_h { |row| [[row.fetch("scenario"), row.fetch("strategy")], row] }
    REQUIRED_FAMILIES.flat_map do |family|
      LARGE_FILTER_COUNTS.flat_map do |filter_count|
        scenario = "#{family}_#{filter_count}"
        current = pooled.fetch([scenario, "current_chained_in"])
        (STRATEGIES - ["current_chained_in"]).map do |strategy|
          candidate = pooled.fetch([scenario, strategy])
          current_p95 = current.dig("latency_ms", "p95")
          candidate_p95 = candidate.dig("latency_ms", "p95")
          timing_proof = conservative_improvement(current_p95, candidate_p95)
          buffers_complete = current.fetch("censored_count").zero? && candidate.fetch("censored_count").zero?
          {
            "scenario" => scenario,
            "family" => family,
            "filter_count" => filter_count,
            "candidate" => strategy,
            "current_p95" => current_p95,
            "candidate_p95" => candidate_p95,
            "timing_20_percent_status" => timing_proof,
            "analyze_buffers_complete" => buffers_complete,
            "replacement_evidence" => timing_proof == "proven" && buffers_complete ? "timing_threshold_met_pending_buffer_regression_analysis" : "inconclusive_or_not_met",
          }
        end
      end
    end
  end

  def replacement_decision(trials)
    comparisons = practical_comparisons(trials)
    representative_equivalence_proven = trials.all? do |trial|
      trial.fetch("scenarios").all? { |scenario| scenario.dig("semantic_summary", "equivalence_proven") }
    end
    family_wins = (STRATEGIES - ["current_chained_in"]).to_h do |strategy|
      families = REQUIRED_FAMILIES.select do |family|
        LARGE_FILTER_COUNTS.all? do |filter_count|
          comparison = comparisons.find { |item| item.fetch("candidate") == strategy && item.fetch("family") == family && item.fetch("filter_count") == filter_count }
          comparison.fetch("timing_20_percent_status") == "proven" && comparison.fetch("analyze_buffers_complete")
        end
      end
      [strategy, families]
    end
    timing_and_complete_buffers = family_wins.any? { |_strategy, families| families.length >= 3 }
    bounded_regressions_proven = false
    evidence_eligible = representative_equivalence_proven && timing_and_complete_buffers && bounded_regressions_proven
    {
      "representative_equivalence_proven" => representative_equivalence_proven,
      "uncensored_twenty_percent_p95_and_complete_buffers_in_three_families" => timing_and_complete_buffers,
      "qualifying_families_by_candidate" => family_wins,
      "bounded_planning_buffer_plan_shape_regressions_proven" => bounded_regressions_proven,
      "bounded_regression_note" => "The harness retains planning, buffer, and plan-shape evidence for policy review but does not pre-authorize a material-regression bound.",
      "production_replacement_eligible" => evidence_eligible,
      "production_replacement_authorized" => false,
      "retain_current_sql" => !evidence_eligible,
    }
  end

  def semantic_smoke_evidence
    return nil unless @tier == "representative"

    path = ENV.fetch("TYPED_EAV_SEMANTIC_SMOKE_PATH")
    smoke = JSON.parse(File.read(path), max_nesting: false)
    oracles = smoke.fetch("trials").flat_map do |trial|
      trial.fetch("scenarios").flat_map do |scenario|
        scenario.fetch("strategies").filter_map do |strategy, evidence|
          next unless evidence.fetch("eligible")

          { "trial" => trial.fetch("trial"), "scenario" => scenario.fetch("name"), "strategy" => strategy, "resolved_filter_sha256" => evidence.fetch("resolved_filter_sha256"), "oracle" => evidence.fetch("result") }
        end
      end
    end
    summaries = smoke.fetch("trials").flat_map do |trial|
      trial.fetch("scenarios").map { |scenario| { "trial" => trial.fetch("trial"), "scenario" => scenario.fetch("name"), **scenario.fetch("semantic_summary") } }
    end
    fully_equal = smoke.dig("dataset", "seed") == 4502 && oracles.length == 98 && oracles.all? { |item| item.dig("oracle", "outcome") == "completed" } && summaries.length == 25 && summaries.all? { |summary| summary.fetch("classification") == "proven_equal" && summary.fetch("equivalence_proven") }
    abort "local semantic smoke is not fully equal" unless fully_equal

    { "seed" => 4502, "oracle_count" => oracles.length, "scenario_summary_count" => summaries.length, "fully_equal" => true, "oracles" => oracles, "scenario_summaries" => summaries, "validation" => smoke.fetch("validation") }
  end

  def corrective_smoke_evidence
    return nil unless @tier == "representative" && @corrective

    path = ENV.fetch("TYPED_EAV_CORRECTIVE_SMOKE_PATH")
    smoke = JSON.parse(File.read(path), max_nesting: false)
    oracles = smoke.fetch("trials").flat_map do |trial|
      trial.fetch("scenarios").flat_map do |scenario|
        scenario.fetch("strategies").filter_map do |strategy, evidence|
          next unless evidence.fetch("eligible")

          { "trial" => trial.fetch("trial"), "scenario" => scenario.fetch("name"), "strategy" => strategy, "resolved_filter_sha256" => evidence.fetch("resolved_filter_sha256"), "oracle" => evidence.fetch("result") }
        end
      end
    end
    summaries = smoke.fetch("trials").flat_map do |trial|
      trial.fetch("scenarios").map { |scenario| { "trial" => trial.fetch("trial"), "scenario" => scenario.fetch("name"), **scenario.fetch("semantic_summary") } }
    end
    fully_equal = smoke.dig("dataset", "seed") == 4502 && smoke.dig("environment", "matrix") == "corrective" && oracles.length == 32 && oracles.all? { |item| item.dig("oracle", "outcome") == "completed" } && summaries.length == 8 && summaries.all? { |summary| summary.fetch("classification") == "proven_equal" && summary.fetch("equivalence_proven") }
    abort "corrective semantic smoke is not fully equal" unless fully_equal

    { "seed" => 4502, "oracle_count" => oracles.length, "scenario_summary_count" => summaries.length, "fully_equal" => true, "oracles" => oracles, "scenario_summaries" => summaries, "validation" => smoke.fetch("validation") }
  end

  def conservative_improvement(current, candidate)
    return candidate.fetch("value_ms") <= (current.fetch("value_ms") * 0.8) ? "proven" : "not_met" if current.fetch("status") == "exact" && candidate.fetch("status") == "exact"
    return candidate.fetch("value_ms") <= (current.fetch("lower_bound_ms") * 0.8) ? "proven_lower_bound" : "inconclusive" if current.fetch("status") == "lower_bound" && candidate.fetch("status") == "exact"

    "inconclusive"
  end

  def validate_result(trials, scenarios)
    required_names = @corrective ? CORRECTIVE_SCENARIOS : REQUIRED_FAMILIES.product([1, 3, 10, 20]).map { |family, count| "#{family}_#{count}" }
    eligible_groups_per_trial = @corrective ? 32 : 98
    scenarios_per_trial = @corrective ? 8 : 25
    trial_complete = trials.length == @trial_count && trials.all? do |trial|
      trial.fetch("scenarios").length == scenarios.length && trial.fetch("dataset_checksum") == dataset_checksum
    end
    repetitions_complete = trials.all? do |trial|
      trial.fetch("scenarios").all? do |scenario|
        scenario.fetch("strategies").values.all? { |evidence| !evidence.fetch("eligible") || evidence.fetch("repetitions").length == @repetitions }
      end
    end
    attempt_count = trials.sum do |trial|
      trial.fetch("scenarios").sum do |scenario|
        scenario.fetch("strategies").values.sum { |evidence| evidence.fetch("eligible") ? evidence.fetch("repetitions").length : 0 }
      end
    end
    oracle_count = trials.sum { |trial| trial.fetch("scenarios").sum { |scenario| scenario.fetch("strategies").values.count { |evidence| evidence.fetch("eligible") && evidence.key?("result") } } }
    semantic_summary_count = trials.sum { |trial| trial.fetch("scenarios").count { |scenario| scenario.key?("semantic_summary") } }
    oracle_shapes_valid = trials.all? do |trial|
      trial.fetch("scenarios").all? do |scenario|
        scenario.fetch("strategies").values.all? do |evidence|
          next true unless evidence.fetch("eligible")

          oracle = evidence.fetch("result")
          common = oracle.fetch("group_sequence") == (@repetitions + 1) && oracle.fetch("identity_sql_sha256") == Digest::SHA256.hexdigest(oracle.fetch("identity_sql")) && oracle.fetch("statement_timeout_ms") == SEMANTIC_TIMEOUT_MS && oracle.fetch("elapsed_ms") >= 0
          completed = oracle.fetch("outcome") == "completed" && oracle.fetch("completed") && oracle["sqlstate"].nil? && !oracle["count"].nil? && !oracle["checksum"].nil? && oracle["timeout_lower_bound_ms"].nil?
          timeout = oracle.fetch("outcome") == "timeout" && !oracle.fetch("completed") && oracle.fetch("sqlstate") == "57014" && oracle["count"].nil? && oracle["checksum"].nil? && oracle.fetch("timeout_lower_bound_ms") == SEMANTIC_TIMEOUT_MS
          common && (completed || timeout)
        end
      end
    end
    summaries_valid = trials.all? do |trial|
      trial.fetch("scenarios").all? do |scenario|
        summary = scenario.fetch("semantic_summary")
        SEMANTIC_CLASSIFICATIONS.include?(summary.fetch("classification")) && summary.fetch("equivalence_proven") == (summary.fetch("classification") == "proven_equal")
      end
    end
    censor_shapes_valid = trials.all? do |trial|
      trial.fetch("scenarios").all? do |scenario|
        scenario.fetch("strategies").values.all? do |evidence|
          next true unless evidence.fetch("eligible")

          attempts = evidence.fetch("repetitions")
          attempts.each_with_index.all? { |attempt, index| attempt.fetch("group_sequence") == index + 1 && (attempt.fetch("completed") ^ attempt.fetch("censored")) } &&
            attempts.select { |attempt| attempt.fetch("censored") }.all? { |attempt| attempt.fetch("sqlstate") == "57014" && attempt.fetch("censor_lower_bound_ms") == MEASURED_TIMEOUT_MS && attempt.fetch("fallback_plan_sha256") == evidence.dig("fallback_plan", "sha256") } &&
            (evidence.fetch("censored_count").zero? ? evidence["fallback_plan"].nil? : !evidence["fallback_plan"].nil?)
        end
      end
    end
    grouped_assertions = trials.all? do |trial|
      trial.fetch("scenarios").select { |scenario| GROUPED_INELIGIBLE_SCENARIOS.include?(scenario.fetch("name")) }.all? do |scenario|
        grouped = scenario.fetch("strategies").fetch("grouped_having")
        !grouped.fetch("eligible") && !grouped.fetch("reason").to_s.empty?
      end
    end
    smoke_semantics_valid = @tier != "smoke" || trials.all? { |trial| trial.fetch("scenarios").all? { |scenario| scenario.dig("semantic_summary", "equivalence_proven") } }
    distinct_corrective_fields = !@corrective || scenarios.all? do |scenario|
      names = scenario.fetch(:filters).map { |filter| filter.fetch(:name) }
      ids = scenario.fetch(:filters).flat_map { |filter| filter.fetch(:field_ids) }
      names.length == scenario.fetch(:filter_count) && names.uniq.length == names.length && scenario.fetch(:filters).all? { |filter| filter.fetch(:field_ids).length == 1 } && ids.uniq.length == ids.length
    end
    required_scenarios_present = if @corrective
                                   scenarios.map { |scenario| scenario.fetch(:name) }.sort == required_names.sort
                                 else
                                   required_names.all? { |name| scenarios.any? { |scenario| scenario.fetch(:name) == name } }
                                 end
    {
      "accepted" => trial_complete && repetitions_complete && grouped_assertions && censor_shapes_valid && oracle_shapes_valid && summaries_valid && smoke_semantics_valid && distinct_corrective_fields && attempt_count == (@trial_count * eligible_groups_per_trial * @repetitions) && oracle_count == (@trial_count * eligible_groups_per_trial) && semantic_summary_count == (@trial_count * scenarios_per_trial) && required_scenarios_present,
      "trial_complete" => trial_complete,
      "repetitions_complete" => repetitions_complete,
      "required_workloads_complete" => required_names,
      "representative_equivalence_proven" => trials.all? { |trial| trial.fetch("scenarios").all? { |scenario| scenario.dig("semantic_summary", "equivalence_proven") } },
      "resolved_filter_checksums_equal" => true,
      "grouped_ineligibility_assertions" => grouped_assertions,
      "attempt_count" => attempt_count,
      "semantic_oracle_count" => oracle_count,
      "semantic_scenario_summary_count" => semantic_summary_count,
      "semantic_oracle_shapes_valid" => oracle_shapes_valid,
      "semantic_summaries_valid" => summaries_valid,
      "smoke_semantics_fully_equal" => smoke_semantics_valid,
      "distinct_corrective_fields" => distinct_corrective_fields,
      "censor_shapes_valid" => censor_shapes_valid,
      "timing_threshold_applied" => false,
    }
  end

  def limitations
    [
      "The authorized host is a continuously busy media server; absolute latency and dispersion are co-tenant diagnostics, not clean-room claims.",
      "Synthetic predicates and distributions establish comparative behavior, not application latency guarantees.",
      "The harness records benchmark evidence only and does not tune or replace production query code.",
      "Direct grouped HAVING is deliberately ineligible for missing/complement and empty-filter semantics instead of approximating them.",
    ]
  end

  def distribution(values)
    sorted = values.sort
    { "p50" => percentile(sorted, 0.50), "p95" => percentile(sorted, 0.95), "p99" => percentile(sorted, 0.99), "min" => sorted.first, "max" => sorted.last }
  end

  def censored_distribution(attempts)
    completed = attempts.select { |attempt| attempt.fetch("completed") }.map { |attempt| attempt.fetch("planning_time_ms") + attempt.fetch("execution_time_ms") }.sort
    observations = completed + Array.new(attempts.length - completed.length, MEASURED_TIMEOUT_MS)
    {
      "scheduled" => attempts.length,
      "completed" => completed.length,
      "censored" => attempts.length - completed.length,
      "p50" => censored_percentile(observations, completed.length, 0.50),
      "p95" => censored_percentile(observations, completed.length, 0.95),
      "p99" => censored_percentile(observations, completed.length, 0.99),
    }
  end

  def censored_percentile(observations, completed_count, fraction)
    rank = [(observations.length * fraction).ceil, 1].max
    if rank <= completed_count
      { "status" => "exact", "rank" => rank, "value_ms" => observations.fetch(rank - 1), "lower_bound_ms" => nil }
    else
      { "status" => "lower_bound", "rank" => rank, "value_ms" => nil, "lower_bound_ms" => MEASURED_TIMEOUT_MS }
    end
  end

  def percentile(sorted, fraction)
    sorted[[(sorted.length * fraction).ceil - 1, 0].max]
  end

  def relative_pstdev(values)
    mean = values.sum.fdiv(values.length)
    return 0.0 if mean.zero?

    Math.sqrt(values.sum { |value| (value - mean)**2 }.fdiv(values.length)) / mean
  end

  def plan_nodes(node)
    [node, *Array(node["Plans"]).flat_map { |child| plan_nodes(child) }]
  end

  def buffer_summary(plan)
    BUFFER_KEYS.to_h do |key|
      [key.downcase.tr(" ", "_"), plan.fetch(key, 0)]
    end
  end
end

MultiFilterBenchmark.run(ARGV) if $PROGRAM_NAME == __FILE__
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity, Rails/IndexBy, Rails/IndexWith, Rails/SquishedSQLHeredocs
