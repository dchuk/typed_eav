# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Performance/CollectionLiteralInLoop
require "json"

class BulkReadArtifactValidator
  MATRIX = { "records_100_scopes_1" => [100, 1], "records_1000_scopes_1" => [1_000, 1], "records_1000_scopes_100" => [1_000, 100], "records_1000_scopes_1000" => [1_000, 1_000] }.freeze

  def initialize(path) = @data = JSON.parse(File.read(path), max_nesting: false)

  def assert(value, message)
    abort("bulk-read artifact rejected: #{message}") unless value
  end

  def call
    assert(@data["schema_version"] == 1, "schema")
    env = @data.fetch("environment")
    assert(env["tier"] == "representative" && env["seed"] == 5_501 && env["ruby_version"] == "3.4.4" && env["postgresql_version_num"].between?(170_000, 179_999), "environment")
    assert(env.dig("cleanup", "dropped") && env.dig("cleanup", "prefix_validated") && !env.dig("cleanup", "created"), "database cleanup")
    smoke = @data.fetch("semantic_smoke")
    assert(smoke["passed"] && smoke["identity"] == smoke["expected_identity"] && smoke.fetch("controls").values.all?, "semantic smoke")
    protocol = @data.fetch("protocol")
    assert(protocol["field_count"] == 20 && protocol["rotations"] == 3 && protocol["measured_repetitions_per_workload_trial"] == 10 && protocol["query_cache"].include?("uncached"), "protocol")
    @data.fetch("datasets").each do |set|
      records, scopes = MATRIX.fetch(set.fetch("name"))
      assert(set["records"] == records && set["scopes"] == scopes && set["value_rows"] == records * 20 && set["field_definitions"] == 20 + (scopes * 40), "dataset #{set["name"]}")
    end
    observations = []
    warmups = []
    @data.fetch("trials").each_with_index do |trial, index|
      assert(trial["trial"] == index + 1 && trial["workload_order"] == MATRIX.keys.rotate(index), "rotation")
      trial.fetch("workloads").each do |workload|
        warmups << workload.fetch("warmup")
        assert(workload.fetch("observations").length == 10, "repetitions")
        observations.concat(workload.fetch("observations"))
      end
    end
    assert(observations.length == 120 && warmups.length == 12, "observation counts")
    (observations + warmups).each do |row|
      assert(row["outcome"] == "completed" && row["semantic_equal"] && row["identity"] == row["expected_identity"], "observation identity")
      assert(row["result_value_count"] == row["result_record_count"] * 20, "result shape")
      sql = row.fetch("sql")
      assert(sql.length == row["sql_statement_count"] && sql.sum { |q| q.fetch("row_count") } == row["sql_returned_rows"], "SQL counts")
      assert(sql.all? { |q| q["sql"].is_a?(String) && q["binds"].is_a?(Array) && q["row_count"].is_a?(Integer) }, "SQL evidence")
      %w[wall_ms active_record_instantiations ruby_allocated_objects rss_bytes_before rss_bytes_after gc_count_delta gc_time_ms_delta].each { |key| assert(row[key].is_a?(Numeric) && row[key] >= 0, key) }
      assert(row["objectspace_bytes_delta"].is_a?(Numeric), "ObjectSpace")
    end
    validation = @data.fetch("validation")
    assert(validation["accepted"] && validation["notification_row_counts_complete"] && validation["all_semantically_equal"], "harness validation")
    validate_safety(@data.fetch("remote_safety"))
    puts "bulk_read_artifact_valid trials=3 warmups=12 observations=120 sql=#{(observations + warmups).sum { |o| o["sql_statement_count"] }}"
  end

  def validate_safety(safety)
    assert(safety["task_label"] == "T086" && safety["runner_status"].zero?, "remote status")
    assert(safety["work_deadline_seconds"] == 3600 && safety["hard_timeout_seconds"] == 4200 && safety["elapsed_seconds"] < 4200, "deadlines")
    assert(safety["internal_network"] && safety["published_ports"].empty? && !safety["host_network"] && !safety["privileged"] && !safety["compose_used"] && !safety["docker_socket_mounted"] && !safety["media_binds"] && safety["restart_policy"] == "no", "isolation")
    assert(safety.dig("postgres_caps", "cpus") <= 2 && safety.dig("postgres_caps", "memory_bytes") <= 8 * (1024**3) && safety.dig("runner_caps", "cpus") <= 1.5 && safety.dig("runner_caps", "memory_bytes") <= 3 * (1024**3), "caps")
    assert(safety.dig("existing_container_invariant", "passed") && safety.dig("existing_container_invariant", "before_sha256") == safety.dig("existing_container_invariant", "after_sha256"), "container invariant")
    assert(safety.dig("finalizer", "states") == %w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED AUDITED] && safety.dig("finalizer", "export_before_cleanup") && safety.dig("finalizer", "audited_after_transfer") && safety["post_cleanup_verified"], "finalization")
    assert(safety.dig("writable_paths", "paths") == %w[/output /work/spec/dummy/tmp /work/spec/dummy/log /tmp] && safety.dig("writable_paths", "root_read_only"), "writable paths")
    assert(safety.dig("drill", "passed") && safety.dig("drill", "export_before_cleanup") && safety.dig("drill", "live_session") && safety.dig("drill", "sessions_terminated") && safety.dig("drill", "stage_count") == 7, "drill")
    assert(safety.dig("anonymous_pressure", "samples").positive? && safety.dig("anonymous_pressure", "sha256").match?(/\A[0-9a-f]{64}\z/) && !safety.dig("anonymous_pressure", "raw_identifiers_retained"), "pressure telemetry")
    assert(safety["source_manifest_sha256"].match?(/\A[0-9a-f]{64}\z/), "source manifest")
    image = safety.fetch("image_lifecycle")
    assert(image["pull_count"] <= 1 && image["repo_digest"].start_with?("ruby@sha256:") && image["ruby_version"] == "3.4.4" && !image["build_pull"] && !image["prune_used"] && image["post_cleanup_verified"], "image lifecycle")
    assert(safety.dig("contract", "seven_states") && safety.dig("contract", "accepted_rejected_exclusive") && safety.dig("contract", "cycle_detection"), "contract")
  end
end

abort "usage: validator ARTIFACT" unless ARGV.length == 1
BulkReadArtifactValidator.new(ARGV.fetch(0)).call
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Performance/CollectionLiteralInLoop
