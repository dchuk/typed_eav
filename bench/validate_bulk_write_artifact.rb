# frozen_string_literal: true
# rubocop:disable all

require "json"

data = JSON.parse(File.read(ARGV.fetch(0)))
abort "schema" unless data["schema_version"] == 2
observations = data.fetch("observations")
abort "observation count" unless observations.length == 9 * data.fetch("protocol").fetch("sizes").length
abort "reset protocol" unless data.fetch("protocol").fetch("independent_observation_reset")
abort "reduced acknowledgement" unless data.fetch("protocol").fetch("reduced_semantics_acknowledged")
observations.each do |row|
  %w[sql_statement_count savepoint_count begin_count commit_count rollback_count host_write_statements typed_value_write_statements version_statements version_rows value_rows value_checksum wall_ms ruby_allocated_objects gc_count_delta gc_time_ms_delta save_callback_count].each { |key| abort "missing #{key}" unless row[key].is_a?(Numeric) }
  abort "rss" unless row["rss_supported"] == false || (row["rss_before"].is_a?(Numeric) && row["rss_after"].is_a?(Numeric))
  abort "wal" unless row["wal_supported"] == false || row["wal_bytes"].is_a?(Numeric)
  abort "identity" unless row["semantic_identity"] && row["logical_digest"].is_a?(String) && row["logical_digest"] == row["expected_logical_digest"] && row["value_rows"] == row["expected_rows"] && row["value_checksum"] == row["expected_checksum"]
  abort "versions" unless row["version_rows"] == row["expected_version_rows"] && row["version_statements"] >= row["version_rows"]
  if row["surface"] == "fast"
    abort "fast result" unless row["returned_rows"] == row["expected_rows"] && row["returned_successes"].nil? && row["returned_errors"].nil? && row["save_callback_count"] == 0 && row["version_rows"] == 0
  else
    abort "semantic result" unless row["returned_successes"] == row["hosts"] && row["returned_errors"] == 0
  end
end
observations.group_by { |row| [row["name"], row["operation"], row["versioning"]] }.each_value do |rows|
  semantic = rows.find { |row| row["surface"] == "semantic" }
  chunks = rows.find { |row| row["surface"] == "chunks" }
  abort "semantic/chunk parity" unless semantic && chunks && %w[value_rows value_checksum logical_digest expected_logical_digest version_rows expected_version_rows semantic_identity].all? { |key| semantic[key] == chunks[key] }
  fast = rows.find { |row| row["surface"] == "fast" }
  abort "surface digest parity" unless fast && fast["logical_digest"] == semantic["logical_digest"]
end
puts "bulk_write_artifact_valid observations=#{observations.length}"
# rubocop:enable all
