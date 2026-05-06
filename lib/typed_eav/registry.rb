# frozen_string_literal: true

module TypedEAV
  # Registry of entity types (host ActiveRecord models) that have opted
  # into typed fields via `has_typed_eav`. Tracks optional field-type
  # restrictions per entity.
  #
  # Populated automatically when a host model calls `has_typed_eav`;
  # read by Field::Base#validate_type_allowed_for_entity to enforce
  # restrictions on field creation.
  #
  # Implementation note: see Config for why the class-level accessor is
  # hand-rolled rather than provided by ActiveSupport::Configurable.
  class Registry
    class << self
      # Mutable registry of entity_type => {types: [...]} entries. Lazy-init
      # so first access seeds an empty Hash; reset! clears in place so the
      # same Hash object is preserved across resets (callers that captured
      # a reference don't end up with a stale snapshot).
      def entities
        @entities ||= {}
      end
      attr_writer :entities

      # Register an entity type with optional type restrictions and optional
      # versioning opt-in.
      #
      # `versioned:` is the per-entity Phase 04 opt-in flag. When true, AND
      # `Config.versioning = true` at engine load (gem-level master switch),
      # the Phase 04 subscriber writes a TypedEAV::ValueVersion row per
      # Value mutation on this entity_type. Default false — apps not using
      # versioning pay zero cost (one Hash#dig per write at most when
      # `Config.versioning = true`, nothing when off).
      #
      # Backward compat: existing callers `register(name, types: types)`
      # continue to work — the new kwarg defaults to false. The entry hash
      # shape changes from `{ types: types }` to `{ types: types, versioned:
      # versioned }`, but consumers (Registry.allowed_types_for,
      # Registry.type_allowed?) only read the `:types` key, so they're
      # unaffected.
      def register(entity_type, types: nil, versioned: false)
        entities[entity_type] = { types: types, versioned: versioned }
      end

      # All registered entity type names.
      def entity_types
        entities.keys
      end

      # Field-type restrictions for a given entity, or nil if unrestricted.
      def allowed_types_for(entity_type)
        entry = entities[entity_type]
        return nil unless entry

        entry[:types]
      end

      # Whether a field type class is allowed for an entity.
      def type_allowed?(entity_type, field_type_class)
        allowed = allowed_types_for(entity_type)
        return true if allowed.nil?

        type_name = field_type_class.name.demodulize.underscore.to_sym
        allowed.include?(type_name)
      end

      # Whether the entity type opted into Phase 04 versioning.
      #
      # Returns the stored boolean for opted-in entities; false for
      # unregistered entities (defensive — callers might query before
      # `has_typed_eav` runs in a particular load order). The Phase 04
      # subscriber calls this on every Value write when `Config.versioning =
      # true` — performance is one Hash#dig per write, negligible.
      #
      # `entities.dig(entity_type, :versioned)` returns nil when
      # `entities[entity_type]` is missing (no register call) OR when the
      # entry is `{ types: ..., versioned: nil }` (impossible by current
      # register contract — kwarg default is false). The `|| false`
      # normalizes to a strict boolean so callers can `if versioned?(...)`
      # without three-way logic.
      def versioned?(entity_type)
        entities.dig(entity_type, :versioned) || false
      end

      # Clear all registrations (test isolation).
      def reset!
        entities.clear
      end
    end
  end
end
