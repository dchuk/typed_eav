# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/StringLiteralsInInterpolation -- standalone evidence validator keeps protocol assertions together.
require "base64"
require "digest"
require "json"
require "zlib"

class MultiFilterCorrectiveArtifactValidator
  SCENARIOS = %w[high_10 high_20 low_10 low_20 mixed_10 mixed_20 skewed_10 skewed_20].freeze
  STRATEGIES = %w[current_chained_in intersect correlated_exists grouped_having].freeze
  BUFFER_KEYS = [
    "Shared Hit Blocks", "Shared Read Blocks", "Shared Dirtied Blocks", "Shared Written Blocks",
    "Local Hit Blocks", "Local Read Blocks", "Local Dirtied Blocks", "Local Written Blocks",
    "Temp Read Blocks", "Temp Written Blocks"
  ].freeze

  def initialize(path)
    @path = path
    @artifact = JSON.parse(File.read(path), max_nesting: false)
  end

  def call
    validate_top_level
    validate_catalog
    validate_smoke("semantic_smoke", 98, 25)
    validate_smoke("corrective_smoke", 32, 8)
    validate_trials
    validate_decision
    validate_remote_safety if @artifact.key?("remote_safety")
    puts "corrective_artifact_valid attempts=960 oracles=96 summaries=24 completed_plans=#{@completed_plans} censored=#{@censored_attempts}"
  rescue KeyError, JSON::ParserError, Zlib::Error, ArgumentError => e
    abort "corrective artifact rejected: #{e.class}: #{e.message}"
  end

  private

  def assert(condition, message)
    abort "corrective artifact rejected: #{message}" unless condition
  end

  def validate_top_level
    assert(@artifact.dig("environment", "tier") == "representative", "tier must be representative")
    assert(@artifact.dig("environment", "matrix") == "corrective", "matrix must be corrective")
    assert(@artifact.dig("dataset", "seed") == 4502, "seed must be 4502")
    assert(@artifact.dig("protocol", "strategies") == STRATEGIES, "strategy set/order changed")
    assert(@artifact.dig("protocol", "trials") == 3, "trial count changed")
    assert(@artifact.dig("protocol", "repetitions_per_strategy_scenario_trial") == 10, "repetition count changed")
    assert(@artifact.dig("protocol", "measured_statement_timeout_ms") == 1_000, "measured timeout changed")
    assert(@artifact.dig("protocol", "semantic_oracle_timeout_ms") == 5_000, "oracle timeout changed")
    assert(@artifact.dig("validation", "accepted"), "harness validation did not accept artifact")
  end

  def validate_catalog
    catalog = @artifact.fetch("scenario_catalog")
    assert(catalog.map { |scenario| scenario.fetch("name") }.sort == SCENARIOS.sort, "corrective scenario matrix changed")
    catalog.each do |scenario|
      expected = scenario.fetch("name").end_with?("_10") ? 10 : 20
      filters = scenario.fetch("filters")
      names = filters.map { |filter| filter.fetch("name") }
      ids = filters.flat_map { |filter| filter.fetch("field_ids") }
      assert(scenario.fetch("filter_count") == expected && filters.length == expected, "#{scenario.fetch('name')} predicate count differs")
      assert(names.uniq.length == expected, "#{scenario.fetch('name')} repeats a field name")
      assert(filters.all? { |filter| filter.fetch("field_ids").length == 1 }, "#{scenario.fetch('name')} does not resolve one definition per predicate")
      assert(ids.uniq.length == expected, "#{scenario.fetch('name')} repeats a field definition")
    end
  end

  def validate_smoke(key, oracle_count, summary_count)
    smoke = @artifact.fetch(key)
    assert(smoke.fetch("seed") == 4502 && smoke.fetch("fully_equal"), "#{key} is not fully equal")
    assert(smoke.fetch("oracle_count") == oracle_count && smoke.fetch("oracles").length == oracle_count, "#{key} oracle count differs")
    assert(smoke.fetch("scenario_summary_count") == summary_count && smoke.fetch("scenario_summaries").length == summary_count, "#{key} summary count differs")
    smoke.fetch("oracles").each do |row|
      oracle = row.fetch("oracle")
      assert(!row.fetch("resolved_filter_sha256").empty?, "#{key} resolved-filter hash missing")
      assert(oracle.fetch("outcome") == "completed" && oracle.fetch("completed"), "#{key} oracle is incomplete")
      assert(!oracle.fetch("count").nil? && !oracle.fetch("checksum").nil?, "#{key} identity missing")
    end
  end

  def validate_trials
    trials = @artifact.fetch("trials")
    assert(trials.length == 3, "representative trials differ")
    @completed_plans = 0
    @censored_attempts = 0
    oracle_count = 0
    summary_count = 0
    attempt_count = 0
    trials.each_with_index do |trial, trial_index|
      assert(trial.fetch("trial") == trial_index + 1, "trial numbering differs")
      assert(trial.fetch("strategy_order") == STRATEGIES.rotate(trial_index), "strategy rotation differs")
      scenarios = trial.fetch("scenarios")
      assert(scenarios.map { |scenario| scenario.fetch("name") }.sort == SCENARIOS.sort, "trial scenario matrix differs")
      scenarios.each do |scenario|
        summary_count += 1
        validate_summary(scenario)
        strategies = scenario.fetch("strategies")
        assert(strategies.keys == trial.fetch("strategy_order"), "strategy execution order differs")
        strategies.each_value do |evidence|
          assert(evidence.fetch("eligible"), "corrective strategy unexpectedly ineligible")
          attempts = evidence.fetch("repetitions")
          assert(attempts.length == 10, "attempt group is incomplete")
          attempts.each_with_index { |attempt, index| validate_attempt(attempt, index + 1, evidence) }
          validate_oracle(evidence.fetch("result"))
          attempt_count += attempts.length
          oracle_count += 1
        end
      end
    end
    assert(attempt_count == 960, "attempt count is #{attempt_count}, expected 960")
    assert(oracle_count == 96, "oracle count is #{oracle_count}, expected 96")
    assert(summary_count == 24, "summary count is #{summary_count}, expected 24")
  end

  def validate_summary(scenario)
    summary = scenario.fetch("semantic_summary")
    outcomes = scenario.fetch("strategies").values.map { |evidence| evidence.fetch("result") }
    completed = outcomes.select { |oracle| oracle.fetch("outcome") == "completed" }
    assert(completed.map { |oracle| oracle.slice("count", "checksum") }.uniq.length <= 1, "completed oracle identity mismatch")
    expected = outcomes.any? { |oracle| oracle.fetch("outcome") == "timeout" } ? "unproved_timeout" : "proven_equal"
    assert(summary.fetch("classification") == expected, "semantic summary classification differs")
    assert(summary.fetch("equivalence_proven") == (expected == "proven_equal"), "semantic equivalence flag differs")
  end

  def validate_attempt(attempt, sequence, evidence)
    assert(attempt.fetch("group_sequence") == sequence, "attempt sequence differs")
    if attempt.fetch("completed")
      assert(!attempt.fetch("censored"), "completed attempt marked censored")
      validate_completed_plan(attempt)
    else
      @censored_attempts += 1
      assert(attempt.fetch("censored"), "incomplete attempt not marked censored")
      assert(attempt.fetch("sqlstate") == "57014" && attempt.fetch("censor_lower_bound_ms") == 1_000, "censor shape differs")
      assert(attempt["buffers"].nil?, "censored attempt fabricates ANALYZE buffers")
      fallback = evidence.fetch("fallback_plan")
      assert(attempt.fetch("fallback_plan_sha256") == fallback.fetch("sha256"), "fallback reference differs")
      validate_lossless_document(fallback.fetch("plan_zlib_base64"), fallback.fetch("sha256"))
    end
  end

  def validate_completed_plan(attempt)
    raw, document = validate_lossless_document(attempt.fetch("plan_zlib_base64"), attempt.fetch("plan_sha256"))
    assert(Digest::SHA256.hexdigest(raw) == attempt.fetch("plan_sha256"), "completed plan hash differs")
    expected_buffers = BUFFER_KEYS.to_h { |key| [key.downcase.tr(" ", "_"), document.fetch("Plan").fetch(key, 0)] }
    assert(attempt.fetch("buffers") == expected_buffers, "derived root-plan buffers differ")
    @completed_plans += 1
  end

  def validate_lossless_document(encoded, expected_hash)
    raw = Zlib::Inflate.inflate(Base64.strict_decode64(encoded))
    assert(Digest::SHA256.hexdigest(raw) == expected_hash, "lossless plan hash differs")
    [raw, JSON.parse(raw, max_nesting: false)]
  end

  def validate_oracle(oracle)
    assert(oracle.fetch("group_sequence") == 11, "oracle did not follow ten attempts")
    assert(oracle.fetch("statement_timeout_ms") == 5_000, "oracle timeout differs")
    assert(Digest::SHA256.hexdigest(oracle.fetch("identity_sql")) == oracle.fetch("identity_sql_sha256"), "oracle SQL hash differs")
    if oracle.fetch("outcome") == "completed"
      assert(oracle.fetch("completed") && oracle["sqlstate"].nil? && !oracle["count"].nil? && !oracle["checksum"].nil?, "completed oracle shape differs")
    else
      assert(oracle.fetch("outcome") == "timeout", "non-timeout oracle error retained")
      assert(!oracle.fetch("completed") && oracle.fetch("sqlstate") == "57014" && oracle.fetch("timeout_lower_bound_ms") == 5_000, "oracle timeout shape differs")
      assert(oracle["count"].nil? && oracle["checksum"].nil?, "timed-out oracle contains identity")
    end
  end

  def validate_decision
    decision = @artifact.fetch("replacement_decision")
    assert(!decision.fetch("production_replacement_eligible"), "artifact claims production eligibility")
    assert(!decision.fetch("production_replacement_authorized"), "artifact claims production authorization")
    assert(decision.fetch("retain_current_sql"), "artifact does not retain current SQL")
  end

  def validate_remote_safety
    safety = @artifact.fetch("remote_safety")
    assert(safety.fetch("task_label") == "T074", "remote task ownership differs")
    assert(safety.fetch("runner_status").zero?, "remote runner failed")
    assert(safety.fetch("internal_network") && safety.fetch("published_ports").empty?, "remote network isolation differs")
    assert(!safety.fetch("host_network") && !safety.fetch("docker_socket_mounted") && !safety.fetch("privileged") && !safety.fetch("media_binds") && !safety.fetch("compose_used"), "remote isolation contract differs")
    assert(safety.fetch("restart_policy") == "no", "restart policy differs")
    postgres_caps_valid = safety.dig("postgres_caps", "cpus") <= 2 && safety.dig("postgres_caps", "memory_bytes") <= 8 * (1024**3)
    runner_caps_valid = safety.dig("runner_caps", "cpus") <= 1.5 && safety.dig("runner_caps", "memory_bytes") <= 3 * (1024**3)
    assert(postgres_caps_valid, "PostgreSQL caps exceed T062")
    assert(runner_caps_valid, "runner caps exceed T062")
    assert(safety.dig("existing_container_invariant", "passed"), "existing-container invariant failed")
    assert(safety.dig("cancellation_drill", "passed") && safety.dig("cancellation_drill", "export_before_drop"), "cancellation drill failed")
    assert(safety.dig("progress_checkpoints", "count") == 96, "representative checkpoint count differs")
    assert(safety.dig("finalizer", "export_before_cleanup") && safety.fetch("post_cleanup_verified"), "export/cleanup ordering is unproved")
    lifecycle = safety.fetch("image_lifecycle")
    assert(lifecycle.fetch("pull_count") <= 1 && lifecycle.fetch("repo_digest").start_with?("ruby@sha256:"), "Ruby image admission differs")
    assert(lifecycle.fetch("ruby_version") == "3.4.4" && !lifecycle.fetch("build_pull") && !lifecycle.fetch("prune_used"), "Ruby image build/lifecycle differs")
    assert(lifecycle.fetch("post_cleanup_verified"), "Ruby image cleanup is unproved")
    return if lifecycle.fetch("initial_exact_tag_present")

    assert(!lifecycle.fetch("post_cleanup_exact_tag_present"), "introduced Ruby tag remains")
    assert(!lifecycle.fetch("image_id_introduced") || !lifecycle.fetch("post_cleanup_image_id_present"), "introduced Ruby image ID remains")
  end
end

abort "usage: ruby #{File.basename($PROGRAM_NAME)} ARTIFACT.json" unless ARGV.length == 1
MultiFilterCorrectiveArtifactValidator.new(ARGV.fetch(0)).call
# rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/StringLiteralsInInterpolation
