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

      # Register an entity type with optional type restrictions.
      def register(entity_type, types: nil)
        entities[entity_type] = { types: types }
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

      # Clear all registrations (test isolation).
      def reset!
        entities.clear
      end
    end
  end
end
