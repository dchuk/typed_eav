# frozen_string_literal: true

require "digest"
require "json"
require "tempfile"

# rubocop:disable all -- Standalone fail-closed artifact validator.
CELLS = %w[
  backfill_default_all
  backfill_relation
  bulk_update_versioning_off
  bulk_update_versioning_on
  field_delete_versioning_on
].freeze
BASELINE = "b74482b84fc5bc75dcbb13ddd99a72c8371763aa"
SOURCES = %w[
  bench/practical_hardening_benchmark.rb
  bench/validate_practical_hardening_artifact.rb
  bench/docker/practical-hardening/run_local.sh
].freeze

def digest(value)
  Digest::SHA256.hexdigest(JSON.generate(value))
end

def source_manifest
  SOURCES.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
end

def expected_population(name, tier)
  return tier == "smoke" ? 20 : 1_000 if name.start_with?("backfill")
  return tier == "smoke" ? 20 : 100 if name.start_with?("bulk")

  tier == "smoke" ? 100 : 1_001
end

def validate_wall_time!(row)
  wall_ms = row.fetch("wall_ms")
  raise "wall time" unless wall_ms.is_a?(Numeric) && wall_ms.finite? && wall_ms >= 0
end

def validate_backfill!(name, row)
  population = row.fetch("population")
  eligible = population == 20 ? 2 : 100
  expected = (0...population).map { |ordinal| [ordinal, ordinal < eligible ? 7 : 99] }
  valid = row.fetch("kind") == "backfill" &&
          row.fetch("relation") == (name == "backfill_relation") &&
          row.fetch("eligible") == eligible &&
          row.fetch("missing_ordinals") == (0...eligible).to_a &&
          row.fetch("cardinality") == population &&
          row.fetch("expected_cardinality") == population &&
          row.fetch("digest") == digest(expected) &&
          row.fetch("expected_digest") == digest(expected)
  raise "backfill" unless valid
end

def validate_bulk!(name, row)
  population = row.fetch("population")
  value_count = population * 10
  versioned = name.end_with?("versioning_on")
  expected = (0...population).flat_map { |host| (0...10).map { |field| [host, field, 2] } }
  valid = row.fetch("kind") == "bulk" &&
          row.fetch("field_count") == 10 &&
          row.fetch("cardinality") == value_count &&
          row.fetch("expected_cardinality") == value_count &&
          row.fetch("digest") == digest(expected) &&
          row.fetch("result_successes") == population &&
          row.fetch("expected_successes") == population &&
          row.fetch("create_version_delta") == (versioned ? value_count : 0) &&
          row.fetch("expected_create_version_delta") == (versioned ? value_count : 0) &&
          row.fetch("update_version_delta") == (versioned ? value_count : 0) &&
          row.fetch("expected_update_version_delta") == (versioned ? value_count : 0) &&
          row.fetch("callback_installed") == versioned &&
          row.fetch("atomic_callbacks") == versioned &&
          row.fetch("callbacks") == { "create" => versioned, "update" => versioned } &&
          row.fetch("config_versioning") == versioned &&
          row.fetch("registry_versioned") == versioned
  raise "bulk" unless valid
end

def validate_deletion!(row)
  population = row.fetch("population")
  valid = row.fetch("kind") == "deletion" &&
          row.fetch("before_values") == population &&
          row.fetch("setup_version_delta") == population &&
          row.fetch("after_values").zero? &&
          row.fetch("field_rows_after").zero? &&
          row.fetch("destroy_version_delta") == population &&
          row.fetch("expected_destroy_version_delta") == population &&
          row.fetch("batch_size") == 1_000 &&
          row.fetch("callback_installed") == true
  raise "deletion" unless valid
end

def validate_measurement!(name, tier, row)
  raise "measurement shape" unless row.is_a?(Hash) && !row.empty?
  raise "population" unless row.fetch("population") == expected_population(name, tier)
  validate_wall_time!(row)
  return validate_backfill!(name, row) if name.start_with?("backfill")
  return validate_bulk!(name, row) if name.start_with?("bulk")

  validate_deletion!(row)
