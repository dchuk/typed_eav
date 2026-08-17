# frozen_string_literal: true

# This validator deliberately does not load the benchmark implementation.  It
# validates only the artifact envelope and the evidence relationships that a
# runner is allowed to publish.  A benchmark self-attestation is never enough
# to pass a gate: counts, sets, digests, rotations, and cross-adapter rows are
# derived again from the raw artifact here.
# The checker intentionally keeps all contract assertions in one bounded file;
# these complexity exceptions make the standalone executable lint-clean while
# preserving its fail-closed validation flow.
# rubocop:disable Layout/LineLength
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
# rubocop:disable Performance/CollectionLiteralInLoop
# rubocop:disable Style/HashExcept, Style/HashSlice
# rubocop:disable Rails/IndexBy, Rails/IndexWith, Style/ReduceToHash

require "digest"
require "json"

module StorageTournamentValidator
  SEED = 12_101
  ADAPTERS = %w[typed_eav jsonb per_type_eav sql].freeze
  SIGNATURE_KEYS = %w[count sum_a xor_a sum_b xor_b sha256].freeze
  ID_SIGNATURE_KEYS = %w[count sum xor sha256].freeze
  VECTOR_ORDINALS = [0, 1, 2, 3, 10, 11, 16, 17, 99].freeze
  STRIDE_VECTORS = {
    "100" => { "delta" => 101, "modulo_10" => 1 },
    "300" => { "delta" => 305, "modulo_10" => 5 },
    "10000" => { "delta" => 10_202, "modulo_10" => 2 },
    "30000" => { "delta" => 30_606, "modulo_10" => 6 },
  }.freeze
  PROFILES = {
    "L100" => {
      "hosts" => 100_000, "definitions" => 10, "values" => 5, "scopes" => 1,
      "workloads" => %w[eq_uniform eq_zipf explicit_null missing filters_3 hydrate_1k bulk_1k]
    },
    "A100" => {
      "hosts" => 100_000, "definitions" => 50, "values" => 20, "scopes" => 100,
      "workloads" => %w[eq_uniform eq_zipf int_range date_range sort_limit prefix contains array_contains explicit_null missing include_missing filters_3 filters_10 filters_20 hydrate_one hydrate_1k cross_scope insert_one update_one create_20 bulk_1k bulk_100k backfill deletion versioned_mutation]
    },
    "H100" => {
      "hosts" => 100_000, "definitions" => 200, "values" => 100, "scopes" => 10_000,
      "workloads" => %w[eq_uniform contains array_contains missing filters_20 hydrate_1k cross_scope bulk_100k deletion]
    },
    "A1M" => {
      "hosts" => 1_000_000, "definitions" => 50, "values" => 20, "scopes" => 100,
      "workloads" => %w[eq_uniform int_range date_range sort_limit prefix contains array_contains explicit_null missing filters_20 hydrate_1k cross_scope bulk_100k]
    },
  }.freeze
  PUBLIC_QUERY_NAMES = %w[eq_uniform eq_zipf integer_range date_range prefix contains array_any explicit_null
                          include_missing filters_3 filters_10 filters_20 cross_scope_admin].freeze
  COMMON_QUERY_NAMES = PUBLIC_QUERY_NAMES.freeze
  SELECTIVE_PUBLIC_QUERIES = %w[eq_uniform integer_range date_range prefix contains array_any explicit_null filters_3
                                filters_10 filters_20].freeze
  COMMON_WRITE_WORKLOADS = %w[single_insert single_update create_20 bulk_1k bulk_100k physical_field_delete].freeze
  FACTOR_SURFACES = %w[public_typed_eav common_queries common_writes].freeze
  FACTOR_LIMITATIONS = {
    "L100" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
    "H100" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
    "A1M" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
  }.freeze
  FACTOR_OBSERVATIONS = {
    "L100" => %w[load eq_uniform eq_zipf explicit_null missing filters_3 hydrate_1k bulk_1k],
    "H100" => %w[load eq_uniform contains array_contains missing filters_20 hydrate_1k cross_scope bulk_100k deletion],
    "A1M" => %w[load eq_uniform int_range date_range sort_limit prefix contains array_contains explicit_null missing filters_20 hydrate_1k cross_scope bulk_100k],
  }.freeze
  FACTOR_UNSUPPORTED_CELLS = %w[missing sort_limit].freeze
  FACTOR_LOAD_CELLS = %w[load].freeze
  FACTOR_WRITE_CELLS = %w[bulk_1k bulk_100k deletion].freeze
  FACTOR_QUERY_CELLS = %w[eq_uniform eq_zipf explicit_null filters_3 hydrate_1k contains array_contains filters_20 cross_scope int_range date_range prefix].freeze
  FACTOR_QUERY_SOURCE = {
    "eq_uniform" => "eq_uniform", "eq_zipf" => "eq_zipf", "explicit_null" => "explicit_null",
    "filters_3" => "filters_3", "hydrate_1k" => "eq_uniform", "contains" => "contains",
    "array_contains" => "array_any", "filters_20" => "filters_20", "cross_scope" => "cross_scope_admin",
    "int_range" => "integer_range", "date_range" => "date_range", "prefix" => "prefix"
  }.freeze
  FACTOR_UNSUPPORTED_KEYS = %w[reason status workload].freeze
  FACTOR_QUERY_KEYS = %w[applicable_adapters identities metrics oracle_identity plans status workload].freeze
  FACTOR_LOAD_KEYS = %w[applicable_adapters metrics oracle_semantic_digest semantic_digests status workload].freeze
  FACTOR_WRITE_KEYS = %w[applicable_adapters metrics oracle_post_state_digest oracle_semantic_digest post_state_digests semantic_digests status workload].freeze
  FACTOR_METRIC_KEYS = %w[execution_ms planning_ms rows wal_bytes].freeze
  FACTOR_TIME_TOLERANCE = 1e-9
  CREATE_20_ROWS_PER_TYPE = [6, 2, 2, 2, 2, 2, 4].freeze
  PLAN_NODE_METRICS = [
    "Actual Rows", "Actual Loops", "Actual Total Time", "Shared Hit Blocks", "Shared Read Blocks",
    "Shared Dirtied Blocks", "Shared Written Blocks", "WAL Records", "WAL Bytes"
  ].freeze
  WRITE_ROTATIONS = [ADAPTERS, ADAPTERS.rotate(1), ADAPTERS.rotate(2)].freeze
  OPERATIONAL_STATUSES = %w[deferred not_applicable].freeze
  MAX_ARTIFACT_BYTES = 50 * 1024 * 1024
  REPRESENTATIVE_ENVIRONMENT_KEYS = %w[admission artifact_sha256 database export mode no_impact postgresql resource_limits ruby telemetry].freeze
  REPRESENTATIVE_ADMISSION_KEYS = %w[docker_free_bytes existing_container_invariant memory_available_bytes
                                     projected_export_bytes required_docker_free_bytes samples smoke_projected_peak_bytes status].freeze
  REPRESENTATIVE_INVARIANT_KEYS = %w[after_sha256 before_sha256 passed].freeze
  REPRESENTATIVE_RESOURCE_KEYS = %w[cpus memory_bytes].freeze
  REPRESENTATIVE_LIMIT_KEYS = %w[headroom host_capacity postgres runner total_deadline_seconds work_deadline_seconds].freeze
  REPRESENTATIVE_TELEMETRY_KEYS = %w[explain_analyze_buffers_wal_settings iowait_breaches live_through_finish
                                     monitor_started_before_work monitor_stopped_after_finish pressure_breaches pressure_monitor samples].freeze
  REPRESENTATIVE_PRESSURE_KEYS = %w[monitor_pass samples sha256 status].freeze
  REPRESENTATIVE_NO_IMPACT_KEYS = %w[existing_container_invariant media_stack_untouched passed].freeze
  REPRESENTATIVE_EXPORT_KEYS = %w[before_cleanup bytes sha256 verified].freeze
  REPRESENTATIVE_CLEANUP_KEYS = %w[exact export_before_cleanup owned_resources_zero post_cleanup_verified remaining_task_relations].freeze
  VALIDATION_ERRORS = [Errno::ENOENT, JSON::NestingError, JSON::ParserError, KeyError, TypeError].freeze
  RELATION_NAMES = {
    "typed_eav" => %w[typed_eav_fields typed_eav_values],
    "jsonb" => %w[t121_json],
    "per_type_eav" => %w[t121_type_definitions t121_type_integer t121_type_decimal t121_type_boolean
                         t121_type_date t121_type_datetime t121_type_text t121_type_json],
    "sql" => %w[t121_sql],
  }.freeze
  INDEX_NAMES = {
    "typed_eav" => %w[idx_te_fields_lookup idx_te_fields_uniq_global idx_te_fields_uniq_scoped_full
                      idx_te_fields_uniq_scoped_only index_typed_eav_fields_on_entity_type
                      index_typed_eav_fields_on_section_id typed_eav_fields_pkey idx_te_values_entity_field
                      idx_te_values_field_bool_present idx_te_values_field_date_present idx_te_values_field_dec_present
                      idx_te_values_field_dt_present idx_te_values_field_int_present idx_te_values_field_str_present
                      idx_te_values_json_gin index_typed_eav_values_on_entity index_typed_eav_values_on_field_id
                      typed_eav_values_pkey],
    "jsonb" => %w[t121_json_array_hot t121_json_date_iso_hot t121_json_document_gin t121_json_integer_hot
                  t121_json_pkey t121_json_sort_hot t121_json_text_prefix t121_json_zipf_hot],
    "per_type_eav" => %w[t121_type_definitions_lookup t121_type_definitions_pkey
                         t121_type_boolean_hydrate t121_type_boolean_lookup t121_type_boolean_pkey
                         t121_type_date_hydrate t121_type_date_lookup t121_type_date_pkey
                         t121_type_datetime_hydrate t121_type_datetime_lookup t121_type_datetime_pkey
                         t121_type_decimal_hydrate t121_type_decimal_lookup t121_type_decimal_pkey
                         t121_type_integer_hydrate t121_type_integer_lookup t121_type_integer_pkey
                         t121_type_json_hydrate t121_type_json_lookup t121_type_json_pkey t121_type_json_value_gin
                         t121_type_text_hydrate t121_type_text_lookup t121_type_text_pkey],
    "sql" => %w[t121_sql_array_hot t121_sql_date_hot t121_sql_integer_hot t121_sql_pkey t121_sql_sort_hot
                t121_sql_text_prefix t121_sql_zipf_hot],
  }.freeze

  class InvalidArtifact < StandardError; end

  class Checker
    def initialize(artifact, path:, mode: nil, expected_sha: nil)
      @artifact = artifact
      @path = path
      @mode = mode || artifact.dig("environment", "mode")
      @representative = @mode == "representative"
      # A self-reported digest cannot authenticate the file that contains it.
      # Only a caller-supplied pin is authoritative; representative artifacts
      # still carry an artifact_sha256 field as export metadata, but it is not
      # silently promoted to a trust anchor.
      @expected_sha = expected_sha
      @actual_sha = Digest::SHA256.file(path).hexdigest
      @artifact_bytes = File.size(path)
    end

    def run
      check(@artifact.is_a?(Hash), "artifact must be an object")
      check(@artifact.keys.sort == %w[accepted cleanup environment kind profiles protocol schema_version],
            "top-level envelope")
      check(@artifact["schema_version"] == 1, "schema_version must be 1")
      check(@artifact["kind"] == "storage_tournament_oracle_foundation", "kind")
      check([true, false].include?(@artifact["accepted"]), "accepted boolean")
      check(@artifact_bytes <= MAX_ARTIFACT_BYTES, "artifact exceeds 50 MiB")
      if @expected_sha
        check(hex64?(@expected_sha), "expected artifact SHA format")
        check(@actual_sha == @expected_sha, "artifact SHA mismatch expected=#{@expected_sha} actual=#{@actual_sha}")
      end
      validate_environment
      validate_protocol
      validate_profiles
      validate_top_cleanup
      validate_acceptance
      {
        "mode" => @mode,
        "accepted" => @artifact.fetch("accepted"),
        "profiles" => @artifact.fetch("profiles").length,
        "observations" => observation_count,
        "common_query_identities" => common_query_identity_count,
        "common_write_observations" => common_write_observation_count,
        "artifact_sha256" => @actual_sha,
        "artifact_bytes" => @artifact_bytes,
      }
    end

    private

    def validate_environment
      environment = object(@artifact, "environment")
      check(%w[mode database postgresql ruby].all? { |key| environment.key?(key) }, "environment identity")
      check(%w[mode database postgresql ruby].all? { |key| string(environment[key]) }, "environment identity types")
      check(@mode == "loader-smoke" || @representative, "unsupported environment mode")
      return unless @representative

      check(string(environment["artifact_sha256"]) && hex64?(environment["artifact_sha256"]),
            "representative artifact SHA")
      check(@expected_sha && hex64?(@expected_sha) && @actual_sha == @expected_sha,
            "representative external artifact SHA pin")
      check(environment.keys.sort == REPRESENTATIVE_ENVIRONMENT_KEYS.sort, "representative environment keys")
      validate_representative_admission(environment.fetch("admission"))
      validate_representative_limits(environment.fetch("resource_limits"))
      validate_representative_telemetry(environment.fetch("telemetry"))
      validate_representative_no_impact(environment.fetch("no_impact"))
      validate_representative_export(environment.fetch("export"))
    end

    def validate_representative_admission(admission)
      check(admission.is_a?(Hash) && admission.keys.sort == REPRESENTATIVE_ADMISSION_KEYS.sort,
            "representative admission structure")
      check(admission.fetch("status") == "passed", "representative admission status")
      check(admission.fetch("samples") == 3, "representative admission samples")
      check(integer(admission.fetch("memory_available_bytes")) && admission.fetch("memory_available_bytes") >= (12 * (1024**3)),
            "representative memory headroom")
      %w[smoke_projected_peak_bytes projected_export_bytes].each do |key|
        check(integer(admission.fetch(key)) && admission.fetch(key).positive?, "representative #{key}")
      end
      required = [100 * (1024**3),
                  (3 * admission.fetch("smoke_projected_peak_bytes")) +
                    (20 * (1024**3)) + admission.fetch("projected_export_bytes")].max
      check(admission.fetch("required_docker_free_bytes") == required, "representative Docker headroom formula")
      check(integer(admission.fetch("docker_free_bytes")) && admission.fetch("docker_free_bytes") >= required,
            "representative Docker headroom")
      validate_representative_invariant(admission.fetch("existing_container_invariant"), "admission")
    end

    def validate_representative_limits(limits)
      check(limits.is_a?(Hash) && limits.keys.sort == REPRESENTATIVE_LIMIT_KEYS.sort,
            "representative resource-limit structure")
      host_capacity = limits.fetch("host_capacity")
      headroom = limits.fetch("headroom")
      [host_capacity, headroom].each do |capacity|
        check(capacity.is_a?(Hash) && capacity.keys.sort == REPRESENTATIVE_RESOURCE_KEYS.sort,
              "representative host capacity structure")
        check(number(capacity.fetch("cpus")) && capacity.fetch("cpus").positive?,
              "representative host CPU capacity")
        check(integer(capacity.fetch("memory_bytes")) && capacity.fetch("memory_bytes").positive?,
              "representative host memory capacity")
      end
      admission = @artifact.fetch("environment").fetch("admission")
      check(headroom.fetch("memory_bytes") == admission.fetch("memory_available_bytes"),
            "representative memory headroom record")
      check(headroom.fetch("cpus") <= host_capacity.fetch("cpus") &&
            headroom.fetch("memory_bytes") <= host_capacity.fetch("memory_bytes"),
            "representative headroom exceeds host capacity")
      cap_sum = { "cpus" => 0.0, "memory_bytes" => 0 }
      %w[postgres runner].each do |role|
        cap = limits.fetch(role)
        check(cap.is_a?(Hash) && cap.keys.sort == REPRESENTATIVE_RESOURCE_KEYS.sort,
              "representative #{role} resource-limit structure")
        check(number(cap.fetch("cpus")) && cap.fetch("cpus").positive?, "representative #{role} CPU cap")
        check(integer(cap.fetch("memory_bytes")) && cap.fetch("memory_bytes").positive?,
              "representative #{role} memory cap")
        check(cap.fetch("cpus") <= host_capacity.fetch("cpus") && cap.fetch("memory_bytes") <= host_capacity.fetch("memory_bytes"),
              "representative #{role} exceeds host capacity")
        check(cap.fetch("cpus") <= headroom.fetch("cpus") && cap.fetch("memory_bytes") <= headroom.fetch("memory_bytes"),
              "representative #{role} exceeds recorded headroom")
        cap_sum["cpus"] += cap.fetch("cpus")
        cap_sum["memory_bytes"] += cap.fetch("memory_bytes")
      end
      check(cap_sum["cpus"] <= headroom.fetch("cpus") && cap_sum["memory_bytes"] <= headroom.fetch("memory_bytes"),
            "representative combined caps exceed headroom")
      check(integer(limits.fetch("work_deadline_seconds")) && limits.fetch("work_deadline_seconds").positive?,
            "representative work deadline")
      check(limits.fetch("work_deadline_seconds") <= 86_400, "representative work deadline exceeds 24 hours")
      check(integer(limits.fetch("total_deadline_seconds")) &&
            limits.fetch("total_deadline_seconds") >= limits.fetch("work_deadline_seconds"),
            "representative total deadline")
    end

    def validate_representative_telemetry(telemetry)
      check(telemetry.is_a?(Hash) && telemetry.keys.sort == REPRESENTATIVE_TELEMETRY_KEYS.sort,
            "representative telemetry structure")
      check(telemetry.fetch("explain_analyze_buffers_wal_settings") == true,
            "representative EXPLAIN telemetry")
      check(integer(telemetry.fetch("samples")) && telemetry.fetch("samples").positive?,
            "representative telemetry samples")
      %w[pressure_breaches iowait_breaches].each do |key|
        check(telemetry.fetch(key).zero?, "representative #{key}")
      end
      %w[live_through_finish monitor_started_before_work monitor_stopped_after_finish].each do |key|
        check(telemetry.fetch(key) == true, "representative #{key}")
      end
      pressure = telemetry.fetch("pressure_monitor")
      check(pressure.is_a?(Hash) && pressure.keys.sort == REPRESENTATIVE_PRESSURE_KEYS.sort,
            "representative pressure telemetry structure")
      check(pressure.fetch("status") == "stopped" && pressure.fetch("monitor_pass") == true,
            "representative pressure telemetry status")
      check(integer(pressure.fetch("samples")) && pressure.fetch("samples").positive?,
            "representative pressure telemetry samples")
      check(hex64?(pressure.fetch("sha256")), "representative pressure telemetry SHA")
    end

    def validate_representative_no_impact(no_impact)
      check(no_impact.is_a?(Hash) && no_impact.keys.sort == REPRESENTATIVE_NO_IMPACT_KEYS.sort,
            "representative no-impact structure")
      validate_representative_invariant(no_impact.fetch("existing_container_invariant"), "no-impact")
      check(no_impact.fetch("media_stack_untouched") == true && no_impact.fetch("passed") == true,
            "representative no-impact proof")
    end

    def validate_representative_invariant(invariant, path)
      check(invariant.is_a?(Hash) && invariant.keys.sort == REPRESENTATIVE_INVARIANT_KEYS.sort,
            "representative #{path} invariant structure")
      check(invariant.fetch("passed") == true, "representative #{path} invariant status")
      check(hex64?(invariant.fetch("before_sha256")) && hex64?(invariant.fetch("after_sha256")),
            "representative #{path} invariant SHA")
      check(invariant.fetch("before_sha256") == invariant.fetch("after_sha256"),
            "representative #{path} invariant changed")
    end

    def validate_representative_export(export)
      check(export.is_a?(Hash) && export.keys.sort == REPRESENTATIVE_EXPORT_KEYS.sort,
            "representative export structure")
      check(export.fetch("before_cleanup") == true && export.fetch("verified") == true,
            "representative export ordering")
      check(integer(export.fetch("bytes")) && export.fetch("bytes").positive?, "representative export bytes")
      check(hex64?(export.fetch("sha256")), "representative export SHA")
    end

    def validate_protocol
      protocol = object(@artifact, "protocol")
      expected_keys = %w[a100_a1m_prefix_equal profiles seed smoke_reduces_hosts_only vector_ordinals]
      check(protocol.keys.sort == expected_keys, "protocol keys")
      check(protocol["seed"] == SEED, "protocol seed")
      check(protocol["profiles"] == PROFILES, "frozen profile matrix")
      check(protocol["vector_ordinals"] == VECTOR_ORDINALS, "vector ordinals")
      check(protocol["smoke_reduces_hosts_only"] == true, "smoke reduction contract")
      check(protocol["a100_a1m_prefix_equal"] == true, "A100/A1M prefix contract")
    end

    def validate_profiles
      profiles = @artifact.fetch("profiles")
      check(profiles.is_a?(Array) && profiles.length == PROFILES.length, "profile count")
      names = profiles.map { |profile| profile.fetch("name") }
      check(names.sort == PROFILES.keys.sort && names.uniq.length == names.length, "profile names")
      profiles.each { |profile| validate_profile(profile) }
      a100 = profiles.find { |profile| profile.fetch("name") == "A100" }
      a1m = profiles.find { |profile| profile.fetch("name") == "A1M" }
      check(
        a100.fetch("manifest").fetch("first_100k_prefix_digest") == a1m.fetch("manifest").fetch("first_100k_prefix_digest"), "equal A100/A1M prefix digest"
      )
    end

    def validate_profile(profile)
      name = profile.fetch("name")
      expected = PROFILES.fetch(name) { fail!("unknown profile #{name}") }
      base_keys = %w[cleanup contenders declared effective immutability logical_definitions manifest name
                     physical_definitions recomputation_vector]
      optional_keys = if @representative && name != "A100"
                        %w[factor_limitations factor_observations]
                      else
                        []
                      end
      check(profile.keys.sort == (base_keys + optional_keys).sort, "#{name} profile keys")
      check(profile.fetch("declared") == expected, "#{name} declared profile")
      effective = object(profile, "effective")
      check(effective.keys.sort == expected.keys.sort, "#{name} effective keys")
      check(profile.fetch("physical_definitions") == effective.fetch("definitions"),
            "#{name} physical definition D")
      check(profile.fetch("logical_definitions") == profile.fetch("physical_definitions") - 2,
            "#{name} logical definition D-2")
      check(effective.fetch("definitions") == expected.fetch("definitions"), "#{name} definitions cannot shrink")
      check(effective.fetch("values") == expected.fetch("values"), "#{name} values cannot shrink")
      check(effective.fetch("scopes") == expected.fetch("scopes"), "#{name} scope cardinality cannot shrink")
      check(effective.fetch("workloads") == expected.fetch("workloads"), "#{name} workload matrix")
      validate_factor_scope(profile)
      if @representative
        check(effective.fetch("hosts") == expected.fetch("hosts"), "#{name} representative host count")
      else
        check(effective.fetch("hosts") == 128, "#{name} smoke host count")
        check(effective.fetch("hosts") < expected.fetch("hosts"), "#{name} smoke must be nonrepresentative")
      end
      validate_manifest(profile, expected)
      validate_immutability(profile)
      validate_contenders(profile, expected)
      validate_vector(profile)
      validate_profile_cleanup(profile)
    rescue KeyError => e
      fail!("#{name || "profile"}: missing #{e.message}")
    end

    def validate_manifest(profile, expected)
      name = profile.fetch("name")
      effective = profile.fetch("effective")
      manifest = object(profile, "manifest")
      hosts = effective.fetch("hosts")
      definitions = effective.fetch("definitions")
      values = effective.fetch("values")
      check(manifest.fetch("hosts") == hosts, "#{name} manifest hosts")
      check(manifest.fetch("logical_definitions") == definitions - 2, "#{name} logical definitions")
      check(manifest.fetch("physical_definitions") == definitions, "#{name} physical definitions")
      check(manifest.fetch("values_per_host") == values, "#{name} values per host")
      check(manifest.fetch("cells") == hosts * values, "#{name} cell count")
      per_host = object(manifest, "per_host_cells")
      check(per_host.fetch("minimum") == values && per_host.fetch("maximum") == values, "#{name} per-host cell bounds")
      check(manifest.fetch("missing_control_count") == manifest.fetch("filler_count"), "#{name} missing/filler balance")
      check(manifest.fetch("missing_control_count").positive?, "#{name} missing control")
      check(manifest.fetch("null_control_count").positive?, "#{name} NULL control")
      shape = object(manifest, "typed_shape")
      check(shape.fetch("total") == manifest.fetch("cells"), "#{name} typed shape total")
      check(shape.fetch("valid_values") + shape.fetch("valid_nulls") == shape.fetch("total"),
            "#{name} typed shape partition")
      check(shape.fetch("valid_values").positive? && shape.fetch("valid_nulls").positive?,
            "#{name} typed shape nonempty")
      scope_cardinality = object(manifest, "scope_cardinality")
      check(scope_cardinality.fetch("declared") == expected.fetch("scopes"), "#{name} declared scopes")
      observed = scope_cardinality.fetch("observed")
      check(observed.positive? && observed <= [expected.fetch("scopes"), hosts].min, "#{name} observed scopes")
      check(scope_cardinality.fetch("parent_observed").positive?, "#{name} observed parent scopes")
      check(scope_cardinality.fetch("representative_proven") == @representative, "#{name} representative scope proof")
      check(observed == [expected.fetch("scopes"), hosts].min, "#{name} representative scope cardinality") if @representative
      validate_distributions(manifest.fetch("distribution_frequencies"), name)
      check(manifest.fetch("mixer_stride_vectors") == STRIDE_VECTORS, "#{name} mixer vectors")
      validate_cohorts(manifest.fetch("matched_version_cohorts"), name)
      validate_group_counts(manifest.fetch("groups"), manifest, hosts, name)
      validate_signature(manifest.fetch("logical_digest"), "#{name} logical digest", keys: SIGNATURE_KEYS)
      prefix_digest = manifest.fetch("first_100k_prefix_digest")
      check(
        prefix_digest.is_a?(Hash) && prefix_digest.keys.sort == (SIGNATURE_KEYS + %w[complete limit
                                                                                     observed_hosts]).sort, "#{name} prefix digest envelope"
      )
      validate_signature(prefix_digest.select do |key, _|
        SIGNATURE_KEYS.include?(key)
      end, "#{name} prefix digest", keys: SIGNATURE_KEYS)
      check(prefix_digest.fetch("limit") == 100_000, "#{name} prefix limit")
      check(prefix_digest.fetch("observed_hosts") == [hosts, 100_000].min, "#{name} prefix observed hosts")
      check(prefix_digest.fetch("complete") == (hosts >= 100_000), "#{name} prefix completeness")
      seal = manifest.fetch("seal_sha256")
      check(hex64?(seal), "#{name} manifest seal")
      unsigned = manifest.reject { |key, _| key == "seal_sha256" }
      check(Digest::SHA256.hexdigest(JSON.generate(unsigned)) == seal, "#{name} manifest seal recomputation")
    end

    def validate_distributions(distributions, name)
      distributions = object(distributions, "#{name} distribution frequencies")
      uniform = object(distributions.fetch("uniform"), "#{name} uniform distribution")
      zipf = object(distributions.fetch("zipf"), "#{name} zipf distribution")
      check(uniform.length >= 8, "#{name} uniform spread")
      check(uniform.values.all? { |value| integer(value) && value.positive? }, "#{name} uniform counts")
      check(zipf.values.all? { |value| integer(value) && value.positive? }, "#{name} zipf counts")
      check(zipf.key?("1") && zipf.fetch("1") > zipf.values.sum / 2, "#{name} zipf hot value")
      mean = uniform.values.sum.fdiv(uniform.length)
      check(uniform.values.max - uniform.values.min <= (mean * 0.4).ceil, "#{name} uniform skew")
    end

    def validate_cohorts(cohorts, name)
      cohorts = object(cohorts, "#{name} version cohorts")
      off = object(cohorts.fetch("off"), "#{name} version_off cohort")
      on = object(cohorts.fetch("on"), "#{name} version_on cohort")
      %w[count sum xor].each do |key|
        check(integer_string(off[key]) && integer_string(on[key]), "#{name} cohort #{key}")
      end
      check(off == on, "#{name} matched version cohort digests")
      check(cohorts.fetch("matched") == true && cohorts.fetch("disjoint") == true, "#{name} version cohort flags")
    end

    def validate_group_counts(groups, manifest, hosts, name)
      groups = object(groups, "#{name} group counts")
      %w[types families states shadow_winners cohorts].each do |key|
        values = object(groups.fetch(key), "#{name} groups.#{key}").values
        check(values.all? { |value| integer(value) && value >= 0 }, "#{name} groups.#{key} values")
      end
      check(groups.fetch("types").values.sum == manifest.fetch("cells"), "#{name} type group total")
      check(groups.fetch("families").values.sum == manifest.fetch("cells"), "#{name} family group total")
      check(groups.fetch("states").values.sum == manifest.fetch("cells"), "#{name} state group total")
      check(groups.fetch("shadow_winners").values.sum == manifest.fetch("cells"), "#{name} shadow group total")
      check(groups.fetch("cohorts").values.sum == hosts, "#{name} cohort group total")
    end

    def validate_immutability(profile)
      name = profile.fetch("name")
      proof = object(profile, "immutability")
      check(proof.fetch("sealed") == true && proof.fetch("post_seal_proof") == true, "#{name} oracle sealed proof")
      expected_tables = %w[t121_oracle_cells t121_oracle_definitions t121_oracle_hosts]
      blocked = object(proof.fetch("mutation_blocked"), "#{name} mutation blocked")
      check(blocked.keys.sort == expected_tables.sort && blocked.values.all?(true), "#{name} oracle mutation battery")
      check(proof.fetch("triggers").sort == expected_tables.map { |table|
        "#{table}_sealed"
      }.sort, "#{name} seal triggers")
    end

    def validate_contenders(profile, expected)
      name = profile.fetch("name")
      contenders = object(profile, "contenders")
      required = ADAPTERS + %w[oracle_unchanged oracle_digest_before oracle_digest_after shared_hosts shared_host
                               logical_definitions declared_physical_definitions]
      factor_surfaces = name == "A100" ? FACTOR_SURFACES : []
      check(contenders.keys.sort == (required + factor_surfaces).sort, "#{name} contender envelope")
      check(contenders.fetch("oracle_unchanged") == true, "#{name} oracle unchanged")
      before = validate_signature(contenders.fetch("oracle_digest_before"), "#{name} oracle before",
                                  keys: SIGNATURE_KEYS)
      after = validate_signature(contenders.fetch("oracle_digest_after"), "#{name} oracle after", keys: SIGNATURE_KEYS)
      check(before == after, "#{name} oracle digest changed")
      logical = validate_signature(profile.fetch("manifest").fetch("logical_digest"),
                                   "#{name} manifest logical digest", keys: SIGNATURE_KEYS)
      check(before == logical, "#{name} contender oracle does not match sealed manifest")
      check(contenders.fetch("shared_hosts") == profile.fetch("effective").fetch("hosts"), "#{name} shared host count")
      validate_shared_host(contenders.fetch("shared_host"), name)
      check(contenders.fetch("logical_definitions") == profile.fetch("logical_definitions"),
            "#{name} contender logical definitions")
      check(contenders.fetch("declared_physical_definitions") == expected.fetch("definitions"),
            "#{name} contender physical definitions")
      semantic_reference = nil
      ADAPTERS.each do |adapter|
        semantic = validate_contender(contenders.fetch(adapter), adapter, profile)
        semantic_reference ||= semantic
        check(semantic == semantic_reference, "#{name} #{adapter} cross-adapter logical identity")
      end
      return unless name == "A100"

      validate_public_queries(contenders.fetch("public_typed_eav"), profile)
      validate_common_queries(contenders.fetch("common_queries"), profile)
      validate_common_writes(contenders.fetch("common_writes"), profile)
    end

    def validate_factor_scope(profile)
      name = profile.fetch("name")
      observed = profile.fetch("contenders").keys & FACTOR_SURFACES
      expected = name == "A100" ? FACTOR_SURFACES : []
      check(observed.sort == expected.sort, "#{name} factor observation set")
      if @representative
        if name == "A100"
          check(!profile.key?("factor_limitations") && !profile.key?("factor_observations"),
                "A100 must not carry factor limitation")
        else
          observations = profile.fetch("factor_observations")
          check(observations.is_a?(Hash) && observations.keys.sort == FACTOR_OBSERVATIONS.fetch(name).sort,
                "#{name} frozen factor observation set")
          observations.each { |cell, evidence| validate_factor_observation(evidence, cell, name, profile) }
          limitations = profile.fetch("factor_limitations")
          check(limitations.fetch("status") != "not_measured", "#{name} factor limitation is not measured")
          check(limitations == FACTOR_LIMITATIONS.fetch(name), "#{name} frozen factor limitation")
        end
      else
        check(!profile.key?("factor_limitations") && !profile.key?("factor_observations"),
              "smoke factor limitations must not masquerade as representative evidence")
      end
    end

    def validate_factor_observation(evidence, cell, name, profile)
      if FACTOR_UNSUPPORTED_CELLS.include?(cell)
        check(evidence.is_a?(Hash) && evidence.keys.sort == FACTOR_UNSUPPORTED_KEYS.sort,
              "#{name} factor #{cell} unsupported evidence structure")
        check(evidence.fetch("status") == "unsupported", "#{name} factor #{cell} unsupported status")
        check(evidence.fetch("workload") == cell && string(evidence.fetch("reason")),
              "#{name} factor #{cell} unsupported reason")
        return
      end

      if FACTOR_QUERY_CELLS.include?(cell)
        check(evidence.is_a?(Hash) && evidence.keys.sort == FACTOR_QUERY_KEYS.sort,
              "#{name} factor #{cell} query evidence structure")
        check(evidence.fetch("status") == "measured", "#{name} factor #{cell} status")
        check(evidence.fetch("workload") == cell, "#{name} factor #{cell} workload")
        adapters = validate_factor_adapters(evidence, cell, name)
        oracle = validate_id_signature(evidence.fetch("oracle_identity"), "#{name} factor #{cell} oracle identity")
        identities = evidence.fetch("identities")
        check(identities.is_a?(Hash) && identities.keys.sort == adapters.sort,
              "#{name} factor #{cell} identity adapter set")
        adapters.each do |adapter|
          identity = validate_id_signature(identities.fetch(adapter), "#{name} factor #{cell} #{adapter} identity")
          check(identity == oracle, "#{name} factor #{cell} #{adapter} identity differs from sealed oracle")
        end
        validate_factor_query_outputs(evidence, adapters, cell, name)
        return
      end

      if FACTOR_LOAD_CELLS.include?(cell)
        validate_factor_load(evidence, cell, name, profile)
        return
      end

      if FACTOR_WRITE_CELLS.include?(cell)
        validate_factor_write(evidence, cell, name, profile)
        return
      end

      fail!("#{name} unknown factor cell #{cell}")
    end

    def validate_factor_adapters(evidence, cell, name)
      adapters = evidence.fetch("applicable_adapters")
      check(adapters.is_a?(Array) && adapters.sort == ADAPTERS.sort, "#{name} factor #{cell} adapter coverage")
      adapters
    end

    def validate_factor_query_outputs(evidence, adapters, cell, name)
      plans = evidence.fetch("plans")
      metrics = evidence.fetch("metrics")
      check(plans.is_a?(Hash) && plans.keys.sort == adapters.sort, "#{name} factor #{cell} plan adapter set")
      check(metrics.is_a?(Hash) && metrics.keys.sort == adapters.sort, "#{name} factor #{cell} metric adapter set")
      adapters.each do |adapter|
        adapter_plans = plans.fetch(adapter)
        check(adapter_plans.is_a?(Array) && !adapter_plans.empty?, "#{name} factor #{cell} #{adapter} plans")
        adapter_plans.each_with_index do |plan, index|
          validate_plan(plan, "#{name} factor #{cell} #{adapter} plan #{index}")
        end
        adapter_metrics = metrics.fetch(adapter)
        check(adapter_metrics.is_a?(Hash) && adapter_metrics.keys.sort == FACTOR_METRIC_KEYS.sort,
              "#{name} factor #{cell} #{adapter} metrics")
        validate_factor_metric_row(adapter_metrics, adapter_plans, cell, name, adapter)
      end
    end

    def validate_factor_load(evidence, cell, name, profile)
      check(evidence.is_a?(Hash) && evidence.keys.sort == FACTOR_LOAD_KEYS.sort,
            "#{name} factor #{cell} load evidence structure")
      check(evidence.fetch("status") == "measured" && evidence.fetch("workload") == cell,
            "#{name} factor #{cell} load status")
      adapters = validate_factor_adapters(evidence, cell, name)
      oracle = validate_signature(profile.fetch("contenders").fetch("typed_eav").fetch("oracle_digest"),
                                  "#{name} factor #{cell} oracle semantic digest", keys: SIGNATURE_KEYS)
      actual_oracle = validate_signature(evidence.fetch("oracle_semantic_digest"), "#{name} factor #{cell} sealed semantic digest", keys: SIGNATURE_KEYS)
      check(actual_oracle == oracle, "#{name} factor #{cell} semantic oracle mismatch")
      validate_factor_digest_set(evidence.fetch("semantic_digests"), adapters, actual_oracle, cell, name, "semantic")
      validate_factor_metrics(evidence.fetch("metrics"), adapters, cell, name)
    end

    def validate_factor_write(evidence, cell, name, profile)
      check(evidence.is_a?(Hash) && evidence.keys.sort == FACTOR_WRITE_KEYS.sort,
            "#{name} factor #{cell} write evidence structure")
      check(evidence.fetch("status") == "measured" && evidence.fetch("workload") == cell,
            "#{name} factor #{cell} write status")
      adapters = validate_factor_adapters(evidence, cell, name)
      oracle = validate_signature(profile.fetch("contenders").fetch("typed_eav").fetch("oracle_digest"),
                                  "#{name} factor #{cell} oracle semantic digest", keys: SIGNATURE_KEYS)
      actual_oracle = validate_signature(evidence.fetch("oracle_semantic_digest"), "#{name} factor #{cell} sealed semantic digest", keys: SIGNATURE_KEYS)
      check(actual_oracle == oracle, "#{name} factor #{cell} semantic oracle mismatch")
      validate_factor_digest_set(evidence.fetch("semantic_digests"), adapters, actual_oracle, cell, name, "semantic")
      post_oracle = validate_signature(evidence.fetch("oracle_post_state_digest"),
                                       "#{name} factor #{cell} oracle post-state", keys: SIGNATURE_KEYS)
      validate_factor_digest_set(evidence.fetch("post_state_digests"), adapters, post_oracle, cell, name, "post-state")
      validate_factor_metrics(evidence.fetch("metrics"), adapters, cell, name)
    end

    def validate_factor_digest_set(digests, adapters, oracle, cell, name, label)
      check(digests.is_a?(Hash) && digests.keys.sort == adapters.sort,
            "#{name} factor #{cell} #{label} digest adapter set")
      adapters.each do |adapter|
        digest = validate_signature(digests.fetch(adapter), "#{name} factor #{cell} #{adapter} #{label} digest", keys: SIGNATURE_KEYS)
        check(digest == oracle, "#{name} factor #{cell} #{adapter} #{label} differs from oracle")
      end
    end

    def validate_factor_metrics(metrics, adapters, cell, name)
      check(metrics.is_a?(Hash) && metrics.keys.sort == adapters.sort, "#{name} factor #{cell} metric adapter set")
      adapters.each do |adapter|
        row = metrics.fetch(adapter)
        check(row.is_a?(Hash) && row.keys.sort == FACTOR_METRIC_KEYS.sort,
              "#{name} factor #{cell} #{adapter} metrics")
        validate_factor_metric_row(row, nil, cell, name, adapter)
      end
    end

    def validate_factor_metric_row(row, plans, cell, name, adapter)
      %w[execution_ms planning_ms wal_bytes].each do |metric|
        check(number(row.fetch(metric)) && row.fetch(metric) >= 0,
              "#{name} factor #{cell} #{adapter} #{metric}")
      end
      check(integer(row.fetch("rows")) && row.fetch("rows") >= 0,
            "#{name} factor #{cell} #{adapter} rows")
      return unless plans

      aggregate = plans.each_with_object({ "execution_ms" => 0.0, "planning_ms" => 0.0,
                                           "rows" => 0, "wal_bytes" => 0 }) do |plan, totals|
        root = plan.fetch(0).fetch("Plan")
        totals["execution_ms"] += plan.fetch(0).fetch("Execution Time")
        totals["planning_ms"] += plan.fetch(0).fetch("Planning Time")
        totals["rows"] += root.fetch("Actual Rows")
        totals["wal_bytes"] += root.fetch("WAL Bytes")
      end
      %w[execution_ms planning_ms rows wal_bytes].each do |metric|
        matches = if %w[execution_ms planning_ms].include?(metric)
                    (row.fetch(metric) - aggregate.fetch(metric)).abs <= FACTOR_TIME_TOLERANCE
                  else
                    row.fetch(metric) == aggregate.fetch(metric)
                  end
        check(matches,
              "#{name} factor #{cell} #{adapter} aggregate #{metric}")
      end
    end

    def validate_shared_host(shared, name)
      shared = object(shared, "#{name} shared host")
      check(string(shared.fetch("indexdef")) && shared.fetch("indexdef").include?("(tenant_id, workspace_id, id)"),
            "#{name} shared tuple index definition")
      check(integer(shared.fetch("bytes")) && shared.fetch("bytes").positive?, "#{name} shared tuple index bytes")
      check(shared.fetch("indisvalid") == true && shared.fetch("indisready") == true,
            "#{name} shared tuple index readiness")
      check(integer(shared.fetch("rows")) && shared.fetch("rows").positive?, "#{name} shared host rows")
      check(shared.fetch("excluded_equally_from_contender_bytes") == true, "#{name} shared byte exclusion")
    end

    def validate_contender(contender, adapter, profile)
      name = profile.fetch("name")
      contender = object(contender, "#{name} #{adapter} contender")
      check(number(contender.fetch("wall_ms")) && contender.fetch("wall_ms") >= 0,
            "#{name} #{adapter} load wall time")
      check(number(contender.fetch("wal_bytes")) && contender.fetch("wal_bytes") >= 0,
            "#{name} #{adapter} load WAL bytes")
      relations = object(contender.fetch("relations"), "#{name} #{adapter} relations")
      check(relations.keys.sort == RELATION_NAMES.fetch(adapter).sort, "#{name} #{adapter} relation set")
      check(relations.any?, "#{name} #{adapter} relations")
      expected_rows = expected_relation_rows(adapter, profile)
      relations.each do |relation, stats|
        stats = object(stats, "#{name} #{adapter} relation #{relation}")
        check(stats.keys.sort == %w[filenode heap index_filenodes indexes rows total].sort,
              "#{name} #{adapter} #{relation} manifest keys")
        %w[heap indexes total rows].each do |key|
          check(integer(stats[key]) && stats[key] >= 0, "#{name} #{adapter} #{relation}.#{key}")
        end
        check(integer(stats.fetch("filenode")) && stats.fetch("filenode").positive?,
              "#{name} #{adapter} #{relation}.filenode")
        index_filenodes = object(stats.fetch("index_filenodes"), "#{name} #{adapter} #{relation} index filenodes")
        check(index_filenodes.any? && index_filenodes.values.all? { |value| integer(value) && value.positive? },
              "#{name} #{adapter} #{relation} index filenode values")
        check(stats.fetch("total") >= stats.fetch("heap") + stats.fetch("indexes"),
              "#{name} #{adapter} relation byte floor")
        check(stats.fetch("rows") == expected_rows.fetch(relation), "#{name} #{adapter} #{relation} row count")
      end
      catalog = object(contender.fetch("catalog"), "#{name} #{adapter} catalog")
      indexes = catalog.fetch("indexes")
      columns = catalog.fetch("columns")
      check(indexes.is_a?(Array) && indexes.length.positive?, "#{name} #{adapter} index catalog")
      check(columns.is_a?(Array) && columns.length.positive?, "#{name} #{adapter} column catalog")
      index_names = indexes.map do |row|
        check(row.is_a?(Array) && row.length >= 7, "#{name} #{adapter} index row shape")
        table, index, definition, bytes, valid, ready, opclasses = row
        check(string(table) && string(index) && string(definition), "#{name} #{adapter} index identity")
        check(integer(bytes) && bytes >= 0, "#{name} #{adapter} index bytes")
        check(valid == true && ready == true, "#{name} #{adapter} index readiness")
        check(string(opclasses) && !opclasses.empty?, "#{name} #{adapter} index opclasses")
        index
      end
      check(index_names.uniq.length == index_names.length, "#{name} #{adapter} duplicate index names")
      check(index_names.sort == INDEX_NAMES.fetch(adapter).sort, "#{name} #{adapter} required index set")
      validate_index_contracts(indexes, adapter, name)
      validate_columns(columns, adapter, profile, name)
      check(hex64?(catalog.fetch("sha256")), "#{name} #{adapter} catalog SHA")
      check(Digest::SHA256.hexdigest(JSON.generate([indexes, columns])) == catalog.fetch("sha256"),
            "#{name} #{adapter} catalog SHA recomputation")
      semantic = validate_signature(contender.fetch("semantic_digest"), "#{name} #{adapter} semantic digest",
                                    keys: SIGNATURE_KEYS)
      actual_oracle = validate_signature(contender.fetch("oracle_digest"), "#{name} #{adapter} oracle digest",
                                         keys: SIGNATURE_KEYS)
      check(semantic == actual_oracle, "#{name} #{adapter} logical identity")
      check(semantic.fetch("count") == profile.fetch("manifest").fetch("cells").to_s,
            "#{name} #{adapter} logical cell count")
      check(contender.fetch("semantic_equal") == (semantic == actual_oracle), "#{name} #{adapter} semantic equality")
      return unless %w[typed_eav per_type_eav].include?(adapter)

      winner = validate_signature(contender.fetch("physical_winner_digest"), "#{name} #{adapter} winner",
                                  keys: %w[count sum xor sha256])
      oracle_winner = validate_signature(contender.fetch("oracle_physical_winner_digest"),
                                         "#{name} #{adapter} oracle winner", keys: %w[count sum xor sha256])
      check(winner == oracle_winner && contender.fetch("physical_winner_equal") == (winner == oracle_winner),
            "#{name} #{adapter} physical winner")
    end

    def expected_relation_rows(adapter, profile)
      manifest = profile.fetch("manifest")
      hosts = profile.fetch("effective").fetch("hosts")
      definitions = profile.fetch("effective").fetch("definitions")
      values = manifest.fetch("values_per_host")
      types = manifest.fetch("groups").fetch("types")
      case adapter
      when "typed_eav"
        { "typed_eav_fields" => definitions, "typed_eav_values" => hosts * values }
      when "jsonb"
        { "t121_json" => hosts }
      when "per_type_eav"
        {
          "t121_type_definitions" => definitions,
          "t121_type_integer" => types.fetch("integer"),
          "t121_type_decimal" => types.fetch("decimal", 0),
          "t121_type_boolean" => types.fetch("boolean", 0),
          "t121_type_date" => types.fetch("date", 0),
          "t121_type_datetime" => types.fetch("datetime", 0),
          "t121_type_text" => types.fetch("text", 0),
          "t121_type_json" => types.fetch("integer_array", 0) + types.fetch("text_array", 0),
        }
      when "sql"
        { "t121_sql" => hosts }
      else
        fail!("#{profile.fetch("name")} unknown adapter #{adapter}")
      end
    end

    def validate_index_contracts(indexes, adapter, name)
      by_name = indexes.to_h { |row| [row.fetch(1), row] }
      require_index = lambda do |index, opclasses: nil, includes: []|
        row = by_name.fetch(index) { fail!("#{name} #{adapter} missing index #{index}") }
        check(row.fetch(4) == true && row.fetch(5) == true, "#{name} #{adapter} #{index} readiness")
        check(row.fetch(6) == opclasses, "#{name} #{adapter} #{index} opclasses") if opclasses
        includes.each { |fragment| check(row.fetch(2).include?(fragment), "#{name} #{adapter} #{index} missing #{fragment}") }
      end

      case adapter
      when "typed_eav"
        require_index.call("idx_te_fields_lookup", opclasses: "text_ops,text_ops,text_ops,int4_ops,text_ops",
                                                   includes: %w[entity_type sort_order name])
        require_index.call("idx_te_fields_uniq_global", opclasses: "text_ops,text_ops", includes: ["WHERE", "scope IS NULL"])
        require_index.call("idx_te_fields_uniq_scoped_full", opclasses: "text_ops,text_ops,text_ops,text_ops",
                                                             includes: ["scope IS NOT NULL", "parent_scope IS NOT NULL"])
        require_index.call("idx_te_fields_uniq_scoped_only", opclasses: "text_ops,text_ops,text_ops",
                                                             includes: ["scope IS NOT NULL", "parent_scope IS NULL"])
        require_index.call("idx_te_values_entity_field", opclasses: "text_ops,int8_ops,int8_ops",
                                                         includes: %w[entity_id field_id])
        {
          "bool" => ["boolean_value", "int8_ops,bool_ops"], "date" => ["date_value", "int8_ops,date_ops"],
          "dec" => ["decimal_value", "int8_ops,numeric_ops"], "dt" => ["datetime_value", "int8_ops,timestamp_ops"],
          "int" => ["integer_value", "int8_ops,int8_ops"], "str" => ["string_value", "int8_ops,text_pattern_ops"]
        }.each do |suffix, (column, opclasses)|
          require_index.call("idx_te_values_field_#{suffix}_present", opclasses: opclasses,
                                                                      includes: ["field_id", column, "INCLUDE (entity_id)", "WHERE (#{column} IS NOT NULL)"])
        end
        require_index.call("idx_te_values_json_gin", opclasses: "jsonb_ops",
                                                     includes: %w[json_value WHERE])
      when "jsonb"
        require_index.call("t121_json_pkey", opclasses: "int8_ops", includes: %w[entity_id])
        require_index.call("t121_json_document_gin", opclasses: "jsonb_path_ops", includes: %w[payload jsonb_path_ops])
        require_index.call("t121_json_array_hot", opclasses: "jsonb_path_ops", includes: %w[payload jsonb_typeof])
        require_index.call("t121_json_date_iso_hot", opclasses: "text_pattern_ops", includes: ["f005", "text_pattern_ops", "IS NOT NULL"])
        require_index.call("t121_json_text_prefix", opclasses: "text_pattern_ops", includes: ["f002", "text_pattern_ops", "IS NOT NULL"])
        { "integer" => "000", "zipf" => "001", "sort" => "004" }.each do |suffix, field|
          require_index.call("t121_json_#{suffix}_hot", opclasses: "int8_ops", includes: ["f#{field}", "IS NOT NULL"])
        end
      when "per_type_eav"
        require_index.call("t121_type_definitions_lookup", opclasses: "text_ops,text_ops,text_ops,int4_ops",
                                                           includes: %w[logical_name specificity])
        require_index.call("t121_type_definitions_pkey", opclasses: "int4_ops", includes: %w[physical_definition])
        %w[boolean date datetime decimal integer text].each do |type|
          require_index.call("t121_type_#{type}_hydrate", opclasses: "int8_ops", includes: %w[entity_id INCLUDE])
          require_index.call("t121_type_#{type}_lookup", opclasses: "int4_ops,#{type_opclass(type)}",
                                                         includes: ["physical_definition", "value", "INCLUDE (entity_id)", "WHERE (value IS NOT NULL)"])
          require_index.call("t121_type_#{type}_pkey", opclasses: "int8_ops,int4_ops",
                                                       includes: %w[entity_id physical_definition])
        end
        require_index.call("t121_type_json_hydrate", opclasses: "int8_ops", includes: %w[entity_id INCLUDE])
        require_index.call("t121_type_json_lookup", opclasses: "int4_ops,int8_ops", includes: %w[physical_definition entity_id])
        require_index.call("t121_type_json_pkey", opclasses: "int8_ops,int4_ops", includes: %w[entity_id physical_definition])
        require_index.call("t121_type_json_value_gin", opclasses: "jsonb_path_ops", includes: %w[value WHERE])
      when "sql"
        require_index.call("t121_sql_pkey", opclasses: "int8_ops", includes: %w[id])
        {
          "array_hot" => %w[f006 array_ops], "date_hot" => %w[f005 date_ops],
          "integer_hot" => %w[f000 int8_ops], "sort_hot" => %w[f004 int8_ops],
          "text_prefix" => %w[f002 text_pattern_ops], "zipf_hot" => %w[f001 int8_ops]
        }.each do |suffix, (field, opclasses)|
          require_index.call("t121_sql_#{suffix}", opclasses: opclasses, includes: [field, "WHERE", "_present", "IS NOT NULL"])
        end
      end
    end

    def type_opclass(type)
      { "boolean" => "bool_ops", "date" => "date_ops", "datetime" => "timestamp_ops",
        "decimal" => "numeric_ops", "integer" => "int8_ops", "text" => "text_pattern_ops" }.fetch(type)
    end

    def validate_columns(columns, adapter, profile, name)
      rows = columns.map do |row|
        check(row.is_a?(Array) && row.length == 4, "#{name} #{adapter} column row shape")
        table, column, type, nullable = row
        check(string(table) && string(column) && string(type) && %w[YES NO].include?(nullable), "#{name} #{adapter} column metadata")
        row
      end
      grouped = rows.group_by(&:first).transform_values { |items| items.map { |item| item.fetch(1) } }
      check(grouped.keys.sort == RELATION_NAMES.fetch(adapter).sort, "#{name} #{adapter} column table set")
      expected_columns(adapter, profile).each do |table, expected|
        check(grouped.fetch(table).sort == expected.sort, "#{name} #{adapter} #{table} column set")
      end
    end

    def expected_columns(adapter, profile)
      profile.fetch("effective").fetch("definitions")
      case adapter
      when "typed_eav"
        {
          "typed_eav_fields" => %w[id name type entity_type scope section_id required sort_order options default_value_meta created_at updated_at parent_scope field_dependent label],
          "typed_eav_values" => %w[id entity_type entity_id field_id string_value text_value boolean_value integer_value decimal_value date_value datetime_value json_value created_at updated_at],
        }
      when "jsonb"
        { "t121_json" => %w[entity_id payload] }
      when "per_type_eav"
        scalar = %w[entity_id physical_definition state value]
        {
          "t121_type_definitions" => %w[physical_definition logical_index logical_name type_name scope parent_scope specificity],
          "t121_type_integer" => scalar, "t121_type_decimal" => scalar, "t121_type_boolean" => scalar,
          "t121_type_date" => scalar, "t121_type_datetime" => scalar, "t121_type_text" => scalar,
          "t121_type_json" => scalar
        }
      when "sql"
        fields = (0...profile.fetch("logical_definitions")).flat_map do |index|
          [format("f%03d", index), format("f%03d_present", index)]
        end
        { "t121_sql" => ["id", *fields] }
      else
        fail!("#{profile.fetch("name")} unknown adapter #{adapter}")
      end
    end

    def validate_public_queries(public, profile)
      name = profile.fetch("name")
      public = object(public, "#{name} public TypedEAV evidence")
      queries = object(public.fetch("queries"), "#{name} public queries")
      check(queries.keys.sort == PUBLIC_QUERY_NAMES.sort, "#{name} public query set")
      queries.each { |query, row| validate_public_query(row, query, name) }
      protocols = object(public.fetch("multi_filter_protocols"), "#{name} filter protocols")
      check(protocols.keys.sort == %w[filters_10 filters_20], "#{name} filter protocol set")
      protocols.each { |workload, filters| validate_filter_protocol(filters, workload, name) }
      hydration = object(public.fetch("hydration"), "#{name} BulkRead hydration")
      check(hydration.keys.sort == %w[1 128], "#{name} BulkRead cardinalities")
      hydration.each { |count, row| validate_bulk_read(row, count, name) }
      validate_unsupported(public.fetch("sort_limit"), "sort_limit", name)
      validate_unsupported(public.fetch("pure_missing"), "pure_missing", name)
      check(string(public.fetch("public_query_host_scope_note")), "#{name} host-scope note")
    end

    def validate_public_query(row, query, name)
      row = object(row, "#{name} public #{query}")
      validate_id_pair(row.fetch("identity"), row.fetch("oracle_identity"), "#{name} public #{query}")
      check(row.fetch("identity_equal") == true, "#{name} public #{query} identity flag")
      check(row.fetch("notification_count") == 2, "#{name} public #{query} SQL count")
      check(hex64?(row.fetch("notification_sha256")), "#{name} public #{query} notification SHA")
      check(integer(row.fetch("eligible_hosts")) && row.fetch("eligible_hosts").positive?,
            "#{name} public #{query} eligible hosts")
      expected_selective = SELECTIVE_PUBLIC_QUERIES.include?(query)
      check(row.fetch("selective") == expected_selective, "#{name} public #{query} selective contract")
      check(row.fetch("selectivity_evaluable") == (row.fetch("eligible_hosts") > 1),
            "#{name} public #{query} selectivity flag")
      if query == "cross_scope_admin"
        check(row.fetch("resolved_definition_count") == 3, "#{name} admin definition map")
      else
        check(row["resolved_definition_count"].nil?, "#{name} ordinary definition map")
      end
      sql = row.fetch("public_sql")
      check(string(sql) && sql.include?("typed_eav_values"), "#{name} public #{query} SQL surface")
      check(sql.scan("field_id").length >= 3, "#{name} admin multimap SQL") if query == "cross_scope_admin"
      validate_plan(row.fetch("plan"), "#{name} public #{query} plan")
    end

    def validate_bulk_read(row, count, name)
      row = object(row, "#{name} BulkRead #{count}")
      check(row.fetch("records") == count.to_i, "#{name} BulkRead #{count} record count")
      check(row.fetch("notification_count") == 3, "#{name} BulkRead #{count} SQL count")
      check(hex64?(row.fetch("notification_sha256")), "#{name} BulkRead #{count} notification SHA")
      validate_id_pair(row.fetch("identity"), row.fetch("oracle_identity"), "#{name} BulkRead #{count}")
      check(row.fetch("identity_equal") == true, "#{name} BulkRead #{count} identity flag")
      check(row.fetch("identity").fetch("count") == (count.to_i * 20).to_s, "#{name} BulkRead #{count} cell count")
    end

    def validate_common_queries(common, profile)
      name = profile.fetch("name")
      common = object(common, "#{name} common queries")
      public = profile.fetch("contenders").fetch("public_typed_eav")
      support = object(common.fetch("support"), "#{name} common query support")
      check(support.fetch("supported") == COMMON_QUERY_NAMES, "#{name} common query support order")
      validate_unsupported(support.fetch("pure_missing"), "pure_missing", name)
      validate_unsupported(support.fetch("sort_limit"), "sort_limit", name)
      queries = object(common.fetch("queries"), "#{name} common query observations")
      check(queries.keys.sort == COMMON_QUERY_NAMES.sort, "#{name} common query workload set")
      queries.each do |workload, adapters|
        check(adapters.is_a?(Hash) && adapters.keys.sort == ADAPTERS.sort, "#{name} common #{workload} adapter set")
        adapters.each { |adapter, row| validate_common_query(row, adapter, workload, name) }
        expected = public.fetch("queries").fetch(workload).fetch("oracle_identity")
        adapters.each do |adapter, row|
          check(row.fetch("identity") == expected, "#{name} common #{workload} #{adapter} differs from public oracle")
        end
      end
      contracts = object(common.fetch("contracts"), "#{name} common query contracts")
      check(contracts.fetch("json_date_iso_index_compatible") == true, "#{name} JSON date index contract")
      check(contracts.fetch("shared_host_tuple_index") == "t121_projects_scope_tuple",
            "#{name} shared host index contract")
      check(contracts.fetch("text_semantics") == "ILIKE for every contender; no ordinary B-tree acceleration claim",
            "#{name} text semantics contract")
      filter_contracts = object(contracts.fetch("multi_filter_distinct_fields"),
                                "#{name} multi-filter distinct-field contract")
      %w[filters_10 filters_20].each do |workload|
        contract = object(filter_contracts.fetch(workload), "#{name} #{workload} distinct-field contract")
        filters = profile.fetch("contenders").fetch("public_typed_eav").fetch("multi_filter_protocols").fetch(workload)
        check(contract.fetch("count") == filters.length && contract.fetch("unique") == true,
              "#{name} #{workload} contract count")
        check(contract.fetch("names") == filters.map do |filter|
          filter.fetch("name")
        end, "#{name} #{workload} contract names")
      end
    end

    def validate_common_query(row, adapter, workload, name)
      row = object(row, "#{name} common #{workload} #{adapter}")
      if adapter == "typed_eav"
        validate_id_pair(row.fetch("identity"), row.fetch("oracle_identity"), "#{name} common #{workload} typed")
        check(row.fetch("identity_equal") == true, "#{name} common #{workload} typed identity")
        check(row.fetch("surface") == "public Project.where_typed_eav", "#{name} common #{workload} typed surface")
        check(string(row.fetch("public_sql")) && row.fetch("public_sql").include?("typed_eav_values"),
              "#{name} common #{workload} typed SQL")
      else
        validate_id_signature(row.fetch("identity"), "#{name} common #{workload} #{adapter} identity")
        check(row.fetch("identity_equal") == true, "#{name} common #{workload} #{adapter} identity")
        check(row.fetch("surface") == "physical contender SQL", "#{name} common #{workload} #{adapter} surface")
        check(string(row.fetch("sql")), "#{name} common #{workload} #{adapter} SQL")
      end
      validate_plan(row.fetch("plan"), "#{name} common #{workload} #{adapter} plan")
    end

    def validate_filter_protocol(filters, workload, name)
      check(filters.is_a?(Array) && filters.length == workload.delete_prefix("filters_").to_i,
            "#{name} #{workload} filter count")
      names = filters.map { |filter| object(filter, "#{name} #{workload} filter").fetch("name") }
      check(names == names.uniq, "#{name} #{workload} distinct fields")
      filters.each_with_index do |filter, index|
        check(filter.fetch("logical_index") == index, "#{name} #{workload} logical index")
        check(filter.fetch("name") == format("f%03d", index), "#{name} #{workload} field name")
        check(%w[integer decimal boolean date datetime text integer_array text_array].include?(filter.fetch("type")),
              "#{name} #{workload} field type")
        expected_operator = %w[integer_array text_array].include?(filter.fetch("type")) ? "any_eq" : "eq"
        check(filter.fetch("operator") == expected_operator, "#{name} #{workload} operator")
        check(integer(filter.fetch("target_ordinal")) && filter.fetch("target_ordinal").positive?,
              "#{name} #{workload} target ordinal")
        check(!filter.fetch("value").nil?, "#{name} #{workload} value")
      end
    end

    def validate_common_writes(common, profile)
      name = profile.fetch("name")
      common = object(common, "#{name} common writes")
      check(common.fetch("surface") == "common direct-storage SQL; reduced callback semantics are explicit",
            "#{name} write surface")
      boundary = object(common.fetch("metric_boundary"), "#{name} metric boundary")
      %w[mutation_wall_ms storage_wall_ms validation_wall_ms physical_reset rotation_order timestamps].each do |key|
        check(string(boundary[key]) && !boundary[key].empty?, "#{name} metric boundary #{key}")
      end
      check(common.fetch("orders") == WRITE_ROTATIONS, "#{name} write rotations")
      check(common.fetch("workloads") == COMMON_WRITE_WORKLOADS, "#{name} write workload order")
      targets = object(common.fetch("targets"), "#{name} write targets")
      %w[source_id missing_id new_ordinal new_id bulk_1k_effective bulk_100k_effective field_delete_rows
         insert_definition update_definition].each do |key|
        check(targets.key?(key), "#{name} write target #{key}")
      end
      check(targets.fetch("source_id") != targets.fetch("missing_id"), "#{name} write source/missing separation")
      check(targets.fetch("insert_definition_contract") == "global f000 fallback", "#{name} insert definition contract")
      check(targets.fetch("update_definition") == "f004", "#{name} update definition contract")
      hosts = profile.fetch("effective").fetch("hosts")
      check(targets.fetch("bulk_1k_effective") == [1_000, hosts].min, "#{name} 1k write target")
      check(targets.fetch("bulk_100k_effective") == [100_000, hosts].min, "#{name} 100k write target")
      check(targets.fetch("field_delete_rows") == [100_000, hosts].min, "#{name} field-delete target")
      observations = common.fetch("observations")
      expected_count = WRITE_ROTATIONS.length * ADAPTERS.length * COMMON_WRITE_WORKLOADS.length
      check(observations.is_a?(Array) && observations.length == expected_count, "#{name} write observation count")
      check(observations.map do |row|
        [row.fetch("trial"), row.fetch("adapter"), row.fetch("workload")]
      end.uniq.length == observations.length, "#{name} duplicate write cells")
      observations.each { |row| validate_write_observation(row, name, profile) }
      validate_write_cross_adapter_state(observations, profile, name)
      summary = object(common.fetch("summary"), "#{name} write summary")
      %w[trials observations expected_observations].each do |key|
        check(summary.fetch(key).is_a?(Integer), "#{name} write summary #{key}")
      end
      check(
        summary.fetch("trials") == WRITE_ROTATIONS.length && summary.fetch("observations") == expected_count && summary.fetch("expected_observations") == expected_count, "#{name} write summary counts"
      )
      %w[all_baselines_restored no_no_ops post_states_equal full_plans_every_trial plan_hash_every_trial].each do |key|
        check(summary.fetch(key) == true, "#{name} write summary #{key}")
      end
      validate_resets(common.fetch("physical_resets"), name)
      validate_operational_only(common.fetch("operational_only"), name)
    end

    def validate_write_observation(row, name, profile)
      row = object(row, "#{name} write observation")
      check(ADAPTERS.include?(row.fetch("adapter")), "#{name} write adapter")
      check(COMMON_WRITE_WORKLOADS.include?(row.fetch("workload")), "#{name} write workload")
      check((1..WRITE_ROTATIONS.length).cover?(row.fetch("trial")), "#{name} write trial")
      check(row.fetch("rotation") == WRITE_ROTATIONS.fetch(row.fetch("trial") - 1), "#{name} write rotation")
      check(row.fetch("transaction") == "rollback", "#{name} write transaction")
      check(
        row.fetch("semantic_surface") == "physical persistence only; no casting, validation, callback, or version claim", "#{name} write semantic surface"
      )
      %w[baseline_restored no_op commit_cost_included].each do |key|
        check(row.key?(key), "#{name} write #{key} evidence")
      end
      check(
        row.fetch("baseline_restored") == true && row.fetch("no_op") == false && row.fetch("commit_cost_included") == false, "#{name} write safety flags"
      )
      %w[mutation_wall_ms storage_wall_ms validation_wall_ms lsn_wal_bytes storage_plan_wal_bytes
         total_plan_wal_bytes].each do |key|
        check(number(row[key]) && row[key] >= 0, "#{name} write #{key}")
      end
      check(
        row.fetch("total_plan_wal_bytes") == row.fetch("storage_plan_wal_bytes") + row.fetch("common_host_plan_wal_bytes"), "#{name} write WAL reconciliation"
      )
      check(row.fetch("mutation_wall_ms") >= row.fetch("storage_wall_ms"), "#{name} mutation boundary excludes storage")
      check(row.fetch("lsn_wal_scope") == "database-global diagnostic; per-plan WAL is the comparable cell metric",
            "#{name} write WAL scope")
      %w[post_state_digest oracle_post_state_digest].each do |key|
        validate_signature(row.fetch(key), "#{name} write #{key}", keys: SIGNATURE_KEYS)
      end
      check(row.fetch("post_state_digest") == row.fetch("oracle_post_state_digest"), "#{name} write oracle post-state")
      plans = row.fetch("plans")
      check(plans.is_a?(Array) && !plans.empty?, "#{name} write plans")
      plans.each_with_index { |plan, index| validate_plan(plan, "#{name} write plan #{index}") }
      check(row.fetch("plan_sha256") == Digest::SHA256.hexdigest(JSON.generate(plans, max_nesting: false)),
            "#{name} write plan SHA")
      common_plans = row.fetch("common_host_plans")
      check(common_plans.is_a?(Array), "#{name} common host plans")
      common_plans.each_with_index { |plan, index| validate_plan(plan, "#{name} common host plan #{index}") }
      check(
        row.fetch("common_host_plan_sha256") == Digest::SHA256.hexdigest(JSON.generate(common_plans,
                                                                                       max_nesting: false)), "#{name} common host plan SHA"
      )
      check(row.fetch("common_host_statement_count") == common_plans.length, "#{name} common host statement count")
      check(row.fetch("storage_statement_count") == plans.length, "#{name} storage statement count")
      check(row.fetch("statement_rows") == expected_statement_rows(row, profile), "#{name} write statement rows")
      check(row.fetch("common_host_statement_rows") == expected_common_host_rows(row), "#{name} common host statement rows")
      check(row.fetch("cell_count_delta") == expected_cell_delta(row), "#{name} write cell delta")
      check(row.fetch("storage_plan_wal_bytes") == plan_wal_bytes(plans), "#{name} raw storage plan WAL")
      check(row.fetch("common_host_plan_wal_bytes") == plan_wal_bytes(common_plans), "#{name} raw common-host plan WAL")
    end

    def expected_statement_rows(row, profile)
      hosts = profile.fetch("effective").fetch("hosts")
      targets = profile.fetch("contenders").fetch("common_writes").fetch("targets")
      case row.fetch("workload")
      when "single_insert", "single_update" then [1]
      when "create_20"
        if row.fetch("adapter") == "typed_eav"
          [20]
        else
          row.fetch("adapter") == "per_type_eav" ? CREATE_20_ROWS_PER_TYPE : [1]
        end
      when "bulk_1k"
        [[targets.fetch("bulk_1k_effective"), hosts].min]
      when "bulk_100k"
        [[targets.fetch("bulk_100k_effective"), hosts].min]
      when "physical_field_delete"
        [[targets.fetch("field_delete_rows"), hosts].min]
      else fail!("#{profile.fetch("name")} unknown write workload")
      end
    end

    def expected_common_host_rows(row)
      row.fetch("workload") == "create_20" ? [1, 1] : []
    end

    def expected_cell_delta(row)
      case row.fetch("workload")
      when "single_insert" then 1
      when "single_update", "bulk_1k", "bulk_100k" then 0
      when "create_20" then 20
      when "physical_field_delete" then -row.fetch("statement_rows").sum
      else fail!("unknown write delta workload")
      end
    end

    def plan_wal_bytes(plans)
      plans.sum do |plan|
        root = plan.fetch(0).fetch("Plan")
        value = root.fetch("WAL Bytes")
        check(number(value) && value >= 0, "plan WAL bytes")
        value
      end
    end

    def validate_write_cross_adapter_state(observations, profile, name)
      baseline = profile.fetch("contenders").fetch("typed_eav").fetch("semantic_digest")
      observations.group_by { |row| [row.fetch("trial"), row.fetch("workload")] }.each do |cell, rows|
        check(rows.map { |row| row.fetch("adapter") }.sort == ADAPTERS.sort, "#{name} write adapter coverage #{cell.inspect}")
        post_states = rows.to_h { |row| [row.fetch("adapter"), row.fetch("post_state_digest")] }
        oracle_states = rows.to_h { |row| [row.fetch("adapter"), row.fetch("oracle_post_state_digest")] }
        check(post_states.values.uniq.length == 1, "#{name} cross-adapter post-state #{cell.inspect}")
        check(oracle_states.values.uniq.length == 1, "#{name} cross-adapter oracle state #{cell.inspect}")
        expected_count = profile.fetch("manifest").fetch("cells") + rows.first.fetch("cell_count_delta")
        check(post_states.values.first.fetch("count") == expected_count.to_s, "#{name} post-state count #{cell.inspect}")
        check(post_states.values.first != baseline, "#{name} write no-op post-state #{cell.inspect}")
      end
    end

    def validate_resets(resets, name)
      check(resets.is_a?(Array) && resets.length == 7, "#{name} physical reset count")
      expected_stages = %w[before_common_writes before_field_delete before_common_writes before_field_delete
                           before_common_writes before_field_delete final]
      check(resets.map { |reset| reset.fetch("stage") } == expected_stages, "#{name} physical reset stages")
      check(resets.map { |reset| reset.fetch("trial") } == [1, 1, 2, 2, 3, 3, 3], "#{name} physical reset trials")
      expected = profile_reset_baseline
      canonical = expected
      previous_generation = expected
      resets.each do |reset|
        proof = object(reset.fetch("proof"), "#{name} physical reset proof")
        check(proof.keys.sort == ADAPTERS.sort, "#{name} physical reset adapter set")
        semantic_digests = proof.map do |adapter, evidence|
          validate_reset_adapter_evidence(evidence, expected.fetch(adapter), adapter, name)
        end
        check(semantic_digests.uniq.length == 1, "#{name} physical reset cross-adapter digest")
        check(reset_generation_rotated?(previous_generation, proof), "#{name} physical reset generation reuse")
        previous_generation = proof
        physical_bytes_equal = reset.fetch("physical_bytes_equal")
        check([true, false].include?(physical_bytes_equal), "#{name} physical byte diagnostic")
        check(physical_bytes_equal == (reset_physical_bytes(proof) == reset_physical_bytes(canonical)),
              "#{name} physical byte diagnostic truthfulness")
      end
    end

    def validate_reset_adapter_evidence(evidence, expected, adapter, name)
      check(ADAPTERS.include?(adapter), "#{name} physical reset adapter")
      evidence = object(evidence, "#{name} physical reset #{adapter}")
      digest = validate_signature(evidence.fetch("semantic_digest"), "#{name} physical reset #{adapter} digest",
                                  keys: SIGNATURE_KEYS)
      relations = object(evidence.fetch("relations"), "#{name} physical reset #{adapter} relations")
      expected_relations = expected.fetch("relations")
      check(relations.keys.sort == expected_relations.keys.sort, "#{name} physical reset #{adapter} relation set")
      relations.each do |relation, stats|
        stats = object(stats, "#{name} physical reset #{adapter} #{relation}")
        check(stats.keys.sort == %w[filenode heap index_filenodes indexes rows total].sort,
              "#{name} physical reset #{adapter} #{relation} manifest keys")
        %w[heap indexes rows total].each do |metric|
          check(integer(stats.fetch(metric)) && stats.fetch(metric) >= 0,
                "#{name} physical reset #{adapter} #{relation} #{metric}")
        end
        check(stats.fetch("total") >= stats.fetch("heap") + stats.fetch("indexes"),
              "#{name} physical reset #{adapter} #{relation} byte floor")
        check(stats.fetch("rows") == expected_relations.fetch(relation).fetch("rows"),
              "#{name} physical reset #{adapter} #{relation} rows")
        check(integer(stats.fetch("filenode")) && stats.fetch("filenode").positive?,
              "#{name} physical reset #{adapter} #{relation} filenode")
        index_filenodes = object(stats.fetch("index_filenodes"),
                                 "#{name} physical reset #{adapter} #{relation} index filenodes")
        check(index_filenodes.keys.sort == expected_relations.fetch(relation).fetch("index_filenodes").keys.sort,
              "#{name} physical reset #{adapter} #{relation} index set")
        check(index_filenodes.values.all? { |value| integer(value) && value.positive? },
              "#{name} physical reset #{adapter} #{relation} index filenode values")
      end
      check(digest == expected.fetch("semantic_digest"), "#{name} physical reset #{adapter} digest")
      digest
    end

    def reset_generation_rotated?(previous, current)
      ADAPTERS.all? do |adapter|
        prior_relations = previous.fetch(adapter).fetch("relations")
        current_relations = current.fetch(adapter).fetch("relations")
        prior_relations.keys.sort == current_relations.keys.sort && prior_relations.all? do |relation, prior|
          candidate = current_relations.fetch(relation)
          prior_indexes = prior.fetch("index_filenodes")
          candidate_indexes = candidate.fetch("index_filenodes")
          candidate.fetch("filenode") != prior.fetch("filenode") &&
            prior_indexes.keys.sort == candidate_indexes.keys.sort &&
            prior_indexes.all? { |index, filenode| candidate_indexes.fetch(index) != filenode }
        end
      end
    end

    def reset_physical_bytes(proof)
      proof.transform_values do |adapter|
        adapter.fetch("relations").transform_values do |manifest|
          manifest.slice("heap", "indexes", "total")
        end
      end
    end

    def profile_reset_baseline
      profile = @artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
      profile.fetch("contenders").slice(*ADAPTERS).transform_values do |contender|
        { "relations" => contender.fetch("relations"), "semantic_digest" => contender.fetch("semantic_digest") }
      end
    end

    def validate_operational_only(operational, name)
      operational = object(operational, "#{name} operational N/A")
      typed = object(operational.fetch("typed_eav"), "#{name} typed operational N/A")
      %w[backfill_pair callback_preserving_deletion versioned_mutation].each do |key|
        item = object(typed.fetch(key), "#{name} operational #{key}")
        check(OPERATIONAL_STATUSES.include?(item.fetch("status")), "#{name} operational #{key} status")
        check(string(item.fetch("reason")) && !item.fetch("reason").empty?, "#{name} operational #{key} reason")
      end
      other = object(operational.fetch("other_adapters"), "#{name} other operational N/A")
      check(other.fetch("status") == "not_applicable" && string(other.fetch("reason")), "#{name} other operational N/A")
    end

    def validate_vector(profile)
      name = profile.fetch("name")
      vector = object(profile.fetch("recomputation_vector"), "#{name} recomputation vector")
      check(vector.fetch("ordinals") == VECTOR_ORDINALS, "#{name} vector ordinals")
      rows = vector.fetch("rows")
      check(rows.is_a?(Array) && rows.length.positive?, "#{name} vector rows")
      rows.each do |row|
        check(row.is_a?(Array) && row.length == 7, "#{name} vector row shape")
        ordinal, logical_index, type, family, state, specificity, canonical = row
        check(
          integer(ordinal) && integer(logical_index) && string(type) && string(family) && %w[value
                                                                                             null].include?(state) && integer(specificity) && (string(canonical) || canonical.nil?), "#{name} vector row types"
        )
        check(VECTOR_ORDINALS.include?(ordinal), "#{name} vector ordinal")
        check(logical_index >= 0 && specificity.between?(0, 2), "#{name} vector indexes")
        check(%w[uniform zipf].include?(family), "#{name} vector family")
      end
      check(hex64?(vector.fetch("sha256")), "#{name} vector SHA")
      check(Digest::SHA256.hexdigest(JSON.generate(rows)) == vector.fetch("sha256"), "#{name} vector SHA recomputation")
    end

    def validate_profile_cleanup(profile)
      cleanup = object(profile.fetch("cleanup"), "#{profile.fetch("name")} profile cleanup")
      check(cleanup.fetch("scheduled") == true && cleanup.fetch("table_prefix") == "t121_oracle_",
            "#{profile.fetch("name")} cleanup schedule")
    end

    def validate_top_cleanup
      cleanup = object(@artifact, "cleanup")
      if @representative
        check(cleanup.keys.sort == REPRESENTATIVE_CLEANUP_KEYS.sort, "representative cleanup structure")
        check(cleanup.fetch("exact") == true && cleanup.fetch("export_before_cleanup") == true &&
              cleanup.fetch("owned_resources_zero") == true && cleanup.fetch("post_cleanup_verified") == true,
              "representative cleanup proof")
      else
        check(cleanup.keys.sort == %w[exact remaining_task_relations].sort, "smoke cleanup structure")
        check(cleanup.fetch("exact") == true, "exact cleanup")
      end
      check(cleanup.fetch("remaining_task_relations") == [], "remaining task relations")
    end

    def validate_acceptance
      prefixes = @artifact.fetch("profiles").map do |profile|
        profile.fetch("manifest").fetch("first_100k_prefix_digest")
      end
      complete = prefixes.all? { |prefix| prefix.fetch("complete") == true }
      if @representative
        check(@artifact.fetch("accepted") == true, "representative artifact must be accepted")
        check(complete, "representative prefix must be complete")
        validate_representative_prerequisites
      else
        check(@artifact.fetch("accepted") == false, "smoke artifact must be accepted=false")
        check(prefixes.all? { |prefix| prefix.fetch("complete") == false }, "smoke prefix must be incomplete")
      end
    end

    def validate_representative_prerequisites
      profiles = @artifact.fetch("profiles").each_with_object({}) do |profile, result|
        result[profile.fetch("name")] = profile
      end
      check(profiles.fetch("A100").fetch("effective").fetch("hosts") == 100_000, "A100 representative host target")
      check(profiles.fetch("A1M").fetch("effective").fetch("hosts") == 1_000_000, "A1M representative host target")
      writes = profiles.fetch("A100").fetch("contenders").fetch("common_writes")
      targets = writes.fetch("targets")
      check(targets.fetch("bulk_1k_effective") == 1_000, "representative 1k write target")
      check(targets.fetch("bulk_100k_effective") == 100_000, "representative 100k write target")
      queries = profiles.fetch("A100").fetch("contenders").fetch("public_typed_eav").fetch("queries")
      SELECTIVE_PUBLIC_QUERIES.each do |workload|
        query = queries.fetch(workload)
        eligible = query.fetch("eligible_hosts")
        observed = query.fetch("identity").fetch("count").to_i
        check(query.fetch("selective") == true, "representative #{workload} selective contract")
        check(query.fetch("selectivity_evaluable") == true && eligible > 1,
              "representative #{workload} selectivity eligibility")
        check(observed.positive? && observed < eligible, "representative #{workload} nonvacuous selectivity")
      end
    end

    def validate_unsupported(row, workload, name)
      row = object(row, "#{name} unsupported #{workload}")
      check(row.fetch("status") == "unsupported", "#{name} #{workload} status")
      check(string(row.fetch("reason")) && !row.fetch("reason").empty?, "#{name} #{workload} reason")
    end

    def validate_plan(plan, path)
      check(plan.is_a?(Array) && plan.length == 1, "#{path} envelope")
      root = plan.fetch(0)
      check(root.is_a?(Hash) && root["Plan"].is_a?(Hash), "#{path} root")
      check(string(root["Plan"]["Node Type"]), "#{path} node type")
      check(root["Settings"].is_a?(Hash), "#{path} settings")
      check(root["Planning"].is_a?(Hash), "#{path} planning stats")
      check(number(root["Planning Time"]) && root["Planning Time"] >= 0 && number(root["Execution Time"]) && root["Execution Time"] >= 0, "#{path} timing")
      PLAN_NODE_METRICS.each do |metric|
        check(number(root["Plan"][metric]) && root["Plan"][metric] >= 0, "#{path} root #{metric}")
      end
      walk_plan(root["Plan"], path)
    end

    def walk_plan(node, path)
      return unless node.is_a?(Hash)

      PLAN_NODE_METRICS.each do |metric|
        check(number(node[metric]) && node[metric] >= 0, "#{path} #{metric}")
      end
      return unless node.key?("Plans")

      check(node["Plans"].is_a?(Array), "#{path} child plans")
      node["Plans"].each_with_index { |child, index| walk_plan(child, "#{path}.Plans[#{index}]") }
    end

    def validate_id_pair(identity, oracle, path)
      actual = validate_id_signature(identity, "#{path} identity")
      expected = validate_id_signature(oracle, "#{path} oracle identity")
      check(actual == expected, "#{path} identity mismatch")
    end

    def validate_id_signature(signature, path)
      validate_signature(signature, path, keys: ID_SIGNATURE_KEYS)
    end

    def validate_signature(signature, path, keys:)
      signature = object(signature, path)
      check(signature.keys.sort == keys.sort, "#{path} keys")
      keys.reject { |key| key == "sha256" }.each { |key| check(integer_string(signature.fetch(key)), "#{path}.#{key}") }
      check(hex64?(signature.fetch("sha256")), "#{path}.sha256")
      expected = Digest::SHA256.hexdigest(signature.values_at(*keys.reject { |key| key == "sha256" }).join("|"))
      check(signature.fetch("sha256") == expected, "#{path} SHA recomputation")
      signature
    end

    def observation_count
      @artifact.fetch("profiles").sum do |profile|
        profile.dig("contenders", "common_queries", "queries")&.values&.sum(&:length) || 0
      end
    end

    def common_query_identity_count
      @artifact.fetch("profiles").sum do |profile|
        queries = profile.dig("contenders", "common_queries", "queries")
        queries ? queries.values.sum(&:length) : 0
      end
    end

    def common_write_observation_count
      @artifact.fetch("profiles").sum do |profile|
        profile.dig("contenders", "common_writes", "observations")&.length || 0
      end
    end

    def object(parent, key)
      # Callers pass either a parent/key pair or an already extracted object
      # plus a diagnostic path.  Accept the latter without weakening the
      # object-type check; required nested keys are still fetched explicitly.
      value = parent.is_a?(Hash) && parent.key?(key) ? parent.fetch(key) : parent
      check(value.is_a?(Hash), "#{key} must be an object")
      value
    end

    def string(value)
      value.is_a?(String) && !value.empty?
    end

    def integer(value)
      value.is_a?(Integer)
    end

    def number(value)
      value.is_a?(Numeric) && value.finite?
    end

    def integer_string(value)
      value.is_a?(String) && value.match?(/\A-?\d+\z/)
    end

    def hex64?(value)
      value.is_a?(String) && value.match?(/\A\h{64}\z/)
    end

    def check(condition, message)
      fail!(message) unless condition
    end

    def fail!(message)
      raise InvalidArtifact, message
    end
  end

  class MutationBattery
    MUTATIONS = {
      "protocol_seed" => ->(artifact) { artifact.fetch("protocol")["seed"] += 1 },
      "smoke_acceptance" => ->(artifact) { artifact["accepted"] = true },
      "manifest_prefix_complete" => lambda { |artifact|
        artifact.fetch("profiles").first.fetch("manifest").fetch("first_100k_prefix_digest")["complete"] = true
      },
      "oracle_digest" => lambda { |artifact|
        artifact.fetch("profiles").first.fetch("contenders").fetch("typed_eav").fetch("oracle_digest")["sum_a"] = "0"
      },
      "catalog_sha" => lambda { |artifact|
        artifact.fetch("profiles").first.fetch("contenders").fetch("typed_eav").fetch("catalog")["sha256"] = "0" * 64
      },
      "public_sql_count" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("public_typed_eav").fetch("queries").fetch("eq_uniform")["notification_count"] = 3
      },
      "bulk_read_count" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("public_typed_eav").fetch("hydration").fetch("128")["notification_count"] = 2
      },
      "filter_duplicate" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("public_typed_eav").fetch("multi_filter_protocols").fetch("filters_10").last["name"] = "f000"
      },
      "write_rotation" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("common_writes").fetch("orders").first.reverse!
      },
      "write_wal" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("common_writes").fetch("observations").first["total_plan_wal_bytes"] += 1
      },
      "reset_count" => lambda { |artifact|
        artifact.fetch("profiles").find do |profile|
          profile.fetch("name") == "A100"
        end.fetch("contenders").fetch("common_writes").fetch("physical_resets").pop
      },
      "alternative_common_query_identity" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        row = profile.fetch("contenders").fetch("common_queries").fetch("queries").fetch("eq_uniform").fetch("jsonb")
        identity = row.fetch("identity")
        identity["sum"] = "0"
        identity["sha256"] = Digest::SHA256.hexdigest(identity.values_at("count", "sum", "xor").join("|"))
      },
      "adapter_relation_rows" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        relation = profile.fetch("contenders").fetch("jsonb").fetch("relations").fetch("t121_json")
        relation["rows"] += 1
      },
      "adapter_required_index" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        indexes = profile.fetch("contenders").fetch("typed_eav").fetch("catalog").fetch("indexes")
        indexes.delete_if { |row| row.fetch(1) == "idx_te_values_field_int_present" }
      },
      "public_plan_settings" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        plan = profile.fetch("contenders").fetch("public_typed_eav").fetch("queries").fetch("eq_uniform").fetch("plan").fetch(0)
        plan.delete("Settings")
      },
      "representative_factor_non_first_plan" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        MutationBattery.representative_factor_shell!(artifact)
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "L100" }
        plans = profile.fetch("factor_observations").fetch("hydrate_1k").fetch("plans").fetch("typed_eav")
        plans << Marshal.load(Marshal.dump(plans.first))
        plans.last.fetch(0)["Execution Time"] += 1.0
      },
      "raw_write_plan_wal" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        plan = profile.fetch("contenders").fetch("common_writes").fetch("observations").first.fetch("plans").first.fetch(0).fetch("Plan")
        plan["WAL Bytes"] += 1
      },
      "write_affected_rows" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        rows = profile.fetch("contenders").fetch("common_writes").fetch("observations").first.fetch("statement_rows")
        rows[0] += 1
      },
      "cross_adapter_post_state" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        observations = profile.fetch("contenders").fetch("common_writes").fetch("observations")
        row = observations.find do |observation|
          observation.fetch("trial") == 1 && observation.fetch("workload") == "single_insert" && observation.fetch("adapter") == "jsonb"
        end
        %w[post_state_digest oracle_post_state_digest].each do |key|
          digest = row.fetch(key)
          digest["sum_a"] = "0"
          digest["sha256"] = Digest::SHA256.hexdigest(digest.values_at("count", "sum_a", "xor_a", "sum_b", "xor_b").join("|"))
        end
      },
      "reset_byte_drift" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        reset = profile.fetch("contenders").fetch("common_writes").fetch("physical_resets").first
        reset["physical_bytes_equal"] = !reset.fetch("physical_bytes_equal")
      },
      "reset_index_generation_reuse" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        baseline = profile.fetch("contenders").fetch("typed_eav").fetch("relations").fetch("typed_eav_values")
        reset = profile.fetch("contenders").fetch("common_writes").fetch("physical_resets").first
        relation = reset.fetch("proof").fetch("typed_eav").fetch("relations").fetch("typed_eav_values")
        index = baseline.fetch("index_filenodes").keys.first
        relation.fetch("index_filenodes")[index] = baseline.fetch("index_filenodes").fetch(index)
      },
      "final_reset_semantic_drift" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        reset = profile.fetch("contenders").fetch("common_writes").fetch("physical_resets").last
        reset.fetch("proof").fetch("typed_eav").fetch("semantic_digest")["sum_a"] = "0"
      },
      "final_reset_row_drift" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        reset = profile.fetch("contenders").fetch("common_writes").fetch("physical_resets").last
        reset.fetch("proof").fetch("typed_eav").fetch("relations").fetch("typed_eav_values")["rows"] += 1
      },
      "final_reset_dishonest_byte_diagnostic" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        reset = profile.fetch("contenders").fetch("common_writes").fetch("physical_resets").last
        reset["physical_bytes_equal"] = !reset.fetch("physical_bytes_equal")
      },
      "operational_na_status" => lambda { |artifact|
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        profile.fetch("contenders").fetch("common_writes").fetch("operational_only").fetch("other_adapters")["status"] = "deferred"
      },
      "representative_relabel" => lambda { |artifact|
        artifact["environment"]["mode"] = "representative"
        artifact["accepted"] = true
      },
      "representative_factor_names" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        MutationBattery.representative_factor_shell!(artifact)
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "L100" }
        profile.fetch("factor_observations").delete(FACTOR_OBSERVATIONS.fetch("L100").first)
        profile.fetch("factor_observations")["unregistered"] = profile.fetch("factor_observations").values.first
      },
      "representative_factor_not_measured" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        MutationBattery.representative_factor_shell!(artifact)
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "L100" }
        profile.fetch("factor_limitations")["status"] = "not_measured"
      },
      "representative_factor_identity" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        MutationBattery.representative_factor_shell!(artifact)
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "L100" }
        identity = profile.fetch("factor_observations").fetch("eq_uniform").fetch("identities").fetch("jsonb")
        identity["sum"] = "0"
        identity["sha256"] = Digest::SHA256.hexdigest(identity.values_at("count", "sum", "xor").join("|"))
      },
      "representative_factor_gap_measured" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        MutationBattery.representative_factor_shell!(artifact)
        profile = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "L100" }
        profile.fetch("factor_observations").fetch("missing")["status"] = "measured"
      },
      "representative_capacity_short" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        admission = artifact.fetch("environment").fetch("admission")
        admission["docker_free_bytes"] = admission.fetch("required_docker_free_bytes") - 1
      },
      "representative_deadline_24h" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        artifact.fetch("environment").fetch("resource_limits")["work_deadline_seconds"] = 86_401
      },
      "representative_pressure_breach" => lambda { |artifact|
        MutationBattery.representative_shell!(artifact)
        artifact.fetch("environment").fetch("telemetry")["pressure_breaches"] = 1
      },
      "cleanup" => ->(artifact) { artifact.fetch("cleanup")["exact"] = false },
    }.freeze

    class << self
      def representative_shell!(artifact)
        gibibyte = 1024**3
        projected_peak = gibibyte
        projected_export = 1024**2
        required_docker_free = [100 * gibibyte,
                                (3 * projected_peak) + (20 * gibibyte) + projected_export].max
        invariant = {
          "after_sha256" => "a" * 64,
          "before_sha256" => "a" * 64,
          "passed" => true,
        }
        artifact["accepted"] = true
        artifact["environment"] = {
          "admission" => {
            "docker_free_bytes" => required_docker_free + 1,
            "existing_container_invariant" => Marshal.load(Marshal.dump(invariant)),
            "memory_available_bytes" => 16 * gibibyte,
            "projected_export_bytes" => projected_export,
            "required_docker_free_bytes" => required_docker_free,
            "samples" => 3,
            "smoke_projected_peak_bytes" => projected_peak,
            "status" => "passed",
          },
          "artifact_sha256" => "0" * 64,
          "database" => "representative_probe",
          "export" => { "before_cleanup" => true, "bytes" => 1, "sha256" => "b" * 64, "verified" => true },
          "mode" => "representative",
          "no_impact" => {
            "existing_container_invariant" => Marshal.load(Marshal.dump(invariant)),
            "media_stack_untouched" => true,
            "passed" => true,
          },
          "postgresql" => "17.7 (Postgres.app)",
          "resource_limits" => {
            "headroom" => { "cpus" => 4.0, "memory_bytes" => 16 * gibibyte },
            "host_capacity" => { "cpus" => 8.0, "memory_bytes" => 32 * gibibyte },
            "postgres" => { "cpus" => 2.0, "memory_bytes" => 8 * gibibyte },
            "runner" => { "cpus" => 1.0, "memory_bytes" => 3 * gibibyte },
            "total_deadline_seconds" => 4_200,
            "work_deadline_seconds" => 3_600,
          },
          "ruby" => "3.4.4",
          "telemetry" => {
            "explain_analyze_buffers_wal_settings" => true,
            "iowait_breaches" => 0,
            "live_through_finish" => true,
            "monitor_started_before_work" => true,
            "monitor_stopped_after_finish" => true,
            "pressure_breaches" => 0,
            "pressure_monitor" => {
              "monitor_pass" => true,
              "samples" => 3,
              "sha256" => "c" * 64,
              "status" => "stopped",
            },
            "samples" => 3,
          },
        }
        artifact["cleanup"] = {
          "exact" => true,
          "export_before_cleanup" => true,
          "owned_resources_zero" => true,
          "post_cleanup_verified" => true,
          "remaining_task_relations" => [],
        }
      end

      def representative_factor_shell!(artifact)
        a100 = artifact.fetch("profiles").find { |candidate| candidate.fetch("name") == "A100" }
        common_queries = a100.fetch("contenders").fetch("common_queries").fetch("queries")
        artifact.fetch("profiles").each do |profile|
          name = profile.fetch("name")
          next if name == "A100"

          profile["factor_limitations"] = Marshal.load(Marshal.dump(FACTOR_LIMITATIONS.fetch(name)))
          profile["factor_observations"] = FACTOR_OBSERVATIONS.fetch(name).to_h do |cell|
            evidence = if FACTOR_UNSUPPORTED_CELLS.include?(cell)
                         { "reason" => "public surface unsupported in factorized tier", "status" => "unsupported", "workload" => cell }
                       elsif FACTOR_QUERY_CELLS.include?(cell)
                         factor_query_fixture(common_queries, cell)
                       elsif FACTOR_LOAD_CELLS.include?(cell)
                         factor_load_fixture(profile)
                       else
                         factor_write_fixture(a100, profile, cell)
                       end
            [cell, evidence]
          end
        end
      end

      def factor_query_fixture(common_queries, cell)
        source = common_queries.fetch(FACTOR_QUERY_SOURCE.fetch(cell))
        oracle = Marshal.load(Marshal.dump(source.fetch("typed_eav").fetch("identity")))
        plans = {}
        identities = {}
        metrics = {}
        ADAPTERS.each do |adapter|
          row = source.fetch(adapter)
          plan = Marshal.load(Marshal.dump(row.fetch("plan")))
          root = plan.fetch(0).fetch("Plan")
          plans[adapter] = [plan]
          identities[adapter] = Marshal.load(Marshal.dump(oracle))
          metrics[adapter] = {
            "execution_ms" => plan.fetch(0).fetch("Execution Time"),
            "planning_ms" => plan.fetch(0).fetch("Planning Time"),
            "rows" => root.fetch("Actual Rows"),
            "wal_bytes" => root.fetch("WAL Bytes"),
          }
        end
        {
          "applicable_adapters" => ADAPTERS,
          "identities" => identities,
          "metrics" => metrics,
          "oracle_identity" => oracle,
          "plans" => plans,
          "status" => "measured",
          "workload" => cell,
        }
      end

      def factor_load_fixture(profile)
        semantic = profile.fetch("contenders").fetch("typed_eav").fetch("oracle_digest")
        metrics = ADAPTERS.to_h do |adapter|
          contender = profile.fetch("contenders").fetch(adapter)
          [adapter, {
            "execution_ms" => contender.fetch("wall_ms"),
            "planning_ms" => 0.0,
            "rows" => profile.fetch("manifest").fetch("cells"),
            "wal_bytes" => contender.fetch("wal_bytes"),
          }]
        end
        {
          "applicable_adapters" => ADAPTERS,
          "metrics" => metrics,
          "oracle_semantic_digest" => Marshal.load(Marshal.dump(semantic)),
          "semantic_digests" => ADAPTERS.to_h do |adapter|
            [adapter, Marshal.load(Marshal.dump(profile.fetch("contenders").fetch(adapter).fetch("semantic_digest")))]
          end,
          "status" => "measured",
          "workload" => "load",
        }
      end

      def factor_write_fixture(a100, profile, cell)
        workload = { "bulk_1k" => "bulk_1k", "bulk_100k" => "bulk_100k", "deletion" => "physical_field_delete" }.fetch(cell)
        source = a100.fetch("contenders").fetch("common_writes").fetch("observations")
        rows = ADAPTERS.to_h do |adapter|
          [adapter, source.find do |observation|
            observation.fetch("trial") == 1 && observation.fetch("adapter") == adapter && observation.fetch("workload") == workload
          end]
        end
        oracle_post = Marshal.load(Marshal.dump(rows.fetch("typed_eav").fetch("oracle_post_state_digest")))
        {
          "applicable_adapters" => ADAPTERS,
          "metrics" => rows.transform_values do |row|
            {
              "execution_ms" => row.fetch("storage_wall_ms"),
              "planning_ms" => 0.0,
              "rows" => row.fetch("statement_rows").sum,
              "wal_bytes" => row.fetch("storage_plan_wal_bytes"),
            }
          end,
          "oracle_post_state_digest" => oracle_post,
          "oracle_semantic_digest" => Marshal.load(Marshal.dump(profile.fetch("contenders").fetch("typed_eav").fetch("oracle_digest"))),
          "post_state_digests" => rows.transform_values do |row|
            Marshal.load(Marshal.dump(row.fetch("post_state_digest")))
          end,
          "semantic_digests" => ADAPTERS.to_h do |adapter|
            [adapter, Marshal.load(Marshal.dump(profile.fetch("contenders").fetch(adapter).fetch("semantic_digest")))]
          end,
          "status" => "measured",
          "workload" => cell,
        }
      end
    end

    def self.run(path)
      raw = JSON.parse(File.read(path), max_nesting: false)
      external_sha = Digest::SHA256.file(path).hexdigest
      failures = MUTATIONS.map do |name, mutation|
        candidate = Marshal.load(Marshal.dump(raw))
        mutation.call(candidate)
        begin
          expected_sha = name.start_with?("representative_") && name != "representative_relabel" ? external_sha : nil
          checker = Checker.new(candidate, path: path, expected_sha: expected_sha)
          if %w[representative_factor_names representative_factor_not_measured representative_factor_identity
                representative_factor_gap_measured representative_factor_non_first_plan].include?(name)
            profile = candidate.fetch("profiles").find { |item| item.fetch("name") == "L100" }
            checker.send(:validate_factor_scope, profile)
          else
            checker.run
          end
          [name, false, "mutation was accepted"]
        rescue InvalidArtifact => e
          [name, true, e.message]
        end
      end
      failures.each { |name, rejected, message| puts "mutation=#{name} rejected=#{rejected} reason=#{message}" }
      raise InvalidArtifact, "mutation battery accepted a corrupt artifact" unless failures.all? { |_, rejected, _| rejected }

      puts "storage_tournament_mutations_valid count=#{failures.length}"
    end
  end

  def self.validate(path, expected_sha: nil)
    artifact = JSON.parse(File.read(path), max_nesting: false)
    result = Checker.new(artifact, path: path, expected_sha: expected_sha).run
    puts "storage_tournament_artifact_valid mode=#{result.fetch("mode")} accepted=#{result.fetch("accepted")} profiles=#{result.fetch("profiles")} common_queries=#{result.fetch("common_query_identities")} common_writes=#{result.fetch("common_write_observations")} sha256=#{result.fetch("artifact_sha256")} bytes=#{result.fetch("artifact_bytes")}"
    result
  rescue *StorageTournamentValidator::VALIDATION_ERRORS, StorageTournamentValidator::InvalidArtifact => e
    abort "invalid artifact: #{e.message}"
  end
end

# rubocop:enable Layout/LineLength
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
# rubocop:enable Performance/CollectionLiteralInLoop
# rubocop:enable Style/HashExcept, Style/HashSlice
# rubocop:enable Rails/IndexBy, Rails/IndexWith, Style/ReduceToHash

if $PROGRAM_NAME == __FILE__
  if ARGV.length == 2 && ARGV.first == "--mutation-battery"
    StorageTournamentValidator::MutationBattery.run(ARGV.last)
  elsif ARGV.length == 3 && ARGV.first == "--expected-sha"
    StorageTournamentValidator.validate(ARGV.fetch(2), expected_sha: ARGV.fetch(1))
  else
    unless ARGV.length == 1
      abort(
        "usage: ruby validate_storage_tournament_artifact.rb " \
        "[--mutation-battery ARTIFACT|--expected-sha SHA ARTIFACT|ARTIFACT]",
      )
    end
    StorageTournamentValidator.validate(ARGV.fetch(0))
  end
end
