# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Rails/IndexWith, Rails/Pluck -- SQL evidence is intentionally cohesive.
require "digest"
require "json"
require "open3"
require "optparse"
require "pg"
require "securerandom"
require "time"

class StringSearchBenchmark
  CANDIDATES = {
    "current_btree" => ["CREATE INDEX %<name>s_btree ON %<table>s (field_id, string_value text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL"],
    "lower_btree" => ["CREATE INDEX %<name>s_btree ON %<table>s (field_id, string_value text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL", "CREATE INDEX %<name>s_lower ON %<table>s (field_id, lower(string_value) text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL"],
    "trgm_gin" => ["CREATE INDEX %<name>s_btree ON %<table>s (field_id, string_value text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL", "CREATE INDEX %<name>s_trgm ON %<table>s USING gin (string_value gin_trgm_ops) WHERE string_value IS NOT NULL"],
  }.freeze
  GIST = ["CREATE INDEX %<name>s_btree ON %<table>s (field_id, string_value text_pattern_ops) INCLUDE (entity_id) WHERE string_value IS NOT NULL", "CREATE INDEX %<name>s_trgm ON %<table>s USING gist (string_value gist_trgm_ops) WHERE string_value IS NOT NULL"].freeze
  PUBLIC_QUERIES = {
    "eq" => ["=", "Acme Alpha 000042"], "starts_with" => ["ILIKE", "Sea%"], "contains" => ["ILIKE", "%port%"], "ends_with" => ["ILIKE", "%Heights"], "not_contains" => ["NOT ILIKE", "%Portland%"],
    "contains_one_character" => ["ILIKE", "%a%"], "contains_two_characters" => ["ILIKE", "%al%"], "contains_literal_percent" => ["ILIKE", "%100\\%%"], "contains_literal_underscore" => ["ILIKE", "%under\\_score%"]
  }.freeze
  DB_PREFIX = "typed_eav_phase3_"
  SMOKE_ENTITIES = 5_000
  REPRESENTATIVE_ENTITIES = 250_000
  SMOKE_MAX_BYTES = 500 * 1024 * 1024
  REPRESENTATIVE_MIN_FREE_BYTES = 20 * (1024**3)
  REPRESENTATIVE_RESERVE_BYTES = 8 * (1024**3)

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
    @admin = PG.connect(connect.merge(dbname: ENV.fetch("PGMAINTENANCE_DB", "postgres")))
    @created = false
    @cleanup = { "created_by_run" => false, "attempted" => false, "database_prefix_validated" => false, "dropped" => false }
  end

  def call
    qualify!
    @admin.exec("CREATE DATABASE #{@admin.quote_ident(@database)}")
    @created = @cleanup["created_by_run"] = true
    @db = PG.connect(connect.merge(dbname: @database))
    @db.exec("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    result = run_all
    cleanup
    result["environment"]["cleanup"] = @cleanup
    File.write(@output, "#{JSON.pretty_generate(result)}\n")
  ensure
    cleanup
    @admin&.close
  end

  private

  def connect
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", nil), user: ENV.fetch("PGUSER", nil), password: ENV.fetch("PGPASSWORD", nil) }.compact
  end

  def cleanup
    return unless @admin && @created

    @cleanup["attempted"] = true
    @cleanup["database_prefix_validated"] = @database.start_with?(DB_PREFIX)
    return unless @cleanup["database_prefix_validated"]

    @db.close if @db && !@db.finished?
    @admin.exec("DROP DATABASE IF EXISTS #{@admin.quote_ident(@database)}")
    @cleanup["dropped"] = @admin.exec_params("SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=$1)", [@database]).getvalue(0, 0) == "t"
    @created = false
  end

  def qualify!
    projected = @entities * 2 * CANDIDATES.length * 1_000
    abort "smoke footprint exceeds 500 MiB" if @tier == "smoke" && projected > SMOKE_MAX_BYTES
    return if @tier == "smoke"

    free = free_bytes(@admin.exec("SHOW data_directory").getvalue(0, 0))
    abort "representative storage is not qualified" if free < [REPRESENTATIVE_MIN_FREE_BYTES, projected + REPRESENTATIVE_RESERVE_BYTES].max
  end

  def free_bytes(path)
    output, status = Open3.capture2("df", "-Pk", path)
    abort "unable to inspect PostgreSQL volume" unless status.success?
    output.lines.last.split.fetch(3).to_i * 1024
  end

  def run_all
    candidates = {}
    checksums = {}
    @order.each do |name|
      candidates[name], checksums[name] = run_candidate(name, CANDIDATES.fetch(name))
      ensure_reserve!
    end
    abort "candidate dataset checksum mismatch" unless checksums.values.uniq.one?
    gist = if @tier == "smoke"
             run_candidate("gist_smoke", GIST).first
           else
             { "advanced_beyond_smoke" => false, "reason" => "GiST remains smoke-only: it adds a non-covering string-only index, while GIN is the representative broad-ILIKE contender. No production conclusion is made." }
           end
    { "generated_at_utc" => Time.now.utc.iso8601, "trial" => ENV.fetch("TYPED_EAV_TRIAL", "1").to_i, "candidate_order" => @order, "environment" => environment, "dataset" => dataset.merge("candidate_checksums" => checksums, "checksum_equal_across_candidates" => true), "public_sql_contract" => public_contract, "candidates" => candidates, "gist" => gist, "limitations" => limitations }
  end

  def run_candidate(name, templates)
    table = @db.quote_ident("string_values_#{name}")
    @db.exec("CREATE TABLE #{table} (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, entity_id integer NOT NULL, field_id integer NOT NULL, string_value text)")
    checksum = load_rows(table)
    vacuum(table)
    build = build_indexes(name, table, templates)
    vacuum(table)
    queries = PUBLIC_QUERIES.to_h { |operator, (_sql, pattern)| [operator, query_evidence(table, operator, pattern)] }
    prototype = lower_prototype(table)
    writes = write_metrics(table)
    vacuum(table)
    post = PUBLIC_QUERIES.to_h { |operator, (_sql, pattern)| [operator, explain(table, predicate(operator, pattern))] }
    [{ "ddl" => build["ddl"], "index_build_elapsed_ms" => build["elapsed_ms"], "index_build_wal_bytes" => build["wal_bytes"], "relation_bytes" => relation_sizes(table), "index_sizes" => index_sizes(table), "write_metrics" => writes, "public_queries" => queries, "lower_like_prototype" => prototype, "post_update_public_plans" => post }, checksum]
  end

  def load_rows(table)
    digest = Digest::SHA256.new
    @db.copy_data("COPY #{table} (entity_id,field_id,string_value) FROM STDIN WITH (FORMAT csv, NULL '\\N')") do
      rng = Random.new(@seed)
      @entities.times do |entity|
        [[entity, 1, generated(entity, rng)], [entity, 2, "Noise #{rng.rand(1_000_000)}"]].each do |row|
          digest << row.inspect
          @db.put_copy_data("#{row.map { |value| PG::Connection.escape_string(value.to_s) }.join(",")}\n")
        end
      end
    end
    digest.hexdigest
  end

  def generated(entity, rng)
    case entity % 100
    when 0 then "100% Portland #{entity} Heights"
    when 1 then "under_score Seattle port #{entity}"
    when 2..6 then "Seattle Port #{rng.rand(10_000)} Heights"
    when 7..26 then "Portland Harbor #{rng.rand(1_000)}"
    when 27..66 then "Acme Alpha #{format("%06d", entity)}"
    else "Zephyr #{rng.rand(1_000_000)}"
    end
  end

  def build_indexes(name, table, templates)
    wal = lsn
    started = clock
    ddl = templates.each_with_index.map do |template, index|
      sql = format(template, name: "idx_#{name}_#{index}", table: table)
      @db.exec(sql)
      sql
    end
    { "ddl" => ddl, "elapsed_ms" => elapsed(started), "wal_bytes" => wal_delta(wal) }
  end

  def write_metrics(table)
    before = lsn
    started = clock
    inserted = @db.exec("INSERT INTO #{table}(entity_id,field_id,string_value) SELECT #{@entities}+g, CASE WHEN g%2=0 THEN 1 ELSE 2 END, CASE WHEN g%10=0 THEN 'Seattle port appended '||g ELSE 'Appended '||g END FROM generate_series(1,#{@entities / 10}) g").cmd_tuples
    insert_ms = elapsed(started)
    insert_wal = wal_delta(before)
    before = lsn
    started = clock
    updated = @db.exec("UPDATE #{table} SET string_value=string_value||' revised' WHERE field_id=1 AND entity_id%20=0").cmd_tuples
    update_ms = elapsed(started)
    { "inserted_rows" => inserted, "insert_elapsed_ms" => insert_ms, "insert_rows_per_second" => rate(inserted, insert_ms), "insert_wal_bytes" => insert_wal, "updated_rows" => updated, "update_elapsed_ms" => update_ms, "update_rows_per_second" => rate(updated, update_ms), "update_wal_bytes" => wal_delta(before) }
  end

  def query_evidence(table, operator, pattern)
    pred = predicate(operator, pattern)
    sql = "SELECT count(*),md5(COALESCE(string_agg(entity_id::text,',' ORDER BY entity_id),'')) FROM #{table} WHERE field_id=1 AND #{pred}"
    row = @db.exec(sql).first
    timings = Array.new(3) do
      started = clock
      @db.exec(sql)
      elapsed(started)
    end
    { "sql" => "SELECT entity_id FROM #{table} WHERE field_id=1 AND #{pred}", "match_count" => row.fetch("count").to_i, "entity_id_checksum" => row.fetch("md5"), "elapsed_ms" => timings, "plan" => explain(table, pred) }
  end

  def predicate(operator, pattern)
    "string_value #{PUBLIC_QUERIES.fetch(operator).first} #{@db.escape_literal(pattern)}"
  end

  def lower_prototype(table)
    pred = "lower(string_value) LIKE 'sea%'"
    { "public_semantics" => false, "sql" => "SELECT entity_id FROM #{table} WHERE field_id=1 AND #{pred}", "warning" => "Different from unchanged public ILIKE; index usability and collation/locale equivalence are not assumed.", "plan" => explain(table, pred) }
  end

  def explain(table, pred)
    doc = JSON.parse(@db.exec("EXPLAIN (ANALYZE,BUFFERS,WAL,SETTINGS,FORMAT JSON) SELECT entity_id FROM #{table} WHERE field_id=1 AND #{pred}").getvalue(0, 0)).first
    root = doc.fetch("Plan")
    nodes = []
    visit = lambda { |node|
      nodes << node
      Array(node["Plans"]).each { |child| visit.call(child) }
    }
    visit.call(root)
    summary = { "node_types" => nodes.map { |node| node["Node Type"] }, "index_names" => nodes.filter_map { |node| node["Index Name"] }, "actual_rows" => root["Actual Rows"], "execution_ms" => root["Actual Total Time"], "shared_hit_blocks" => nodes.sum { |node| node.fetch("Shared Hit Blocks", 0) }, "shared_read_blocks" => nodes.sum { |node| node.fetch("Shared Read Blocks", 0) }, "heap_fetches" => nodes.sum { |node| node.fetch("Heap Fetches", 0) }, "rows_removed_by_filter" => nodes.sum { |node| node.fetch("Rows Removed by Filter", 0) } }
    { "document" => doc, "summary" => summary }
  end

  def vacuum(table) = @db.exec("VACUUM (ANALYZE) #{table}")
  def lsn = @db.exec("SELECT pg_current_wal_lsn()").getvalue(0, 0)
  def wal_delta(before) = @db.exec_params("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(),$1)::bigint", [before]).getvalue(0, 0).to_i
  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def elapsed(started) = ((clock - started) * 1_000).round(3)
  def rate(rows, milliseconds) = (rows / (milliseconds / 1_000.0)).round(1)

  def relation_sizes(table)
    row = @db.exec_params("SELECT pg_relation_size($1),pg_indexes_size($1),pg_total_relation_size($1)", [table.delete('"')]).first
    { "heap_bytes" => row.fetch("pg_relation_size").to_i, "index_bytes" => row.fetch("pg_indexes_size").to_i, "total_bytes" => row.fetch("pg_total_relation_size").to_i }
  end

  def index_sizes(table)
    @db.exec_params("SELECT indexrelname,pg_relation_size(indexrelid) bytes FROM pg_stat_user_indexes WHERE relname=$1 ORDER BY indexrelname", [table.delete('"')]).map { |row| { "name" => row.fetch("indexrelname"), "bytes" => row.fetch("bytes").to_i } }
  end

  def ensure_reserve!
    return unless @tier == "representative"

    abort "representative reserve breached" if free_bytes(@db.exec("SHOW data_directory").getvalue(0, 0)) < REPRESENTATIVE_RESERVE_BYTES
  end

  def environment
    settings = %w[server_version server_encoding shared_buffers work_mem maintenance_work_mem].to_h { |key| [key, @db.exec("SHOW #{key}").getvalue(0, 0)] }
    locale = @db.exec("SELECT datcollate,datctype FROM pg_database WHERE datname=current_database()").first
    settings.merge("database_collation" => locale["datcollate"], "database_ctype" => locale["datctype"], "ruby" => RUBY_VERSION, "pg_gem" => PG::VERSION, "pg_trgm_version" => @db.exec("SELECT extversion FROM pg_extension WHERE extname='pg_trgm'").getvalue(0, 0), "tier" => @tier, "database" => @database, "cleanup" => @cleanup)
  end

  def dataset
    { "seed" => @seed, "entities_per_field" => @entities, "rows_per_candidate_before_write_probe" => @entities * 2, "fields" => 2, "target_field_id" => 1, "distribution" => "deterministic skew: 40% Acme Alpha, 33% Zephyr, 20% Portland Harbor, 5% Seattle Port Heights, 1% escaped percent, 1% escaped underscore; field 2 is noise", "selectivity_controls" => PUBLIC_QUERIES.keys }
  end

  def public_contract
    PUBLIC_QUERIES.transform_values { |operator, pattern| { "operator" => operator, "escaped_operand" => pattern, "predicate" => "field_id=1 AND string_value #{operator} #{@db.escape_literal(pattern)}" } }
  end

  def limitations
    ["Public eq is =; starts_with/contains/ends_with are ILIKE; not_contains is NOT ILIKE.", "One/two-character contains probes expose sub-trigram limitations.", "NOT ILIKE is negative; no acceleration claim is made.", "lower/LIKE changes public SQL and is not evidence for unchanged ILIKE.", "Absolute co-tenant latency is diagnostic; relative evidence requires dispersion/no-impact gates.", "PG15/16/18 prove extension lifecycle compatibility only; PG17 is the sole performance/planner evidence."]
  end
end

StringSearchBenchmark.run(ARGV)
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Rails/IndexWith, Rails/Pluck
