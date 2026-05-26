# frozen_string_literal: true

module TypedEAV
  # Class-level query orchestration extended onto host AR models by the
  # `has_typed_eav` macro. Owns the `UNSET_SCOPE` / `ALL_SCOPES` sentinels
  # and the `resolve_scope` chain; delegates the heavy lifting to
  # `FilterQuery` (multi-filter SQL composition) and `BulkRead` (bulk
  # per-record reads). `bulk_set_typed_eav_values` stays as a 3-line wrapper
  # around the existing `BulkWrite` executor.
  module EntityQuery
    # Sentinel for the `scope:` kwarg default. Distinguishes "kwarg not
    # passed -> resolve from ambient" (UNSET_SCOPE) from "explicitly nil ->
    # filter to global-only fields" (preserves prior behavior).
    UNSET_SCOPE = Object.new.freeze

    # Sentinel returned by `resolve_scope` inside an `unscoped { }` block.
    # Signals the caller to skip the scope filter entirely (return fields
    # across all partitions, not just global).
    ALL_SCOPES = Object.new.freeze

    # Query by custom field values. Accepts an array of filter hashes
    # or a hash of hashes (from form params).
    #
    # Each filter needs:
    #   :name or :n      - the field name
    #   :op or :operator - the operator (default: :eq)
    #   :value or :v     - the comparison value
    #
    #   Contact.where_typed_eav(
    #     { name: "age", op: :gt, value: 21 },
    #     { name: "city", value: "Portland" }   # op defaults to :eq
    #   )
    #
    # `scope:` and `parent_scope:` behavior:
    #   - omitted        -> resolve from ambient (`with_scope` -> resolver -> raise/nil)
    #   - passed a value -> use verbatim (explicit override; admin/test path)
    #   - passed nil     -> filter to global-only on that axis (prior behavior)
    #
    # `include_missing:` behavior (opt-in, default `false`):
    #   - Only meaningful when paired with `:is_null`. When `true`, the
    #     `:is_null` predicate broadens to the user-intuitive "is empty"
    #     semantic: matches hosts with **no non-NULL value** for the field —
    #     including hosts that have no `typed_eav_values` row at all
    #     (Reading A from ADR-0006).
    #   - With `:is_not_null`, the kwarg is a no-op (lets filter UIs pass
    #     it uniformly without branching per operator).
    #   - With any other operator (`:eq`, `:gt`, `:contains`, `:between`,
    #     `:starts_with`, `:references`, etc.), the kwarg is silently
    #     ignored.
    def where_typed_eav(*filters, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE, include_missing: false)
      resolved = resolve_scope(scope, parent_scope)
      effective_scope, effective_parent = scope_pair(resolved)

      TypedEAV::FilterQuery.new(
        model: self,
        filters: filters,
        scope: effective_scope,
        parent_scope: effective_parent,
        include_missing: include_missing,
      ).to_relation
    end

    # Shorthand for single-field queries.
    #
    #   Contact.with_field("age", :gt, 21)
    #   Contact.with_field("active", true)      # op defaults to :eq
    #   Contact.with_field("name", :contains, "smith")
    #
    # Accepts both `scope:` and `parent_scope:` kwargs with the same
    # ambient/explicit/nil semantics as `where_typed_eav`. Single-scope
    # callers (no `parent_scope:`) are unaffected.
    #
    # `include_missing:` (opt-in, default `false`) is forwarded to
    # `where_typed_eav` unchanged. See its RDoc for full semantics — in
    # short: meaningful only with `:is_null` (Reading A "no non-NULL
    # value," includes no-row hosts), no-op with `:is_not_null`, silently
    # ignored otherwise.
    def with_field(name, operator_or_value = nil, value = nil, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE, include_missing: false)
      filter = if value.nil? && !operator_or_value.is_a?(Symbol)
                 # Two-arg form: with_field("name", "value") implies :eq
                 { name: name, op: :eq, value: operator_or_value }
               else
                 { name: name, op: operator_or_value, value: value }
               end
      where_typed_eav(filter, scope: scope, parent_scope: parent_scope, include_missing: include_missing)
    end

    # Returns field definitions for this entity type.
    #
    # `scope:` and `parent_scope:` behavior:
    #   - omitted        -> resolve from ambient (`with_scope` -> resolver -> raise/nil)
    #   - passed a value -> use verbatim (explicit override; admin/test path)
    #   - passed nil     -> filter to global-only on that axis (prior behavior preserved)
    def typed_eav_definitions(scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)
      resolved = resolve_scope(scope, parent_scope)
      if resolved.equal?(ALL_SCOPES)
        TypedEAV::Partition.visible_fields(entity_type: name, mode: :all_partitions)
      else
        s, ps = resolved
        TypedEAV::Partition.visible_fields(entity_type: name, scope: s, parent_scope: ps)
      end
    end

    # Bulk read API. Returns `{ record_id => { field_name => value } }` for
    # an Enumerable of host records — the class-method bulk variant of
    # `HasTypedEAV::InstanceMethods#typed_eav_hash`. N+1-free regardless of
    # record count or field count. See `TypedEAV::BulkRead` for the pipeline
    # and query bound.
    def typed_eav_hash_for(records)
      TypedEAV::BulkRead.new(host_class: self, records: records).to_hash
    end

    # Bulk write API. Sets the same `values_by_field_name` Hash on every
    # record in `records` inside ONE outer ActiveRecord transaction with a
    # SAVEPOINT-PER-RECORD failure-isolation envelope. See `TypedEAV::BulkWrite`
    # for the transaction shape, error-aggregation contract, and the
    # `version_grouping:` semantics.
    def bulk_set_typed_eav_values(records, values_by_field_name, version_grouping: :default)
      TypedEAV::BulkWrite.execute(
        host_class: self,
        records: records,
        values_by_field_name: values_by_field_name,
        version_grouping: version_grouping,
      )
    end

    private

    # Translates a resolved scope into the `(scope, parent_scope)` pair
    # passed to `FilterQuery`. Preserves the `ALL_SCOPES` sentinel through
    # to `FilterQuery` (it routes to the multimap branch); for resolved
    # tuples, returns the pair verbatim.
    def scope_pair(resolved)
      return [ALL_SCOPES, nil] if resolved.equal?(ALL_SCOPES)

      resolved
    end

    # Resolves the scope and parent_scope kwargs into a concrete tuple for
    # field-definition lookup. Returns one of:
    #   - `ALL_SCOPES`            — inside `TypedEAV.unscoped { }`, atomic bypass.
    #   - `[scope, parent_scope]` — both elements are String or nil.
    # Raises:
    #   - `TypedEAV::ScopeRequired` when the model declares `scope_method:`
    #     but ambient scope can't be resolved and `require_scope` is true.
    def resolve_scope(explicit_scope, explicit_parent_scope)
      return ALL_SCOPES if TypedEAV.unscoped?

      if explicit_given?(explicit_scope, explicit_parent_scope)
        return resolve_explicit_scope(explicit_scope, explicit_parent_scope)
      end

      return [nil, nil] unless typed_eav_scope_method

      resolve_ambient_scope
    end

    def explicit_given?(explicit_scope, explicit_parent_scope)
      !explicit_scope.equal?(UNSET_SCOPE) || !explicit_parent_scope.equal?(UNSET_SCOPE)
    end

    # Per-slot normalize via `ScopeTuple.normalize_permissive` to coerce
    # scalars/AR-records to strings, with UNSET_SCOPE collapsing to nil for
    # the corresponding slot. Orphan-parent invariant: a request for
    # parent_scope without scope is dead-letter — silently narrow ps to nil.
    def resolve_explicit_scope(explicit_scope, explicit_parent_scope)
      s = normalize_explicit_or_nil(explicit_scope, slot: :scope)
      ps = normalize_explicit_or_nil(explicit_parent_scope, slot: :parent)
      ps = nil unless TypedEAV::ScopeTuple.invariant_satisfied?(s, ps)
      [s, ps]
    end

    def normalize_explicit_or_nil(value, slot:)
      return nil if value.equal?(UNSET_SCOPE)

      normalize_explicit_slot(value, slot: slot)
    end

    def normalize_explicit_slot(value, slot:)
      tuple = slot == :scope ? [value, nil] : [nil, value]
      index = slot == :scope ? :first : :last
      TypedEAV::ScopeTuple.normalize_permissive(tuple)&.public_send(index)
    end

    # Ambient resolver path (via `with_scope` stack or configured lambda).
    # `TypedEAV.current_scope` already validates the return shape to
    # `nil | [a, b]` — no shape check is duplicated here.
    def resolve_ambient_scope
      resolved = TypedEAV.current_scope
      return resolved if resolved

      raise_scope_required if TypedEAV.config.require_scope

      [nil, nil]
    end

    def raise_scope_required
      raise TypedEAV::ScopeRequired,
            "No ambient scope resolvable for #{name}. " \
            "Wrap the call in `TypedEAV.with_scope(value) { ... }`, " \
            "configure `TypedEAV.config.scope_resolver`, or use " \
            "`TypedEAV.unscoped { ... }` to deliberately bypass."
    end
  end
end
