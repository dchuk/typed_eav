# frozen_string_literal: true

# TypedEAV configuration.
#
# `scope_resolver` is the single integration point for multi-tenancy /
# partitioning. It's a callable that returns `[scope, parent_scope]`
# (tenant id, workspace id — whatever axes your app uses) or nil.
# If you only use one partition axis, return `[scope, nil]`.
#
# Class-level queries like `Contact.where_typed_eav(...)` consult this
# resolver when no explicit `scope:` kwarg or `TypedEAV.with_scope(...)`
# block is active. If the resolver returns nil and the model declared
# `has_typed_eav scope_method: ...`, queries raise
# `TypedEAV::ScopeRequired` (fail-closed).
#
# Pick ONE of the patterns below and uncomment it:

TypedEAV.configure do |c|
  # --- DEFAULT ---
  # If the `acts_as_tenant` gem is loaded, the default resolver reads
  # `ActsAsTenant.current_tenant` with zero configuration. If you use AAT,
  # no change is needed here.

  # --- Rails CurrentAttributes ---
  # c.scope_resolver = -> { [Current.account&.id, nil] }
  # c.scope_resolver = -> { [Current.account&.id, Current.workspace&.id] }

  # --- Custom Current-like class ---
  # c.scope_resolver = -> { [MyApp::Tenancy.current_tenant_id, MyApp::Tenancy.current_workspace_id] }

  # --- Subdomain / session / thread-local ---
  # c.scope_resolver = -> { [Thread.current[:org_id], nil] }

  # --- Disable ambient resolution entirely (explicit `scope:` kwarg only) ---
  # c.scope_resolver = nil

  # --- Fail-closed mode ---
  # When true (default), scoped-model queries raise if no scope resolves.
  # Set to false for gradual adoption — when no scope resolves, queries
  # see ONLY global fields (those defined with `scope: nil`), not other
  # partitions' fields. To query across all partitions, use the explicit
  # escape hatch: `TypedEAV.unscoped { ... }`.
  # c.require_scope = true

  # --- Custom field types ---
  # c.register_field_type :phone, "MyApp::Fields::Phone"
end
