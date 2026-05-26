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
  # ## Architecture (ADR-0002, 0.3.0 refactor)
  #
  # This file holds the macro entry + macro-time guards. Per-record API
  # lives in `TypedEAV::HasTypedEAV::InstanceMethods`. Class-level query
  # orchestration lives in `TypedEAV::EntityQuery` (extended onto the host
  # class), which delegates the heavy lifting to `TypedEAV::FilterQuery`
  # (where_typed_eav) and `TypedEAV::BulkRead` (typed_eav_hash_for).
  # `bulk_set_typed_eav_values` continues to delegate to `TypedEAV::BulkWrite`.
  module HasTypedEAV
    extend ActiveSupport::Concern

    autoload :InstanceMethods, "typed_eav/has_typed_eav/instance_methods"

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
      #                          `ArgumentError` at class load.
      #   types:               - restrict which field types are allowed (array of symbols)
      #                          e.g. [:text, :integer, :boolean]; default: all types
      #   versioned:           - Phase 04 opt-in: when true, mutations to typed values on
      #                          this entity type are recorded in typed_eav_value_versions.
      #                          Requires `TypedEAV.config.versioning = true` (the gem-
      #                          level master switch — default false).
      #
      # Configuration error: `parent_scope_method:` without `scope_method:` raises
      # `ArgumentError` at class load time. This closes the silent dead-letter mode
      # where ambient scope resolution would short-circuit to `[nil, nil]` for a model
      # declaring parent_scope but no scope, routing every query to the global-only
      # branch and silently discarding the parent_scope intent.
      #
      # Public DSL macro modeled on `acts_as_*`; renaming would break callers.
      def has_typed_eav(scope_method: nil, parent_scope_method: nil, types: nil, versioned: false) # rubocop:disable Naming/PredicatePrefix
        validate_has_typed_eav_options!(scope_method, parent_scope_method)

        # class_attribute rather than cattr_accessor: class variables are
        # copied-on-write across subclasses and reload well under Rails'
        # code reloader. Normalize the types list to strings once so hot
        # paths (type-restriction validation, `typed_eav_attributes=`)
        # don't have to re-map per call.
        class_attribute :typed_eav_scope_method, instance_accessor: false, default: scope_method
        class_attribute :typed_eav_parent_scope_method, instance_accessor: false, default: parent_scope_method
        class_attribute :allowed_typed_eav_types, instance_accessor: false,
                                                  default: types && types.map(&:to_s).freeze

        include InstanceMethods
        extend TypedEAV::EntityQuery

        has_many :typed_values,
                 class_name: "TypedEAV::Value",
                 as: :entity,
                 inverse_of: :entity,
                 autosave: true,
                 dependent: :destroy

        accepts_nested_attributes_for :typed_values, allow_destroy: true

        TypedEAV.registry.register(name, types: types, versioned: versioned)
      end

      private

      # Macro-time configuration guard. Failing fast at class-load time is
      # strictly better than at query time because the misconfiguration is
      # static (a property of the macro call, not of the request). Closes
      # the silent dead-letter mode that would otherwise route every
      # parent-scope-aware query to the global-only branch.
      def validate_has_typed_eav_options!(scope_method, parent_scope_method)
        return unless parent_scope_method && !scope_method

        raise ArgumentError,
              "has_typed_eav: `parent_scope_method:` requires `scope_method:` to also be set. " \
              "A model declaring parent_scope without scope is a configuration error — " \
              "ambient resolution would silently return [nil, nil] and queries would dead-letter. " \
              "Either add `scope_method: :your_scope_method` or remove `parent_scope_method:`."
      end
    end
  end
end