end

def validate(data, partial: false)
  protocol = data.fetch("protocol")
  raise "schema" unless data.fetch("schema_version") == 3
  raise "baseline" unless protocol.fetch("baseline") == BASELINE
  raise "protocol" unless protocol.fetch("cells") == CELLS
  tier = protocol.fetch("tier")
  raise "tier" unless %w[smoke bounded].include?(tier)
  raise "source" unless protocol.fetch("source_sha256") == source_manifest
  raise "conclusions" if data.key?("conclusions")

  cleanup = protocol.fetch("cleanup")
  expected_database = /\Atyped_eav_t167_#{tier}_[0-9]+\z/
  raise "cleanup" unless cleanup.fetch("database").match?(expected_database) && cleanup.fetch("database_absent") == true
  raise "finalization" unless protocol.fetch("finalized") == !partial
  elapsed = protocol.fetch("measured_total_seconds")
  raise "total time" unless elapsed.is_a?(Numeric) && elapsed >= 0
  raise "total time" if !partial && elapsed > (tier == "smoke" ? 120 : 300)

  cells = data.fetch("cells")
  raise "prefix" unless cells.map { |cell| cell["name"] } == CELLS.first(cells.length)
  raise "incomplete" if !partial && cells.length != CELLS.length
  previous = "GENESIS"
  cells.each do |cell|
    raise "cell shape" unless cell.keys.sort == %w[complete measurement name previous_sha256 sha256 tier]
    raise "cell" unless cell.fetch("tier") == tier && cell.fetch("complete") == true
    raise "chain" unless cell.fetch("previous_sha256") == previous
    unhashed = cell.dup
    sha = unhashed.delete("sha256")
    raise "hash" unless digest(unhashed) == sha
    validate_measurement!(cell.fetch("name"), tier, cell.fetch("measurement"))
    previous = sha
  end
  true
end

def validate_file(path, expected_sha:, partial: false)
  raise "external sha required" if expected_sha.nil? || expected_sha.empty?
  raise "external sha" unless Digest::SHA256.file(path).hexdigest == expected_sha
  validate(JSON.parse(File.read(path)), partial: partial)
end

def smoke_rows
  backfill = (0...20).map { |ordinal| [ordinal, ordinal < 2 ? 7 : 99] }
  bulk = (0...20).flat_map { |host| (0...10).map { |field| [host, field, 2] } }
  [
    { "kind" => "backfill", "population" => 20, "eligible" => 2, "missing_ordinals" => [0, 1], "relation" => false, "cardinality" => 20, "expected_cardinality" => 20, "digest" => digest(backfill), "expected_digest" => digest(backfill), "wall_ms" => 1.0 },
    { "kind" => "backfill", "population" => 20, "eligible" => 2, "missing_ordinals" => [0, 1], "relation" => true, "cardinality" => 20, "expected_cardinality" => 20, "digest" => digest(backfill), "expected_digest" => digest(backfill), "wall_ms" => 1.0 },
    { "kind" => "bulk", "population" => 20, "field_count" => 10, "cardinality" => 200, "expected_cardinality" => 200, "digest" => digest(bulk), "result_successes" => 20, "expected_successes" => 20, "create_version_delta" => 0, "expected_create_version_delta" => 0, "update_version_delta" => 0, "expected_update_version_delta" => 0, "callback_installed" => false, "atomic_callbacks" => false, "callbacks" => { "create" => false, "update" => false }, "config_versioning" => false, "registry_versioned" => false, "wall_ms" => 1.0 },
    { "kind" => "bulk", "population" => 20, "field_count" => 10, "cardinality" => 200, "expected_cardinality" => 200, "digest" => digest(bulk), "result_successes" => 20, "expected_successes" => 20, "create_version_delta" => 200, "expected_create_version_delta" => 200, "update_version_delta" => 200, "expected_update_version_delta" => 200, "callback_installed" => true, "atomic_callbacks" => true, "callbacks" => { "create" => true, "update" => true }, "config_versioning" => true, "registry_versioned" => true, "wall_ms" => 1.0 },
    { "kind" => "deletion", "population" => 100, "before_values" => 100, "after_values" => 0, "field_rows_after" => 0, "setup_version_delta" => 100, "destroy_version_delta" => 100, "expected_destroy_version_delta" => 100, "batch_size" => 1_000, "callback_installed" => true, "wall_ms" => 1.0 },
  ]
