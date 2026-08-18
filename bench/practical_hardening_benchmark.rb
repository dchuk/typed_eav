# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "timeout"
require_relative "../spec/spec_helper"
# rubocop:disable all

class PracticalHardeningBenchmark
  CELLS = %w[backfill_default_all backfill_relation bulk_update_versioning_off bulk_update_versioning_on field_delete_versioning_on].freeze
  BASELINE = "b74482b84fc5bc75dcbb13ddd99a72c8371763aa"
  SOURCES = %w[bench/practical_hardening_benchmark.rb bench/validate_practical_hardening_artifact.rb bench/docker/practical-hardening/run_local.sh].freeze

  def self.run(argv)
    options = {}
    OptionParser.new { |p| p.on("--tier TIER") { |v| options[:tier] = v }; p.on("--cell CELL") { |v| options[:cell] = v }; p.on("--output PATH") { |v| options[:output] = v } }.parse!(argv)
    abort "missing options" unless options.values_at(:tier, :cell, :output).all?
    new(**options).call
  end

  def initialize(tier:, cell:, output:)
    @cell, @output, @tier = cell, output, tier
    @hosts, @eligible = if cell.start_with?("backfill")
                          tier == "smoke" ? [20, 2] : [1_000, 100]
                        elsif cell.start_with?("bulk")
                          [tier == "smoke" ? 20 : 100, nil]
                        else
                          [tier == "smoke" ? 100 : 1_001, nil]
                        end
    @deadline = tier == "smoke" ? 30 : 90
  end

  def call
    guard_harness!
    configure_versioning(@cell.end_with?("versioning_on"))
    Timeout.timeout(@deadline) { reset; append(fixture) }
  ensure
    TypedEAV.config.versioning = false
  end

  private

  def guard_harness!
    abort "invalid tier" unless %w[smoke bounded].include?(@tier)
    abort "invalid cell" unless CELLS.include?(@cell)
    expected = ENV.fetch("TYPED_EAV_PRACTICAL_DB", nil)
    abort "unsafe database name" unless expected&.match?(/\Atyped_eav_t167_#{@tier}_[0-9]+\z/)
    actual = ActiveRecord::Base.connection.current_database
    abort "unsafe database" unless actual == expected
  end

  def configure_versioning(enabled)
    TypedEAV.config.versioning = enabled
    TypedEAV.registry.register("Contact", types: nil, versioned: enabled)
    TypedEAV::Versioning.register_if_enabled if enabled
  end

  def reset
    TypedEAV::ValueVersion.delete_all; TypedEAV::Value.delete_all; TypedEAV::Field::Base.delete_all; Contact.delete_all
  end

  def contacts(count = @hosts)
    now = Time.current
    ids = Contact.insert_all(Array.new(count) { |i| { name: "bench-#{i}", tenant_id: "bench", created_at: now, updated_at: now } }, returning: %w[id]).rows.flatten
    Contact.where(id: ids).order(:id).to_a
  end

  def field(name, default: nil)
    TypedEAV::Field::Integer.create!(name: name, entity_type: "Contact", scope: "bench", default_value: default, field_dependent: "destroy")
  end

  def fixture
    return backfill(@cell == "backfill_relation") if @cell.start_with?("backfill")
    return bulk if @cell.start_with?("bulk")
    return deletion if @cell == "field_delete_versioning_on"
    abort "unknown cell"
  end

  def backfill(relation)
    hosts = contacts; target = field("default_#{@cell}", default: 7)
    hosts.drop(@eligible).each { |host| host.typed_values.create!(field: target, value: 99) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    target.backfill_default!(relation: relation ? Contact.where(id: hosts.first(@eligible).map(&:id)) : nil)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ordinal = hosts.each_with_index.to_h { |host, i| [host.id, i] }
    values = TypedEAV::Value.where(field_id: target.id).pluck(:entity_id, :integer_value).sort_by { |id, _| ordinal.fetch(id) }.map { |id, value| [ordinal.fetch(id), value] }
    expected = (0...@hosts).map { |i| [i, i < @eligible ? 7 : 99] }
    { "kind" => "backfill", "population" => @hosts, "eligible" => @eligible, "missing_ordinals" => (0...@eligible).to_a,
      "relation" => relation, "cardinality" => values.length, "expected_cardinality" => expected.length,
      "digest" => digest(values), "expected_digest" => digest(expected), "wall_ms" => (elapsed * 1000).round(2) }
  end

  def bulk
    hosts = contacts; fields = 10.times.map { |i| field("bulk_#{@cell}_#{i}") }
    before = TypedEAV::ValueVersion.where(entity_type: "Contact").count
    initial = fields.to_h { |f| [f.name, 1] }
    hosts.each { |host| host.typed_eav_attributes = initial.map { |name, value| { name: name, value: value } }; host.save! }
    creates = TypedEAV::ValueVersion.where(entity_type: "Contact").count - before
    atomic_callbacks = TypedEAV::Versioning.atomic_callbacks_installed?
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Contact.bulk_set_typed_eav_values(hosts, fields.to_h { |f| [f.name, 2] })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    updates = TypedEAV::ValueVersion.where(entity_type: "Contact").count - before - creates
    rows = TypedEAV::Value.where(field_id: fields.map(&:id)).pluck(:entity_id, :field_id, :integer_value)
    ord = hosts.each_with_index.to_h { |h, i| [h.id, i] }; ford = fields.each_with_index.to_h { |f, i| [f.id, i] }
    triples = rows.map { |eid, fid, value| [ord.fetch(eid), ford.fetch(fid), value] }.sort
    { "kind" => "bulk", "population" => @hosts, "field_count" => 10, "cardinality" => rows.length,
      "expected_cardinality" => @hosts * 10, "digest" => digest(triples), "result_successes" => result.fetch(:successes, []).length,
      "expected_successes" => @hosts, "create_version_delta" => creates, "update_version_delta" => updates,
      "expected_create_version_delta" => @cell.end_with?("on") ? @hosts * 10 : 0, "expected_update_version_delta" => @cell.end_with?("on") ? @hosts * 10 : 0,
      "callback_installed" => atomic_callbacks, "atomic_callbacks" => atomic_callbacks,
      "callbacks" => { "create" => atomic_callbacks, "update" => atomic_callbacks },
      "config_versioning" => TypedEAV.config.versioning, "registry_versioned" => TypedEAV.registry.versioned?("Contact"), "wall_ms" => (elapsed * 1000).round(2) }
  end

  def deletion
    hosts = contacts; target = field("delete_#{@cell}")
    before_setup_versions = TypedEAV::ValueVersion.where(entity_type: "Contact").count
    hosts.each { |host| host.typed_eav_attributes = [{ name: target.name, value: 3 }]; host.save! }
    before = TypedEAV::Value.where(field_id: target.id).count
    setup_versions = TypedEAV::ValueVersion.where(entity_type: "Contact").count - before_setup_versions
    before_destroy_versions = TypedEAV::ValueVersion.where(entity_type: "Contact").count
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC); target.destroy_with_values_in_batches!(batch_size: 1_000); elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    destroy_versions = TypedEAV::ValueVersion.where(entity_type: "Contact").count - before_destroy_versions
    { "kind" => "deletion", "population" => @hosts, "before_values" => before, "after_values" => TypedEAV::Value.where(field_id: target.id).count,
      "field_rows_after" => TypedEAV::Field::Base.where(id: target.id).count, "setup_version_delta" => setup_versions,
      "destroy_version_delta" => destroy_versions, "expected_destroy_version_delta" => @hosts, "batch_size" => 1_000,
      "callback_installed" => TypedEAV::Versioning.atomic_callbacks_installed?, "wall_ms" => (elapsed * 1000).round(2) }
  end

  def digest(value) = Digest::SHA256.hexdigest(JSON.generate(value))

  def append(result)
    artifact = File.exist?(@output) ? JSON.parse(File.read(@output)) : { "schema_version" => 3, "protocol" => { "cells" => CELLS, "tier" => @tier, "baseline" => BASELINE, "source_sha256" => SOURCES.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }, "finalized" => false }, "cells" => [] }
    previous = artifact["cells"].last&.fetch("sha256", "GENESIS") || "GENESIS"
    cell = { "name" => @cell, "tier" => @tier, "measurement" => result, "complete" => true, "previous_sha256" => previous }; cell["sha256"] = Digest::SHA256.hexdigest(JSON.generate(cell)); artifact["cells"] << cell
    tmp = "#{@output}.tmp-#{Process.pid}"; File.open(tmp, "w") { |f| f.write(JSON.pretty_generate(artifact) + "\n"); f.flush; f.fsync }; File.rename(tmp, @output)
  end
end

PracticalHardeningBenchmark.run(ARGV)
