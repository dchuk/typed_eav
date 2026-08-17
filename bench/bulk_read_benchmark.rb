# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Naming/MethodParameterName, Performance/TimesMap, Rails/ApplicationRecord, Rails/SkipsModelValidations
require "digest"
require "json"
require "objspace"
require "optparse"
require "pg"
require "securerandom"
require "time"

class BulkReadBenchmark
  PREFIX = "typed_eav_phase5_bulk_read_"
  MATRIX = [["records_100_scopes_1", 100, 1], ["records_1000_scopes_1", 1_000, 1], ["records_1000_scopes_100", 1_000, 100], ["records_1000_scopes_1000", 1_000, 1_000]].freeze
  FIELDS = 20

  def self.run(argv)
    options = {}
    OptionParser.new do |p|
      p.on("--tier TIER") { |v| options[:tier] = v }
      p.on("--output PATH") { |v| options[:output] = v }
    end.parse!(argv)
    abort "--tier and --output required" unless %w[smoke representative].include?(options[:tier]) && options[:output]
    abort "representative not admitted" if options[:tier] == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
    new(**options).call
  end

  def initialize(tier:, output:)
    @tier = tier
    @output = output
    @database = "#{PREFIX}#{Process.pid}_#{Time.now.utc.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
    @admin = PG.connect(pg.merge(dbname: "postgres"))
    @cleanup = { "created" => false, "prefix_validated" => false, "dropped" => false }
  end

  def call
    @admin.exec("CREATE DATABASE #{@admin.quote_ident(@database)}")
    @cleanup["created"] = true
    ENV["RAILS_ENV"] = "test"
    ENV["DATABASE_URL"] = "postgresql://#{ENV.fetch("PGUSER", "postgres")}@#{ENV.fetch("PGHOST", "localhost")}/#{@database}"
    require_relative "../spec/dummy/config/environment"
    ActiveRecord::MigrationContext.new([File.expand_path("../db/migrate", __dir__), File.expand_path("../spec/dummy/db/migrate", __dir__)]).migrate
    Object.const_set(:BulkReadBenchmarkHost, Class.new(ActiveRecord::Base))
    BulkReadBenchmarkHost.table_name = "bulk_read_benchmark_hosts"
    BulkReadBenchmarkHost.has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id
    ActiveRecord::Base.connection.create_table(:bulk_read_benchmark_hosts) do |t|
      t.string :tenant_id, null: false
      t.string :workspace_id, null: false
      t.string :label, null: false
      t.timestamps
    end
    result = execute
    cleanup
    result["environment"]["cleanup"] = @cleanup
    File.write(@output, "#{JSON.pretty_generate(result)}\n")
  ensure
    cleanup
    @admin&.close
  end

  def pg
    { host: ENV.fetch("PGHOST", "localhost"), port: ENV.fetch("PGPORT", nil), user: ENV.fetch("PGUSER", nil), password: ENV.fetch("PGPASSWORD", nil) }.compact
  end

  def execute
    smoke = semantic_smoke
    TypedEAV::Value.delete_all
    TypedEAV::Field::Base.delete_all
    BulkReadBenchmarkHost.delete_all
    scenarios = MATRIX.map.with_index { |(name, records, scopes), i| dataset(name, @tier == "smoke" ? [records, 20].min : records, @tier == "smoke" ? [scopes, 5].min : scopes, i) }
    trials = 3.times.map do |rotation|
      ordered = scenarios.rotate(rotation)
      { "trial" => rotation + 1, "workload_order" => ordered.map { |s| s[:name] }, "workloads" => ordered.map { |s| { "name" => s[:name], "warmup" => observe(s, 0, false), "observations" => 10.times.map { |i| observe(s, i + 1, true) } } } }
    end
    observations = trials.flat_map { |t| t["workloads"] }.flat_map { |w| w["observations"] }
    warmups = trials.flat_map { |t| t["workloads"] }.pluck("warmup")
    {
      "schema_version" => 1, "generated_at_utc" => Time.now.utc.iso8601,
      "environment" => environment, "protocol" => protocol, "semantic_smoke" => smoke,
      "datasets" => scenarios.pluck(:metadata), "relation_sizes" => sizes,
      "trials" => trials, "summaries" => summaries(trials),
      "instrumentation_limitations" => ["SQL row and AR object counts are Rails notification payloads from the actual public call.", "ObjectSpace and RSS are whole-process snapshots; allocator retention can produce negative ObjectSpace deltas.", "Instrumentation perturbs absolute timing; co-tenant latency is diagnostic only.", "Host records are materialized before measurement."],
      "validation" => { "accepted" => smoke["passed"] && observations.length == 120 && warmups.length == 12 && observations.all? { |o| o["semantic_equal"] } && (observations + warmups).all? { |o| o["sql"].all? { |q| q["row_count"].is_a?(Integer) } }, "trial_count" => 3, "warmup_count" => warmups.length, "observation_count" => observations.length, "all_semantically_equal" => observations.all? { |o| o["semantic_equal"] }, "notification_row_counts_complete" => (observations + warmups).all? { |o| o["sql"].all? { |q| q["row_count"].is_a?(Integer) } }, "no_censored_or_error_observations" => observations.all? { |o| o["outcome"] == "completed" } }
    }
  end

  def semantic_smoke
    now = Time.now.utc
    BulkReadBenchmarkHost.insert_all!([{ tenant_id: "smoke-t", workspace_id: "smoke-w", label: "primary", created_at: now, updated_at: now }, { tenant_id: "smoke-t", workspace_id: "smoke-w", label: "missing", created_at: now, updated_at: now }])
    hosts = BulkReadBenchmarkHost.order(:id).to_a
    global = field("collision", "TypedEAV::Field::Integer")
    scoped = field("collision", "TypedEAV::Field::Integer", "smoke-t")
    full = field("collision", "TypedEAV::Field::Integer", "smoke-t", "smoke-w")
    nullable = field("nullable", "TypedEAV::Field::Integer", "smoke-t", "smoke-w")
    currency = TypedEAV::Field::Currency.create!(name: "price", entity_type: "BulkReadBenchmarkHost", scope: "smoke-t", parent_scope: "smoke-w", default_currency: "USD", allowed_currencies: %w[USD CAD])
    orphan = field("orphan", "TypedEAV::Field::Text", "smoke-t", "smoke-w")
    [[global, 1], [scoped, 2], [full, 3], [nullable, nil], [currency, { amount: "12.50", currency: "CAD" }], [orphan, "discarded"]].each { |f, v| value(hosts.first, f, v) }
    TypedEAV::Field::Base.connection.execute("DELETE FROM typed_eav_fields WHERE id=#{orphan.id}")
    actual = BulkReadBenchmarkHost.typed_eav_hash_for(hosts)
    expected = { hosts.first.id => { "collision" => 3, "nullable" => nil, "price" => { amount: BigDecimal("12.5"), currency: "CAD" } }, hosts.last.id => {} }
    controls = { "global_scope_full_tuple_winner" => actual.dig(hosts.first.id, "collision") == 3, "explicit_null_present" => actual[hosts.first.id].key?("nullable") && actual.dig(hosts.first.id, "nullable").nil?, "missing_absent" => actual[hosts.last.id].empty?, "currency_multi_cell" => actual.dig(hosts.first.id, "price") == expected.dig(hosts.first.id, "price"), "orphan_skipped" => !actual[hosts.first.id].key?("orphan"), "public_shape" => actual.keys.all?(Integer) && actual.values.all?(Hash) }
    { "actual" => canonical(actual), "expected" => canonical(expected), "identity" => identity(actual), "expected_identity" => identity(expected), "controls" => controls, "passed" => controls.values.all? && identity(actual) == identity(expected) }
  end

  def field(name, type, scope = nil, parent = nil)
    TypedEAV::Field::Base.create!(name: name, type: type, entity_type: "BulkReadBenchmarkHost", scope: scope, parent_scope: parent)
  end

  def value(host, field, raw)
    TypedEAV::Value.new(entity: host, field: field).tap do |v|
      v.value = raw
      v.save!
    end
  end

  def dataset(name, record_count, scope_count, index)
    now = Time.now.utc
    prefix = "s#{index}"
    rows = record_count.times.map do |i|
      s = i % scope_count
      { tenant_id: "#{prefix}-t-#{s}", workspace_id: "#{prefix}-w-#{s}", label: "#{prefix}-h-#{i}", created_at: now, updated_at: now }
    end
    ids = BulkReadBenchmarkHost.insert_all!(rows, returning: %w[id]).rows.flatten
    hosts = BulkReadBenchmarkHost.where(id: ids).order(:id).to_a
    defs = FIELDS.times.map { |f| field_row("#{prefix}_field_#{f}", nil, nil, now) }
    scope_count.times do |s|
      FIELDS.times do |f|
        defs << field_row("#{prefix}_field_#{f}", "#{prefix}-t-#{s}", nil, now)
        defs << field_row("#{prefix}_field_#{f}", "#{prefix}-t-#{s}", "#{prefix}-w-#{s}", now)
      end
    end
    field_ids = {}
    TypedEAV::Field::Base.insert_all!(defs, returning: %w[id name scope parent_scope]).rows.each { |id, n, s, p| field_ids[[n, s, p]] = id }
    expected = {}
    values = []
    hosts.each_with_index do |host, hi|
      expected[host.id] = {}
      FIELDS.times do |f|
        n = "#{prefix}_field_#{f}"
        v = (index * 1_000_000) + (hi * FIELDS) + f
        expected[host.id][n] = v
        values << { entity_type: "BulkReadBenchmarkHost", entity_id: host.id, field_id: field_ids.fetch([n, host.tenant_id, host.workspace_id]), integer_value: v, created_at: now, updated_at: now }
      end
    end
    TypedEAV::Value.insert_all!(values)
    { name: name, hosts: hosts, expected: identity(expected), metadata: { "name" => name, "records" => record_count, "scopes" => scope_count, "values_per_host" => FIELDS, "host_ids_sha256" => Digest::SHA256.hexdigest(ids.join(",")), "expected_identity" => identity(expected), "field_definitions" => defs.length, "value_rows" => values.length } }
  end

  def field_row(name, scope, parent, now)
    { name: name, type: "TypedEAV::Field::Integer", entity_type: "BulkReadBenchmarkHost", scope: scope, parent_scope: parent, required: false, options: {}, default_value_meta: {}, field_dependent: "destroy", created_at: now, updated_at: now }
  end

  def observe(scenario, sequence, measured)
    GC.start(full_mark: true, immediate_sweep: true)
    before_gc = GC.stat
    before_mem = ObjectSpace.memsize_of_all
    before_rss = rss
    sql = []
    instantiated = 0
    sub_sql = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, p|
      next if %w[SCHEMA TRANSACTION CACHE].include?(p[:name]) || p[:cached]

      sql << { "name" => p[:name], "sql" => p[:sql], "binds" => Array(p[:binds]).map { |b| b.respond_to?(:value_for_database) ? { "name" => b.name, "value" => canonical(b.value_for_database) } : canonical(b) }, "row_count" => p[:row_count] }
    end
    sub_inst = ActiveSupport::Notifications.subscribe("instantiation.active_record") { |_n, _s, _f, _i, p| instantiated += p[:record_count] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = BulkReadBenchmarkHost.connection.uncached { BulkReadBenchmarkHost.typed_eav_hash_for(scenario[:hosts]) }
    wall = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    after_gc = GC.stat
    found = identity(result)
    { "sequence" => sequence, "measured" => measured, "outcome" => "completed", "identity" => found, "expected_identity" => scenario[:expected], "semantic_equal" => found == scenario[:expected], "result_record_count" => result.length, "result_value_count" => result.values.sum(&:length), "wall_ms" => wall, "sql_statement_count" => sql.length, "sql_returned_rows" => sql.sum { |q| q["row_count"] }, "active_record_instantiations" => instantiated, "ruby_allocated_objects" => after_gc[:total_allocated_objects] - before_gc[:total_allocated_objects], "objectspace_bytes_delta" => ObjectSpace.memsize_of_all - before_mem, "rss_bytes_before" => before_rss, "rss_bytes_after" => rss, "gc_count_delta" => after_gc[:count] - before_gc[:count], "gc_time_ms_delta" => after_gc[:time] - before_gc[:time], "sql" => sql }
  ensure
    ActiveSupport::Notifications.unsubscribe(sub_sql) if sub_sql
    ActiveSupport::Notifications.unsubscribe(sub_inst) if sub_inst
  end

  def summaries(trials)
    MATRIX.map do |name, _r, _s|
      rows = trials.flat_map { |t| t["workloads"] }.select { |w| w["name"] == name }.flat_map { |w| w["observations"] }
      wall = rows.map { |o| o["wall_ms"] }.sort
      { "name" => name, "observation_count" => rows.length, "wall_ms_p50" => pct(wall, 0.5), "wall_ms_p95" => pct(wall, 0.95), "wall_ms_p99" => pct(wall, 0.99), "sql_statement_count_values" => rows.map { |o| o["sql_statement_count"] }.uniq.sort, "sql_returned_rows_values" => rows.map { |o| o["sql_returned_rows"] }.uniq.sort, "active_record_instantiation_values" => rows.map { |o| o["active_record_instantiations"] }.uniq.sort, "ruby_allocated_objects_p50" => pct(rows.map { |o| o["ruby_allocated_objects"] }.sort, 0.5), "objectspace_bytes_delta_p50" => pct(rows.map { |o| o["objectspace_bytes_delta"] }.sort, 0.5), "rss_bytes_after_p50" => pct(rows.map { |o| o["rss_bytes_after"] }.sort, 0.5), "gc_count_delta_p50" => pct(rows.map { |o| o["gc_count_delta"] }.sort, 0.5), "gc_time_ms_delta_p50" => pct(rows.map { |o| o["gc_time_ms_delta"] }.sort, 0.5) }
    end
  end

  def pct(a, p) = a.fetch(((a.length - 1) * p).ceil)

  def rss
    return File.read("/proc/self/status").match(/^VmRSS:\s+(\d+)/)[1].to_i * 1024 if File.exist?("/proc/self/status")

    IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).to_i * 1024
  rescue Errno::EPERM
    nil
  end

  def identity(v) = { "record_count" => v.length, "value_count" => v.values.sum(&:length), "sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(v))) }

  def canonical(v)
    case v; when Hash then v.sort_by { |k, _| k.to_s }.to_h { |k, x| [k.to_s, canonical(x)] }; when Array then v.map { |x| canonical(x) }; when BigDecimal then v.to_s("F"); when Time, Date, DateTime then v.iso8601; else v; end
  end

  def sizes
    %w[bulk_read_benchmark_hosts typed_eav_fields typed_eav_values].index_with { |r| ActiveRecord::Base.connection.exec_query("SELECT pg_relation_size('#{r}') heap_bytes,pg_indexes_size('#{r}') index_bytes,pg_total_relation_size('#{r}') total_bytes").first.transform_values(&:to_i) }
  end

  def environment = { "tier" => @tier, "seed" => 5_501, "ruby_version" => RUBY_VERSION, "rails_version" => Rails.version, "active_record_version" => ActiveRecord.version.to_s, "postgresql_version" => ActiveRecord::Base.connection.select_value("SHOW server_version"), "postgresql_version_num" => ActiveRecord::Base.connection.select_value("SHOW server_version_num").to_i, "platform" => RUBY_PLATFORM }
  def protocol = { "public_call" => "BulkReadBenchmarkHost.typed_eav_hash_for(materialized_hosts)", "matrix" => MATRIX.map { |n, r, s| { "name" => n, "records" => r, "scopes" => s } }, "field_count" => FIELDS, "rotations" => 3, "warmups_per_workload_trial" => 1, "measured_repetitions_per_workload_trial" => 10, "query_cache" => "disabled with connection.uncached", "host_loading_in_measurement" => false, "workload_rotation" => "cyclic" }

  def cleanup
    return unless @admin && @cleanup["created"]

    @cleanup["prefix_validated"] = @database.start_with?(PREFIX)
    return unless @cleanup["prefix_validated"]

    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
    @admin.exec_params("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1", [@database])
    @admin.exec("DROP DATABASE IF EXISTS #{@admin.quote_ident(@database)}")
    @cleanup["dropped"] = @admin.exec_params("SELECT NOT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)", [@database]).getvalue(0, 0) == "t"
    @cleanup["created"] = false
  end
end

BulkReadBenchmark.run(ARGV)
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Naming/MethodParameterName, Performance/TimesMap, Rails/ApplicationRecord, Rails/SkipsModelValidations
