# frozen_string_literal: true

module TypedEAV
  module HasTypedEAV
    # Per-record API mixed into host AR models by the `has_typed_eav` macro.
    # Reads/writes typed values via field name, returns scope/parent_scope
    # via the configured accessor methods, and builds the collision-collapsed
    # per-instance definition map (delegating to `Partition.definitions_by_name`
    # so the class-query path and the instance path share one source of truth).
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
        existing_field_ids = existing_typed_value_field_ids

        typed_eav_defs_by_name.each_value do |field|
          next if existing_field_ids.include?(field.id)

          typed_values.build(field: field, value: field.default_value)
        end

        typed_values
      end

      # Bulk assign values by field NAME. Coexists with (rather than replaces)
      # the `accepts_nested_attributes_for :typed_values` setter declared
      # on the host model, which accepts entries keyed by field ID.
      #
      # The nested-attributes setter is the standard Rails form contract
      # (forms post `field_id` as a hidden input per value row). This setter
      # takes entries keyed by field *name* and translates them to field
      # IDs before handing off to the nested-attributes setter. It also
      # enforces the `types:` restriction declared on `has_typed_eav` and
      # supports `_destroy: true` for removing a value by name.
      #
      #   record.typed_eav_attributes = [
      #     { name: "age",       value: 30 },
      #     { name: "email",     value: "test@example.com" },
      #     { name: "old_field", _destroy: true },
      #   ]
      #
      # Pick the one that fits: forms -> typed_values_attributes=, scripting
      # -> typed_eav_attributes=. They can't both run in the same save.
      def typed_eav_attributes=(attributes)
        fields_by_name     = typed_eav_defs_by_name
        values_by_field_id = typed_values.index_by(&:field_id)

        nested = normalize_typed_eav_attributes(attributes).filter_map do |attrs|
          build_or_update_typed_value(attrs, fields_by_name, values_by_field_id)
        end

        self.typed_values_attributes = nested if nested.any?
      end

      alias typed_eav= typed_eav_attributes=

      # Get a specific field's value by name. Honors an already-loaded
      # `typed_values` association so list-page callers that preloaded
      # `typed_values: :field` don't trigger a fresh query per record.
      #
      # On a global+scoped name collision, prefer the value bound to the
      # winning field_id (scoped wins). Without this guard, a stray value
      # row attached to a shadowed global field would surface here even
      # though writes route through the scoped winner.
      def typed_eav_value(name)
        winning    = typed_eav_defs_by_name[name.to_s]
        # Skip orphans (`v.field` nil — definition deleted out from under
        # the value via raw SQL or a missing FK cascade) so a stray row
        # can't crash the read path with NoMethodError.
        candidates = loaded_typed_values_with_fields.select { |v| v.field && v.field.name == name.to_s }
        select_winning_value(candidates, winning)&.value
      end

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

        loaded_typed_values_with_fields.each_with_object({}) do |tv, hash|
          # Skip orphans (`tv.field` nil — definition deleted out from under
          # the value) so the hash isn't crashy when stale rows linger.
          next unless tv.field

          assign_hash_value(hash, tv, winning_ids_by_name)
        end
      end

      private

      # Field ids already represented in `typed_values`, accounting for both
      # persisted rows and in-memory builds. Three branches:
      #
      # - **new_record? or loaded?** — walk the in-memory collection, with a
      #   `field_id || field&.id` fallback so callers who bypass the
      #   belongs_to FK setter (e.g. assigning via `association(:field).target=`)
      #   still get dedup-correct results.
      # - **persisted + unloaded** — combine a cheap `pluck` of persisted rows
      #   with any in-memory builds in `typed_values.target`. AR's
      #   `add_to_target` (called by `build`) does not flip `@loaded`, so
      #   target-resident builds are otherwise invisible to `pluck`. The
      #   persisted-no-builds happy path is unaffected: `target` is empty,
      #   `pluck` runs once, no extra association load.
      def existing_typed_value_field_ids
        return walk_in_memory_typed_value_field_ids if new_record? || typed_values.loaded?

        persisted = typed_values.pluck(:field_id)
        in_memory = typed_values.target.reject(&:persisted?).filter_map { |tv| tv.field_id || tv.field&.id }
        (persisted + in_memory).uniq
      end

      def walk_in_memory_typed_value_field_ids
        typed_values.filter_map { |tv| tv.field_id || tv.field&.id }
      end

      # Selects the candidate value for `typed_eav_value`. On a collision,
      # prefer the row attached to the winning field_id; otherwise fall back
      # to the first orphan/non-collision candidate.
      def select_winning_value(candidates, winning)
        return candidates.first unless winning

        candidates.detect { |v| (v.field_id || v.field&.id) == winning.id } || candidates.first
      end

      # Hash-builder helper for `typed_eav_hash`. When a winner is registered
      # for the name, only its row may surface (scoped-beats-global). When
      # no winner is registered (definition deleted while values remain),
      # fall back to first-wins so the hash isn't lossy.
      def assign_hash_value(hash, value_row, winning_ids_by_name)
        name = value_row.field.name
        winning_id = winning_ids_by_name[name]
        effective_id = value_row.field_id || value_row.field&.id

        if winning_id
          hash[name] = value_row.value if effective_id == winning_id
        else
          hash[name] = value_row.value unless hash.key?(name)
        end
      end

      # Normalize the input to `typed_eav_attributes=` into an Array of
      # plain Hashes. Accepts ActionController::Parameters, hash-of-hashes
      # (form params), Array, or any Enumerable.
      def normalize_typed_eav_attributes(attributes)
        attributes = attributes.to_h if attributes.respond_to?(:permitted?)
        attributes = attributes.values if attributes.is_a?(Hash)
        Array(attributes)
      end

      # Translate a single name-keyed attribute hash into the corresponding
      # nested-attributes entry (id-keyed), or builds a new value row in-place.
      # Returns nil when the field is unknown, the field type is excluded by
      # the host's `types:` restriction, or when the new-row path already
      # added to the association (no nested-attributes entry needed).
      def build_or_update_typed_value(attrs, fields_by_name, values_by_field_id)
        attrs = attrs.to_h.with_indifferent_access
        field = fields_by_name[attrs[:name]]
        return nil unless field
        return nil if typed_eav_type_disallowed?(field)

        existing = values_by_field_id[field.id]
        return { id: existing&.id, _destroy: true } if destroy_flag?(attrs)
        return { id: existing.id, value: attrs[:value] } if existing

        typed_values.build(field: field, value: attrs[:value])
        nil
      end

      def typed_eav_type_disallowed?(field)
        allowed = self.class.allowed_typed_eav_types
        allowed&.exclude?(field.field_type_name)
      end

      def destroy_flag?(attrs)
        ActiveRecord::Type::Boolean.new.cast(attrs[:_destroy])
      end

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

      # Field definitions indexed by name with deterministic collision
      # handling: when both a global (scope=NULL) and a scoped field share
      # a name, the most-specific (scoped) definition wins. Delegates to
      # `TypedEAV::Partition.definitions_by_name` so the class-query path
      # and the instance path share one source of truth.
      #
      # ## Bulk-write memoization (Phase 06 plan 05)
      #
      # `bulk_set_typed_eav_values` sets `Thread.current[:typed_eav_bulk_defs_memo]`
      # to a Hash before its records loop. We consult it here so the per-
      # record `typed_eav_attributes=` call does NOT issue a fresh
      # `typed_eav_definitions` SELECT per record. AR's per-block query
      # cache (`ActiveRecord::Base.cache`) is invalidated by every write —
      # because each record's INSERT clears the cache — so cache-do alone
      # cannot keep field-definition reads N+1-free across the bulk loop.
      # The thread-local memo is the explicit fallback documented in plan
      # 06-05 §T3 notes; it pre-warms once per `[host_class, scope,
      # parent_scope]` tuple and reuses across every record in that tuple.
      #
      # Outside a bulk operation the memo is nil and we fall through to
      # the standard read path — zero overhead.
      def typed_eav_defs_by_name
        memo = Thread.current[:typed_eav_bulk_defs_memo]
        if memo
          key = [self.class.name, typed_eav_scope, typed_eav_parent_scope]
          memo[key] ||= TypedEAV::Partition.definitions_by_name(typed_eav_definitions)
        else
          TypedEAV::Partition.definitions_by_name(typed_eav_definitions)
        end
      end
    end
  end
end
