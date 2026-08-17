# frozen_string_literal: true

# rubocop:disable all

# The Phase 10 benchmark is intentionally a bounded protocol, not a benchmark
# framework. All contenders load from the same sealed database oracle. Smoke
# mode reduces only host count; it does not change contender semantics or DDL.
require "active_record"
require "date"
require "digest"
require "json"
require "optparse"
require_relative "../spec/dummy/config/environment"
require_relative "../spec/dummy/app/models/test_models"

module TypedEAVStorageTournament
  SEED = 12_101
  TYPE_CLASSES = {
    "integer" => TypedEAV::Field::Integer,
    "text" => TypedEAV::Field::Text,
    "boolean" => TypedEAV::Field::Boolean,
    "date" => TypedEAV::Field::Date,
    "integer_array" => TypedEAV::Field::IntegerArray,
    "text_array" => TypedEAV::Field::TextArray,
    "decimal" => TypedEAV::Field::Decimal,
    "datetime" => TypedEAV::Field::DateTime,
  }.freeze
  PROFILES = {
    "L100" => { hosts: 100_000, definitions: 10, values: 5, scopes: 1,
                workloads: %w[eq_uniform eq_zipf explicit_null missing filters_3 hydrate_1k bulk_1k] },
    "A100" => { hosts: 100_000, definitions: 50, values: 20, scopes: 100,
                workloads: %w[eq_uniform eq_zipf int_range date_range sort_limit prefix contains array_contains explicit_null missing include_missing filters_3 filters_10 filters_20 hydrate_one hydrate_1k cross_scope insert_one update_one create_20 bulk_1k bulk_100k backfill deletion versioned_mutation] },
    "H100" => { hosts: 100_000, definitions: 200, values: 100, scopes: 10_000,
                workloads: %w[eq_uniform contains array_contains missing filters_20 hydrate_1k cross_scope bulk_100k deletion] },
    "A1M" => { hosts: 1_000_000, definitions: 50, values: 20, scopes: 100,
                workloads: %w[eq_uniform int_range date_range sort_limit prefix contains array_contains explicit_null missing filters_20 hydrate_1k cross_scope bulk_100k] },
  }.freeze
  ADAPTERS = %w[typed_eav jsonb per_type_eav sql].freeze
  FACTOR_SMOKE_PROFILES = %w[L100 H100 A1M].freeze
  FACTOR_SMOKE_UNSUPPORTED = %w[missing sort_limit].freeze
  FACTOR_SMOKE_QUERY_WORKLOADS = {
    "L100" => %w[eq_uniform eq_zipf explicit_null filters_3],
    "H100" => %w[eq_uniform contains array_any filters_20 cross_scope_admin],
    "A1M" => %w[eq_uniform integer_range date_range prefix contains array_any explicit_null filters_20 cross_scope_admin],
  }.freeze
  FACTOR_QUERY_NAME_MAP = {
    "array_any" => "array_contains", "integer_range" => "int_range", "cross_scope_admin" => "cross_scope",
  }.freeze
  FACTOR_SMOKE_WRITE_WORKLOADS = {
    "L100" => %w[bulk_1k],
    "H100" => %w[bulk_100k physical_field_delete],
    "A1M" => %w[bulk_100k],
  }.freeze
  FACTOR_LIMITATIONS = {
    "L100" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
    "H100" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
    "A1M" => { "status" => "bounded", "reason" => "factorized public/common contender cells are measured only in A100" },
  }.freeze

  # Loads each physical contender from the sealed oracle.  It performs no
  # workload measurements; its only job is to prove that all four layouts
  # represent the same logical cells under fair, explicit index contracts.
  class ContenderLoader
    PT_TYPES = %w[integer decimal boolean date datetime text json].freeze
    DISPOSABLE_DATABASE = /\Atyped_eav_t123_[a-z0-9_]+\z/

    def initialize(connection)
      @connection = connection
      @quote = connection.method(:quote)
    end

    def call(name:, declared:, effective_hosts:, logical_definitions:, oracle_manifest:, mode:)
      assert_disposable_database!
      prepare_hosts(logical_definitions)
      oracle_before = oracle_compact_digest
      evidence = {}
      evidence["typed_eav"] = measure_load("typed_eav") { load_typed_eav }
      evidence["jsonb"] = measure_load("jsonb") { load_jsonb }
      evidence["per_type_eav"] = measure_load("per_type_eav") { load_per_type }
      evidence["sql"] = measure_load("sql") { load_sql(logical_definitions) }
      analyze_loaded_relations
      expected = semantic_digest(expected_semantic_sql)
      winner = winner_digest(oracle_winner_sql)
      evidence.each do |adapter, result|
        actual = semantic_digest(semantic_sql(adapter, logical_definitions))
        result["semantic_digest"] = actual
        result["oracle_digest"] = expected
        result["semantic_equal"] = actual == expected
        raise "#{name} #{adapter} load identity mismatch" unless actual == expected
      end
      %w[typed_eav per_type_eav].each do |adapter|
        actual = winner_digest(winner_sql(adapter))
        evidence.fetch(adapter)["physical_winner_digest"] = actual
        evidence.fetch(adapter)["oracle_physical_winner_digest"] = winner
        evidence.fetch(adapter)["physical_winner_equal"] = actual == winner
        raise "#{name} #{adapter} physical winner mismatch" unless actual == winner
      end
      if (mode == "factor-smoke" || mode == "representative") && FACTOR_SMOKE_PROFILES.include?(name)
        if FACTOR_SMOKE_PROFILES.include?(name)
          factor_workloads = FACTOR_SMOKE_QUERY_WORKLOADS.fetch(name)
          scope_protocol = factor_scope_protocol
          public_queries = PublicTypedEAVQueryProbe.new(@connection).call(
            effective_hosts: effective_hosts,
            logical_definitions: logical_definitions,
            workloads: factor_workloads,
            include_hydration: true,
            factor_hydration: true,
            scope_protocol: scope_protocol,
          )
          common_queries = CommonContenderQueryProbe.new(@connection, scope_protocol: scope_protocol).call(
            public_queries, workloads: factor_workloads,
          )
          common_hydration = CommonContenderQueryProbe.new(@connection).hydration(
            count: [effective_hosts, 1_000].min,
            logical_definitions: logical_definitions,
            oracle_identity: public_queries.fetch("hydration").fetch([effective_hosts, 1_000].min.to_s).fetch("oracle_identity"),
          )
          common_writes = CommonWriteProbe.new(
            @connection,
            logical_definitions: logical_definitions,
            semantic_sql: method(:semantic_sql),
            semantic_digest: method(:semantic_digest),
            physical_reset: -> { reset_write_baseline(logical_definitions) },
            initial_physical_baseline: write_reset_baseline(evidence),
            workloads: FACTOR_SMOKE_WRITE_WORKLOADS.fetch(name),
          ).call
          evidence["factor_observations"] = factor_smoke_observations(
            name, evidence, expected, public_queries, common_queries, common_hydration, common_writes,
          )
        else
          evidence["factor_observations"] = {}
        end
      elsif name == "A100"
        public_queries = PublicTypedEAVQueryProbe.new(@connection).call(
          effective_hosts: effective_hosts,
          logical_definitions: logical_definitions,
        )
        evidence["public_typed_eav"] = public_queries
        evidence["common_queries"] = CommonContenderQueryProbe.new(@connection).call(public_queries)
        evidence["common_writes"] = CommonWriteProbe.new(
          @connection,
          logical_definitions: logical_definitions,
          semantic_sql: method(:semantic_sql),
          semantic_digest: method(:semantic_digest),
          physical_reset: -> { reset_write_baseline(logical_definitions) },
          initial_physical_baseline: write_reset_baseline(evidence),
        ).call
      end
      raise "#{name} host count mismatch" unless @connection.select_value("SELECT count(*) FROM t121_hosts").to_i == effective_hosts
      oracle_after = oracle_compact_digest
      raise "#{name} oracle manifest does not match sealed tables" unless oracle_before == oracle_manifest.fetch("logical_digest")
      raise "#{name} oracle changed during contender load" unless oracle_after == oracle_before

      evidence["oracle_unchanged"] = true
      evidence["oracle_digest_before"] = oracle_before
      evidence["oracle_digest_after"] = oracle_after
      evidence["shared_hosts"] = effective_hosts
      evidence["shared_host"] = shared_host_manifest
      evidence["logical_definitions"] = logical_definitions
      evidence["declared_physical_definitions"] = declared.fetch(:definitions)
      evidence
    ensure
      cleanup
    end

    private

    def factor_smoke_observations(name, evidence, oracle_digest, public_evidence, common_evidence, common_hydration,
                                  common_writes)
      return {} unless FACTOR_SMOKE_PROFILES.include?(name)

      observations = {
        "load" => {
          "applicable_adapters" => ADAPTERS,
          "metrics" => evidence.slice(*ADAPTERS).transform_values do |result|
            {
              "execution_ms" => result.fetch("wall_ms"),
              "planning_ms" => 0.0,
              "rows" => result.fetch("relations").values.sum { |relation| relation.fetch("rows") },
              "wal_bytes" => result.fetch("wal_bytes"),
            }
          end,
          "oracle_semantic_digest" => oracle_digest,
          "semantic_digests" => evidence.slice(*ADAPTERS).transform_values { |result| result.fetch("semantic_digest") },
          "status" => "measured",
          "workload" => "load",
        },
        "missing" => {
          "reason" => "no shipped pure-missing public operator; include_missing is different; no raw substitute was measured",
          "status" => "unsupported",
          "workload" => "missing",
        },
      }
      hydration_count = public_evidence.fetch("hydration").keys.map(&:to_i).max
      public_hydration = public_evidence.fetch("hydration").fetch(hydration_count.to_s)
      hydration_oracle = public_hydration.fetch("oracle_identity")
      hydration_identities = {
        "typed_eav" => public_hydration.fetch("identity"),
        **common_hydration.transform_values { |row| row.fetch("identity") },
      }
      raise "#{name} hydrate_1k factor identity mismatch" unless hydration_identities.values.all? { |identity| identity == hydration_oracle }
      hydration_plans = {
        "typed_eav" => public_hydration.fetch("plans"),
        **common_hydration.transform_values { |row| [row.fetch("plan")] },
      }
      observations["hydrate_1k"] = factor_query_observation(
        "hydrate_1k", hydration_oracle, hydration_identities, hydration_plans,
      )
      FACTOR_SMOKE_QUERY_WORKLOADS.fetch(name).each do |public_name|
        cell = FACTOR_QUERY_NAME_MAP.fetch(public_name, public_name)
        public_query = public_evidence.fetch("queries").fetch(public_name)
        common_query = common_evidence.fetch("queries").fetch(public_name)
        oracle_identity = public_query.fetch("oracle_identity")
        identities = ADAPTERS.to_h do |adapter|
          [adapter, common_query.fetch(adapter).fetch("identity")]
        end
        raise "#{name} #{cell} factor identity mismatch" unless identities.values.all? { |identity| identity == oracle_identity }
        plans = ADAPTERS.to_h do |adapter|
          [adapter, [common_query.fetch(adapter).fetch("plan")]]
        end
        metrics = ADAPTERS.to_h do |adapter|
          plan = common_query.fetch(adapter).fetch("plan").fetch(0)
          root = plan.fetch("Plan")
          [adapter, {
            "execution_ms" => plan.fetch("Execution Time"),
            "planning_ms" => plan.fetch("Planning Time"),
            "rows" => root.fetch("Actual Rows"),
            "wal_bytes" => root.fetch("WAL Bytes"),
          }]
        end
        observations[cell] = factor_query_observation(cell, oracle_identity, identities, plans)
      end
      FACTOR_SMOKE_WRITE_WORKLOADS.fetch(name).each do |physical_workload|
        cell = physical_workload == "physical_field_delete" ? "deletion" : physical_workload
        expected_observations = CommonWriteProbe::ORDERS.length * ADAPTERS.length *
                                FACTOR_SMOKE_WRITE_WORKLOADS.fetch(name).length
        raise "#{name} factor write workload order drift" unless common_writes.fetch("workloads") == FACTOR_SMOKE_WRITE_WORKLOADS.fetch(name)
        summary = common_writes.fetch("summary")
        raise "#{name} factor write observation count" unless summary.fetch("observations") == expected_observations &&
                                                               summary.fetch("expected_observations") == expected_observations
        %w[all_baselines_restored no_no_ops post_states_equal full_plans_every_trial plan_hash_every_trial].each do |flag|
          raise "#{name} factor write #{flag}" unless summary.fetch(flag) == true
        end
        expected_resets = CommonWriteProbe::ORDERS.length *
                          (FACTOR_SMOKE_WRITE_WORKLOADS.fetch(name).include?("physical_field_delete") ? 2 : 1) + 1
        raise "#{name} factor write reset proof count" unless common_writes.fetch("physical_resets").length == expected_resets
        observations_by_adapter = ADAPTERS.to_h do |adapter|
          adapter_rows = common_writes.fetch("observations").select do |candidate|
            candidate.fetch("adapter") == adapter && candidate.fetch("workload") == physical_workload
          end
          raise "#{name} #{cell} factor observation count for #{adapter}" unless adapter_rows.length == 3 &&
                                                                                     adapter_rows.map { |row| row.fetch("trial") }.sort == [1, 2, 3]

          target_key = physical_workload == "bulk_1k" ? "bulk_1k_effective" : "bulk_100k_effective"
          target_key = "field_delete_rows" if physical_workload == "physical_field_delete"
          expected_rows = common_writes.fetch("targets").fetch(target_key)
          raise "#{name} #{cell} factor target rows for #{adapter}" unless adapter_rows.all? do |row|
            row.fetch("statement_rows").sum == expected_rows
          end

          [adapter, adapter_rows]
        end
        oracle_post_state = observations_by_adapter.fetch("typed_eav").first.fetch("oracle_post_state_digest")
        post_states = observations_by_adapter.to_h do |adapter, observations|
          digests = observations.map { |row| row.fetch("post_state_digest") }
          raise "#{name} #{cell} factor post-state drift for #{adapter}" unless digests.all? { |digest| digest == oracle_post_state }

          [adapter, digests.first]
        end
        observations[cell] = {
          "applicable_adapters" => ADAPTERS,
          "metrics" => observations_by_adapter.transform_values do |rows|
            statement_rows = rows.map { |row| row.fetch("statement_rows").sum }
            raise "#{name} #{cell} factor affected-row drift" unless statement_rows.uniq.length == 1

            {
              "execution_ms" => median(rows.map do |row|
                row.fetch("plans").sum { |plan| plan.fetch(0).fetch("Execution Time") }
              end),
              "planning_ms" => median(rows.map do |row|
                row.fetch("plans").sum { |plan| plan.fetch(0).fetch("Planning Time") }
              end),
              "rows" => statement_rows.first,
              "wal_bytes" => median(rows.map { |row| row.fetch("storage_plan_wal_bytes") }),
            }
          end,
          "oracle_post_state_digest" => oracle_post_state,
          "oracle_semantic_digest" => oracle_digest,
          "post_state_digests" => post_states,
          "semantic_digests" => evidence.slice(*ADAPTERS).transform_values { |result| result.fetch("semantic_digest") },
          "status" => "measured",
          "workload" => cell,
        }
      end
      if name == "A1M"
        observations["sort_limit"] = {
          "reason" => "no public typed-field sort API; no raw SQL substitute was measured",
          "status" => "unsupported",
          "workload" => "sort_limit",
        }
      end
      observations
    end

    def median(values)
      ordered = values.sort
      middle = ordered.length / 2
      ordered.length.odd? ? ordered.fetch(middle) : (ordered.fetch(middle - 1) + ordered.fetch(middle)) / 2.0
    end

    def factor_query_observation(workload, oracle_identity, identities, plans)
      metrics = plans.transform_values do |adapter_plans|
        plan_envelopes = adapter_plans.map { |plan| plan.fetch(0) }
        {
          "execution_ms" => plan_envelopes.sum { |plan| plan.fetch("Execution Time") },
          "planning_ms" => plan_envelopes.sum { |plan| plan.fetch("Planning Time") },
          "rows" => plan_envelopes.sum { |plan| plan.fetch("Plan").fetch("Actual Rows") },
          "wal_bytes" => plan_envelopes.sum { |plan| plan.fetch("Plan").fetch("WAL Bytes") },
        }
      end
      {
        "applicable_adapters" => ADAPTERS,
        "identities" => identities,
        "metrics" => metrics,
        "oracle_identity" => oracle_identity,
        "plans" => plans,
        "status" => "measured",
        "workload" => workload,
      }
    end

    def prepare_hosts(logical_definitions)
      cleanup
      assert_typed_eav_indexes!
      @connection.execute(<<~SQL)
        INSERT INTO projects (id, name, tenant_id, workspace_id, created_at, updated_at)
        SELECT ordinal + 1, 'T121 project ' || ordinal, scope, parent_scope, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM t121_oracle_hosts ORDER BY ordinal
      SQL
      @connection.execute(<<~SQL)
        SELECT setval(pg_get_serial_sequence('projects', 'id'),
                      GREATEST((SELECT COALESCE(max(id), 1) FROM projects), 1), true)
      SQL
      @connection.execute("CREATE INDEX IF NOT EXISTS t121_projects_scope_tuple ON projects(tenant_id, workspace_id, id)")
      definition = @connection.select_value(<<~SQL)
        SELECT indexdef FROM pg_indexes WHERE schemaname=current_schema()
          AND tablename='projects' AND indexname='t121_projects_scope_tuple'
      SQL
      raise "shared host tuple index missing" unless definition&.include?("(tenant_id, workspace_id, id)")
      @connection.execute(<<~SQL)
        CREATE TABLE t121_hosts AS
        SELECT p.id, h.ordinal, h.scope, h.parent_scope
        FROM t121_oracle_hosts h JOIN projects p ON p.id = h.ordinal + 1
      SQL
      @connection.execute("ALTER TABLE t121_hosts ADD PRIMARY KEY (id)")
      @connection.execute("CREATE UNIQUE INDEX t121_hosts_ordinal ON t121_hosts(ordinal)")
      @connection.execute("CREATE INDEX t121_hosts_scope ON t121_hosts(scope, parent_scope, ordinal)")
      create_json_schema
      create_per_type_schema
      create_sql_schema(logical_definitions)
    end

    def factor_scope_protocol
      regular = @connection.select_one(<<~SQL)
        SELECT h.scope, h.parent_scope
        FROM t121_oracle_hosts h
        WHERE EXISTS (
          SELECT 1 FROM t121_oracle_cells c
          WHERE c.ordinal=h.ordinal AND c.logical_index=0 AND c.state='value'
            AND c.canonical_value='3'
        ) AND EXISTS (
          SELECT 1 FROM t121_oracle_cells c
          WHERE c.ordinal=h.ordinal AND c.logical_index=1 AND c.state='value'
            AND c.canonical_value='1'
        ) AND EXISTS (
          SELECT 1 FROM t121_oracle_cells c
          WHERE c.ordinal=h.ordinal AND c.logical_index=4 AND c.state='value'
            AND c.canonical_value='7'
        )
        ORDER BY h.ordinal LIMIT 1
      SQL
      null = @connection.select_one(<<~SQL)
        SELECT h.scope, h.parent_scope
        FROM t121_oracle_hosts h
        WHERE EXISTS (
          SELECT 1 FROM t121_oracle_cells c
          WHERE c.ordinal=h.ordinal AND c.logical_index=0 AND c.state='null'
        )
        ORDER BY h.ordinal LIMIT 1
      SQL
      raise "factor query protocol has no value-bearing host" unless regular
      raise "factor query protocol has no explicit-null host" unless null

      {
        "tenant" => regular.fetch("scope"),
        "parent_scope" => regular.fetch("parent_scope"),
        "null_tenant" => null.fetch("scope"),
        "null_parent_scope" => null.fetch("parent_scope"),
        "missing_tenant" => regular.fetch("scope"),
        "missing_parent_scope" => regular.fetch("parent_scope"),
      }
    end

    def load_typed_eav
      type_case = OracleFoundation::TYPE_ORDER.uniq.map do |type|
        "WHEN '#{type}' THEN '#{TYPE_CLASSES.fetch(type).name}'"
      end.join(" ")
      @connection.execute(<<~SQL)
        INSERT INTO typed_eav_fields
          (name, type, entity_type, scope, parent_scope, required, sort_order, options,
           default_value_meta, field_dependent, created_at, updated_at)
        SELECT logical_name, CASE type_name #{type_case} END, 'Project', scope, parent_scope,
               false, physical_definition, '{}'::jsonb, '{}'::jsonb, 'destroy', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM t121_oracle_definitions ORDER BY physical_definition
      SQL
      @connection.execute(<<~SQL)
        INSERT INTO typed_eav_values
          (entity_type, entity_id, field_id, string_value, boolean_value, integer_value,
           decimal_value, date_value, datetime_value, json_value, created_at, updated_at)
        SELECT 'Project', c.ordinal + 1, f.id,
               c.text_value, c.boolean_value, c.integer_value, c.decimal_value,
               c.date_value, c.datetime_value, c.json_value, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM t121_oracle_cells c
        JOIN t121_oracle_definitions d ON d.physical_definition = c.physical_definition
        JOIN typed_eav_fields f ON f.entity_type = 'Project' AND f.name = d.logical_name
          AND f.scope IS NOT DISTINCT FROM d.scope
          AND f.parent_scope IS NOT DISTINCT FROM d.parent_scope
        ORDER BY c.ordinal, c.logical_index
      SQL
    end

    def create_json_schema
      @connection.execute("CREATE TABLE t121_json(entity_id bigint PRIMARY KEY REFERENCES t121_hosts(id), payload jsonb NOT NULL)")
      @connection.execute("CREATE INDEX t121_json_document_gin ON t121_json USING gin(payload jsonb_path_ops)")
      @connection.execute("CREATE INDEX t121_json_integer_hot ON t121_json(((payload->>'f000')::bigint)) WHERE payload->>'f000' IS NOT NULL")
      @connection.execute("CREATE INDEX t121_json_zipf_hot ON t121_json(((payload->>'f001')::bigint)) WHERE payload->>'f001' IS NOT NULL")
      @connection.execute("CREATE INDEX t121_json_sort_hot ON t121_json(((payload->>'f004')::bigint)) WHERE payload->>'f004' IS NOT NULL")
      # PostgreSQL marks text-to-date casts STABLE, so they cannot appear in an
      # expression index.  The generator's canonical ISO-8601 dates preserve
      # chronological order under text_pattern_ops without a custom wrapper.
      @connection.execute("CREATE INDEX t121_json_date_iso_hot ON t121_json((payload->>'f005') text_pattern_ops) WHERE payload->>'f005' IS NOT NULL")
      @connection.execute("CREATE INDEX t121_json_text_prefix ON t121_json((payload->>'f002') text_pattern_ops) WHERE payload->>'f002' IS NOT NULL")
      @connection.execute("CREATE INDEX t121_json_array_hot ON t121_json USING gin((payload->'f006') jsonb_path_ops) WHERE jsonb_typeof(payload->'f006') = 'array'")
    end

    def load_jsonb
      @connection.execute(<<~SQL)
        INSERT INTO t121_json(entity_id, payload)
        SELECT h.ordinal + 1,
               jsonb_object_agg(c.logical_name,
                 CASE WHEN c.state = 'null' THEN 'null'::jsonb
                      WHEN c.type_name = 'integer' THEN to_jsonb(c.integer_value)
                      WHEN c.type_name = 'decimal' THEN to_jsonb(c.decimal_value)
                      WHEN c.type_name = 'boolean' THEN to_jsonb(c.boolean_value)
                      WHEN c.type_name = 'date' THEN to_jsonb(c.date_value)
                      WHEN c.type_name = 'datetime' THEN to_jsonb(c.datetime_value)
                      WHEN c.type_name = 'text' THEN to_jsonb(c.text_value)
                      ELSE c.json_value END ORDER BY c.logical_index)
        FROM t121_oracle_hosts h JOIN t121_oracle_cells c USING (ordinal)
        GROUP BY h.ordinal ORDER BY h.ordinal
      SQL
    end

    def create_per_type_schema
      @connection.execute(<<~SQL)
        CREATE TABLE t121_type_definitions(
          physical_definition integer PRIMARY KEY,
          logical_index integer NOT NULL,
          logical_name text NOT NULL,
          type_name text NOT NULL,
          scope text,
          parent_scope text,
          specificity integer NOT NULL
        )
      SQL
      @connection.execute("CREATE INDEX t121_type_definitions_lookup ON t121_type_definitions(logical_name, scope, parent_scope, specificity)")
      definitions = {
        "integer" => "value bigint", "decimal" => "value numeric", "boolean" => "value boolean",
        "date" => "value date", "datetime" => "value timestamp", "text" => "value text",
        "json" => "value jsonb",
      }
      definitions.each do |type, value_sql|
        table = "t121_type_#{type}"
        @connection.execute(<<~SQL)
          CREATE TABLE #{table}(
            entity_id bigint NOT NULL REFERENCES t121_hosts(id),
            physical_definition integer NOT NULL REFERENCES t121_type_definitions(physical_definition),
            state text NOT NULL CHECK (state IN ('value','null')),
            #{value_sql},
            PRIMARY KEY(entity_id, physical_definition)
          )
        SQL
        @connection.execute("CREATE INDEX #{table}_hydrate ON #{table}(entity_id) INCLUDE(physical_definition, state, value)")
      end
      %w[integer decimal boolean date datetime].each do |type|
        @connection.execute("CREATE INDEX t121_type_#{type}_lookup ON t121_type_#{type}(physical_definition, value) INCLUDE(entity_id) WHERE value IS NOT NULL")
      end
      @connection.execute("CREATE INDEX t121_type_text_lookup ON t121_type_text(physical_definition, value text_pattern_ops) INCLUDE(entity_id) WHERE value IS NOT NULL")
      @connection.execute("CREATE INDEX t121_type_json_lookup ON t121_type_json(physical_definition, entity_id)")
      @connection.execute("CREATE INDEX t121_type_json_value_gin ON t121_type_json USING gin(value jsonb_path_ops) WHERE value IS NOT NULL")
    end

    def load_per_type
      @connection.execute(<<~SQL)
        INSERT INTO t121_type_definitions
          (physical_definition, logical_index, logical_name, type_name, scope, parent_scope, specificity)
        SELECT physical_definition, logical_index, logical_name, type_name, scope, parent_scope, specificity
        FROM t121_oracle_definitions ORDER BY physical_definition
      SQL
      scalar = {
        "integer" => "integer_value", "decimal" => "decimal_value", "boolean" => "boolean_value",
        "date" => "date_value", "datetime" => "datetime_value", "text" => "text_value",
      }
      scalar.each do |type, column|
        @connection.execute(<<~SQL)
          INSERT INTO t121_type_#{type}(entity_id, physical_definition, state, value)
          SELECT ordinal + 1, physical_definition, state, #{column}
          FROM t121_oracle_cells WHERE type_name = '#{type}'
          ORDER BY ordinal, physical_definition
        SQL
      end
      @connection.execute(<<~SQL)
        INSERT INTO t121_type_json(entity_id, physical_definition, state, value)
        SELECT ordinal + 1, physical_definition, state, json_value
        FROM t121_oracle_cells WHERE type_name IN ('integer_array','text_array')
        ORDER BY ordinal, physical_definition
      SQL
    end

    def create_sql_schema(logical_definitions)
      columns = logical_definitions.times.flat_map do |index|
        type = OracleFoundation::TYPE_ORDER.fetch(index % OracleFoundation::TYPE_ORDER.length)
        sql_type = case type
                   when "integer" then "bigint"
                   when "decimal" then "numeric"
                   when "boolean" then "boolean"
                   when "date" then "date"
                   when "datetime" then "timestamp"
                   when "text" then "text"
                   when "integer_array" then "bigint[]"
                   when "text_array" then "text[]"
                   end
        ["f#{format('%03d', index)} #{sql_type}", "f#{format('%03d', index)}_present boolean NOT NULL"]
      end
      @connection.execute("CREATE TABLE t121_sql(id bigint PRIMARY KEY REFERENCES t121_hosts(id), #{columns.join(',')})")
      @connection.execute("CREATE INDEX t121_sql_integer_hot ON t121_sql(f000) WHERE f000_present AND f000 IS NOT NULL")
      @connection.execute("CREATE INDEX t121_sql_zipf_hot ON t121_sql(f001) WHERE f001_present AND f001 IS NOT NULL")
      @connection.execute("CREATE INDEX t121_sql_sort_hot ON t121_sql(f004) WHERE f004_present AND f004 IS NOT NULL")
      @connection.execute("CREATE INDEX t121_sql_date_hot ON t121_sql(f005) WHERE f005_present AND f005 IS NOT NULL")
      @connection.execute("CREATE INDEX t121_sql_text_prefix ON t121_sql(f002 text_pattern_ops) WHERE f002_present AND f002 IS NOT NULL")
      @connection.execute("CREATE INDEX t121_sql_array_hot ON t121_sql USING gin(f006) WHERE f006_present AND f006 IS NOT NULL")
    end

    def load_sql(logical_definitions)
      columns = ["id"]
      projections = ["h.ordinal + 1"]
      logical_definitions.times do |index|
        field = "f#{format('%03d', index)}"
        type = OracleFoundation::TYPE_ORDER.fetch(index % OracleFoundation::TYPE_ORDER.length)
        value = if type == "integer_array"
                  "ARRAY(SELECT element::bigint FROM jsonb_array_elements_text(c2.json_value) WITH ORDINALITY AS item(element, position) ORDER BY position)"
                elsif type == "text_array"
                  "ARRAY(SELECT element FROM jsonb_array_elements_text(c2.json_value) WITH ORDINALITY AS item(element, position) ORDER BY position)"
                else
                  "#{type}_value"
                end
        columns.concat([field, "#{field}_present"])
        projection = if %w[integer_array text_array].include?(type)
                       "(SELECT #{value} FROM t121_oracle_cells c2 WHERE c2.ordinal=h.ordinal AND c2.logical_index=#{index})"
                     else
                       "(array_agg(c.#{value} ORDER BY c.logical_index) FILTER (WHERE c.logical_index = #{index}))[1]"
                     end
        projections.concat([projection, "count(*) FILTER (WHERE c.logical_index = #{index}) > 0"])
      end
      @connection.execute(<<~SQL)
        INSERT INTO t121_sql(#{columns.join(',')})
        SELECT #{projections.join(',')}
        FROM t121_oracle_hosts h LEFT JOIN t121_oracle_cells c USING (ordinal)
        GROUP BY h.ordinal ORDER BY h.ordinal
      SQL
    end

    def measure_load(adapter)
      before = wal_lsn
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      relations = relations_for(adapter)
      {
        "wall_ms" => (elapsed * 1000).round(3),
        "wal_bytes" => wal_delta(before, wal_lsn),
        "relations" => relation_manifest(relations),
        "catalog" => catalog_manifest(relations),
      }
    end

    def analyze_loaded_relations
      relations = ["projects", "t121_hosts", *%w[typed_eav_fields typed_eav_values t121_json
                                                 t121_type_definitions t121_type_integer t121_type_decimal
                                                 t121_type_boolean t121_type_date t121_type_datetime
                                                 t121_type_text t121_type_json t121_sql]]
      relations.each { |relation| @connection.execute("ANALYZE #{relation}") }
    end

    def shared_host_manifest
      row = @connection.select_one(<<~SQL)
        SELECT indexes.indexdef, pg_relation_size(indexes.indexname::regclass)::bigint AS bytes,
               catalog.indisvalid, catalog.indisready
        FROM pg_indexes indexes
        JOIN pg_namespace namespace ON namespace.nspname=indexes.schemaname
        JOIN pg_class relation ON relation.relname=indexes.indexname AND relation.relnamespace=namespace.oid
        JOIN pg_index catalog ON catalog.indexrelid=relation.oid
        WHERE indexes.schemaname=current_schema() AND indexes.tablename='projects'
          AND indexes.indexname='t121_projects_scope_tuple'
      SQL
      raise "shared host tuple index is not valid/ready" unless row&.values_at("indisvalid", "indisready") == [true, true]

      row.merge("rows" => @connection.select_value("SELECT count(*) FROM projects").to_i,
                "excluded_equally_from_contender_bytes" => true)
    end

    def expected_semantic_sql
      <<~SQL
        SELECT c.ordinal, c.logical_index, c.type_name, c.state,
               c.canonical_value AS value
        FROM t121_oracle_cells c
      SQL
    end

    def semantic_sql(adapter, logical_definitions)
      case adapter
      when "typed_eav" then typed_eav_semantic_sql
      when "jsonb" then jsonb_semantic_sql
      when "per_type_eav" then per_type_semantic_sql
      when "sql" then sql_semantic_sql(logical_definitions)
      end
    end

    def typed_eav_semantic_sql
      <<~SQL
        SELECT h.ordinal, substring(f.name from 2)::integer AS logical_index,
               CASE f.type
                 WHEN 'TypedEAV::Field::Integer' THEN 'integer'
                 WHEN 'TypedEAV::Field::Decimal' THEN 'decimal'
                 WHEN 'TypedEAV::Field::Boolean' THEN 'boolean'
                 WHEN 'TypedEAV::Field::Date' THEN 'date'
                 WHEN 'TypedEAV::Field::DateTime' THEN 'datetime'
                 WHEN 'TypedEAV::Field::Text' THEN 'text'
                 WHEN 'TypedEAV::Field::IntegerArray' THEN 'integer_array'
                 WHEN 'TypedEAV::Field::TextArray' THEN 'text_array' END AS type_name,
               CASE WHEN num_nonnulls(v.integer_value, v.decimal_value, v.boolean_value, v.date_value,
                 v.datetime_value, v.string_value, v.json_value) = 0 THEN 'null' ELSE 'value' END AS state,
               CASE
                 WHEN num_nonnulls(v.integer_value, v.decimal_value, v.boolean_value, v.date_value,
                   v.datetime_value, v.string_value, v.json_value) = 0 THEN 'null'
                 WHEN f.type = 'TypedEAV::Field::Integer' THEN v.integer_value::text
                 WHEN f.type = 'TypedEAV::Field::Decimal' THEN trim(trailing '.' FROM trim(trailing '0' FROM v.decimal_value::text))
                 WHEN f.type = 'TypedEAV::Field::Boolean' THEN v.boolean_value::text
                 WHEN f.type = 'TypedEAV::Field::Date' THEN to_char(v.date_value, 'YYYY-MM-DD')
                 WHEN f.type = 'TypedEAV::Field::DateTime' THEN to_char(v.datetime_value, 'YYYY-MM-DD"T"HH24:MI:SS')
                 WHEN f.type = 'TypedEAV::Field::Text' THEN v.string_value
                 ELSE (SELECT string_agg(element, ',' ORDER BY position)
                       FROM jsonb_array_elements_text(v.json_value) WITH ORDINALITY AS item(element, position))
               END AS value
        FROM typed_eav_values v JOIN typed_eav_fields f ON f.id = v.field_id
        JOIN t121_hosts h ON h.id = v.entity_id
        WHERE v.entity_type = 'Project'
      SQL
    end

    def jsonb_semantic_sql
      <<~SQL
        SELECT h.ordinal, substring(entry.key from 2)::integer AS logical_index, d.type_name,
               CASE WHEN jsonb_typeof(entry.value) = 'null' THEN 'null' ELSE 'value' END AS state,
               CASE WHEN jsonb_typeof(entry.value) = 'null' THEN 'null'
                    WHEN d.type_name = 'integer' THEN (entry.value #>> '{}')::bigint::text
                    WHEN d.type_name = 'decimal' THEN trim(trailing '.' FROM trim(trailing '0' FROM (entry.value #>> '{}')::numeric::text))
                    WHEN d.type_name = 'boolean' THEN (entry.value #>> '{}')::boolean::text
                    WHEN d.type_name = 'date' THEN to_char((entry.value #>> '{}')::date, 'YYYY-MM-DD')
                    WHEN d.type_name = 'datetime' THEN to_char((entry.value #>> '{}')::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS')
                    WHEN d.type_name = 'text' THEN entry.value #>> '{}'
                    ELSE (SELECT string_agg(element, ',' ORDER BY position)
                          FROM jsonb_array_elements_text(entry.value) WITH ORDINALITY AS item(element, position))
               END AS value
        FROM t121_json j JOIN t121_hosts h ON h.id = j.entity_id
        CROSS JOIN LATERAL jsonb_each(j.payload) entry
        JOIN (SELECT DISTINCT ON (logical_index) logical_index, type_name
              FROM t121_oracle_definitions ORDER BY logical_index, specificity) d
          ON d.logical_index = substring(entry.key from 2)::integer
      SQL
    end

    def per_type_semantic_sql
      scalar = %w[integer decimal boolean date datetime text].map do |type|
        value = canonical_scalar("v.value", type)
        "SELECT h.ordinal, d.logical_index, d.type_name, v.state, " \
          "CASE WHEN v.state='null' THEN 'null' ELSE #{value} END AS value " \
          "FROM t121_type_#{type} v JOIN t121_type_definitions d USING (physical_definition) " \
          "JOIN t121_hosts h ON h.id=v.entity_id"
      end
      scalar << "SELECT h.ordinal, d.logical_index, d.type_name, v.state, CASE WHEN v.state='null' THEN 'null' ELSE (SELECT string_agg(element, ',' ORDER BY position) FROM jsonb_array_elements_text(v.value) WITH ORDINALITY AS item(element, position)) END AS value FROM t121_type_json v JOIN t121_type_definitions d USING (physical_definition) JOIN t121_hosts h ON h.id=v.entity_id"
      scalar.join(" UNION ALL ")
    end

    def sql_semantic_sql(logical_definitions)
      branches = logical_definitions.times.map do |index|
        field = "f#{format('%03d', index)}"
        type = OracleFoundation::TYPE_ORDER.fetch(index % OracleFoundation::TYPE_ORDER.length)
        value = if %w[integer_array text_array].include?(type)
                  "array_to_string(s.#{field}, ',')"
                else
                  canonical_scalar("s.#{field}", type)
                end
        "SELECT h.ordinal, #{index} AS logical_index, '#{type}' AS type_name, " \
          "CASE WHEN s.#{field} IS NULL THEN 'null' ELSE 'value' END AS state, " \
          "CASE WHEN s.#{field} IS NULL THEN 'null' ELSE #{value} END AS value " \
          "FROM t121_sql s JOIN t121_hosts h ON h.id=s.id WHERE s.#{field}_present"
      end
      branches.join(" UNION ALL ")
    end

    def semantic_digest(sql)
      row = @connection.select_one(<<~SQL)
        WITH material AS (#{sql}), hashed AS (
          SELECT hashtextextended(ordinal || '|' || logical_index || '|' || type_name || '|' || state || '|' || value, #{SEED}) AS a,
                 hashtextextended(ordinal || '|' || logical_index || '|' || type_name || '|' || state || '|' || value, #{SEED + 1}) AS b
          FROM material
        )
        SELECT count(*)::text AS count, COALESCE(sum(a::numeric),0)::text AS sum_a,
               COALESCE(bit_xor(a),0)::text AS xor_a, COALESCE(sum(b::numeric),0)::text AS sum_b,
               COALESCE(bit_xor(b),0)::text AS xor_b FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def oracle_winner_sql
      "SELECT ordinal, physical_definition FROM t121_oracle_cells"
    end

    def winner_sql(adapter)
      return typed_eav_winner_sql if adapter == "typed_eav"

      PT_TYPES.map do |type|
        "SELECT h.ordinal, v.physical_definition FROM t121_type_#{type} v JOIN t121_hosts h ON h.id=v.entity_id"
      end.join(" UNION ALL ")
    end

    def typed_eav_winner_sql
      <<~SQL
        SELECT h.ordinal, d.physical_definition
        FROM typed_eav_values v
        JOIN typed_eav_fields f ON f.id = v.field_id
        JOIN t121_oracle_definitions d ON d.logical_name = f.name
          AND d.scope IS NOT DISTINCT FROM f.scope
          AND d.parent_scope IS NOT DISTINCT FROM f.parent_scope
        JOIN t121_hosts h ON h.id = v.entity_id
        WHERE v.entity_type = 'Project' AND f.entity_type = 'Project'
      SQL
    end

    def winner_digest(sql)
      row = @connection.select_one(<<~SQL)
        WITH material AS (#{sql}), hashed AS (
          SELECT hashtextextended(ordinal || '|' || physical_definition, #{SEED}) AS value
          FROM material
        )
        SELECT count(*)::text AS count, COALESCE(sum(value::numeric),0)::text AS sum,
               COALESCE(bit_xor(value),0)::text AS xor FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def canonical_scalar(expression, type)
      case type
      when "decimal" then "trim(trailing '.' FROM trim(trailing '0' FROM #{expression}::text))"
      when "date" then "to_char(#{expression}, 'YYYY-MM-DD')"
      when "datetime" then "to_char(#{expression}, 'YYYY-MM-DD\"T\"HH24:MI:SS')"
      else "#{expression}::text"
      end
    end

    def oracle_compact_digest
      row = @connection.select_one(<<~SQL)
        WITH material AS (
          SELECT 'host|' || ordinal || '|' || data_ordinal || '|' || scope || '|' || parent_scope || '|' || version_cohort AS value
          FROM t121_oracle_hosts
          UNION ALL
          SELECT 'definition|' || physical_definition || '|' || logical_index || '|' || logical_name || '|' ||
                 type_name || '|' || family || '|' || COALESCE(scope, '') || '|' || COALESCE(parent_scope, '') || '|' || specificity
          FROM t121_oracle_definitions
          UNION ALL
          SELECT 'cell|' || c.ordinal || '|' || h.data_ordinal || '|' || h.scope || '|' || h.parent_scope || '|' ||
                 h.version_cohort || '|' || c.logical_index || '|' || c.physical_definition || '|' ||
                 c.winner_specificity || '|' || c.type_name || '|' || c.family || '|' || c.state || '|' || c.canonical_value
          FROM t121_oracle_cells c JOIN t121_oracle_hosts h USING (ordinal)
        ), hashed AS (
          SELECT hashtextextended(value, #{SEED}) AS hash_a,
                 hashtextextended(value, #{SEED + 1}) AS hash_b FROM material
        )
        SELECT count(*)::text AS count,
               COALESCE(sum(hash_a::numeric), 0)::text AS sum_a,
               COALESCE(bit_xor(hash_a), 0)::text AS xor_a,
               COALESCE(sum(hash_b::numeric), 0)::text AS sum_b,
               COALESCE(bit_xor(hash_b), 0)::text AS xor_b
        FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def assert_typed_eav_indexes!
      expected = %w[
        idx_te_values_field_int_present idx_te_values_field_dec_present
        idx_te_values_field_date_present idx_te_values_field_dt_present
        idx_te_values_field_bool_present idx_te_values_field_str_present
      ]
      rows = @connection.select_rows(<<~SQL).to_h
        SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = current_schema() AND tablename = 'typed_eav_values'
          AND indexname IN (#{expected.map { |name| @quote.call(name) }.join(',')})
      SQL
      raise "fresh migrated database is missing TypedEAV partial indexes" unless rows.keys.sort == expected.sort
      unless rows.values.all? { |definition| definition.include?("INCLUDE (entity_id)") && definition.include?("WHERE") && definition.include?("IS NOT NULL") && !definition.include?("entity_type)") }
        raise "TypedEAV scalar index catalog does not match partial-covering policy"
      end
    end

    def relations_for(adapter)
      case adapter
      when "typed_eav" then %w[typed_eav_fields typed_eav_values]
      when "jsonb" then %w[t121_json]
      when "per_type_eav" then ["t121_type_definitions", *PT_TYPES.map { |type| "t121_type_#{type}" }]
      when "sql" then %w[t121_sql]
      end
    end

    def reset_write_baseline(logical_definitions)
      relations = %w[typed_eav_value_versions typed_eav_values typed_eav_fields t121_json
                     t121_type_integer t121_type_decimal t121_type_boolean t121_type_date
                     t121_type_datetime t121_type_text t121_type_json t121_type_definitions t121_sql]
      @connection.execute("TRUNCATE #{relations.join(', ')} RESTART IDENTITY CASCADE")
      load_typed_eav
      load_jsonb
      load_per_type
      load_sql(logical_definitions)
      analyze_loaded_relations

      proof = %w[typed_eav jsonb per_type_eav sql].to_h do |adapter|
        names = relations_for(adapter)
        [adapter, {
          "semantic_digest" => semantic_digest(semantic_sql(adapter, logical_definitions)),
          "relations" => relation_manifest(names),
        }]
      end
      raise "physical reset semantic mismatch" unless proof.values.map { |value| value.fetch("semantic_digest") }.uniq.one?

      proof
    end

    def relation_manifest(relations)
      relations.to_h do |relation|
        row = @connection.select_one(<<~SQL)
          SELECT pg_relation_size(#{@quote.call(relation)}::regclass)::bigint AS heap,
                 pg_indexes_size(#{@quote.call(relation)}::regclass)::bigint AS indexes,
                 pg_total_relation_size(#{@quote.call(relation)}::regclass)::bigint AS total,
                 pg_relation_filenode(#{@quote.call(relation)}::regclass)::bigint AS filenode
        SQL
        index_filenodes = @connection.select_rows(<<~SQL).to_h.transform_values(&:to_i)
          SELECT index_relation.relname,
                 pg_relation_filenode(index_relation.oid)::bigint
          FROM pg_index indexes
          JOIN pg_class index_relation ON index_relation.oid = indexes.indexrelid
          WHERE indexes.indrelid = #{@quote.call(relation)}::regclass
          ORDER BY index_relation.relname
        SQL
        [relation, row.transform_values(&:to_i).merge(
          "rows" => @connection.select_value("SELECT count(*) FROM #{relation}").to_i,
          "index_filenodes" => index_filenodes,
        )]
      end
    end

    def write_reset_baseline(evidence)
      ADAPTERS.to_h do |adapter|
        contender = evidence.fetch(adapter)
        [adapter, contender.slice("semantic_digest", "relations")]
      end
    end

    def catalog_manifest(relations)
      indexes = @connection.select_rows(<<~SQL)
        SELECT indexes.tablename, indexes.indexname, indexes.indexdef,
               pg_relation_size(indexes.indexname::regclass)::bigint AS bytes,
               catalog.indisvalid, catalog.indisready,
               COALESCE(string_agg(opclass.opcname, ',' ORDER BY keys.ordinality), '') AS opclasses
        FROM pg_indexes indexes
        JOIN pg_namespace index_namespace ON index_namespace.nspname = indexes.schemaname
        JOIN pg_class index_relation ON index_relation.relname = indexes.indexname
          AND index_relation.relnamespace = index_namespace.oid
        JOIN pg_index catalog ON catalog.indexrelid = index_relation.oid
        LEFT JOIN LATERAL unnest(catalog.indclass::oid[]) WITH ORDINALITY keys(opclass_oid, ordinality) ON true
        LEFT JOIN pg_opclass opclass ON opclass.oid = keys.opclass_oid
        WHERE indexes.schemaname = current_schema() AND indexes.tablename IN (#{relations.map { |name| @quote.call(name) }.join(',')})
        GROUP BY indexes.tablename, indexes.indexname, indexes.indexdef, catalog.indisvalid, catalog.indisready
        ORDER BY tablename, indexname
      SQL
      columns = @connection.select_rows(<<~SQL)
        SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name IN (#{relations.map { |name| @quote.call(name) }.join(',')})
        ORDER BY table_name, ordinal_position
      SQL
      { "indexes" => indexes, "columns" => columns,
        "sha256" => Digest::SHA256.hexdigest(JSON.generate([indexes, columns])) }
    end

    def wal_lsn
      @connection.select_value("SELECT pg_current_wal_lsn()")
    end

    def wal_delta(before, after_lsn)
      @connection.select_value("SELECT pg_wal_lsn_diff(#{@quote.call(after_lsn)}, #{@quote.call(before)})").to_i
    end

    def cleanup
      assert_disposable_database!
      %w[t121_type_json t121_type_text t121_type_datetime t121_type_date t121_type_boolean
         t121_type_decimal t121_type_integer t121_type_definitions t121_json t121_sql t121_hosts].each do |table|
        @connection.execute("DROP TABLE IF EXISTS #{table} CASCADE")
      end
      @connection.execute("DROP INDEX IF EXISTS t121_projects_scope_tuple")
      reset = %w[typed_eav_value_versions typed_eav_values typed_eav_fields projects].select { |table| table_exists?(table) }
      @connection.execute("TRUNCATE #{reset.join(', ')} RESTART IDENTITY CASCADE") if reset.any?
    end

    def assert_disposable_database!
      database = @connection.select_value("SELECT current_database()")
      raise "refusing destructive tournament cleanup outside typed_eav_t123_*" unless DISPOSABLE_DATABASE.match?(database)
    end

    def table_exists?(name)
      @connection.select_value("SELECT to_regclass(#{@quote.call(name)})").present?
    end
  end

  # Exercises only the common direct-storage boundary. It intentionally does
  # not claim host callbacks, Value persistence callbacks, or version rows.
  # TypedEAV-only operational semantics remain outside contender ranking.
  class CommonWriteProbe
    ADAPTERS = %w[typed_eav jsonb per_type_eav sql].freeze
    ORDERS = [ADAPTERS, ADAPTERS.rotate(1), ADAPTERS.rotate(2)].freeze
    WORKLOADS = %w[single_insert single_update create_20 bulk_1k bulk_100k physical_field_delete].freeze
    PRE_DELETE_WORKLOADS = WORKLOADS - %w[physical_field_delete]

    def initialize(connection, logical_definitions:, semantic_sql:, semantic_digest:, physical_reset:,
                   initial_physical_baseline:, workloads: WORKLOADS)
      @connection = connection
      @logical_definitions = logical_definitions
      @semantic_sql = semantic_sql
      @semantic_digest = semantic_digest
      @physical_reset = physical_reset
      @initial_physical_baseline = initial_physical_baseline
      @workloads = workloads
    end

    def call
      targets = target_manifest
      observations = []
      reset_proofs = []
      canonical_reset = @initial_physical_baseline
      previous_reset = canonical_reset
      pre_delete_workloads = @workloads - %w[physical_field_delete]
      ORDERS.each_with_index do |order, trial_index|
        reset = @physical_reset.call
        assert_reset_generation!(canonical_reset, previous_reset, reset, "rotation #{trial_index + 1}")
        reset_proofs << reset_evidence(trial_index + 1, "before_common_writes", canonical_reset, reset)
        previous_reset = reset
        baselines = ADAPTERS.to_h { |adapter| [adapter, adapter_digest(adapter)] }
        raise "common write baselines differ" unless baselines.values.uniq.one?
        order.each do |adapter|
          pre_delete_workloads.each do |workload|
            observations << run_one(adapter, workload, trial_index + 1, order, targets, baselines.fetch(adapter))
          end
        end
        if @workloads.include?("physical_field_delete")
          reset = @physical_reset.call
          assert_reset_generation!(canonical_reset, previous_reset, reset,
                                   "rotation #{trial_index + 1} pre-delete")
          reset_proofs << reset_evidence(trial_index + 1, "before_field_delete", canonical_reset, reset)
          previous_reset = reset
          baselines = ADAPTERS.to_h { |adapter| [adapter, adapter_digest(adapter)] }
          order.each do |adapter|
            observations << run_one(adapter, "physical_field_delete", trial_index + 1, order, targets, baselines.fetch(adapter))
          end
        end
      end
      assert_equal_post_states!(observations)
      final_reset = @physical_reset.call
      assert_reset_generation!(canonical_reset, previous_reset, final_reset, "final")
      reset_proofs << reset_evidence(ORDERS.length, "final", canonical_reset, final_reset)
      raise "common write final baselines drifted" unless ADAPTERS.all? do |adapter|
        adapter_digest(adapter) == canonical_reset.fetch(adapter).fetch("semantic_digest")
      end

      {
        "surface" => "common direct-storage SQL; reduced callback semantics are explicit",
        "metric_boundary" => {
          "mutation_wall_ms" => "common host setup plus contender storage DML; excludes post-state validation",
          "storage_wall_ms" => "contender-specific storage DML only",
          "validation_wall_ms" => "independent post-state digest only",
          "physical_reset" => "before each fixed rotation and again before field-wide deletion",
          "rotation_order" => "fixed small-to-large; bulk_100k is last before reset",
          "timestamps" => "as-shipped physical schemas: TypedEAV Value rows carry timestamps; alternative cells do not",
        },
        "orders" => ORDERS,
        "workloads" => @workloads,
        "targets" => targets,
        "observations" => observations,
        "physical_resets" => reset_proofs,
        "summary" => summarize(observations),
        "operational_only" => {
          "typed_eav" => {
            "backfill_pair" => { "status" => "deferred", "reason" => "requires later sequential snapshot-clone milestone" },
            "callback_preserving_deletion" => { "status" => "deferred", "reason" => "not a common physical contender ranking cell" },
            "versioned_mutation" => { "status" => "deferred", "reason" => "not a common physical contender ranking cell" },
          },
          "other_adapters" => { "status" => "not_applicable", "reason" => "TypedEAV operational API only" },
        },
      }
    end

    private

    def assert_reset_generation!(canonical, previous, candidate, label)
      raise "#{label} semantic or row reset differs" unless reset_semantics_and_rows_equal?(canonical, candidate)
      raise "#{label} reused physical storage generation" unless reset_generation_rotated?(previous, candidate)
    end

    def reset_evidence(trial, stage, canonical, proof)
      {
        "trial" => trial,
        "stage" => stage,
        "proof" => proof,
        "physical_bytes_equal" => reset_physical_bytes(proof) == reset_physical_bytes(canonical),
      }
    end

    def reset_semantics_and_rows_equal?(canonical, candidate)
      ADAPTERS.all? do |adapter|
        expected = canonical.fetch(adapter)
        actual = candidate.fetch(adapter)
        next false unless actual.fetch("semantic_digest") == expected.fetch("semantic_digest")

        expected_relations = expected.fetch("relations")
        actual_relations = actual.fetch("relations")
        actual_relations.keys.sort == expected_relations.keys.sort && expected_relations.all? do |relation, manifest|
          actual_relations.fetch(relation).fetch("rows") == manifest.fetch("rows")
        end
      end
    end

    def reset_generation_rotated?(previous, candidate)
      ADAPTERS.all? do |adapter|
        prior_relations = previous.fetch(adapter).fetch("relations")
        current_relations = candidate.fetch(adapter).fetch("relations")
        prior_relations.keys.sort == current_relations.keys.sort && prior_relations.all? do |relation, manifest|
          current = current_relations.fetch(relation)
          prior_indexes = manifest.fetch("index_filenodes")
          current_indexes = current.fetch("index_filenodes")
          current.fetch("filenode") != manifest.fetch("filenode") &&
            prior_indexes.keys.sort == current_indexes.keys.sort &&
            prior_indexes.all? { |index, filenode| current_indexes.fetch(index) != filenode }
        end
      end
    end

    def reset_physical_bytes(proof)
      proof.transform_values do |adapter|
        adapter.fetch("relations").transform_values { |manifest| manifest.slice("heap", "indexes", "total") }
      end
    end

    def run_one(adapter, workload, trial, order, targets, baseline)
      plans = nil
      common_host_plans = []
      post_state = nil
      wal_bytes = nil
      mutation_wall_ms = nil
      storage_wall_ms = nil
      validation_wall_ms = nil
      @connection.transaction(requires_new: true) do
        before_lsn = @connection.select_value("SELECT pg_current_wal_lsn()")
        mutation_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        common_host_plans = setup_create_host(targets) if workload == "create_20"
        storage_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        plans = write_sql(adapter, workload, targets).map { |sql| execute_plan(sql) }
        storage_wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - storage_started) * 1000).round(3)
        mutation_wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - mutation_started) * 1000).round(3)
        validation_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        post_state = adapter_digest(adapter)
        validation_wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - validation_started) * 1000).round(3)
        after_lsn = @connection.select_value("SELECT pg_current_wal_lsn()")
        wal_bytes = @connection.select_value(
          "SELECT pg_wal_lsn_diff(#{@connection.quote(after_lsn)}, #{@connection.quote(before_lsn)})"
        ).to_i
        raise ActiveRecord::Rollback
      end
      restored = adapter_digest(adapter)
      raise "#{workload} #{adapter} rollback drift" unless restored == baseline
      raise "#{workload} #{adapter} was a no-op" if post_state == baseline
      expected = oracle_post_digest(workload, targets)
      raise "#{workload} #{adapter} differs from independent oracle delta" unless post_state == expected
      expected_delta = {
        "single_insert" => 1,
        "create_20" => 20,
        "physical_field_delete" => -targets.fetch("field_delete_rows"),
      }.fetch(workload, 0)
      actual_delta = post_state.fetch("count").to_i - baseline.fetch("count").to_i
      raise "#{workload} #{adapter} cell delta #{actual_delta}, expected #{expected_delta}" unless actual_delta == expected_delta

      plan_hash = Digest::SHA256.hexdigest(JSON.generate(plans, max_nesting: false))
      common_host_plan_hash = Digest::SHA256.hexdigest(JSON.generate(common_host_plans, max_nesting: false))
      statement_rows = plans.map { |plan| plan_source_rows(plan) }
      common_host_statement_rows = common_host_plans.map { |plan| plan_source_rows(plan) }
      expected_common_rows = workload == "create_20" ? [1, 1] : []
      unless common_host_statement_rows == expected_common_rows
        raise "#{workload} #{adapter} common host rows #{common_host_statement_rows.inspect}, expected #{expected_common_rows.inspect}"
      end
      expected_physical_rows = case workload
                               when "single_insert", "single_update" then 1
                               when "bulk_1k" then targets.fetch("bulk_1k_effective")
                               when "bulk_100k" then targets.fetch("bulk_100k_effective")
                               when "physical_field_delete" then targets.fetch("field_delete_rows")
                               end
      if expected_physical_rows && statement_rows.sum != expected_physical_rows
        raise "#{workload} #{adapter} affected #{statement_rows.sum} physical rows, expected #{expected_physical_rows}"
      end
      {
        "trial" => trial,
        "rotation" => order,
        "adapter" => adapter,
        "workload" => workload,
        "transaction" => "rollback",
        "commit_cost_included" => false,
        "semantic_surface" => "physical persistence only; no casting, validation, callback, or version claim",
        "storage_statement_count" => plans.length,
        "common_host_statement_count" => common_host_plans.length,
        "statement_rows" => statement_rows,
        "common_host_statement_rows" => common_host_statement_rows,
        "storage_plan_wal_bytes" => plans.sum { |plan| plan_root(plan).fetch("WAL Bytes", 0).to_i },
        "common_host_plan_wal_bytes" => common_host_plans.sum { |plan| plan_root(plan).fetch("WAL Bytes", 0).to_i },
        "total_plan_wal_bytes" => (plans + common_host_plans).sum { |plan| plan_root(plan).fetch("WAL Bytes", 0).to_i },
        "post_state_digest" => post_state,
        "oracle_post_state_digest" => expected,
        "baseline_restored" => true,
        "no_op" => false,
        "cell_count_delta" => actual_delta,
        "lsn_wal_bytes" => wal_bytes,
        "lsn_wal_scope" => "database-global diagnostic; per-plan WAL is the comparable cell metric",
        "mutation_wall_ms" => mutation_wall_ms,
        "storage_wall_ms" => storage_wall_ms,
        "validation_wall_ms" => validation_wall_ms,
        "plan_sha256" => plan_hash,
        "common_host_plan_sha256" => common_host_plan_hash,
        "common_host_plans" => common_host_plans,
        "plans" => plans,
      }
    end

    def target_manifest
      needs_source = (@workloads & %w[single_update create_20]).any?
      needs_missing = @workloads.include?("single_insert")
      source_id = if needs_source
                    if @workloads.include?("create_20")
                      @connection.select_value(<<~SQL)
                        SELECT h.ordinal + 1 FROM t121_oracle_hosts h
                        WHERE (SELECT count(*) FROM t121_oracle_cells c
                               WHERE c.ordinal=h.ordinal AND c.logical_index BETWEEN 0 AND 19 AND c.state='value') = 20
                        ORDER BY h.ordinal LIMIT 1
                      SQL
                    else
                      @connection.select_value(<<~SQL)
                        SELECT h.ordinal + 1 FROM t121_oracle_hosts h
                        WHERE EXISTS (SELECT 1 FROM t121_oracle_cells c
                                      WHERE c.ordinal=h.ordinal AND c.logical_index=4 AND c.state='value')
                        ORDER BY h.ordinal LIMIT 1
                      SQL
                    end
                  end
      missing_id = if needs_missing
                     @connection.select_value(<<~SQL)
                       SELECT h.ordinal + 1 FROM t121_oracle_hosts h
                       WHERE h.scope <> 'tenant_0'
                         AND NOT EXISTS (SELECT 1 FROM t121_oracle_cells c WHERE c.ordinal=h.ordinal AND c.logical_index=0)
                       ORDER BY h.ordinal LIMIT 1
                     SQL
                   end
      if needs_source || needs_missing
        raise "common write source/missing targets unavailable" if (needs_source && !source_id) || (needs_missing && !missing_id)
      end

      max_ordinal = @connection.select_value("SELECT max(ordinal) FROM t121_hosts").to_i
      manifest = {
        "source_id" => source_id&.to_i,
        "missing_id" => missing_id&.to_i,
        "new_ordinal" => max_ordinal + 1,
        "new_id" => max_ordinal + 2,
        "bulk_1k_effective" => [@connection.select_value("SELECT count(*) FROM t121_hosts").to_i, 1_000].min,
        "bulk_100k_effective" => [@connection.select_value("SELECT count(*) FROM t121_hosts").to_i, 100_000].min,
        "field_delete_rows" => @connection.select_value("SELECT count(*) FROM t121_oracle_cells WHERE logical_index=4").to_i,
        "insert_definition_contract" => "global f000 fallback",
        "update_definition" => "f004",
      }
      if needs_missing
        insert_definition = @connection.select_value(<<~SQL).to_i
          SELECT d.physical_definition FROM t121_oracle_hosts h
          JOIN LATERAL (
            SELECT physical_definition FROM t121_oracle_definitions d
            WHERE d.logical_index=0 AND (d.scope IS NULL OR d.scope=h.scope)
              AND (d.parent_scope IS NULL OR d.parent_scope=h.parent_scope)
            ORDER BY d.specificity DESC LIMIT 1
          ) d ON true WHERE h.ordinal=#{missing_id.to_i - 1}
        SQL
        raise "single insert target is not global-fallback f000" unless insert_definition.zero?
        manifest["insert_definition"] = insert_definition
      end
      raise "common write targets overlap" if needs_source && needs_missing && manifest.fetch("source_id") == manifest.fetch("missing_id")

      manifest
    end

    def setup_create_host(targets)
      source_id = targets.fetch("source_id")
      new_id = targets.fetch("new_id")
      new_ordinal = targets.fetch("new_ordinal")
      project_sql = <<~SQL
        INSERT INTO projects(id, name, tenant_id, workspace_id, created_at, updated_at)
        SELECT #{new_id}, 'T123 transaction-local project', tenant_id, workspace_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM projects WHERE id=#{source_id}
      SQL
      helper_sql = <<~SQL
        INSERT INTO t121_hosts(id, ordinal, scope, parent_scope)
        SELECT #{new_id}, #{new_ordinal}, scope, parent_scope FROM t121_hosts WHERE id=#{source_id}
      SQL
      [project_sql, helper_sql].map { |sql| execute_plan(sql) }
    end

    def write_sql(adapter, workload, targets)
      case workload
      when "single_insert" then [single_insert_sql(adapter, targets.fetch("missing_id"))]
      when "single_update" then [single_update_sql(adapter, targets.fetch("source_id"))]
      when "create_20" then create_20_sql(adapter, targets.fetch("source_id"), targets.fetch("new_id"))
      when "bulk_1k" then [bulk_update_sql(adapter, targets.fetch("bulk_1k_effective"))]
      when "bulk_100k" then [bulk_update_sql(adapter, targets.fetch("bulk_100k_effective"))]
      when "physical_field_delete" then [physical_field_delete_sql(adapter)]
      end
    end

    def single_insert_sql(adapter, id)
      case adapter
      when "typed_eav"
        <<~SQL.squish
          INSERT INTO typed_eav_values(entity_type, entity_id, field_id, integer_value, created_at, updated_at)
          SELECT 'Project', p.id, f.id, 42, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM projects p
          JOIN LATERAL (SELECT id FROM typed_eav_fields WHERE entity_type='Project' AND name='f000'
            AND (scope IS NULL OR scope=p.tenant_id) AND (parent_scope IS NULL OR parent_scope=p.workspace_id)
            ORDER BY CASE WHEN parent_scope IS NOT NULL THEN 2 WHEN scope IS NOT NULL THEN 1 ELSE 0 END DESC LIMIT 1) f ON true
          WHERE p.id=#{id}
        SQL
      when "jsonb" then "UPDATE t121_json SET payload=jsonb_set(payload, '{f000}', '42'::jsonb) WHERE entity_id=#{id}"
      when "per_type_eav"
        <<~SQL.squish
          INSERT INTO t121_type_integer(entity_id, physical_definition, state, value)
          SELECT p.id, d.physical_definition, 'value', 42 FROM projects p
          JOIN LATERAL (SELECT physical_definition FROM t121_type_definitions WHERE logical_name='f000'
            AND (scope IS NULL OR scope=p.tenant_id) AND (parent_scope IS NULL OR parent_scope=p.workspace_id)
            ORDER BY specificity DESC LIMIT 1) d ON true WHERE p.id=#{id}
        SQL
      when "sql" then "UPDATE t121_sql SET f000=42, f000_present=true WHERE id=#{id}"
      end
    end

    def single_update_sql(adapter, id)
      case adapter
      when "typed_eav" then "UPDATE typed_eav_values SET integer_value=99 WHERE entity_type='Project' AND entity_id=#{id} AND field_id IN (SELECT id FROM typed_eav_fields WHERE entity_type='Project' AND name='f004') AND integer_value IS NOT NULL"
      when "jsonb" then "UPDATE t121_json SET payload=jsonb_set(payload, '{f004}', '99'::jsonb) WHERE entity_id=#{id} AND jsonb_typeof(payload->'f004')='number'"
      when "per_type_eav" then "UPDATE t121_type_integer SET value=99 WHERE entity_id=#{id} AND physical_definition IN (SELECT physical_definition FROM t121_type_definitions WHERE logical_index=4) AND value IS NOT NULL"
      when "sql" then "UPDATE t121_sql SET f004=99 WHERE id=#{id} AND f004_present AND f004 IS NOT NULL"
      end
    end

    def physical_field_delete_sql(adapter)
      case adapter
      when "typed_eav" then "DELETE FROM typed_eav_values WHERE entity_type='Project' AND field_id IN (SELECT id FROM typed_eav_fields WHERE entity_type='Project' AND name='f004')"
      when "jsonb" then "UPDATE t121_json SET payload=payload-'f004' WHERE payload ? 'f004'"
      when "per_type_eav" then "DELETE FROM t121_type_integer WHERE physical_definition IN (SELECT physical_definition FROM t121_type_definitions WHERE logical_index=4)"
      when "sql" then "UPDATE t121_sql SET f004=NULL, f004_present=false WHERE f004_present"
      end
    end

    def create_20_sql(adapter, source_id, new_id)
      case adapter
      when "typed_eav"
        ["INSERT INTO typed_eav_values(entity_type, entity_id, field_id, string_value, boolean_value, integer_value, decimal_value, date_value, datetime_value, json_value, created_at, updated_at) SELECT entity_type, #{new_id}, field_id, string_value, boolean_value, integer_value, decimal_value, date_value, datetime_value, json_value, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM typed_eav_values WHERE entity_type='Project' AND entity_id=#{source_id}"]
      when "jsonb" then ["INSERT INTO t121_json(entity_id, payload) SELECT #{new_id}, payload FROM t121_json WHERE entity_id=#{source_id}"]
      when "per_type_eav"
        %w[integer decimal boolean date datetime text json].map do |type|
          "INSERT INTO t121_type_#{type}(entity_id, physical_definition, state, value) SELECT #{new_id}, physical_definition, state, value FROM t121_type_#{type} WHERE entity_id=#{source_id}"
        end
      when "sql"
        columns = @logical_definitions.times.flat_map { |index| name = "f#{format('%03d', index)}"; [name, "#{name}_present"] }
        ["INSERT INTO t121_sql(id, #{columns.join(',')}) SELECT #{new_id}, #{columns.join(',')} FROM t121_sql WHERE id=#{source_id}"]
      end
    end

    def bulk_update_sql(adapter, limit)
      ids = "SELECT id FROM t121_hosts ORDER BY ordinal LIMIT #{Integer(limit)}"
      case adapter
      when "typed_eav" then "UPDATE typed_eav_values SET integer_value=integer_value+1000 WHERE entity_type='Project' AND field_id IN (SELECT id FROM typed_eav_fields WHERE entity_type='Project' AND name='f004') AND integer_value IS NOT NULL AND entity_id IN (#{ids})"
      when "jsonb" then "UPDATE t121_json SET payload=jsonb_set(payload, '{f004}', to_jsonb((payload->>'f004')::bigint+1000)) WHERE jsonb_typeof(payload->'f004')='number' AND entity_id IN (#{ids})"
      when "per_type_eav" then "UPDATE t121_type_integer SET value=value+1000 WHERE physical_definition IN (SELECT physical_definition FROM t121_type_definitions WHERE logical_index=4) AND value IS NOT NULL AND entity_id IN (#{ids})"
      when "sql" then "UPDATE t121_sql SET f004=f004+1000 WHERE f004_present AND f004 IS NOT NULL AND id IN (#{ids})"
      end
    end

    def oracle_post_digest(workload, targets)
      base = <<~SQL
        SELECT ordinal, logical_index, type_name, state, canonical_value AS value
        FROM t121_oracle_cells
      SQL
      sql = case workload
            when "single_insert"
              <<~SQL
                #{base}
                UNION ALL
                SELECT #{targets.fetch("missing_id") - 1}, 0, 'integer', 'value', '42'
              SQL
            when "single_update"
              <<~SQL
                SELECT ordinal, logical_index, type_name, state,
                       CASE WHEN ordinal=#{targets.fetch("source_id") - 1} AND logical_index=4 THEN '99'
                            ELSE canonical_value END AS value
                FROM t121_oracle_cells
              SQL
            when "create_20"
              <<~SQL
                #{base}
                UNION ALL
                SELECT #{targets.fetch("new_ordinal")}, logical_index, type_name, state, canonical_value
                FROM t121_oracle_cells
                WHERE ordinal=#{targets.fetch("source_id") - 1} AND logical_index BETWEEN 0 AND 19
              SQL
            when "bulk_1k", "bulk_100k"
              limit = targets.fetch(workload == "bulk_1k" ? "bulk_1k_effective" : "bulk_100k_effective")
              <<~SQL
                SELECT ordinal, logical_index, type_name, state,
                       CASE WHEN ordinal < #{limit} AND logical_index=4
                            THEN (canonical_value::bigint + 1000)::text ELSE canonical_value END AS value
                FROM t121_oracle_cells
              SQL
            when "physical_field_delete"
              "#{base} WHERE logical_index <> 4"
            end
      @semantic_digest.call(sql)
    end

    def execute_plan(sql)
      value = @connection.select_value("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}")
      value.is_a?(String) ? JSON.parse(value, max_nesting: false) : value
    end

    def plan_root(plan)
      plan.fetch(0).fetch("Plan")
    end

    def plan_source_rows(plan)
      root = plan_root(plan)
      child = root.fetch("Plans", []).first
      (child || root).fetch("Actual Rows", 0).to_i
    end

    def adapter_digest(adapter)
      @semantic_digest.call(@semantic_sql.call(adapter, @logical_definitions))
    end

    def assert_equal_post_states!(observations)
      @workloads.each do |workload|
        1.upto(ORDERS.length) do |trial|
          rows = observations.select { |row| row.fetch("workload") == workload && row.fetch("trial") == trial }
          raise "#{workload} trial #{trial} adapter coverage mismatch" unless rows.map { |row| row.fetch("adapter") }.sort == ADAPTERS.sort
          raise "#{workload} trial #{trial} post-state mismatch" unless rows.map { |row| row.fetch("post_state_digest") }.uniq.one?
        end
      end
    end

    def summarize(observations)
      {
        "trials" => ORDERS.length,
        "observations" => observations.length,
        "expected_observations" => ORDERS.length * ADAPTERS.length * @workloads.length,
        "all_baselines_restored" => observations.all? { |row| row.fetch("baseline_restored") },
        "no_no_ops" => observations.none? { |row| row.fetch("no_op") },
        "post_states_equal" => true,
        "full_plans_every_trial" => true,
        "plan_hash_every_trial" => true,
      }
    end
  end

  # Compares the three alternative layouts to the already-approved public
  # TypedEAV query identities. It intentionally contains no adaptive planner,
  # write path, or unsupported raw TypedEAV substitute.
  class CommonContenderQueryProbe
    ADAPTERS = %w[jsonb per_type_eav sql].freeze
    SUPPORTED = %w[eq_uniform eq_zipf integer_range date_range prefix contains array_any explicit_null include_missing filters_3 filters_10 filters_20 cross_scope_admin].freeze
    TENANT = "tenant_11"
    PARENT_SCOPE = "workspace_2"
    NULL_TENANT = "tenant_10"
    NULL_PARENT_SCOPE = "workspace_1"
    MISSING_TENANT = "tenant_3"
    MISSING_PARENT_SCOPE = "workspace_0"

    def initialize(connection, scope_protocol: nil)
      @connection = connection
      @scope_protocol = scope_protocol || {
        "tenant" => TENANT, "parent_scope" => PARENT_SCOPE,
        "null_tenant" => NULL_TENANT, "null_parent_scope" => NULL_PARENT_SCOPE,
        "missing_tenant" => MISSING_TENANT, "missing_parent_scope" => MISSING_PARENT_SCOPE,
      }
    end

    def call(public_evidence, workloads: nil)
      raise "common/public query host protocol drift" unless public_evidence.fetch("scope_protocol") == @scope_protocol
      public_queries = public_evidence.fetch("queries")
      multi_filter_protocols = public_evidence.fetch("multi_filter_protocols")
      selected = workloads || SUPPORTED
      results = selected.to_h do |name|
        expected = public_queries.fetch(name).fetch("oracle_identity")
        adapters = ADAPTERS.to_h do |adapter|
          sql = query_sql(adapter, name, multi_filter_protocols)
          actual = id_digest(sql)
          raise "#{name} #{adapter} differs from public/oracle identity" unless actual == expected

          plan = @connection.select_value("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}")
          plan = JSON.parse(plan, max_nesting: false) if plan.is_a?(String)
          [adapter, { "surface" => "physical contender SQL", "identity" => actual,
                      "identity_equal" => true, "sql" => sql, "plan" => plan }]
        end
        typed = public_queries.fetch(name).slice("identity", "oracle_identity", "identity_equal", "public_sql", "plan")
        [name, { "typed_eav" => typed.merge("surface" => "public Project.where_typed_eav"), **adapters }]
      end
      {
        "support" => {
          "supported" => SUPPORTED,
          "pure_missing" => public_evidence.fetch("pure_missing"),
          "sort_limit" => public_evidence.fetch("sort_limit"),
        },
        "queries" => results,
        "contracts" => {
          "json_date_iso_index_compatible" => begin
            date_sql = results.dig("date_range", "jsonb", "sql")
            date_sql.nil? || !date_sql.include?("::date")
          end,
          "shared_host_tuple_index" => "t121_projects_scope_tuple",
          "text_semantics" => "ILIKE for every contender; no ordinary B-tree acceleration claim",
          "multi_filter_distinct_fields" => multi_filter_protocols.transform_values do |protocol|
            names = protocol.map { |filter| filter.fetch("name") }
            { "count" => names.length, "unique" => names.uniq.length == names.length, "names" => names }
          end,
        },
      }
    end

    def hydration(count:, logical_definitions:, oracle_identity:)
      ADAPTERS.to_h do |adapter|
        sql = hydration_sql(adapter, count, logical_definitions)
        actual = hydration_digest(sql)
        raise "#{adapter} hydration identity mismatch" unless actual == oracle_identity

        [adapter, { "identity" => actual, "plan" => explain_plan(sql), "sql" => sql }]
      end
    end

    private

    def hydration_sql(adapter, count, logical_definitions)
      case adapter
      when "jsonb" then jsonb_hydration_sql(count)
      when "per_type_eav" then per_type_hydration_sql(count)
      when "sql" then sql_hydration_sql(count, logical_definitions)
      end
    end

    def jsonb_hydration_sql(count)
      <<~SQL
        WITH definitions AS (
          SELECT DISTINCT ON (logical_index) logical_index, logical_name, type_name
          FROM t121_oracle_definitions
          ORDER BY logical_index, specificity DESC, physical_definition DESC
        )
        SELECT j.entity_id, definitions.logical_name,
               CASE
                 WHEN jsonb_typeof(entry.value) = 'null' THEN 'null'
                 WHEN definitions.type_name = 'integer' THEN (entry.value #>> '{}')::bigint::text
                 WHEN definitions.type_name = 'decimal' THEN trim(trailing '.' FROM trim(trailing '0' FROM (entry.value #>> '{}')::numeric::text))
                 WHEN definitions.type_name = 'boolean' THEN (entry.value #>> '{}')::boolean::text
                 WHEN definitions.type_name = 'date' THEN to_char((entry.value #>> '{}')::date, 'YYYY-MM-DD')
                 WHEN definitions.type_name = 'datetime' THEN to_char((entry.value #>> '{}')::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS')
                 WHEN definitions.type_name = 'text' THEN entry.value #>> '{}'
                 ELSE (SELECT string_agg(element, ',' ORDER BY position)
                       FROM jsonb_array_elements_text(entry.value) WITH ORDINALITY AS item(element, position))
               END AS canonical_value
        FROM t121_json j
        JOIN t121_hosts h ON h.id = j.entity_id
        CROSS JOIN LATERAL jsonb_each(j.payload) entry
        JOIN definitions ON definitions.logical_name = entry.key
        WHERE h.ordinal < #{Integer(count)}
      SQL
    end

    def per_type_hydration_sql(count)
      scalar = {
        "integer" => "v.value::bigint::text",
        "decimal" => "trim(trailing '.' FROM trim(trailing '0' FROM v.value::numeric::text))",
        "boolean" => "v.value::boolean::text",
        "date" => "to_char(v.value::date, 'YYYY-MM-DD')",
        "datetime" => "to_char(v.value::timestamp, 'YYYY-MM-DD\"T\"HH24:MI:SS')",
        "text" => "v.value::text",
        "json" => "(SELECT string_agg(element, ',' ORDER BY position) FROM jsonb_array_elements_text(v.value) WITH ORDINALITY AS item(element, position))",
      }
      scalar.map do |type, canonical|
        <<~SQL.squish
          SELECT v.entity_id, d.logical_name,
                 CASE WHEN v.state='null' THEN 'null' ELSE #{canonical} END AS canonical_value
          FROM t121_type_#{type} v
          JOIN t121_type_definitions d USING (physical_definition)
          JOIN t121_hosts h ON h.id = v.entity_id
          WHERE h.ordinal < #{Integer(count)}
        SQL
      end.join(" UNION ALL ")
    end

    def sql_hydration_sql(count, logical_definitions)
      selects = Integer(logical_definitions).times.map do |index|
        field = "f#{format('%03d', index)}"
        type = OracleFoundation::TYPE_ORDER.fetch(index % OracleFoundation::TYPE_ORDER.length)
        canonical = case type
                    when "integer" then "s.#{field}::bigint::text"
                    when "decimal" then "trim(trailing '.' FROM trim(trailing '0' FROM s.#{field}::numeric::text))"
                    when "boolean" then "s.#{field}::boolean::text"
                    when "date" then "to_char(s.#{field}::date, 'YYYY-MM-DD')"
                    when "datetime" then "to_char(s.#{field}::timestamp, 'YYYY-MM-DD\"T\"HH24:MI:SS')"
                    when "integer_array", "text_array" then "array_to_string(s.#{field}, ',')"
                    else "s.#{field}::text"
                    end
        <<~SQL.squish
          SELECT s.id AS entity_id, '#{field}' AS logical_name,
                 CASE WHEN s.#{field} IS NULL THEN 'null' ELSE #{canonical} END AS canonical_value
          FROM t121_sql s
          JOIN t121_hosts h ON h.id = s.id
          WHERE s.#{field}_present AND h.ordinal < #{Integer(count)}
        SQL
      end
      selects.join(" UNION ALL ")
    end

    def hydration_digest(sql)
      row = @connection.select_one(<<~SQL)
        WITH material AS (
          SELECT ('x' || substr(md5(entity_id::text || '|' || logical_name || '|' || canonical_value), 1, 16))::bit(64)::bigint AS value
          FROM (#{sql}) hydrated
        )
        SELECT count(*)::text AS count, COALESCE(sum(value::numeric),0)::text AS sum,
               COALESCE(bit_xor(value),0)::text AS xor FROM material
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def explain_plan(sql)
      raw = @connection.select_value("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}")
      JSON.parse(raw, max_nesting: false)
    end

    def query_sql(adapter, name, multi_filter_protocols)
      return filter_intersection(adapter) if name == "filters_3"
      return multi_filter_sql(adapter, multi_filter_protocols.fetch(name)) if %w[filters_10 filters_20].include?(name)

      case name
      when "eq_uniform" then scalar(adapter, 0, "= 3", host: regular_host)
      when "eq_zipf" then scalar(adapter, 1, "= 1", host: regular_host)
      when "integer_range" then scalar(adapter, 0, "BETWEEN 2 AND 4", host: regular_host)
      when "date_range" then scalar(adapter, 5, "BETWEEN DATE '2020-01-20' AND DATE '2020-01-31'", host: regular_host)
      when "prefix" then scalar(adapter, 2, "ILIKE 'VALUE-16%'", host: regular_host)
      when "contains" then scalar(adapter, 2, "ILIKE '%VALUE-16%'", host: regular_host)
      when "array_any" then array(adapter, 6, 7, host: regular_host)
      when "explicit_null" then explicit_null(adapter)
      when "include_missing" then include_missing(adapter)
      when "cross_scope_admin" then scalar(adapter, 0, "= 4", host: nil, all_definitions: true)
      end
    end

    def multi_filter_sql(adapter, protocol)
      if %w[jsonb sql].include?(adapter)
        table_alias = adapter == "jsonb" ? "j" : "s"
        table = adapter == "jsonb" ? "t121_json" : "t121_sql"
        id = adapter == "jsonb" ? "j.entity_id" : "s.id"
        conditions = protocol.map { |filter| filter_condition(adapter, filter) }
        return "SELECT #{id} AS id FROM #{table} #{table_alias}#{project_join(id, regular_host)} " \
               "WHERE #{conditions.join(' AND ')}#{host_where(regular_host)}"
      end

      protocol.map do |filter|
        logical_index = Integer(filter.fetch("logical_index"))
        definition = winning_physical_definition(logical_index, regular_host)
        type = filter.fetch("type")
        table = %w[integer_array text_array].include?(type) ? "json" : type
        condition = filter_condition(adapter, filter)
        "SELECT v.entity_id AS id FROM t121_type_#{table} v#{project_join('v.entity_id', regular_host)} " \
          "WHERE v.physical_definition=#{definition} AND v.state='value' AND #{condition}#{host_where(regular_host)}"
      end.join(" INTERSECT ")
    end

    def filter_condition(adapter, filter)
      name = filter.fetch("name")
      type = filter.fetch("type")
      value = filter.fetch("value")
      if adapter == "jsonb"
        expression = "j.payload->>'#{name}'"
        return "j.payload->'#{name}' @> #{@connection.quote([value].to_json)}::jsonb" if filter.fetch("operator") == "any_eq"
        expression = "(#{expression})::bigint" if type == "integer"
        expression = "(#{expression})::numeric" if type == "decimal"
        expression = "(#{expression})::boolean" if type == "boolean"
        literal = %w[date datetime].include?(type) ? @connection.quote(value) : sql_literal(type, value)
        return "#{expression}=#{literal}"
      end
      if adapter == "sql"
        return "#{sql_presence(name)} AND #{sql_array_condition("s.#{name}", type, value)}" if filter.fetch("operator") == "any_eq"

        return "#{sql_presence(name)} AND s.#{name}=#{sql_literal(type, value)}"
      end

      return "v.value @> #{@connection.quote([value].to_json)}::jsonb" if filter.fetch("operator") == "any_eq"

      "v.value=#{sql_literal(type, value)}"
    end

    def sql_presence(name)
      "s.#{name}_present"
    end

    def sql_array_condition(column, type, value)
      cast = type == "integer_array" ? "bigint" : "text"
      "#{@connection.quote(value)}::#{cast} = ANY(#{column})"
    end

    def sql_literal(type, value)
      quoted = @connection.quote(value)
      case type
      when "integer" then "#{Integer(value)}"
      when "decimal" then "#{BigDecimal(value.to_s).to_s("F")}::numeric"
      when "boolean" then (value == true || value == "true") ? "TRUE" : "FALSE"
      when "date" then "DATE #{quoted}"
      when "datetime" then "TIMESTAMP #{quoted}"
      else quoted
      end
    end

    def filter_intersection(adapter)
      if adapter == "jsonb"
        host = regular_host
        return "SELECT j.entity_id AS id FROM t121_json j#{project_join('j.entity_id', host)} " \
               "WHERE (j.payload->>'f000')::bigint=3 AND (j.payload->>'f001')::bigint=1 " \
               "AND (j.payload->>'f004')::bigint=7#{host_where(host)}"
      end
      if adapter == "sql"
        host = regular_host
        return "SELECT s.id FROM t121_sql s#{project_join('s.id', host)} " \
               "WHERE s.f000_present AND s.f000=3 AND s.f001_present AND s.f001=1 " \
               "AND s.f004_present AND s.f004=7#{host_where(host)}"
      end

      [scalar(adapter, 0, "= 3", host: regular_host),
       scalar(adapter, 1, "= 1", host: regular_host),
       scalar(adapter, 4, "= 7", host: regular_host)].join(" INTERSECT ")
    end

    def scalar(adapter, logical_index, predicate, host:, all_definitions: false)
      field = "f#{format('%03d', logical_index)}"
      case adapter
      when "jsonb"
        cast = case logical_index
               when 0, 1, 4 then "(j.payload->>'#{field}')::bigint"
               else "j.payload->>'#{field}'"
               end
        json_predicate = logical_index == 5 ? predicate.gsub("DATE ", "") : predicate
        "SELECT j.entity_id AS id FROM t121_json j#{project_join('j.entity_id', host)} WHERE #{cast} #{json_predicate}#{host_where(host)}"
      when "per_type_eav"
        table, value = case logical_index
                       when 0, 1, 4 then ["integer", "v.value"]
                       when 5 then ["date", "v.value"]
                       else ["text", "v.value"]
                       end
        definition = all_definitions ? "d.logical_index=#{logical_index}" :
                      "v.physical_definition=#{winning_physical_definition(logical_index, host)}"
        definition_join = all_definitions ? " JOIN t121_type_definitions d USING (physical_definition)" : ""
        "SELECT v.entity_id AS id FROM t121_type_#{table} v#{definition_join}#{project_join('v.entity_id', host)} " \
          "WHERE #{definition} AND v.state='value' AND #{value} #{predicate}#{host_where(host)}"
      when "sql"
        "SELECT s.id FROM t121_sql s#{project_join('s.id', host)} WHERE s.#{field}_present AND s.#{field} #{predicate}#{host_where(host)}"
      end
    end

    def array(adapter, logical_index, element, host:)
      field = "f#{format('%03d', logical_index)}"
      case adapter
      when "jsonb"
        "SELECT j.entity_id AS id FROM t121_json j#{project_join('j.entity_id', host)} " \
          "WHERE j.payload->'#{field}' @> '[#{element}]'::jsonb#{host_where(host)}"
      when "per_type_eav"
        definition = winning_physical_definition(logical_index, host)
        "SELECT v.entity_id AS id FROM t121_type_json v#{project_join('v.entity_id', host)} " \
          "WHERE v.physical_definition=#{definition} AND v.state='value' AND v.value @> '[#{element}]'::jsonb#{host_where(host)}"
      when "sql"
        "SELECT s.id FROM t121_sql s#{project_join('s.id', host)} " \
          "WHERE s.#{field}_present AND s.#{field} @> ARRAY[#{element}]::bigint[]#{host_where(host)}"
      end
    end

    def explicit_null(adapter)
      host = [@scope_protocol.fetch("null_tenant"), @scope_protocol.fetch("null_parent_scope")]
      case adapter
      when "jsonb"
        "SELECT j.entity_id AS id FROM t121_json j#{project_join('j.entity_id', host)} " \
          "WHERE jsonb_typeof(j.payload->'f000')='null'#{host_where(host)}"
      when "per_type_eav"
        definition = winning_physical_definition(0, host)
        "SELECT v.entity_id AS id FROM t121_type_integer v#{project_join('v.entity_id', host)} " \
          "WHERE v.physical_definition=#{definition} AND v.state='null'#{host_where(host)}"
      when "sql"
        "SELECT s.id FROM t121_sql s#{project_join('s.id', host)} " \
          "WHERE s.f000_present AND s.f000 IS NULL#{host_where(host)}"
      end
    end

    def include_missing(adapter)
      host = [@scope_protocol.fetch("missing_tenant"), @scope_protocol.fetch("missing_parent_scope")]
      case adapter
      when "jsonb"
        "SELECT j.entity_id AS id FROM t121_json j#{project_join('j.entity_id', host)} " \
          "WHERE (j.payload->'f000' IS NULL OR jsonb_typeof(j.payload->'f000')='null')#{host_where(host)}"
      when "per_type_eav"
        definition = winning_physical_definition(0, host)
        "SELECT p.id FROM projects p WHERE #{direct_host_where(host)} AND NOT EXISTS " \
          "(SELECT 1 FROM t121_type_integer v WHERE v.entity_id=p.id AND v.physical_definition=#{definition} " \
          "AND v.state='value' AND v.value IS NOT NULL)"
      when "sql"
        "SELECT s.id FROM t121_sql s#{project_join('s.id', host)} " \
          "WHERE (NOT s.f000_present OR s.f000 IS NULL)#{host_where(host)}"
      end
    end

    def regular_host
      [@scope_protocol.fetch("tenant"), @scope_protocol.fetch("parent_scope")]
    end

    def winning_physical_definition(logical_index, host)
      tenant, parent_scope = host
      @connection.select_value(<<~SQL).to_i
        SELECT physical_definition
        FROM t121_oracle_definitions
        WHERE logical_index=#{Integer(logical_index)}
          AND (scope IS NULL OR scope=#{@connection.quote(tenant)})
          AND (parent_scope IS NULL OR parent_scope=#{@connection.quote(parent_scope)})
        ORDER BY specificity DESC
        LIMIT 1
      SQL
    end

    def project_join(id, host)
      host ? " JOIN projects p ON p.id=#{id}" : ""
    end

    def host_where(host)
      host ? " AND #{direct_host_where(host)}" : ""
    end

    def direct_host_where(host)
      "p.tenant_id=#{@connection.quote(host[0])} AND p.workspace_id=#{@connection.quote(host[1])}"
    end

    def id_digest(sql)
      row = @connection.select_one(<<~SQL)
        WITH ids AS (#{sql}), distinct_ids AS (SELECT DISTINCT id::bigint AS id FROM ids), hashed AS (
          SELECT hashtextextended(id::text, #{SEED}) AS value FROM distinct_ids
        )
        SELECT count(*)::text AS count, COALESCE(sum(value::numeric),0)::text AS sum,
               COALESCE(bit_xor(value),0)::text AS xor FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end
  end

  # Exercises only shipped public TypedEAV read surfaces. Other contender SQL
  # is deliberately deferred until this boundary is independently accepted.
  class PublicTypedEAVQueryProbe
    TENANT = "tenant_11"
    PARENT_SCOPE = "workspace_2"
    NULL_TENANT = "tenant_10"
    NULL_PARENT_SCOPE = "workspace_1"
    MISSING_TENANT = "tenant_3"
    MISSING_PARENT_SCOPE = "workspace_0"
    SELECTIVE_PROBES = %w[eq_uniform integer_range date_range prefix contains array_any explicit_null filters_3 filters_10 filters_20].freeze

    def initialize(connection, scope_protocol: nil)
      @connection = connection
      @scope_protocol = scope_protocol || {
        "tenant" => TENANT, "parent_scope" => PARENT_SCOPE,
        "null_tenant" => NULL_TENANT, "null_parent_scope" => NULL_PARENT_SCOPE,
        "missing_tenant" => MISSING_TENANT, "missing_parent_scope" => MISSING_PARENT_SCOPE,
      }
    end

    def call(effective_hosts:, logical_definitions:, workloads: nil, include_hydration: true,
             factor_hydration: false, scope_protocol: nil)
      @scope_protocol = scope_protocol if scope_protocol
      selected = workloads&.dup
      multi_filter_protocols = {}
      [10, 20].each do |size|
        name = "filters_#{size}"
        multi_filter_protocols[name] = multi_filter_protocol(size) if selected.nil? || selected.include?(name)
      end
      probes = query_probes(logical_definitions, multi_filter_protocols, workloads: selected).to_h do |name, relation_factory, oracle_sql|
        [name, measure_relation(name, relation_factory, oracle_sql)]
      end
      hydrations = if include_hydration
                     hydration_counts = if factor_hydration
                                          [[effective_hosts, 1_000].min]
                                        else
                                          [1, [effective_hosts, 1_000].min].uniq
                                        end
                     hydration_counts.to_h do |count|
                       measurement = factor_hydration ? measure_factor_hydration(count) : measure_hydration(count)
                       [count.to_s, measurement]
                     end
                   else
                     {}
                   end
      {
        "queries" => probes,
        "multi_filter_protocols" => multi_filter_protocols,
        "hydration" => hydrations,
        "scope_protocol" => @scope_protocol,
        "sort_limit" => {
          "status" => "unsupported",
          "reason" => "Project has no public dynamic typed-field ordering API; no raw SQL substitute was measured",
        },
        "pure_missing" => {
          "status" => "unsupported",
          "reason" => "no shipped pure-missing operator; include_missing composes missing with explicit NULL",
        },
        "public_query_host_scope_note" => "ordinary probes add an explicit tenant+workspace host tuple predicate; unscoped admin intentionally spans all hosts",
      }
    end

    private

    def query_probes(logical_definitions, multi_filter_protocols, workloads: nil)
      if (workloads.nil? || workloads.include?("filters_20")) && logical_definitions < 20
        raise "filters_20 requires at least 20 logical definitions"
      end

      scoped = { scope: @scope_protocol.fetch("tenant"), parent_scope: @scope_protocol.fetch("parent_scope") }
      probes = [
        ["eq_uniform", -> { tenant_query({ name: "f000", op: :eq, value: 3 }, **scoped) },
         oracle_cells(0, "canonical_value = '3'")],
        ["eq_zipf", -> { tenant_query({ name: "f001", op: :eq, value: 1 }, **scoped) },
         oracle_cells(1, "canonical_value = '1'")],
        ["integer_range", -> { tenant_query({ name: "f000", op: :between, value: 2..4 }, **scoped) },
         oracle_cells(0, "state='value' AND canonical_value::bigint BETWEEN 2 AND 4")],
        ["date_range", -> { tenant_query({ name: "f005", op: :between, value: Date.new(2020, 1, 20)..Date.new(2020, 1, 31) }, **scoped) },
         oracle_cells(5, "state='value' AND canonical_value::date BETWEEN DATE '2020-01-20' AND DATE '2020-01-31'")],
        ["prefix", -> { tenant_query({ name: "f002", op: :starts_with, value: "VALUE-16" }, **scoped) },
         oracle_cells(2, "canonical_value ILIKE 'VALUE-16%'")],
        ["contains", -> { tenant_query({ name: "f002", op: :contains, value: "VALUE-16" }, **scoped) },
         oracle_cells(2, "canonical_value ILIKE '%VALUE-16%'")],
        ["array_any", -> { tenant_query({ name: "f006", op: :any_eq, value: 7 }, **scoped) },
         oracle_cells(6, "json_value @> '[7]'::jsonb")],
        ["explicit_null", -> {
          Project.where_typed_eav({ name: "f000", op: :is_null }, scope: @scope_protocol.fetch("null_tenant"),
                                  parent_scope: @scope_protocol.fetch("null_parent_scope")).where(
                                    tenant_id: @scope_protocol.fetch("null_tenant"),
                                    workspace_id: @scope_protocol.fetch("null_parent_scope")
                                  )
        }, oracle_cells(0, "state = 'null'", tenant: @scope_protocol.fetch("null_tenant"),
                        parent_scope: @scope_protocol.fetch("null_parent_scope"))],
        ["include_missing", -> {
          Project.where_typed_eav({ name: "f000", op: :is_null }, scope: @scope_protocol.fetch("missing_tenant"),
                                  parent_scope: @scope_protocol.fetch("missing_parent_scope"), include_missing: true).where(
                                    tenant_id: @scope_protocol.fetch("missing_tenant"),
                                    workspace_id: @scope_protocol.fetch("missing_parent_scope")
                                  )
        }, "SELECT ordinal + 1 AS id FROM t121_oracle_hosts WHERE scope='#{@scope_protocol.fetch("missing_tenant")}' " \
           "AND parent_scope='#{@scope_protocol.fetch("missing_parent_scope")}' AND ordinal NOT IN " \
           "(SELECT ordinal FROM t121_oracle_cells WHERE physical_definition=0 AND state='value')"],
        ["filters_3", -> {
          tenant_query([
            { name: "f000", op: :eq, value: 3 },
            { name: "f001", op: :eq, value: 1 },
            { name: "f004", op: :eq, value: 7 },
          ], **scoped)
        }, [oracle_cells(0, "canonical_value='3'"), oracle_cells(1, "canonical_value='1'"),
            oracle_cells(4, "canonical_value='7'")].join(" INTERSECT ")],
        ["cross_scope_admin", -> {
          TypedEAV.unscoped { Project.where_typed_eav({ name: "f000", op: :eq, value: 4 }) }
        }, oracle_logical_cells(0, "canonical_value='4'")],
      ]
      multi_filter_protocols.each do |name, protocol|
        probes.insert(-2, [name, -> { tenant_query(public_filters(protocol), **scoped) },
                            protocol.map { |filter| oracle_filter_sql(filter) }.join(" INTERSECT ")])
      end
      workloads ? probes.select { |name, _relation_factory, _oracle_sql| workloads.include?(name) } : probes
    end

    def multi_filter_protocol(size)
      target = @connection.select_value(<<~SQL)
        SELECT h.ordinal FROM t121_oracle_hosts h
        WHERE h.scope=#{@connection.quote(@scope_protocol.fetch("tenant"))} AND
              h.parent_scope=#{@connection.quote(@scope_protocol.fetch("parent_scope"))}
          AND EXISTS (SELECT 1 FROM t121_oracle_cells c WHERE c.ordinal=h.ordinal
                      AND c.logical_index=0 AND c.state='value')
        ORDER BY h.ordinal LIMIT 1
      SQL
      raise "no value-bearing target host for filters_#{size}" unless target

      rows = @connection.select_all(<<~SQL).to_a
        SELECT logical_index, logical_name, type_name, canonical_value
        FROM t121_oracle_cells
        WHERE ordinal=#{Integer(target)} AND logical_index BETWEEN 0 AND #{size - 1} AND state='value'
        ORDER BY logical_index
      SQL
      raise "filters_#{size} target does not have #{size} distinct values" unless rows.length == size

      rows.map do |row|
        type = row.fetch("type_name")
        raw = row.fetch("canonical_value")
        value = %w[integer_array text_array].include?(type) ? raw.split(",").first : raw
        value = Integer(value) if type == "integer_array"
        {
          "logical_index" => row.fetch("logical_index").to_i,
          "name" => row.fetch("logical_name"),
          "type" => type,
          "operator" => %w[integer_array text_array].include?(type) ? "any_eq" : "eq",
          "value" => value,
          "target_ordinal" => Integer(target),
        }
      end
    end

    def public_filters(protocol)
      protocol.map do |filter|
        value = public_operand(filter.fetch("type"), filter.fetch("value"))
        { name: filter.fetch("name"), op: filter.fetch("operator").to_sym, value: value }
      end
    end

    def public_operand(type, value)
      case type
      when "integer" then Integer(value)
      when "decimal" then BigDecimal(value)
      when "boolean" then value == true || value == "true"
      when "date" then Date.iso8601(value)
      when "datetime" then Time.iso8601("#{value}Z")
      else value
      end
    end

    def oracle_filter_sql(filter)
      predicate = if filter.fetch("operator") == "any_eq"
                    "json_value @> #{@connection.quote([filter.fetch("value")].to_json)}::jsonb"
                  else
                    "canonical_value=#{@connection.quote(filter.fetch("value").to_s)}"
                  end
      oracle_cells(filter.fetch("logical_index"), "state='value' AND #{predicate}")
    end

    def tenant_query(filters, **scope)
      Project.where_typed_eav(filters, **scope).where(
        tenant_id: @scope_protocol.fetch("tenant"), workspace_id: @scope_protocol.fetch("parent_scope")
      )
    end

    def oracle_cells(logical_index, predicate, tenant: nil, parent_scope: nil)
      tenant ||= @scope_protocol.fetch("tenant")
      parent_scope ||= @scope_protocol.fetch("parent_scope")
      "SELECT ordinal + 1 AS id FROM t121_oracle_cells " \
        "WHERE logical_index=#{Integer(logical_index)} AND #{predicate} " \
        "AND ordinal IN (SELECT ordinal FROM t121_oracle_hosts WHERE scope='#{tenant}' " \
        "AND parent_scope='#{parent_scope}')"
    end

    def oracle_logical_cells(logical_index, predicate)
      "SELECT ordinal + 1 AS id FROM t121_oracle_cells " \
        "WHERE logical_index=#{Integer(logical_index)} AND #{predicate}"
    end

    def measure_relation(name, relation_factory, oracle_sql)
      statements = []
      relation = nil
      public_sql = nil
      actual = nil
      subscribe_sql(statements) do
        relation = relation_factory.call
        public_sql = relation.select(:id).to_sql
        actual = id_digest(public_sql)
      end
      expected = id_digest(oracle_sql)
      unless actual == expected
        raise "#{name} public query identity mismatch: actual=#{actual.inspect} expected=#{expected.inspect} " \
              "public_sql=#{public_sql.inspect} oracle_sql=#{oracle_sql.inspect}"
      end
      raise "#{name} public query count changed: #{statements.length}" unless statements.length == 2
      result_count = actual.fetch("count").to_i
      eligible_sql = if name == "cross_scope_admin"
                       "SELECT count(*) FROM projects"
                     else
                       tenant, parent = case name
                                        when "include_missing" then [@scope_protocol.fetch("missing_tenant"), @scope_protocol.fetch("missing_parent_scope")]
                                        when "explicit_null" then [@scope_protocol.fetch("null_tenant"), @scope_protocol.fetch("null_parent_scope")]
                                        else [@scope_protocol.fetch("tenant"), @scope_protocol.fetch("parent_scope")]
                                        end
                       "SELECT count(*) FROM projects WHERE tenant_id=#{@connection.quote(tenant)} " \
                         "AND workspace_id=#{@connection.quote(parent)}"
                     end
      eligible_count = @connection.select_value(eligible_sql).to_i
      if SELECTIVE_PROBES.include?(name)
        valid = result_count.positive? && (eligible_count == 1 || result_count < eligible_count)
        raise "#{name} is not selective: #{result_count}/#{eligible_count}" unless valid
      end
      resolved_count = assert_admin_multimap!(public_sql) if name == "cross_scope_admin"

      plan = @connection.select_value("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{public_sql}")
      plan = JSON.parse(plan, max_nesting: false) if plan.is_a?(String)
      {
        "identity" => actual,
        "oracle_identity" => expected,
        "identity_equal" => true,
        "notification_count" => statements.length,
        "notification_sha256" => Digest::SHA256.hexdigest(statements.join("\n")),
        "eligible_hosts" => eligible_count,
        "selective" => SELECTIVE_PROBES.include?(name),
        "selectivity_evaluable" => eligible_count > 1,
        "resolved_definition_count" => resolved_count,
        "public_sql" => public_sql,
        "plan" => plan,
      }
    end

    def assert_admin_multimap!(public_sql)
      ids = @connection.select_values("SELECT id FROM typed_eav_fields WHERE entity_type='Project' AND name='f000' ORDER BY id")
      raise "admin multimap did not resolve three f000 definitions" unless ids.length == 3
      raise "admin SQL does not include every f000 definition" unless ids.all? { |id| public_sql.match?(/\b#{Regexp.escape(id.to_s)}\b/) }

      ids.length
    end

    def id_digest(sql)
      row = @connection.select_one(<<~SQL)
        WITH ids AS (#{sql}), distinct_ids AS (SELECT DISTINCT id::bigint AS id FROM ids), hashed AS (
          SELECT hashtextextended(id::text, #{SEED}) AS value FROM distinct_ids
        )
        SELECT count(*)::text AS count, COALESCE(sum(value::numeric),0)::text AS sum,
               COALESCE(bit_xor(value),0)::text AS xor FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def measure_hydration(count)
      records = Project.order(:id).limit(count).to_a
      statements = []
      result = nil
      subscribe_sql(statements) { result = Project.typed_eav_hash_for(records) }
      raise "BulkRead expected 3 statements, got #{statements.length}" unless statements.length == 3

      actual = ruby_value_digest(result)
      expected = oracle_value_digest(count)
      raise "BulkRead #{count} identity mismatch" unless actual == expected
      {
        "records" => count,
        "notification_count" => statements.length,
        "notification_sha256" => Digest::SHA256.hexdigest(statements.join("\n")),
        "identity" => actual,
        "oracle_identity" => expected,
        "identity_equal" => true,
      }
    end

    def measure_factor_hydration(count)
      records = Project.order(:id).limit(count).to_a
      statements = []
      result = nil
      callback = lambda do |_name, _started, _finished, _id, payload|
        next if payload[:name] == "SCHEMA" || %w[TRANSACTION CACHE].include?(payload[:name])

        statements << { "sql" => payload.fetch(:sql), "binds" => payload[:binds] || [] }
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        result = Project.typed_eav_hash_for(records)
      end
      raise "BulkRead expected 3 statements, got #{statements.length}" unless statements.length == 3

      actual = ruby_value_digest(result)
      expected = oracle_value_digest(count)
      raise "BulkRead #{count} factor identity mismatch" unless actual == expected
      plans = statements.map { |statement| explain_plan(statement.fetch("sql"), binds: statement.fetch("binds")) }
      {
        "records" => count,
        "notification_count" => statements.length,
        "notification_sha256" => Digest::SHA256.hexdigest(statements.map { |statement| statement.fetch("sql") }.join("\n")),
        "identity" => actual,
        "oracle_identity" => expected,
        "identity_equal" => true,
        "plans" => plans,
      }
    end

    def explain_plan(sql, binds: [])
      raw = if binds.empty?
              @connection.select_value("EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}")
            else
              @connection.exec_query(
                "EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, FORMAT JSON) #{sql}",
                "T125 factor hydration EXPLAIN", binds,
              ).rows.fetch(0).fetch(0)
            end
      JSON.parse(raw, max_nesting: false)
    end

    def ruby_value_digest(result)
      hashes = result.sort.flat_map do |entity_id, fields|
        fields.sort.map { |name, value| md5_i64("#{entity_id}|#{name}|#{canonical_ruby(value)}") }
      end
      digest_numbers(hashes)
    end

    def oracle_value_digest(count)
      row = @connection.select_one(<<~SQL)
        WITH material AS (
          SELECT ('x' || substr(md5((c.ordinal + 1) || '|' || c.logical_name || '|' || c.canonical_value), 1, 16))::bit(64)::bigint AS value
          FROM t121_oracle_cells c WHERE c.ordinal < #{Integer(count)}
        )
        SELECT count(*)::text AS count, COALESCE(sum(value::numeric),0)::text AS sum,
               COALESCE(bit_xor(value),0)::text AS xor FROM material
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def canonical_ruby(value)
      case value
      when BigDecimal then value.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, "\\1")
      when DateTime, Time then value.strftime("%Y-%m-%dT%H:%M:%S")
      when Date then value.iso8601
      when Array then value.join(",")
      when nil then "null"
      else value.to_s
      end
    end

    def md5_i64(value)
      number = Digest::MD5.hexdigest(value)[0, 16].to_i(16)
      number >= (1 << 63) ? number - (1 << 64) : number
    end

    def digest_numbers(numbers)
      xor = numbers.reduce(0) { |memo, number| memo ^ (number & ((1 << 64) - 1)) }
      xor -= (1 << 64) if xor >= (1 << 63)
      row = { "count" => numbers.length.to_s, "sum" => numbers.sum.to_s, "xor" => xor.to_s }
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def subscribe_sql(statements)
      callback = lambda do |_name, _started, _finished, _id, payload|
        next if payload[:name] == "SCHEMA" || %w[TRANSACTION CACHE].include?(payload[:name])

        statements << payload.fetch(:sql)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    end
  end

  # Immutable protocol population used by the storage tournament.  This layer
  # is deliberately independent from every contender table: it is populated
  # first, sealed, and then treated as read-only input.  Representative rows
  # never cross the Ruby boundary; Ruby receives only compact manifests and a
  # small preregistered recomputation vector.
  class OracleFoundation
    VECTOR_ORDINALS = [0, 1, 2, 3, 10, 11, 16, 17, 99].freeze
    TYPE_ORDER = %w[integer integer text boolean integer date integer_array text_array decimal datetime].freeze

    def initialize(connection, mode:, output:, consumer: nil)
      @connection = connection
      @mode = mode
      @output = output
      @consumer = consumer
    end

    def call
      profiles = PROFILES.map do |name, declared|
        run_profile(name, declared)
      ensure
        drop_tables
      end
      a100 = profiles.find { |profile| profile.fetch("name") == "A100" }
      a1m = profiles.find { |profile| profile.fetch("name") == "A1M" }
      prefix_equal = a100.dig("manifest", "first_100k_prefix_digest") ==
                     a1m.dig("manifest", "first_100k_prefix_digest")
      raise "A100/A1M first-100k prefix mismatch" unless prefix_equal
      remaining_task_relations = @connection.select_values(<<~SQL)
        SELECT relname FROM pg_class
        WHERE relnamespace = current_schema()::regnamespace AND relname LIKE 't121\_%' ESCAPE '\\'
        ORDER BY relname
      SQL
      raise "tournament task relations remain after cleanup: #{remaining_task_relations.join(', ')}" if remaining_task_relations.any?
      payload = {
        "schema_version" => 1,
        "kind" => "storage_tournament_oracle_foundation",
        "accepted" => false,
        "protocol" => {
          "seed" => SEED,
          "profiles" => PROFILES.transform_values { |profile| stringify(profile) },
          "vector_ordinals" => VECTOR_ORDINALS,
          "smoke_reduces_hosts_only" => true,
          "a100_a1m_prefix_equal" => prefix_equal,
        },
        "profiles" => profiles,
        "environment" => {
          "mode" => @mode,
          "database" => @connection.select_value("SELECT current_database()"),
          "postgresql" => @connection.select_value("SHOW server_version"),
          "ruby" => RUBY_VERSION,
        },
        "cleanup" => { "remaining_task_relations" => remaining_task_relations, "exact" => true },
      }
      File.write(@output, "#{JSON.pretty_generate(payload, max_nesting: false)}\n")
    ensure
      drop_tables
    end

    private

    def run_profile(name, declared)
      drop_tables
      create_tables
      hosts = @mode.end_with?("-smoke") ? [declared[:hosts], 128].min : declared[:hosts]
      logical_definitions = declared[:definitions] - 2
      raise "profile requires shadow-capable definitions" if logical_definitions <= declared[:values]

      insert_hosts(hosts, declared[:scopes])
      insert_definitions(logical_definitions)
      insert_cells(declared[:values])
      manifest = build_manifest(hosts:, declared:, logical_definitions:)
      database_vector = vector_rows
      ruby_vector = recompute_vector(hosts:, scopes: declared[:scopes], values: declared[:values],
                                     logical_definitions:)
      unless database_vector == ruby_vector
        index = [database_vector.length, ruby_vector.length].min.times.find do |offset|
          database_vector[offset] != ruby_vector[offset]
        end
      raise "independent oracle vector mismatch for #{name} at #{index.inspect}: " \
              "database=#{database_vector[index].inspect} ruby=#{ruby_vector[index].inspect}"
      end
      seal = seal_tables
      consumer_evidence = @consumer&.call(
        name: name,
        declared: declared,
        effective_hosts: hosts,
        logical_definitions: logical_definitions,
        oracle_manifest: manifest,
        mode: @mode,
      )

      factor_observations = consumer_evidence&.delete("factor_observations") if
        %w[factor-smoke representative].include?(@mode) && FACTOR_SMOKE_PROFILES.include?(name)

      profile = {
        "name" => name,
        "declared" => stringify(declared),
        "effective" => stringify(declared.merge(hosts: hosts)),
        "logical_definitions" => logical_definitions,
        "physical_definitions" => declared[:definitions],
        "manifest" => manifest,
        "immutability" => seal,
        "contenders" => consumer_evidence,
        "recomputation_vector" => {
          "ordinals" => VECTOR_ORDINALS.select { |ordinal| ordinal < hosts },
          "rows" => database_vector,
          "sha256" => Digest::SHA256.hexdigest(JSON.generate(database_vector)),
        },
        "cleanup" => { "scheduled" => true, "table_prefix" => "t121_oracle_" },
      }
      if %w[factor-smoke representative].include?(@mode) && FACTOR_SMOKE_PROFILES.include?(name)
        profile["factor_observations"] = factor_observations
      end
      profile["factor_limitations"] = FACTOR_LIMITATIONS.fetch(name) if
        @mode == "representative" && FACTOR_SMOKE_PROFILES.include?(name)
      profile
    end

    def create_tables
      @connection.execute(<<~SQL)
        CREATE TABLE t121_oracle_hosts (
          ordinal bigint PRIMARY KEY,
          data_ordinal bigint NOT NULL,
          scope text NOT NULL,
          parent_scope text NOT NULL,
          version_cohort text NOT NULL
        )
      SQL
      @connection.execute(<<~SQL)
        CREATE TABLE t121_oracle_definitions (
          physical_definition integer PRIMARY KEY,
          logical_index integer NOT NULL,
          logical_name text NOT NULL,
          type_name text NOT NULL,
          family text NOT NULL,
          scope text,
          parent_scope text,
          specificity integer NOT NULL,
          UNIQUE (logical_index, scope, parent_scope)
        )
      SQL
      @connection.execute(<<~SQL)
        CREATE TABLE t121_oracle_cells (
          ordinal bigint NOT NULL REFERENCES t121_oracle_hosts(ordinal),
          logical_index integer NOT NULL,
          logical_name text NOT NULL,
          physical_definition integer NOT NULL REFERENCES t121_oracle_definitions(physical_definition),
          winner_specificity integer NOT NULL,
          type_name text NOT NULL,
          family text NOT NULL,
          state text NOT NULL CHECK (state IN ('value', 'null')),
          integer_value bigint,
          decimal_value numeric,
          boolean_value boolean,
          date_value date,
          datetime_value timestamp,
          text_value text,
          json_value jsonb,
          canonical_value text,
          PRIMARY KEY (ordinal, logical_index)
        )
      SQL
      @connection.execute("CREATE INDEX t121_oracle_cells_logical ON t121_oracle_cells(logical_index, state, ordinal)")
      @connection.execute("CREATE INDEX t121_oracle_cells_physical ON t121_oracle_cells(physical_definition, ordinal)")
    end

    def insert_hosts(hosts, scopes)
      @connection.execute(<<~SQL)
        INSERT INTO t121_oracle_hosts (ordinal, data_ordinal, scope, parent_scope, version_cohort)
        SELECT ordinal, data_ordinal,
               CASE WHEN data_ordinal IN (0, 2) THEN 'tenant_0'
                    ELSE 'tenant_' || (data_ordinal % #{Integer(scopes)}) END,
               CASE WHEN data_ordinal = 0 THEN 'workspace_0'
                    WHEN data_ordinal = 2 THEN 'workspace_1'
                    ELSE 'workspace_' || (data_ordinal % 3) END,
               CASE ordinal WHEN 0 THEN 'version_off'
                            WHEN 1 THEN 'version_on'
                                    ELSE 'base' END
        FROM (
          SELECT ordinal,
                 CASE WHEN ordinal = 1 THEN 0
                      ELSE ordinal END AS data_ordinal
          FROM generate_series(0, #{Integer(hosts) - 1}) AS ordinal
        ) generated
      SQL
    end

    def insert_definitions(logical_definitions)
      # D physical definitions represent D-2 logical names: logical field zero
      # has global, scope-only, and full-tuple definitions; every other name is
      # global.  This keeps the declared definition count exact.
      @connection.execute(<<~SQL)
        INSERT INTO t121_oracle_definitions
          (physical_definition, logical_index, logical_name, type_name, family, scope, parent_scope, specificity)
        SELECT logical_index,
               logical_index,
               'f' || lpad(logical_index::text, 3, '0'),
               (ARRAY[#{TYPE_ORDER.map { |type| @connection.quote(type) }.join(',')}])[(logical_index % #{TYPE_ORDER.length}) + 1],
               CASE WHEN logical_index = 1 THEN 'zipf' ELSE 'uniform' END,
               NULL, NULL, 0
        FROM generate_series(0, #{Integer(logical_definitions) - 1}) AS logical_index
      SQL
      @connection.execute(<<~SQL)
        INSERT INTO t121_oracle_definitions
          (physical_definition, logical_index, logical_name, type_name, family, scope, parent_scope, specificity)
        SELECT #{Integer(logical_definitions)}, 0, 'f000', '#{TYPE_ORDER.first}', 'uniform', 'tenant_0', NULL, 1
        UNION ALL
        SELECT #{Integer(logical_definitions) + 1}, 0, 'f000', '#{TYPE_ORDER.first}', 'uniform', 'tenant_0', 'workspace_0', 2
      SQL
    end

    def insert_cells(values)
      @connection.execute(<<~SQL)
        WITH selected AS (
          SELECT h.ordinal, h.data_ordinal, h.scope, h.parent_scope,
                 CASE
                   WHEN candidate < #{Integer(values)} AND NOT (candidate = 0 AND (h.data_ordinal + #{SEED}) % 17 = 0)
                     THEN candidate
                   WHEN candidate = #{Integer(values)} AND (h.data_ordinal + #{SEED}) % 17 = 0
                     THEN candidate
                 END AS logical_index
          FROM t121_oracle_hosts h
          CROSS JOIN LATERAL generate_series(0, #{Integer(values)}) AS candidate
        ), winners AS (
          SELECT selected.*, definition.*
          FROM selected
          JOIN LATERAL (
            SELECT d.physical_definition, d.logical_name, d.type_name, d.family, d.specificity
            FROM t121_oracle_definitions d
            WHERE d.logical_index = selected.logical_index
              AND (d.scope IS NULL OR d.scope = selected.scope)
              AND (d.parent_scope IS NULL OR d.parent_scope = selected.parent_scope)
            ORDER BY d.specificity DESC
            LIMIT 1
          ) definition ON selected.logical_index IS NOT NULL
        ), mixed AS (
          SELECT *, data_ordinal + data_ordinal / 97 + data_ordinal / 101 AS mixed_ordinal
          FROM winners
        ), generated AS (
          SELECT *,
                 (logical_index = 0 AND (data_ordinal + #{SEED}) % 11 = 0) AS is_null,
                 CASE WHEN logical_index = 1
                        THEN CASE WHEN (mixed_ordinal + #{SEED}) % 10 < 7 THEN 1 ELSE ((mixed_ordinal + #{SEED}) % 9) + 2 END
                      ELSE ((mixed_ordinal + logical_index + #{SEED}) % 10) + 1 END AS integer_formula
          FROM mixed
        )
        INSERT INTO t121_oracle_cells
          (ordinal, logical_index, logical_name, physical_definition, winner_specificity,
           type_name, family, state, integer_value, decimal_value, boolean_value,
           date_value, datetime_value, text_value, json_value, canonical_value)
        SELECT ordinal, logical_index, logical_name, physical_definition, specificity,
               type_name, family, CASE WHEN is_null THEN 'null' ELSE 'value' END,
               CASE WHEN NOT is_null AND type_name = 'integer' THEN integer_formula END,
               CASE WHEN NOT is_null AND type_name = 'decimal' THEN ((mixed_ordinal + #{SEED}) % 1000)::numeric / 10 END,
               CASE WHEN NOT is_null AND type_name = 'boolean' THEN (mixed_ordinal + #{SEED}) % 2 = 0 END,
               CASE WHEN NOT is_null AND type_name = 'date' THEN DATE '2020-01-01' + ((mixed_ordinal + logical_index + #{SEED}) % 31)::integer END,
               CASE WHEN NOT is_null AND type_name = 'datetime' THEN TIMESTAMP '2020-01-01 00:00:00' + ((mixed_ordinal + #{SEED}) % 86400) * INTERVAL '1 second' END,
               CASE WHEN NOT is_null AND type_name = 'text' THEN 'value-' || ((mixed_ordinal + logical_index + #{SEED}) % 23) || '-' || (mixed_ordinal % 5) END,
               CASE WHEN NOT is_null AND type_name = 'integer_array' THEN to_jsonb(ARRAY[((mixed_ordinal + #{SEED}) % 5) + 1, 3, ((mixed_ordinal + logical_index) % 7) + 4])
                    WHEN NOT is_null AND type_name = 'text_array' THEN to_jsonb(ARRAY['tag-' || (mixed_ordinal % 5), 'tag-' || logical_index]) END,
               CASE WHEN is_null THEN 'null'
                    WHEN type_name = 'integer' THEN integer_formula::text
                    WHEN type_name = 'decimal' THEN trim(trailing '.' FROM trim(trailing '0' FROM (((mixed_ordinal + #{SEED}) % 1000)::numeric / 10)::text))
                    WHEN type_name = 'boolean' THEN (((mixed_ordinal + #{SEED}) % 2) = 0)::text
                    WHEN type_name = 'date' THEN to_char(DATE '2020-01-01' + ((mixed_ordinal + logical_index + #{SEED}) % 31)::integer, 'YYYY-MM-DD')
                    WHEN type_name = 'datetime' THEN to_char(TIMESTAMP '2020-01-01 00:00:00' + ((mixed_ordinal + #{SEED}) % 86400) * INTERVAL '1 second', 'YYYY-MM-DD"T"HH24:MI:SS')
                    WHEN type_name = 'text' THEN 'value-' || ((mixed_ordinal + logical_index + #{SEED}) % 23) || '-' || (mixed_ordinal % 5)
                    WHEN type_name = 'integer_array' THEN array_to_string(ARRAY[((mixed_ordinal + #{SEED}) % 5) + 1, 3, ((mixed_ordinal + logical_index) % 7) + 4], ',')
                    WHEN type_name = 'text_array' THEN array_to_string(ARRAY['tag-' || (mixed_ordinal % 5), 'tag-' || logical_index], ',') END
        FROM generated
      SQL
    end

    def build_manifest(hosts:, declared:, logical_definitions:)
      host_count = @connection.select_value("SELECT count(*) FROM t121_oracle_hosts").to_i
      cell_count = @connection.select_value("SELECT count(*) FROM t121_oracle_cells").to_i
      definition_count = @connection.select_value("SELECT count(*) FROM t121_oracle_definitions").to_i
      raise "host count mismatch" unless host_count == hosts
      raise "cell count mismatch" unless cell_count == hosts * declared[:values]
      raise "physical definition count mismatch" unless definition_count == declared[:definitions]
      per_host = @connection.select_one(<<~SQL)
        SELECT min(cell_count)::integer AS minimum, max(cell_count)::integer AS maximum
        FROM (SELECT ordinal, count(*) AS cell_count FROM t121_oracle_cells GROUP BY ordinal) counts
      SQL
      raise "per-host value count mismatch" unless per_host.values_at("minimum", "maximum") == [declared[:values]] * 2

      groups = {
        "types" => grouped_counts("type_name"),
        "families" => grouped_counts("family"),
        "states" => grouped_counts("state"),
        "shadow_winners" => grouped_counts("winner_specificity"),
        "cohorts" => @connection.select_rows("SELECT version_cohort, count(*) FROM t121_oracle_hosts GROUP BY version_cohort ORDER BY version_cohort").to_h.transform_values(&:to_i),
      }
      missing_count = hosts - @connection.select_value("SELECT count(*) FROM t121_oracle_cells WHERE logical_index = 0").to_i
      filler_count = @connection.select_value("SELECT count(*) FROM t121_oracle_cells WHERE logical_index = #{Integer(declared[:values])}").to_i
      null_control_count = @connection.select_value("SELECT count(*) FROM t121_oracle_cells WHERE logical_index = 0 AND state = 'null'").to_i
      typed_shape = @connection.select_one(<<~SQL).transform_values(&:to_i)
        SELECT count(*) FILTER (WHERE state = 'value' AND
          num_nonnulls(integer_value, decimal_value, boolean_value, date_value, datetime_value, text_value, json_value) = 1 AND
          ((type_name = 'integer' AND integer_value IS NOT NULL) OR
           (type_name = 'decimal' AND decimal_value IS NOT NULL) OR
           (type_name = 'boolean' AND boolean_value IS NOT NULL) OR
           (type_name = 'date' AND date_value IS NOT NULL) OR
           (type_name = 'datetime' AND datetime_value IS NOT NULL) OR
           (type_name = 'text' AND text_value IS NOT NULL) OR
           (type_name IN ('integer_array', 'text_array') AND json_value IS NOT NULL))) AS valid_values,
          count(*) FILTER (WHERE state = 'null' AND
          num_nonnulls(integer_value, decimal_value, boolean_value, date_value, datetime_value, text_value, json_value) = 0) AS valid_nulls,
          count(*) AS total
        FROM t121_oracle_cells
      SQL
      raise "missing/filler mismatch" unless missing_count == filler_count
      raise "typed cell shape mismatch" unless typed_shape.fetch("valid_values") + typed_shape.fetch("valid_nulls") == cell_count
      distributions = distribution_frequencies
      uniform_values = distributions.fetch("uniform")
      zipf_values = distributions.fetch("zipf")
      raise "uniform family lacks spread" unless uniform_values.length >= 8
      uniform_counts = uniform_values.values
      uniform_tolerance = (uniform_counts.sum.fdiv(uniform_counts.length) * 0.4).ceil
      raise "uniform family is materially skewed" if uniform_counts.max - uniform_counts.min > uniform_tolerance
      raise "zipf family lacks hot value" unless zipf_values.fetch("1", 0) > zipf_values.values.sum / 2
      stride_vectors = mixer_stride_vectors
      cohorts = matched_cohorts
      raise "version cohorts are not matched" unless cohorts.fetch("matched")
      observed_scopes = @connection.select_value("SELECT count(DISTINCT scope) FROM t121_oracle_hosts").to_i
      observed_parent_scopes = @connection.select_value("SELECT count(DISTINCT parent_scope) FROM t121_oracle_hosts").to_i
      if hosts == declared[:hosts]
        raise "representative scope cardinality mismatch" unless observed_scopes == [declared[:scopes], hosts].min
      end
      logical = compact_digest
      prefix = compact_digest("ordinal < 100000")
      manifest = {
        "hosts" => host_count,
        "logical_definitions" => logical_definitions,
        "physical_definitions" => definition_count,
        "values_per_host" => declared[:values],
        "cells" => cell_count,
        "per_host_cells" => per_host,
        "missing_control_count" => missing_count,
        "filler_count" => filler_count,
        "null_control_count" => null_control_count,
        "typed_shape" => typed_shape,
        "scope_cardinality" => {
          "declared" => declared[:scopes],
          "observed" => observed_scopes,
          "expected_when_representative" => [declared[:scopes], declared[:hosts]].min,
          "parent_observed" => observed_parent_scopes,
          "representative_proven" => hosts == declared[:hosts],
        },
        "distribution_frequencies" => distributions,
        "mixer_stride_vectors" => stride_vectors,
        "matched_version_cohorts" => cohorts,
        "groups" => groups,
        "logical_digest" => logical,
        "first_100k_prefix_digest" => prefix.merge(
          "limit" => 100_000,
          "observed_hosts" => [hosts, 100_000].min,
          "complete" => hosts >= 100_000,
        ),
      }
      manifest["seal_sha256"] = Digest::SHA256.hexdigest(JSON.generate(manifest))
      manifest
    end

    def grouped_counts(column)
      @connection.select_rows("SELECT #{column}::text, count(*) FROM t121_oracle_cells GROUP BY #{column} ORDER BY #{column}").to_h.transform_values(&:to_i)
    end

    def compact_digest(predicate = "TRUE")
      row = @connection.select_one(<<~SQL)
        WITH material AS (
          SELECT 'host|' || ordinal || '|' || data_ordinal || '|' || scope || '|' || parent_scope || '|' || version_cohort AS value
          FROM t121_oracle_hosts WHERE #{predicate}
          UNION ALL
          SELECT 'definition|' || physical_definition || '|' || logical_index || '|' || logical_name || '|' ||
                 type_name || '|' || family || '|' || COALESCE(scope, '') || '|' || COALESCE(parent_scope, '') || '|' || specificity
          FROM t121_oracle_definitions
          UNION ALL
          SELECT 'cell|' || c.ordinal || '|' || h.data_ordinal || '|' || h.scope || '|' || h.parent_scope || '|' ||
                 h.version_cohort || '|' || c.logical_index || '|' || c.physical_definition || '|' ||
                 c.winner_specificity || '|' || c.type_name || '|' || c.family || '|' || c.state || '|' || c.canonical_value
          FROM t121_oracle_cells c JOIN t121_oracle_hosts h USING (ordinal)
          WHERE #{predicate.gsub('ordinal', 'c.ordinal')}
        ), hashed AS (
          SELECT hashtextextended(value, #{SEED}) AS hash_a,
                 hashtextextended(value, #{SEED + 1}) AS hash_b FROM material
        )
        SELECT count(*)::text AS count,
               COALESCE(sum(hash_a::numeric), 0)::text AS sum_a,
               COALESCE(bit_xor(hash_a), 0)::text AS xor_a,
               COALESCE(sum(hash_b::numeric), 0)::text AS sum_b,
               COALESCE(bit_xor(hash_b), 0)::text AS xor_b
        FROM hashed
      SQL
      row.merge("sha256" => Digest::SHA256.hexdigest(row.values.join("|")))
    end

    def distribution_frequencies
      rows = @connection.select_rows(<<~SQL)
        SELECT family, canonical_value, count(*)
        FROM t121_oracle_cells
        WHERE logical_index IN (0, 1) AND state = 'value'
        GROUP BY family, canonical_value
        ORDER BY family, canonical_value
      SQL
      rows.each_with_object({ "uniform" => {}, "zipf" => {} }) do |(family, value, count), result|
        result.fetch(family)[value] = count.to_i
      end
    end

    def mixer_stride_vectors
      rows = @connection.select_rows(<<~SQL)
        SELECT stride, stride + stride / 97 + stride / 101 AS mixed
        FROM unnest(ARRAY[100, 300, 10000, 30000]) AS stride ORDER BY stride
      SQL
      vectors = rows.to_h do |stride, mixed|
        expected = mix_ordinal(stride.to_i) - mix_ordinal(0)
        raise "Ruby/SQL mixer stride mismatch" unless mixed.to_i == expected
        raise "mixer remains correlated at stride #{stride}" if (expected % 10).zero?

        [stride.to_s, { "delta" => expected, "modulo_10" => expected % 10 }]
      end
      raise "mixer stride protocol incomplete" unless vectors.keys == %w[100 300 10000 30000]

      vectors
    end

    def matched_cohorts
      rows = @connection.select_rows(<<~SQL)
        WITH signatures AS (
          SELECT h.version_cohort,
                 count(*)::text AS count,
                 COALESCE(sum(hashtextextended(h.data_ordinal || '|' || c.logical_index || '|' ||
                   c.winner_specificity || '|' || c.type_name || '|' || c.family || '|' || c.state || '|' || c.canonical_value,
                   #{SEED})::numeric), 0)::text AS sum,
                 COALESCE(bit_xor(hashtextextended(h.data_ordinal || '|' || c.logical_index || '|' ||
                   c.winner_specificity || '|' || c.type_name || '|' || c.family || '|' || c.state || '|' || c.canonical_value,
                   #{SEED})), 0)::text AS xor
          FROM t121_oracle_hosts h JOIN t121_oracle_cells c USING (ordinal)
          WHERE h.version_cohort IN ('version_off', 'version_on')
          GROUP BY h.version_cohort
        )
        SELECT version_cohort, count, sum, xor FROM signatures ORDER BY version_cohort
      SQL
      signatures = rows.to_h { |cohort, count, sum, xor| [cohort, { "count" => count, "sum" => sum, "xor" => xor }] }
      { "off" => signatures["version_off"], "on" => signatures["version_on"],
        "disjoint" => true, "matched" => signatures["version_off"] == signatures["version_on"] }
    end

    def vector_rows
      ordinals = VECTOR_ORDINALS.join(",")
      @connection.select_rows(<<~SQL).map do |row|
        SELECT c.ordinal, c.logical_index, c.type_name, c.family, c.state, c.winner_specificity, c.canonical_value
        FROM t121_oracle_cells c
        WHERE ordinal IN (#{ordinals})
        ORDER BY ordinal, logical_index
      SQL
        [row[0].to_i, row[1].to_i, row[2], row[3], row[4], row[5].to_i, row[6]]
      end
    end

    def recompute_vector(hosts:, scopes:, values:, logical_definitions:)
      VECTOR_ORDINALS.select { |ordinal| ordinal < hosts }.flat_map do |ordinal|
        data_ordinal = ordinal == 1 ? 0 : ordinal
        missing = (data_ordinal + SEED) % 17 == 0
        indexes = (0...values).to_a
        indexes = indexes.drop(1) + [values] if missing
        indexes.map do |logical_index|
          raise "filler exceeds logical definitions" if logical_index >= logical_definitions

          type = TYPE_ORDER.fetch(logical_index % TYPE_ORDER.length)
          family = logical_index == 1 ? "zipf" : "uniform"
          state = logical_index.zero? && (data_ordinal + SEED) % 11 == 0 ? "null" : "value"
          scope_zero = [0, 2].include?(data_ordinal) || data_ordinal % scopes == 0
          workspace = data_ordinal.zero? ? 0 : data_ordinal == 2 ? 1 : data_ordinal % 3
          specificity = if logical_index.zero? && scope_zero && workspace.zero?
                          2
                        elsif logical_index.zero? && scope_zero
                          1
                        else
                          0
                        end
          [ordinal, logical_index, type, family, state, specificity,
           state == "null" ? "null" : ruby_value(data_ordinal, logical_index, type)]
        end
      end
    end

    def ruby_value(ordinal, logical_index, type)
      mixed = mix_ordinal(ordinal)
      case type
      when "integer"
        (logical_index == 1 ? ((mixed + SEED) % 10 < 7 ? 1 : ((mixed + SEED) % 9) + 2) : ((mixed + logical_index + SEED) % 10) + 1).to_s
      when "decimal" then format("%.1f", ((mixed + SEED) % 1000) / 10.0).sub(/\.0\z/, "")
      when "boolean" then (((mixed + SEED) % 2).zero?).to_s
      when "date" then (Date.new(2020, 1, 1) + ((mixed + logical_index + SEED) % 31)).iso8601
      when "datetime" then (Time.utc(2020, 1, 1) + ((mixed + SEED) % 86_400)).strftime("%Y-%m-%dT%H:%M:%S")
      when "text" then "value-#{(mixed + logical_index + SEED) % 23}-#{mixed % 5}"
      when "integer_array" then [((mixed + SEED) % 5) + 1, 3, ((mixed + logical_index) % 7) + 4].join(",")
      when "text_array" then ["tag-#{mixed % 5}", "tag-#{logical_index}"].join(",")
      end
    end

    def mix_ordinal(ordinal)
      ordinal + ordinal / 97 + ordinal / 101
    end

    def seal_tables
      @connection.execute(<<~SQL)
        CREATE OR REPLACE FUNCTION t121_oracle_reject_mutation() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 't121 oracle is sealed';
        END
        $$
      SQL
      tables = %w[t121_oracle_hosts t121_oracle_definitions t121_oracle_cells]
      tables.each do |table|
        @connection.execute(<<~SQL)
          CREATE TRIGGER #{table}_sealed
          BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION t121_oracle_reject_mutation()
        SQL
      end
      blocked = tables.to_h do |table|
        result = false
        begin
          @connection.execute("DELETE FROM #{table} WHERE false")
        rescue ActiveRecord::StatementInvalid => error
          result = error.message.include?("t121 oracle is sealed")
        end
        [table, result]
      end
      raise "oracle mutation guard failed" unless blocked.values.all?

      triggers = @connection.select_values(<<~SQL)
        SELECT tgname FROM pg_trigger
        WHERE NOT tgisinternal AND tgname LIKE 't121_oracle_%_sealed'
        ORDER BY tgname
      SQL
      { "sealed" => true, "mutation_blocked" => blocked, "triggers" => triggers,
        "post_seal_proof" => blocked.values.all? }
    end

    def stringify(value)
      value.transform_keys(&:to_s)
    end

    def drop_tables
      %w[t121_oracle_cells t121_oracle_definitions t121_oracle_hosts].each do |table|
        @connection.execute("DROP TABLE IF EXISTS #{table} CASCADE")
      rescue ActiveRecord::StatementInvalid
        nil
      end
      @connection.execute("DROP FUNCTION IF EXISTS t121_oracle_reject_mutation()")
    rescue ActiveRecord::StatementInvalid
      nil
    end
  end

  class Tournament
    SUPPORTED_MODES = %w[oracle-smoke loader-smoke factor-smoke representative].freeze

    def initialize(mode:, output:)
      @mode = mode
      @output = output
      @connection = ActiveRecord::Base.connection
    end

    def call
      raise ArgumentError, "unsupported mode #{@mode.inspect}; expected one of #{SUPPORTED_MODES.join(', ')}" unless SUPPORTED_MODES.include?(@mode)
      if @mode == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
        raise "representative mode requires TYPED_EAV_REPRESENTATIVE_OK=1"
      end

      if @mode == "oracle-smoke"
        OracleFoundation.new(@connection, mode: @mode, output: @output).call
        return
      end

      loader = ContenderLoader.new(@connection)
      OracleFoundation.new(@connection, mode: @mode, output: @output, consumer: loader.method(:call)).call
    end
  end
end

options = {}
OptionParser.new do |parser|
  parser.on("--mode MODE") { |value| options[:mode] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
abort "--mode and --output required" unless options[:mode] && options[:output]
abort "representative mode requires TYPED_EAV_REPRESENTATIVE_OK=1" if
  options[:mode] == "representative" && ENV["TYPED_EAV_REPRESENTATIVE_OK"] != "1"
TypedEAVStorageTournament::Tournament.new(**options).call
