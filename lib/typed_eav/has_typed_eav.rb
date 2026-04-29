# frozen_string_literal: true

module TypedEAV
  # Include this in any ActiveRecord model to give it typed custom fields.
  #
  #   class Contact < ApplicationRecord
  #     has_typed_eav
  #   end
  #
  #   class Contact < ApplicationRecord
  #     has_typed_eav scope_method: :tenant_id
  #   end
  #
  # This gives you:
  #
  #   # Reading/writing values
  #   contact.typed_values                    # => collection
  #   contact.initialize_typed_values         # => builds missing values with defaults
  #   contact.typed_eav_attributes = [...]    # => bulk assign via nested attributes
  #
  #   # Querying (the good stuff)
  #   Contact.where_typed_eav(
  #     { name: "age", op: :gt, value: 21 },
  #     { name: "status", op: :eq, value: "active" }
  #   )
  #
  #   # Or the short form with a hash:
  #   Contact.with_field("age", :gt, 21)
  #   Contact.with_field("status", "active")  # :eq is default
  #
  module HasTypedEAV
    extend ActiveSupport::Concern

    # Indexes field definitions by name with deterministic three-way
    # collision resolution: when global (scope=NULL, parent_scope=NULL),
    # scope-only (scope set, parent_scope=NULL), and full-triple (both set)
    # fields share a name, the most-specific row wins.
    #
    # Sort key `[scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` orders rows:
    #   [0, 0] global              (least specific) → comes first
    #   [1, 0] scope-only          (middle)
    #   [1, 1] full triple         (most specific)  → comes last
    #
    # `index_by(&:name)` keeps the LAST entry on duplicate keys (Rails
    # convention via `Array#to_h`), so most-specific wins. The two-key sort
    # extends the prior "scoped beats global" rule into "two-key beats
    # one-key beats global" without changing the index_by-last-wins
    # mechanism. The `(scope=NULL, parent_scope=NOT NULL)` slot is unreachable
    # by construction (orphan-parent invariant in Field::Base), so the
    # ordering is exhaustive across the three valid shapes.
    #
    # `for_entity(name, scope:, parent_scope:)` returns the union across
    # all three shapes on a collision, and a bare `index_by(&:name)` would
    # let DB row order pick the winner. Shared by the class-query path
    # (ClassQueryMethods#where_typed_eav) and the instance path
    # (InstanceMethods#typed_eav_defs_by_name) so the two can't drift.
    def self.definitions_by_name(defs)
      defs.to_a
          .sort_by { |d| [d.scope.nil? ? 0 : 1, d.parent_scope.nil? ? 0 : 1] }
          .index_by(&:name)
    end

    # Indexes field definitions by name into a multi-map (one name →
    # array of fields). Used by the class-query path under
    # `TypedEAV.unscoped { }`, where the same field name may legitimately
    # exist across multiple tenant partitions and we must OR-across all
    # matching field_ids per filter rather than collapse to a single row.
    def self.definitions_multimap_by_name(defs)
      defs.to_a.group_by(&:name)
    end

    class_methods do
      # Register this model as having typed fields.
      #
      # Options:
      #   scope_method:        - method name that returns a scope value (e.g. :tenant_id)
      #                          for multi-tenant field isolation. Optional; nil means
      #                          the model is "global" (no per-tenant partitioning).
      #   parent_scope_method: - method name that returns a parent_scope value
      #                          (e.g. :workspace_id) for two-level partitioning under
      #                          `scope_method:`. Optional; nil means the model uses a
      #                          single-axis partition. REQUIRES `scope_method:` to also
      #                          be set — declaring `parent_scope_method:` alone raises
      #                          `ArgumentError` at class load (see below).
      #   types:               - restrict which field types are allowed (array of symbols)
      #                          e.g. [:text, :integer, :boolean]
      #                          default: all types
      #
      # Configuration error: `parent_scope_method:` without `scope_method:` raises
      # `ArgumentError` at class load time. This closes the silent dead-letter mode
      # where ambient scope resolution would short-circuit to `[nil, nil]` for a model
      # declaring parent_scope but no scope, routing every query to the global-only
      # branch and silently discarding the parent_scope intent.
      #
      # Public DSL macro modeled on `acts_as_*`; renaming would break callers.
      def has_typed_eav(scope_method: nil, parent_scope_method: nil, types: nil) # rubocop:disable Naming/PredicatePrefix
        # Macro-time configuration guard. Failing fast at class-load time is strictly
        # better than at query time because the misconfiguration is static (a
        # property of the macro call, not of the request). Closes the silent
        # dead-letter mode that would otherwise route every parent-scope-aware
        # query to the global-only branch.
        if parent_scope_method && !scope_method
          raise ArgumentError,
                "has_typed_eav: `parent_scope_method:` requires `scope_method:` to also be set. " \
                "A model declaring parent_scope without scope is a configuration error — " \
                "ambient resolution would silently return [nil, nil] and queries would dead-letter. " \
                "Either add `scope_method: :your_scope_method` or remove `parent_scope_method:`."
        end

        # class_attribute rather than cattr_accessor: class variables are
        # copied-on-write across subclasses and reload well under Rails'
        # code reloader. Normalize the types list to strings once so hot
        # paths (type-restriction validation, `typed_eav_attributes=`)
        # don't have to re-map per call.
        class_attribute :typed_eav_scope_method, instance_accessor: false,
                                                 default: scope_method
        class_attribute :typed_eav_parent_scope_method, instance_accessor: false,
                                                        default: parent_scope_method
        class_attribute :allowed_typed_eav_types, instance_accessor: false,
                                                  default: types && types.map(&:to_s).freeze

        include InstanceMethods
        extend ClassQueryMethods

        has_many :typed_values,
                 class_name: "TypedEAV::Value",
                 as: :entity,
                 inverse_of: :entity,
                 autosave: true,
                 dependent: :destroy

        accepts_nested_attributes_for :typed_values, allow_destroy: true

        # Register with the global registry
        TypedEAV.registry.register(name, types: types)
      end
    end

    # ──────────────────────────────────────────────────
    # Class-level query methods
    # ──────────────────────────────────────────────────
    module ClassQueryMethods
      # Sentinel for the `scope:` kwarg default. Distinguishes "kwarg not
      # passed → resolve from ambient" (UNSET_SCOPE) from "explicitly nil →
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
      #   :name or :n    - the field name
      #   :op or :operator - the operator (default: :eq)
      #   :value or :v   - the comparison value
      #
      #   Contact.where_typed_eav(
      #     { name: "age", op: :gt, value: 21 },
      #     { name: "city", value: "Portland" }   # op defaults to :eq
      #   )
      #
      # `scope:` and `parent_scope:` behavior:
      #   - omitted        → resolve from ambient (`with_scope` → resolver → raise/nil)
      #   - passed a value → use verbatim (explicit override; admin/test path)
      #   - passed nil     → filter to global-only on that axis (prior behavior)
      #
      # Single-scope BC: callers that don't pass `parent_scope:` see no
      # behavior change. The kwarg defaults to `UNSET_SCOPE` — ambient
      # resolution applies if the model declares `parent_scope_method:`,
      # otherwise resolves to nil.
      #
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- input normalization + multimap branch + filter dispatch genuinely belong together; splitting hurts readability of the scope-collision logic.
      def where_typed_eav(*filters, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)
        # Normalize input: accept splat args, a single array, a single filter hash,
        # a hash-of-hashes (form params), or ActionController::Parameters.
        filters = filters.map { |f| f.respond_to?(:to_unsafe_h) ? f.to_unsafe_h : f }

        if filters.size == 1
          inner = filters.first
          inner = inner.to_unsafe_h if inner.respond_to?(:to_unsafe_h)

          if inner.is_a?(Array)
            filters = inner
          elsif inner.is_a?(Hash)
            # A single filter hash has keys like :name/:n, :op, :value/:v.
            # A hash-of-hashes (form params) has values that are all hashes.
            filter_keys = %i[name n op operator value v].map(&:to_s)
            filters = if inner.keys.any? { |k| filter_keys.include?(k.to_s) }
                        [inner]
                      else
                        inner.values
                      end
          end
        end

        filters = Array(filters)

        # Resolve the (scope, parent_scope) tuple once so we can branch on
        # whether we're inside `TypedEAV.unscoped { }` (ALL_SCOPES) or a
        # normal single-scope query. Under ALL_SCOPES the same name can
        # legitimately appear across multiple tenant partitions; collapsing
        # to one definition would silently drop all but one tenant's
        # matches. See the multimap branch below.
        resolved = resolve_scope(scope, parent_scope)
        all_scopes = resolved.equal?(ALL_SCOPES)

        defs = if all_scopes
                 # Multimap branch is structurally unchanged — atomic-bypass
                 # per CONTEXT.md drops both scope AND parent_scope predicates.
                 # The OR-collapse at field_id level naturally OR's across all
                 # (scope, parent_scope) combinations.
                 TypedEAV::Field::Base.where(entity_type: name)
               else
                 s, ps = resolved
                 TypedEAV::Field::Base.for_entity(name, scope: s, parent_scope: ps)
               end

        if all_scopes
          fields_multimap = HasTypedEAV.definitions_multimap_by_name(defs)

          filters.inject(all) do |query, filter|
            filter = filter.to_h.with_indifferent_access

            name     = filter[:n] || filter[:name]
            operator = (filter[:op] || filter[:operator] || :eq).to_sym
            value    = filter.key?(:v) ? filter[:v] : filter[:value]

            matching_fields = fields_multimap[name.to_s]
            unless matching_fields&.any?
              raise ArgumentError, "Unknown typed field '#{name}' for #{self.name}. " \
                                   "Available fields: #{fields_multimap.keys.join(", ")}"
            end

            # OR-across all field_ids that share this name (across tenants),
            # while preserving AND between filters via the chained `.where`.
            # Use the underlying Value scope (`.filter(...)`) and pluck
            # entity_ids — `entity_ids` returns a relation, and pluck collapses
            # it to a plain integer array we can union across tenants.
            union_ids = matching_fields.flat_map do |f|
              TypedEAV::QueryBuilder.filter(f, operator, value).pluck(:entity_id)
            end.uniq

            query.where(id: union_ids)
          end
        else
          fields_by_name = HasTypedEAV.definitions_by_name(defs)

          filters.inject(all) do |query, filter|
            filter = filter.to_h.with_indifferent_access

            name     = filter[:n] || filter[:name]
            operator = (filter[:op] || filter[:operator] || :eq).to_sym
            value    = filter.key?(:v) ? filter[:v] : filter[:value]

            field = fields_by_name[name.to_s]
            unless field
              raise ArgumentError, "Unknown typed field '#{name}' for #{self.name}. " \
                                   "Available fields: #{fields_by_name.keys.join(", ")}"
            end

            matching_ids = TypedEAV::QueryBuilder.entity_ids(field, operator, value)
            query.where(id: matching_ids)
          end
        end
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
      def with_field(name, operator_or_value = nil, value = nil, scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)
        if value.nil? && !operator_or_value.is_a?(Symbol)
          # Two-arg form: with_field("name", "value") implies :eq
          where_typed_eav(
            { name: name, op: :eq, value: operator_or_value },
            scope: scope, parent_scope: parent_scope,
          )
        else
          where_typed_eav(
            { name: name, op: operator_or_value, value: value },
            scope: scope, parent_scope: parent_scope,
          )
        end
      end

      # Returns field definitions for this entity type.
      #
      # `scope:` and `parent_scope:` behavior:
      #   - omitted        → resolve from ambient (`with_scope` → resolver → raise/nil)
      #   - passed a value → use verbatim (explicit override; admin/test path)
      #   - passed nil     → filter to global-only on that axis (prior behavior preserved)
      def typed_eav_definitions(scope: UNSET_SCOPE, parent_scope: UNSET_SCOPE)
        resolved = resolve_scope(scope, parent_scope)
        if resolved.equal?(ALL_SCOPES)
          TypedEAV::Field::Base.where(entity_type: name)
        else
          s, ps = resolved
          TypedEAV::Field::Base.for_entity(name, scope: s, parent_scope: ps)
        end
      end

      private

      # Resolves the scope and parent_scope kwargs into a concrete tuple for
      # field-definition lookup. See `typed_eav_definitions` docs for kwarg
      # semantics.
      #
      # Returns one of:
      #   - `ALL_SCOPES`          — inside `TypedEAV.unscoped { }`, atomic bypass.
      #   - `[scope, parent_scope]` — both elements are String or nil.
      # Raises:
      #   - `TypedEAV::ScopeRequired` when the model declares `scope_method:`
      #     but ambient scope can't be resolved and `require_scope` is true.
      #
      # Resolver-callable contract violations (`Config.scope_resolver`
      # returning a bare scalar) raise `ArgumentError` directly inside
      # `TypedEAV.current_scope` (plan 02), BEFORE this method consumes the
      # value. By the time `resolve_scope` calls `TypedEAV.current_scope`,
      # the result is guaranteed to be `nil` or a 2-element Array — no shape
      # check is duplicated here; that would be dead code.
      def resolve_scope(explicit_scope, explicit_parent_scope)
        # Inside `TypedEAV.unscoped { }` — atomic bypass, drops both predicates
        # entirely (per CONTEXT.md). The multimap branch in `where_typed_eav`
        # handles ALL_SCOPES; do not narrow to per-axis predicates inside unscoped.
        return ALL_SCOPES if TypedEAV.unscoped?

        # Determine the explicit-overrides path. If EITHER kwarg was passed
        # explicitly (i.e., not UNSET_SCOPE), normalize what was given and skip
        # ambient resolution entirely. Mixing explicit + ambient resolution
        # within one call would be confusing; explicit wins for the whole tuple.
        explicit_given = !explicit_scope.equal?(UNSET_SCOPE) || !explicit_parent_scope.equal?(UNSET_SCOPE)

        if explicit_given
          # Per-slot normalize: an explicit kwarg passes through `normalize_scope`
          # to coerce scalars/AR-records to strings, with UNSET_SCOPE collapsing
          # to nil for the corresponding slot. We pass `[value, nil]` to extract
          # the first slot and `[nil, value]` to extract the second so the
          # public `normalize_scope` BC contract (used by with_scope) handles
          # the per-slot coercion uniformly.
          s = if explicit_scope.equal?(UNSET_SCOPE)
                nil
              else
                TypedEAV.normalize_scope([explicit_scope, nil]).first
              end
          ps = if explicit_parent_scope.equal?(UNSET_SCOPE)
                 nil
               else
                 TypedEAV.normalize_scope([nil, explicit_parent_scope]).last
               end
          # Orphan-parent invariant at the read layer: a request for parent_scope
          # without scope is dead-letter (no rows can match — the Field-level
          # validator forbids `(scope=NULL, parent_scope=NOT NULL)` rows). Don't
          # raise here — just narrow the predicate. The Field-level invariant
          # (plan 03) prevents the corresponding write.
          return [s, ps]
        end

        # Models that did NOT opt into scoping must NOT see ambient scope.
        # If the host declared `has_typed_eav` without `scope_method:`, it
        # has no per-instance scope accessor, so `Value#validate_field_scope_matches_entity`
        # would reject any attempt to attach a scoped field anyway. Honoring
        # ambient scope here would surface scoped field definitions that the
        # model can never actually use — confusing in admin/forms — and would
        # leak cross-model ambient state into a model that never opted in.
        # An explicit `scope:` kwarg (handled above) still overrides this, so
        # admin/test paths retain the ability to query arbitrary scopes.
        #
        # NOTE: a model with `parent_scope_method:` but no `scope_method:` is
        # impossible to construct — the macro-time guard in `has_typed_eav`
        # raises `ArgumentError` at class-load time. If we get here, either
        # both are set or only `scope_method` is set, never only
        # `parent_scope_method`.
        return [nil, nil] unless typed_eav_scope_method

        # Ambient resolver (via `with_scope` stack or configured lambda). The
        # return value is already validated as `nil | [a, b]` by
        # `TypedEAV.current_scope` — no shape check needed here.
        resolved = TypedEAV.current_scope
        if resolved.nil?
          # Fail-closed: the model opted into scoping (`scope_method:` declared)
          # but nothing resolved. Raise so data can't leak across partitions.
          if TypedEAV.config.require_scope
            raise TypedEAV::ScopeRequired,
                  "No ambient scope resolvable for #{name}. " \
                  "Wrap the call in `TypedEAV.with_scope(value) { ... }`, " \
                  "configure `TypedEAV.config.scope_resolver`, or use " \
                  "`TypedEAV.unscoped { ... }` to deliberately bypass."
          end
          return [nil, nil]
        end

        # `resolved` is guaranteed to be a 2-element Array by current_scope's
        # contract (plan 02). Return verbatim — both halves already normalized.
        resolved
      end
    end

    # ──────────────────────────────────────────────────
    # Instance methods
    # ──────────────────────────────────────────────────
    module InstanceMethods
      # The field definitions available for this record
      def typed_eav_definitions
        self.class.typed_eav_definitions(
          scope: typed_eav_scope,
          parent_scope: typed_eav_parent_scope,
        )
      end

      # Current scope value (for multi-tenant)
      def typed_eav_scope
        return nil unless self.class.typed_eav_scope_method

        send(self.class.typed_eav_scope_method)&.to_s
      end

      # Current parent_scope value (for two-level partitioning).
      #
      # Returns nil for models that did not declare `parent_scope_method:` —
      # the method is defined unconditionally so callers (e.g. the Value-side
      # cross-axis validator) can `respond_to?` and read uniformly without
      # branching on `parent_scope_method` configuration. Mirrors the
      # `&.to_s` normalization on `typed_eav_scope`.
      def typed_eav_parent_scope
        return nil unless self.class.typed_eav_parent_scope_method

        send(self.class.typed_eav_parent_scope_method)&.to_s
      end

      # Build missing values with defaults for all available fields.
      # Useful in forms to show all fields even when no value exists yet.
      #
      # Iterates the collision-collapsed view (`typed_eav_defs_by_name`)
      # rather than the raw definitions list. Otherwise, when a record's
      # scope partition has both a global (scope=NULL) and a same-name
      # scoped field, `for_entity` returns BOTH rows and the form would
      # render two inputs for the same name — but only the scoped one
      # round-trips on save (it wins in `typed_eav_defs_by_name`).
      def initialize_typed_values
        existing_field_ids = typed_values.loaded? ? typed_values.map(&:field_id) : typed_values.pluck(:field_id)

        typed_eav_defs_by_name.each_value do |field|
          next if existing_field_ids.include?(field.id)

          typed_values.build(field: field, value: field.default_value)
        end

        typed_values
      end

      # Bulk assign values by field NAME. Coexists with (rather than replaces)
      # the `accepts_nested_attributes_for :typed_values` setter declared above,
      # which accepts entries keyed by field ID.
      #
      # Why both exist:
      #
      #   * The nested-attributes setter (`typed_values_attributes=`) is the
      #     standard Rails form contract. HTML form builders emit `field_id`
      #     as a hidden input per value row, so when a form posts back, the
      #     params look like:
      #       { typed_values_attributes: [
      #           { id: 12, field_id: 4, value: "40" }, ...
      #       ] }
      #     `accepts_nested_attributes_for` matches existing values by `id`.
      #
      #   * This setter (`typed_eav_attributes=` / `typed_eav=`) takes
      #     entries keyed by field *name* and translates them to field IDs
      #     before handing off to the nested-attributes setter. It also
      #     enforces the `types:` restriction declared on `has_typed_eav`
      #     (rejecting entries for disallowed field types) and supports
      #     `_destroy: true` for removing a value by name. This is the
      #     ergonomic path for console/seed code:
      #       record.typed_eav_attributes = [
      #         { name: "age",       value: 30 },
      #         { name: "email",     value: "test@example.com" },
      #         { name: "old_field", _destroy: true },
      #       ]
      #
      # Pick the one that fits: forms -> typed_values_attributes=, scripting
      # -> typed_eav_attributes=. They can't both run in the same save.
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # rubocop:disable Metrics/AbcSize -- branches on existing/new/destroy and type-restriction in one place; splitting would obscure the precedence rules.
      def typed_eav_attributes=(attributes)
        attributes = attributes.to_h if attributes.respond_to?(:permitted?)
        attributes = attributes.values if attributes.is_a?(Hash)
        attributes = Array(attributes)

        fields_by_name = typed_eav_defs_by_name
        values_by_field_id = typed_values.index_by(&:field_id)

        nested = attributes.filter_map do |attrs|
          attrs = attrs.to_h.with_indifferent_access

          field = fields_by_name[attrs[:name]]
          next unless field

          # Enforce type restrictions. Normalized to strings at registration
          # time (see `has_typed_eav`), so no per-call mapping.
          allowed = self.class.allowed_typed_eav_types
          next if allowed&.exclude?(field.field_type_name)

          existing = values_by_field_id[field.id]

          if ActiveRecord::Type::Boolean.new.cast(attrs[:_destroy])
            { id: existing&.id, _destroy: true }
          elsif existing
            { id: existing.id, value: attrs[:value] }
          else
            typed_values.build(field: field, value: attrs[:value])
            nil # build already added it, skip nested_attributes
          end
        end.compact

        self.typed_values_attributes = nested if nested.any?
      end

      # rubocop:enable Metrics/AbcSize
      alias typed_eav= typed_eav_attributes=

      # Get a specific field's value by name. Honors an already-loaded
      # `typed_values` association so list-page callers that preloaded
      # `typed_values: :field` don't trigger a fresh query per record.
      #
      # On a global+scoped name collision, prefer the value bound to the
      # winning field_id (scoped wins). Without this guard, a stray value
      # row attached to a shadowed global field would surface here even
      # though writes route through the scoped winner.
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity -- name-collision precedence + orphan guard + already-loaded preload reuse.
      def typed_eav_value(name)
        winning = typed_eav_defs_by_name[name.to_s]
        # Skip orphans (`v.field` nil — definition deleted out from under the
        # value via raw SQL or a missing FK cascade) so a stray row can't
        # crash the read path with NoMethodError.
        candidates = loaded_typed_values_with_fields.select { |v| v.field && v.field.name == name.to_s }
        tv = if winning && candidates.any? { |v| (v.field_id || v.field&.id) == winning.id }
               candidates.detect { |v| (v.field_id || v.field&.id) == winning.id }
             else
               candidates.first
             end
        tv&.value
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity

      # Set a specific field's value by name
      def set_typed_eav_value(name, value)
        field = typed_eav_defs_by_name[name.to_s]
        return unless field

        existing = typed_values.detect { |v| v.field_id == field.id }
        if existing
          existing.value = value
        else
          typed_values.build(field: field, value: value)
        end
      end

      # Hash of all field values: { "field_name" => value, ... }. Same
      # preload semantics as `typed_eav_value` — respects already-loaded
      # associations instead of rebuilding the relation.
      #
      # Collision-safe: on a global+scoped name overlap, the value attached
      # to the winning field_id wins (scoped). Without this guard, a stray
      # row tied to a shadowed global field could surface here even though
      # writes route through the scoped winner.
      def typed_eav_hash
        winning_ids_by_name = typed_eav_defs_by_name.transform_values(&:id)
        rows = loaded_typed_values_with_fields

        rows.each_with_object({}) do |tv, hash|
          # Skip orphans (`tv.field` nil — definition deleted out from under
          # the value) so the hash isn't crashy when stale rows linger.
          next unless tv.field

          name = tv.field.name
          winning_id = winning_ids_by_name[name]
          effective_id = tv.field_id || tv.field&.id

          # A winner is registered for this name: only its row is allowed.
          # If no winner is registered (definition deleted while values
          # remain), fall back to first-wins so the hash isn't lossy.
          if winning_id
            hash[name] = tv.value if effective_id == winning_id
          else
            hash[name] = tv.value unless hash.key?(name)
          end
        end
      end

      private

      # Returns typed_values with their fields, preferring already-loaded
      # associations. Callers on list pages should preload with
      # `includes(typed_values: :field)`; this method keeps the happy path
      # fast without forcing that contract.
      def loaded_typed_values_with_fields
        if typed_values.loaded?
          # Don't re-query if the caller already preloaded; ensure each value's
          # field is materialized (fall back to per-row load if the nested
          # `:field` was not preloaded).
          typed_values.to_a
        else
          typed_values.includes(:field).to_a
        end
      end

      # Field definitions indexed by name with deterministic collision handling:
      # when both a global (scope=NULL) and a scoped field share a name, the
      # scoped definition wins. Delegates to `HasTypedEAV.definitions_by_name`
      # so the class-query path and the instance path share one source of truth.
      def typed_eav_defs_by_name
        HasTypedEAV.definitions_by_name(typed_eav_definitions)
      end
    end
  end
end
