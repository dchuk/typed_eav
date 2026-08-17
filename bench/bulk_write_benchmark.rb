# frozen_string_literal: true

# Benchmark orchestration intentionally trades method-size/style rules for
# explicit metric collection and protocol readability.
# rubocop:disable all

require "json"
require "optparse"
require "digest"
require_relative "../spec/spec_helper"

class BulkWriteBenchmark
  SIZES = { "hosts_100" => 100, "hosts_1000" => 1_000, "hosts_10000" => 10_000 }.freeze
  FIELDS = 10
  SURFACES = %w[semantic fast chunks].freeze
  WORKLOADS = [["insert", false], ["update", false], ["update", true]].freeze

  def self.run(argv)
    options = {}
    OptionParser.new { |p| p.on("--tier TIER") { |v| options[:tier] = v }; p.on("--output PATH") { |v| options[:output] = v } }.parse!(argv)
    abort "--tier and --output required" unless options[:tier] && options[:output]
    new(**options).call
  end

  def initialize(tier:, output:)
    @tier = tier
    @output = output
  end

  def call
    fields = prepare_fields
    observations = []
    sizes.each do |name, count|
      WORKLOADS.each do |operation, versioning|
        configure_versioning(versioning)
        SURFACES.each do |surface|
          reset_observation_state
          records = prepare_records(count)
          records = seed_update(records, fields) if operation == "update"
          observations << measure(name, count, operation, versioning, surface, records, fields)
        end
      end
    end
    File.write(@output, JSON.pretty_generate("schema_version" => 2, "protocol" => protocol, "observations" => observations) + "\n")
  ensure
    TypedEAV.config.versioning = false
  end

  private

  def sizes
    return SIZES.slice("hosts_100") if @tier == "smoke"
    return SIZES.slice("hosts_100", "hosts_1000") if @tier == "bounded"

    SIZES
  end

  def prepare_fields
    TypedEAV::Value.delete_all
    TypedEAV::ValueVersion.delete_all
    TypedEAV::Field::Base.delete_all
    (0...FIELDS).map { |i| TypedEAV::Field::Integer.create!(name: "bulk_#{i}", entity_type: "Contact", scope: "bench") }
  end

  def prepare_records(count)
    Contact.delete_all
    now = Time.current
    ids = Contact.insert_all(Array.new(count) { |i| { tenant_id: "bench", name: "Host #{i}", created_at: now, updated_at: now } }, returning: %w[id]).rows.flatten
    Contact.where(id: ids).order(:id).to_a
  end

  def configure_versioning(enabled)
    TypedEAV.config.versioning = enabled
    TypedEAV.registry.register("Contact", types: nil, versioned: enabled)
    TypedEAV::Versioning.register_if_enabled if enabled
  end

  def reset_observation_state
    TypedEAV::Value.delete_all
    TypedEAV::ValueVersion.delete_all
  end

  def seed_update(records, fields)
    values = fields.each_with_index.to_h { |field, i| [field.name, -(i + 1)] }
    Contact.bulk_upsert_typed_eav_values(records, values, acknowledge_reduced_semantics: true)
    Contact.where(id: records.map(&:id)).order(:id).to_a
  end

  def measure(name, count, operation, versioning, surface, records, fields)
    values = fields.each_with_index.to_h { |field, i| [field.name, i + 1] }
    expected_rows = count * FIELDS
    expected_checksum = expected_rows * (FIELDS + 1) / 2
    sql = []
    gc_before = GC.stat
    rss_supported, rss_before = rss_bytes
    allocated_before = gc_before[:total_allocated_objects]
    wal_supported, wal_before = wal_lsn
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    callback = lambda { |_, _, _, _, payload| sql << payload[:sql] unless payload[:name] == "SCHEMA" }
    install_save_counter
    Thread.current[:t091_save_callbacks] = 0
    result = nil
    begin
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        case surface
        when "semantic" then result = Contact.bulk_set_typed_eav_values(records, values)
        when "fast" then result = Contact.bulk_upsert_typed_eav_values(records, values, acknowledge_reduced_semantics: true)
        when "chunks" then result = Contact.bulk_set_typed_eav_values(records, values, transaction: :chunks, chunk_size: 250)
        end
      end
    ensure
      save_callbacks = Thread.current[:t091_save_callbacks] || 0
      Thread.current[:t091_save_callbacks] = nil
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    # Capture post-write resource counters before any identity queries or
    # Ruby allocations used to validate the logical result.
    gc_after = GC.stat
    rss_supported_after, rss_after = rss_bytes
    wal_supported_after, wal_after = wal_lsn
    typed_values = TypedEAV::Value.where(entity_type: "Contact", entity_id: records.map(&:id)).pluck(:integer_value).compact
    ordinal_by_id = records.each_with_index.to_h { |record, index| [record.id, index] }
    actual_triples = TypedEAV::Value.joins(:field).where(entity_type: "Contact", entity_id: records.map(&:id)).pluck(
      :entity_id, "typed_eav_fields.name", :integer_value
    ).map do |entity_id, name, value|
      [ordinal_by_id.fetch(entity_id), name, value]
    end
    expected_triples = records.each_with_index.flat_map do |_record, ordinal|
      values.map { |name, value| [ordinal, name.to_s, value] }
    end
    logical_digest = lambda do |triples|
      Digest::SHA256.hexdigest(JSON.generate(triples.sort_by { |triple| JSON.generate(triple) }))
    end
    actual_digest = logical_digest.call(actual_triples)
    expected_digest = logical_digest.call(expected_triples)
    {
      "name" => name, "hosts" => count, "operation" => operation, "versioning" => versioning, "surface" => surface,
      "sql_statement_count" => sql.length, "savepoint_count" => sql.count { |q| q.start_with?("SAVEPOINT") },
      "begin_count" => sql.count { |q| q.match?(/\A(?:BEGIN|START TRANSACTION)/i) }, "commit_count" => sql.count { |q| q.match?(/\ACOMMIT/i) }, "rollback_count" => sql.count { |q| q.match?(/\AROLLBACK/i) },
      "host_write_statements" => sql.count { |q| q.match?(/\A\s*INSERT\s+INTO\s+[\"`]?contacts[\"`]?/i) || q.match?(/\A\s*UPDATE\s+[\"`]?contacts[\"`]?/i) }, "typed_value_write_statements" => sql.count { |q| q.match?(/\A\s*INSERT\s+INTO\s+[\"`]?typed_eav_values[\"`]?/i) || q.match?(/\A\s*UPDATE\s+[\"`]?typed_eav_values[\"`]?/i) },
      "version_statements" => sql.count { |q| q.match?(/typed_eav_value_versions/i) }, "version_rows" => TypedEAV::ValueVersion.where(entity_type: "Contact", entity_id: records.map(&:id)).count,
      # Update/versioning observations seed prior values before timing, so
      # semantic/chunk surfaces must retain real audit rows.
      "expected_version_rows" => operation == "update" && versioning && surface != "fast" ? expected_rows : 0,
      "value_rows" => typed_values.length, "value_checksum" => typed_values.sum, "expected_rows" => expected_rows, "expected_checksum" => expected_checksum,
      "logical_digest" => actual_digest, "expected_logical_digest" => expected_digest, "semantic_identity" => typed_values.length == expected_rows && typed_values.sum == expected_checksum && actual_digest == expected_digest, "returned_successes" => result.is_a?(Hash) ? result.fetch(:successes, []).length : nil, "returned_errors" => result.is_a?(Hash) ? result.fetch(:errors_by_record, {}).length : nil, "returned_rows" => result.is_a?(Integer) ? result : nil, "save_callback_count" => save_callbacks, "wall_ms" => (elapsed * 1000).round(2),
      "throughput_values_per_second" => (expected_rows / elapsed).round(2), "ruby_allocated_objects" => gc_after[:total_allocated_objects] - allocated_before,
      "gc_count_delta" => gc_after[:count] - gc_before[:count], "gc_time_ms_delta" => gc_after[:time] - gc_before[:time], "rss_supported" => rss_supported && rss_supported_after, "rss_before" => rss_before, "rss_after" => rss_after, "wal_supported" => wal_supported && wal_supported_after, "wal_bytes" => wal_after && wal_before ? wal_after - wal_before : nil,
    }
  end

  def wal_lsn
    [true, TypedEAV::Value.connection.select_value("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')")&.to_i]
  rescue ActiveRecord::StatementInvalid
    [false, nil]
  end

  def rss_bytes
    status = File.read("/proc/self/status")
    match = status.match(/VmRSS:\s+(\d+) kB/)
    [!match.nil?, match && match[1].to_i * 1024]
  rescue Errno::ENOENT
    begin
      value = IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).to_i
      [value.positive?, value.positive? ? value * 1024 : nil]
    rescue Errno::EPERM
      [false, nil]
    end
  rescue Errno::EPERM
    [false, nil]
  end

  def install_save_counter
    return if Contact.instance_variable_defined?(:@t091_benchmark_save_counter)

    counter = Module.new do
      define_method(:save) do |*args, **kwargs, &block|
        Thread.current[:t091_save_callbacks] = Thread.current.fetch(:t091_save_callbacks, 0) + 1
        super(*args, **kwargs, &block)
      end
    end
    Contact.prepend(counter)
    Contact.instance_variable_set(:@t091_benchmark_save_counter, true)
    Thread.current[:t091_save_callbacks] = 0
  end

  def protocol = { "field_count" => FIELDS, "sizes" => sizes, "surfaces" => SURFACES, "workloads" => WORKLOADS.map { |operation, versioning| { "operation" => operation, "versioning" => versioning } }, "chunk_size" => 250, "independent_observation_reset" => true, "reduced_semantics_acknowledged" => true }
end

BulkWriteBenchmark.run(ARGV)
# rubocop:enable all
