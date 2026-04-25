# frozen_string_literal: true

module TypedFields
  # Include this in any ActiveRecord model to give it typed custom fields.
  #
  #   class Contact < ApplicationRecord
  #     has_typed_fields
  #   end
  #
  #   class Contact < ApplicationRecord
  #     has_typed_fields scope_method: :tenant_id
  #   end
  #
  # This gives you:
  #
  #   # Reading/writing values
  #   contact.typed_values                    # => collection
  #   contact.initialize_typed_values         # => builds missing values with defaults
  #   contact.typed_fields_attributes = [...]  # => bulk assign via nested attributes
  #
  #   # Querying (the good stuff)
  #   Contact.where_typed_fields(
  #     { name: "age", op: :gt, value: 21 },
  #     { name: "status", op: :eq, value: "active" }
  #   )
  #
  #   # Or the short form with a hash:
  #   Contact.with_field("age", :gt, 21)
  #   Contact.with_field("status", "active")  # :eq is default
  #
  module HasTypedFields
    extend ActiveSupport::Concern

    # Indexes field definitions by name with deterministic collision
    # resolution: when a global (scope=NULL) and a scoped field share a
    # name, the scoped row wins. `for_entity(name, scope:)` returns both
    # rows on a collision, and a bare `index_by(&:name)` would let DB row
    # order pick the winner. Shared by the class-query path
    # (ClassQueryMethods#where_typed_fields) and the instance path
    # (InstanceMethods#typed_fields_defs_by_name) so the two can't drift.
    def self.definitions_by_name(defs)
      defs.to_a.sort_by { |d| d.scope.nil? ? 0 : 1 }.index_by(&:name)
    end

    # Indexes field definitions by name into a multi-map (one name →
    # array of fields). Used by the class-query path under
    # `TypedFields.unscoped { }`, where the same field name may legitimately
    # exist across multiple tenant partitions and we must OR-across all
    # matching field_ids per filter rather than collapse to a single row.
    def self.definitions_multimap_by_name(defs)
      defs.to_a.group_by(&:name)
    end

    class_methods do
      # Register this model as having typed fields.
      #
      # Options:
      #   scope_method: - method name that returns a scope value (e.g. :tenant_id)
      #                   for multi-tenant field isolation
      #   types:        - restrict which field types are allowed (array of symbols)
      #                   e.g. [:text, :integer, :boolean]
      #                   default: all types
      # Public DSL macro modeled on `acts_as_*`; renaming would break callers.
      def has_typed_fields(scope_method: nil, types: nil) # rubocop:disable Naming/PredicatePrefix
        # class_attribute rather than cattr_accessor: class variables are
        # copied-on-write across subclasses and reload well under Rails'
        # code reloader. Normalize the types list to strings once so hot
        # paths (type-restriction validation, `typed_fields_attributes=`)
        # don't have to re-map per call.
        class_attribute :typed_fields_scope_method, instance_accessor: false,
                                                    default: scope_method
        class_attribute :allowed_typed_field_types, instance_accessor: false,
                                                    default: types && types.map(&:to_s).freeze

        include InstanceMethods
        extend ClassQueryMethods

        has_many :typed_values,
                 class_name: "TypedFields::Value",
                 as: :entity,
                 inverse_of: :entity,
                 autosave: true,
                 dependent: :destroy

        accepts_nested_attributes_for :typed_values, allow_destroy: true

        # Register with the global registry
        TypedFields.registry.register(name, types: types)
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
      #   Contact.where_typed_fields(
      #     { name: "age", op: :gt, value: 21 },
      #     { name: "city", value: "Portland" }   # op defaults to :eq
      #   )
      #
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- input normalization + multimap branch + filter dispatch genuinely belong together; splitting hurts readability of the scope-collision logic.
      def where_typed_fields(*filters, scope: UNSET_SCOPE)
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

        # Resolve the scope once so we can branch on whether we're inside
        # `TypedFields.unscoped { }` (ALL_SCOPES) or a normal single-scope
        # query. Under ALL_SCOPES the same name can legitimately appear
        # across multiple tenant partitions; collapsing to one definition
        # would silently drop all but one tenant's matches. See the
        # multimap branch below.
        resolved = resolve_scope(scope)
        all_scopes = resolved.equal?(ALL_SCOPES)

        defs = if all_scopes
                 TypedFields::Field::Base.where(entity_type: name)
               else
                 TypedFields::Field::Base.for_entity(name, scope: resolved)
               end

        if all_scopes
          fields_multimap = HasTypedFields.definitions_multimap_by_name(defs)

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
              TypedFields::QueryBuilder.filter(f, operator, value).pluck(:entity_id)
            end.uniq

            query.where(id: union_ids)
          end
        else
          fields_by_name = HasTypedFields.definitions_by_name(defs)

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

            matching_ids = TypedFields::QueryBuilder.entity_ids(field, operator, value)
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
      def with_field(name, operator_or_value = nil, value = nil, scope: UNSET_SCOPE)
        if value.nil? && !operator_or_value.is_a?(Symbol)
          # Two-arg form: with_field("name", "value") implies :eq
          where_typed_fields({ name: name, op: :eq, value: operator_or_value }, scope: scope)
        else
          where_typed_fields({ name: name, op: operator_or_value, value: value }, scope: scope)
        end
      end

      # Returns field definitions for this entity type.
      #
      # `scope:` behavior:
      #   - omitted        → resolve from ambient (`with_scope` → resolver → raise/nil)
      #   - passed a value → use verbatim (explicit override; admin/test path)
      #   - passed nil     → filter to global-only fields (prior behavior preserved)
      def typed_field_definitions(scope: UNSET_SCOPE)
        resolved = resolve_scope(scope)
        if resolved.equal?(ALL_SCOPES)
          TypedFields::Field::Base.where(entity_type: name)
        else
          TypedFields::Field::Base.for_entity(name, scope: resolved)
        end
      end

      private

      # Resolves the scope kwarg into a concrete value for field-definition
      # lookup. See `typed_field_definitions` docs for kwarg semantics.
      # Raises `TypedFields::ScopeRequired` when the model declares
      # `scope_method:` but ambient scope can't be resolved and fail-closed
      # mode is enabled.
      def resolve_scope(explicit)
        # Explicit override (including explicit nil) — use verbatim.
        return TypedFields.normalize_scope(explicit) unless explicit.equal?(UNSET_SCOPE)

        # Inside `TypedFields.unscoped { }` — skip the scope filter entirely.
        return ALL_SCOPES if TypedFields.unscoped?

        # Models that did NOT opt into scoping must NOT see ambient scope.
        # If the host declared `has_typed_fields` without `scope_method:`, it
        # has no per-instance scope accessor, so `Value#validate_field_scope_matches_entity`
        # would reject any attempt to attach a scoped field anyway. Honoring
        # ambient scope here would surface scoped field definitions that the
        # model can never actually use — confusing in admin/forms — and would
        # leak cross-model ambient state into a model that never opted in.
        # An explicit `scope:` kwarg (handled above) still overrides this, so
        # admin/test paths retain the ability to query arbitrary scopes.
        return nil unless typed_fields_scope_method

        # Ambient resolver (via `with_scope` stack or configured lambda).
        resolved = TypedFields.current_scope
        return resolved unless resolved.nil?

        # Fail-closed: the model opted into scoping (`scope_method:` declared)
        # but nothing resolved. Raise so data can't leak across partitions.
        if typed_fields_scope_method && TypedFields.config.require_scope
          raise TypedFields::ScopeRequired,
                "No ambient scope resolvable for #{name}. " \
                "Wrap the call in `TypedFields.with_scope(value) { ... }`, " \
                "configure `TypedFields.config.scope_resolver`, or use " \
                "`TypedFields.unscoped { ... }` to deliberately bypass."
        end

        nil
      end
    end

    # ──────────────────────────────────────────────────
    # Instance methods
    # ──────────────────────────────────────────────────
    module InstanceMethods
      # The field definitions available for this record
      def typed_field_definitions
        self.class.typed_field_definitions(scope: typed_fields_scope)
      end

      # Current scope value (for multi-tenant)
      def typed_fields_scope
        return nil unless self.class.typed_fields_scope_method

        send(self.class.typed_fields_scope_method)&.to_s
      end

      # Build missing values with defaults for all available fields.
      # Useful in forms to show all fields even when no value exists yet.
      #
      # Iterates the collision-collapsed view (`typed_fields_defs_by_name`)
      # rather than the raw definitions list. Otherwise, when a record's
      # scope partition has both a global (scope=NULL) and a same-name
      # scoped field, `for_entity` returns BOTH rows and the form would
      # render two inputs for the same name — but only the scoped one
      # round-trips on save (it wins in `typed_fields_defs_by_name`).
      def initialize_typed_values
        existing_field_ids = typed_values.loaded? ? typed_values.map(&:field_id) : typed_values.pluck(:field_id)

        typed_fields_defs_by_name.each_value do |field|
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
      #   * This setter (`typed_fields_attributes=` / `typed_fields=`) takes
      #     entries keyed by field *name* and translates them to field IDs
      #     before handing off to the nested-attributes setter. It also
      #     enforces the `types:` restriction declared on `has_typed_fields`
      #     (rejecting entries for disallowed field types) and supports
      #     `_destroy: true` for removing a value by name. This is the
      #     ergonomic path for console/seed code:
      #       record.typed_fields_attributes = [
      #         { name: "age",       value: 30 },
      #         { name: "email",     value: "test@example.com" },
      #         { name: "old_field", _destroy: true },
      #       ]
      #
      # Pick the one that fits: forms -> typed_values_attributes=, scripting
      # -> typed_fields_attributes=. They can't both run in the same save.
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # rubocop:disable Metrics/AbcSize -- branches on existing/new/destroy and type-restriction in one place; splitting would obscure the precedence rules.
      def typed_fields_attributes=(attributes)
        attributes = attributes.to_h if attributes.respond_to?(:permitted?)
        attributes = attributes.values if attributes.is_a?(Hash)
        attributes = Array(attributes)

        fields_by_name = typed_fields_defs_by_name
        values_by_field_id = typed_values.index_by(&:field_id)

        nested = attributes.filter_map do |attrs|
          attrs = attrs.to_h.with_indifferent_access

          field = fields_by_name[attrs[:name]]
          next unless field

          # Enforce type restrictions. Normalized to strings at registration
          # time (see `has_typed_fields`), so no per-call mapping.
          allowed = self.class.allowed_typed_field_types
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
      alias typed_fields= typed_fields_attributes=

      # Get a specific field's value by name. Honors an already-loaded
      # `typed_values` association so list-page callers that preloaded
      # `typed_values: :field` don't trigger a fresh query per record.
      #
      # On a global+scoped name collision, prefer the value bound to the
      # winning field_id (scoped wins). Without this guard, a stray value
      # row attached to a shadowed global field would surface here even
      # though writes route through the scoped winner.
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity -- name-collision precedence + orphan guard + already-loaded preload reuse.
      def typed_field_value(name)
        winning = typed_fields_defs_by_name[name.to_s]
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
      def set_typed_field_value(name, value)
        field = typed_fields_defs_by_name[name.to_s]
        return unless field

        existing = typed_values.detect { |v| v.field_id == field.id }
        if existing
          existing.value = value
        else
          typed_values.build(field: field, value: value)
        end
      end

      # Hash of all field values: { "field_name" => value, ... }. Same
      # preload semantics as `typed_field_value` — respects already-loaded
      # associations instead of rebuilding the relation.
      #
      # Collision-safe: on a global+scoped name overlap, the value attached
      # to the winning field_id wins (scoped). Without this guard, a stray
      # row tied to a shadowed global field could surface here even though
      # writes route through the scoped winner.
      def typed_fields_hash
        winning_ids_by_name = typed_fields_defs_by_name.transform_values(&:id)
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
      # scoped definition wins. Delegates to `HasTypedFields.definitions_by_name`
      # so the class-query path and the instance path share one source of truth.
      def typed_fields_defs_by_name
        HasTypedFields.definitions_by_name(typed_field_definitions)
      end
    end
  end
end
