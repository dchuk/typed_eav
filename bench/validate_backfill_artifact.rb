# frozen_string_literal: true

require "json"
# rubocop:disable all

data = JSON.parse(File.read(ARGV.fetch(0)))
observations = data.fetch("observations")
abort "observation count" unless observations.length == 6
abort "sizes" unless observations.map { |row| row["name"] }.uniq.sort == %w[hosts_100 hosts_1000 hosts_10000]
observations.each do |row|
  %w[sql_statement_count rows_examined value_rows expected_rows write_statements save_callback_count version_rows transaction_count ruby_allocated_objects wall_ms throughput_hosts_per_second].each do |key|
    abort "missing #{key}" unless row[key].is_a?(Numeric)
  end
  abort "identity" unless row["semantic_identity"] && row["logical_digest"] == row["expected_logical_digest"] && row["value_rows"] == row["expected_rows"]
  abort "rss" unless row["rss_supported"] == false || (row["rss_before"].is_a?(Numeric) && row["rss_after"].is_a?(Numeric))
  abort "wal" unless row["wal_supported"] == false || row["wal_bytes"].is_a?(Numeric)
end
observations.group_by { |row| row["name"] }.each_value do |rows|
  abort "surface parity" unless rows.map { |row| row["logical_digest"] }.uniq.one?
end
puts "backfill_artifact_valid observations=#{observations.length}"
