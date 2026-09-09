---
title: "Configuration reference"
---

# Configuration reference

Configure the gem in a Rails initializer:

```ruby
TypedEAV.configure do |config|
  config.scope_resolver = -> { [Current.account&.id, Current.workspace&.id] }
  config.require_scope = true
end
```

The example assumes those are the same partition identifiers returned by the
host's declared accessors. `TypedEAV.config` returns the configuration object;
`configure` also accepts a block.

| Setting | Default | Contract |
| --- | --- | --- |
| `scope_resolver` | Auto-detect `ActsAsTenant` | Callable returning `nil` or exactly `[scope, parent_scope]`. Default returns `[ActsAsTenant.current_tenant, nil]` when available, otherwise `nil`. Bare scalars raise `ArgumentError`. |
| `require_scope` | `true` | Scoped host class queries raise `TypedEAV::ScopeRequired` when scope cannot be resolved. |
| `versioning` | `false` | Boot-time master switch for transactional audit callbacks; host must also declare `versioned: true`. |
| `actor_resolver` | `nil` | Optional callable supplying audit actor identity. Missing actor is allowed; applications can enforce stricter requirements in the resolver. |
| `on_value_change` | `nil` | `->(value, change_type, context) { ... }`; after commit, with `:create`, `:update`, or `:destroy`. |
| `on_field_change` | `nil` | `->(field, change_type) { ... }`; after commit, with `:create`, `:update`, `:destroy`, or `:rename`. |
| `on_image_attached` | `nil` | `->(value, blob) { ... }`; image attachment notification after commit, when Active Storage is available. |

Public callback errors are logged rather than propagated to the completed save.
Versioning is independent of the public callback slots. Configure the versioning
switch before the engine installs callbacks, not dynamically per request.
See [events and versioning](../guides/events-and-versioning.md) for ordering,
actor normalization, payloads, and audit transaction guarantees.

## Field type registration

```ruby
TypedEAV.configure do |config|
  config.register_field_type :phone, "MyApp::Fields::Phone"
end
```

`config.field_types` maps type-name Symbols to class-name Strings;
`config.type_names` lists registered names; `config.field_class_for(:phone)`
constantizes a registered class and raises `ArgumentError` for an unknown type.
Use registration to extend built-ins and the host macro's `types:` option to
restrict a model. See [custom field types](../guides/fields.md).

## Block-scoped state

| API | Contract |
| --- | --- |
| `TypedEAV.with_scope(value) { ... }` | Temporary ambient scope; accepts a scalar, `[scope, parent_scope]`, or `nil`. Nested blocks restore prior state. |
| `TypedEAV.current_scope` | Resolved normalized tuple, or `nil`; consults the block stack before the resolver. |
| `TypedEAV.unscoped { ... }` | Explicit all-partition query mode; differs from `scope: nil` (global definitions only). |
| `TypedEAV.unscoped?` | Whether that bypass is active. |
| `TypedEAV.with_context(**kwargs) { ... }` | Temporary merged context for value events and versions; nested blocks restore prior state. |
| `TypedEAV.current_context` | Frozen current context Hash, empty when unset. |

Scope resolution is for field definitions. Continue to filter and authorize host
records in the application. Scalar sorting and summaries reject all-partition
mode because same-name definitions are ambiguous. See
[scoping](../guides/scoping.md) and [queries](../guides/queries.md).
