# frozen_string_literal: true

module TypedEAV
  # Multi-filter query orchestrator. Given a model + a list of filter hashes
  # + an already-resolved scope tuple (or `EntityQuery::ALL_SCOPES`), composes
  # an `ActiveRecord::Relation` by fanning out across filters and dispatching
  # each per-filter predicate to `TypedEAV::QueryBuilder`.
  #
  #   FilterQuery.new(
  #     model: Contact,
  #     filters: [{ name: "age", op: :gt, value: 21 }],
  #     scope: "t1",
  #     parent_scope: nil,
  #   ).to_relation
  #
  # ## Two altitudes (ADR-0002)
  #
  # `QueryBuilder` stays the per-field SQL primitive (knows nothing about
  # multi-filter composition or scope collision). `FilterQuery` is the
  # orchestrator that knows about input shape, partition lookup, collision
  # precedence, and per-filter chaining.
  #
  # ## Scope shape
  #
  # `scope:` is either `EntityQuery::ALL_SCOPES` (atomic-bypass under
  # `TypedEAV.unscoped { }` — the multimap branch) or a `String | nil`
  # already-resolved scope value. `parent_scope:` is `String | nil`. Scope
  # resolution and sentinel handling live in `EntityQuery#resolve_scope`;
  # this class works on resolved tuples only.
  #
  # ## `include_missing:` (Reading A)
  #
  # Opt-in kwarg (default `false`). Only meaningful when
  # `operator == :is_null`; silently ignored otherwise (`:is_not_null` becomes
  # a no-op; other operators are unaffected). When `true`, the `:is_null`
  # predicate is composed as a **set complement** against `:is_not_null`:
  # matches hosts that have **no non-NULL value** for the field — including
  # hosts with no `typed_eav_values` row at all.
  #
  # On the multimap (`ALL_SCOPES`) branch, "no non-NULL value" reads across
  # ALL matching field definitions for the name: a host matches iff none of
  # the per-tenant field defs have a non-NULL value for it (Reading A —
  # NOT "no row anywhere"). See ADR-0006 for why composition happens at this
  # altitude rather than via a LEFT JOIN in `QueryBuilder`.
  class FilterQuery
    FILTER_KEYS = %w[name n op operator value v].freeze
    private_constant :FILTER_KEYS

    def initialize(model:, filters:, scope:, parent_scope:, include_missing: false)
      @model           = model
      @raw_filters     = filters
      @scope           = scope
      @parent_scope    = parent_scope
      @include_missing = include_missing
    end

    def to_relation
      filters = normalize_filters(@raw_filters)
      defs    = lookup_definitions

      if all_scopes?
        apply_multimap_filters(filters, TypedEAV::Partition.definitions_multimap_by_name(defs))
      else
        apply_single_scope_filters(filters, TypedEAV::Partition.definitions_by_name(defs))
      end
    end

    private

    attr_reader :model

    # ── Input normalization ─────────────────────────────────────────────

    # Accepts splat args, a single Array, a single filter Hash, a hash-of-
    # hashes (form params), or `ActionController::Parameters`. Returns an
    # Array of plain Hashes (each a filter spec with :name/:n, :op/:operator,
    # :value/:v keys).
    def normalize_filters(filters)
      flattened = filters.map { |f| coerce_to_h(f) }
      flattened = expand_single_argument(flattened) if flattened.size == 1
      Array(flattened)
    end

    def coerce_to_h(filter)
      filter.respond_to?(:to_unsafe_h) ? filter.to_unsafe_h : filter
    end

    def expand_single_argument(filters)
      inner = coerce_to_h(filters.first)
      return inner            if inner.is_a?(Array)
      return [inner]          unless inner.is_a?(Hash)
      return [inner]          if filter_hash?(inner)

      inner.values
    end

    def filter_hash?(hash)
      hash.keys.any? { |k| FILTER_KEYS.include?(k.to_s) }
    end

    # ── Partition lookup ───────────────────────────────────────────────

    def all_scopes?
      @scope.equal?(TypedEAV::EntityQuery::ALL_SCOPES)
    end

    def lookup_definitions
      if all_scopes?
        TypedEAV::Partition.visible_fields(entity_type: model.name, mode: :all_partitions)
      else
        TypedEAV::Partition.visible_fields(
          entity_type: model.name,
          scope: @scope,
          parent_scope: @parent_scope,
        )
      end
    end

    # ── Filter dispatch ────────────────────────────────────────────────

    def apply_single_scope_filters(filters, fields_by_name)
      filters.inject(model.all) do |query, filter|
        spec  = parse_filter(filter)
        field = fields_by_name[spec[:name]] || raise_unknown_field(spec[:name], fields_by_name.keys)

        if invert_is_null?(spec[:operator])
          # Reading A: "no non-NULL value." Set-complement against the
          # scope-winning field's `:is_not_null` subquery — includes both
          # NULL-column rows and entities with no row at all. ADR-0006.
          non_missing_ids = TypedEAV::QueryBuilder.entity_ids(field, :is_not_null, nil)
          query.where.not(id: non_missing_ids)
        else
          matching_ids = TypedEAV::QueryBuilder.entity_ids(field, spec[:operator], spec[:value])
          query.where(id: matching_ids)
        end
      end
    end

    def apply_multimap_filters(filters, fields_multimap)
      filters.inject(model.all) do |query, filter|
        spec    = parse_filter(filter)
        fields  = fields_multimap[spec[:name]]
        raise_unknown_field(spec[:name], fields_multimap.keys) unless fields&.any?

        if invert_is_null?(spec[:operator])
          # Reading A across all matching field defs: a host matches iff NO
          # field def has a non-NULL value for it. Union the non-missing
          # entity_ids across all per-tenant field defs, then complement at
          # the host level. ADR-0006.
          non_missing_ids = fields.flat_map do |f|
            TypedEAV::QueryBuilder.entity_ids(f, :is_not_null, nil).pluck(:entity_id)
          end.uniq
          query.where.not(id: non_missing_ids)
        else
          union_ids = union_entity_ids(fields, spec[:operator], spec[:value])
          query.where(id: union_ids)
        end
      end
    end

    # `include_missing: true` only modifies the `:is_null` branch (Reading A:
    # "no non-NULL value"). For every other operator — including
    # `:is_not_null`, which already returns the natural complement — the
    # kwarg is silently ignored, so filter UIs can pass it uniformly without
    # branching per operator.
    def invert_is_null?(operator)
      @include_missing && operator == :is_null
    end

    # OR-across all field_ids that share the same name (across tenants),
    # while preserving AND between filters via the chained `.where`. Use the
    # underlying Value scope (`.filter`) and `pluck(:entity_id)` to collapse
    # to a plain integer array we can union across tenants.
    def union_entity_ids(fields, operator, value)
      fields.flat_map { |f| TypedEAV::QueryBuilder.filter(f, operator, value).pluck(:entity_id) }.uniq
    end

    def parse_filter(filter)
      h = filter.to_h.with_indifferent_access
      {
        name: (h[:n] || h[:name]).to_s,
        operator: (h[:op] || h[:operator] || :eq).to_sym,
        value: h.key?(:v) ? h[:v] : h[:value],
      }
    end

    def raise_unknown_field(name, available)
      raise ArgumentError,
            "Unknown typed field '#{name}' for #{model.name}. " \
            "Available fields: #{available.join(", ")}"
    end
  end
end