end

def rehash!(data)
  data.fetch("cells").each_with_index do |cell, index|
    cell.delete("sha256")
    cell["previous_sha256"] = index.zero? ? "GENESIS" : data["cells"][index - 1].fetch("sha256")
    cell["sha256"] = digest(cell)
  end
end

def assert_rejected!(family, expected_error)
  yield
rescue StandardError => error
  raise "#{family}: expected #{expected_error}, got #{error.message}" unless error.message == expected_error
else
  raise "#{family}: mutation accepted"
end

def self_test
  data = {
    "schema_version" => 3,
    "protocol" => { "cells" => CELLS, "tier" => "smoke", "baseline" => BASELINE, "source_sha256" => source_manifest, "cleanup" => { "database" => "typed_eav_t167_smoke_123", "database_absent" => true }, "finalized" => true, "measured_total_seconds" => 1 },
    "cells" => CELLS.zip(smoke_rows).map { |name, measurement| { "name" => name, "tier" => "smoke", "measurement" => measurement, "complete" => true, "previous_sha256" => "GENESIS" } },
  }
  rehash!(data)
  validate(data)

  changed = Marshal.load(Marshal.dump(data)); changed["cells"][1]["name"] = CELLS[0]
  assert_rejected!("prefix/hash", "prefix") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["cells"][0]["sha256"] = "bad"
  assert_rejected!("prefix/hash", "hash") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["cells"][0]["measurement"]["relation"] = true; rehash!(changed)
  assert_rejected!("backfill", "backfill") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["cells"][3]["measurement"]["update_version_delta"] = 0; rehash!(changed)
  assert_rejected!("bulk", "bulk") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["cells"][4]["measurement"]["after_values"] = 1; rehash!(changed)
  assert_rejected!("deletion", "deletion") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["protocol"]["finalized"] = false
  assert_rejected!("finalization/provenance/SHA", "finalization") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["protocol"]["source_sha256"][SOURCES.first] = "bad"
  assert_rejected!("finalization/provenance/SHA", "source") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["protocol"]["cleanup"]["database_absent"] = false
  assert_rejected!("finalization/provenance/SHA", "cleanup") { validate(changed) }
  changed = Marshal.load(Marshal.dump(data)); changed["protocol"]["cleanup"]["database"] = "typed_eav_t167_bounded_123"
  assert_rejected!("finalization/provenance/SHA", "cleanup") { validate(changed) }
  Tempfile.create("t167-validator") do |file|
    file.write(JSON.generate(data)); file.flush
    assert_rejected!("finalization/provenance/SHA", "external sha") { validate_file(file.path, expected_sha: "bad") }
    assert_rejected!("finalization/provenance/SHA", "external sha required") { validate_file(file.path, expected_sha: nil) }
  end
  puts "validator self-test passed: five named mutation families"
end

if ARGV.first == "--self-test"
  self_test
  exit
end

path = ARGV.shift or abort "artifact path required"
partial = ARGV.delete("--partial")
sha_index = ARGV.index("--expected-sha")
expected_sha = sha_index ? ARGV[sha_index + 1] : nil
validate_file(path, expected_sha: expected_sha, partial: !!partial)
puts "validated #{JSON.parse(File.read(path)).fetch('cells').length} cells"
# rubocop:enable all
