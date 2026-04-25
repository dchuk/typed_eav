# frozen_string_literal: true

require "active_support/configurable"

module TypedFields
  # Gem-level configuration for field type registration.
  #
  #   TypedFields.configure do |c|
  #     c.register_field_type :phone, "MyApp::Fields::Phone"
  #   end
  #
  # Accessible from anywhere via `TypedFields.config` (which returns this
  # class; class-level `field_types` / `register_field_type` / `field_class_for`
  # / `type_names` methods are defined below).
  class Config
    include ActiveSupport::Configurable

    # Default ambient-scope resolver. Auto-detects `acts_as_tenant` when
    # loaded so AAT users get zero-config behavior. Apps using any other
    # multi-tenancy primitive (Rails `Current` attributes, a subdomain
    # lookup, a thread-local, etc.) override via `TypedFields.configure`.
    DEFAULT_SCOPE_RESOLVER = lambda {
      ::ActsAsTenant.current_tenant if defined?(::ActsAsTenant)
    }

    # Map of type names to their STI class names.
    # Add custom types via TypedFields.configure.
    BUILTIN_FIELD_TYPES = {
      text: "TypedFields::Field::Text",
      long_text: "TypedFields::Field::LongText",
      integer: "TypedFields::Field::Integer",
      decimal: "TypedFields::Field::Decimal",
      boolean: "TypedFields::Field::Boolean",
      date: "TypedFields::Field::Date",
      date_time: "TypedFields::Field::DateTime",
      select: "TypedFields::Field::Select",
      multi_select: "TypedFields::Field::MultiSelect",
      integer_array: "TypedFields::Field::IntegerArray",
      decimal_array: "TypedFields::Field::DecimalArray",
      text_array: "TypedFields::Field::TextArray",
      date_array: "TypedFields::Field::DateArray",
      email: "TypedFields::Field::Email",
      url: "TypedFields::Field::Url",
      color: "TypedFields::Field::Color",
      json: "TypedFields::Field::Json",
    }.freeze

    # Mutable registry of type_name => class_name pairs. Seeded from
    # BUILTIN_FIELD_TYPES on first access; extended via register_field_type.
    config_accessor(:field_types) { BUILTIN_FIELD_TYPES.dup }

    # Callable returning the ambient scope (partition key) for class-level
    # queries. Invoked by `TypedFields.current_scope` when no explicit
    # `scope:` kwarg is passed and no `with_scope` block is active.
    config_accessor :scope_resolver, default: DEFAULT_SCOPE_RESOLVER

    # When true, class-level queries on a model that declared
    # `has_typed_fields scope_method: ...` raise `TypedFields::ScopeRequired`
    # if no scope can be resolved (explicit arg, active `with_scope` block,
    # or configured resolver all returned nil). Bypass per-call via
    # `TypedFields.unscoped { ... }`.
    config_accessor :require_scope, default: true

    class << self
      # Register a custom field type.
      def register_field_type(name, class_name)
        field_types[name.to_sym] = class_name
      end

      # Resolve a type name to its STI class.
      def field_class_for(type_name)
        class_name = field_types[type_name.to_sym]
        raise ArgumentError, "Unknown field type: #{type_name}" unless class_name

        class_name.constantize
      end

      # All registered type names.
      def type_names
        field_types.keys
      end

      # Restore defaults (test isolation).
      def reset!
        self.field_types = BUILTIN_FIELD_TYPES.dup
        self.scope_resolver = DEFAULT_SCOPE_RESOLVER
        self.require_scope = true
      end
    end
  end
end
