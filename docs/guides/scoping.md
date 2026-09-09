---
title: "Multi-tenant scoping"
---

# Multi-tenant scoping

[Documentation home](../index.md)

**Scope selects field definitions; it does not authorize or filter host records. Apply tenant and authorization filters to the host relation.**

## Multi-Tenant Scoping

Field definitions are partitioned by a `scope` column so multiple tenants (or accounts, workspaces, orgs — any partition key your app uses) can each define their own fields without collisions. Fields with `scope = NULL` are global, visible to every partition.

### Declaring a scoped model

```ruby
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
end
```

`scope_method:` names an instance method on your model. When the record reads its own field definitions (e.g., in a form), that method tells TypedEAV which partition the record belongs to.

### Class-level queries resolve scope automatically

Queries like `Contact.where_typed_eav(...)` consult an **ambient scope resolver** — no need to pass `scope:` on every call:

```ruby
# The resolver tells TypedEAV which partition is active.
Contact.where_typed_eav({ name: "age", op: :gt, value: 21 })
```

The resolver chain (highest priority first):

1. Explicit `scope:` keyword argument on the query
2. Active `TypedEAV.with_scope(value) { ... }` block
3. Configured `TypedEAV.config.scope_resolver` callable
4. `nil`

If every step returns `nil` and the model declared `scope_method:`, queries raise `TypedEAV::ScopeRequired` — the **fail-closed default**. This is the whole point: forgetting to set scope can't silently leak other partitions' data.

### Wiring the resolver

Pick the pattern that matches your app and set it once in `config/initializers/typed_eav.rb`:

```ruby
TypedEAV.configure do |c|
  # acts_as_tenant (auto-detected — no config needed if loaded)
  # c.scope_resolver = -> { [ActsAsTenant.current_tenant&.id, nil] }

  # Rails CurrentAttributes
  # c.scope_resolver = -> { [Current.account&.id, nil] }

  # Custom class
  # c.scope_resolver = -> { [MyApp::Tenancy.current_workspace_id, nil] }

  # Subdomain / session / thread-local
  # c.scope_resolver = -> { [Thread.current[:org_id], nil] }

  # Disable ambient resolution entirely
  # c.scope_resolver = nil

  c.require_scope = true  # fail-closed (default). Set false for gradual adoption.
end
```

The resolver MUST return a 2-element Array `[scope, parent_scope]`. Each slot
accepts a raw value (`"t1"`, `42`), an AR record (TypedEAV calls `.id.to_s`
on anything that responds to `#id`), or `nil`. If you don't use parent_scope,
return `[scope, nil]`. A bare scalar return raises `ArgumentError` at the
next ambient query — see [Migrating from v0.1.x](upgrading.md#migrating-from-v01x) for
the upgrade path.

### Block APIs

```ruby
# Run a block with a specific ambient scope (background jobs, console, rake tasks):
TypedEAV.with_scope(tenant_id) do
  Contact.where_typed_eav({ name: "status", op: :eq, value: "active" })
end

# Escape hatch for admin tools, migrations, or cross-tenant audits:
TypedEAV.unscoped do
  Contact.where_typed_eav({ name: "status", op: :eq, value: "active" })
  # returns matches across ALL partitions
end
```

Both are exception-safe via `ensure` and nest cleanly.

`unscoped` is an explicit administrative/analytics escape hatch, not the
ordinary tenant request path. It keeps every same-name definition across the
visible partitions and unions their matches for each filter. For broad audits
or migrations, bound the definition universe to the work you actually need and
batch the job at an application-owned boundary. TypedEAV does not prescribe a
universal limit or batch size; measure generated SQL, planning/execution,
memory, and workload interference in your application. Keep normal request
traffic on scoped resolution so global, scope-only, and full-tuple definitions
collapse to the most-specific match.

### Explicit `scope:` override

Any query method accepts `scope:` as an override for admin tools and tests:

```ruby
Contact.where_typed_eav({ name: "status", value: "active" }, scope: "t1")
Contact.with_field("age", :gt, 21, scope: "t1")
```

Explicit wins over ambient. Passing `scope: nil` explicitly (as opposed to omitting the kwarg) means "filter to global fields only" — useful for admin UIs that want to see unscoped field definitions without activating `unscoped` mode.

### Background jobs

ActiveJob (including Sidekiq via the ActiveJob adapter) wraps every `perform` in Rails' executor, which already clears `ActiveSupport::CurrentAttributes` between jobs — so if your resolver reads from `Current.account`, each job starts clean. For raw `Sidekiq::Job` (no ActiveJob), wrap the job body manually:

```ruby
class ExportJob
  include Sidekiq::Job

  def perform(tenant_id, ...)
    TypedEAV.with_scope(tenant_id) do
      Contact.where_typed_eav(...)
    end
  end
end
```

### Disabling enforcement for gradual adoption

If your app has existing typed-eav queries that don't yet pass scope, flip `require_scope` to `false` in the initializer. When no scope resolves, queries fall back to **global fields only** (definitions stored with `scope: nil`) instead of raising — they do **not** return all partitions' fields. Audit and fix callers, then flip back to `true`.

To intentionally query across every partition (admin tools, migrations, cross-tenant audits), use the explicit escape hatch `TypedEAV.unscoped { ... }` rather than relying on `require_scope = false`.

### Two-level scoping (`parent_scope`)

When a single tenant axis isn't enough — say, `tenant_id` for the customer AND
`workspace_id` for an in-tenant partition — declare both:

```ruby
class Project < ApplicationRecord
  has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id
end
```

Field (and section) definitions partition on the tuple `(entity_type, scope,
parent_scope)`. A `Project` record reads field definitions in three precedence
layers: a full-triple `(scope, parent_scope)` match wins, then `(scope, nil)`
(tenant-wide), then `(nil, nil)` (truly global). The same precedence applies
to the class-level query path.

`parent_scope_method:` requires `scope_method:` — declaring it without a scope
method raises at macro-expansion time (no host can have a parent partition
without a scope partition).

Both `with_scope` and the configured `scope_resolver` carry the tuple now:

```ruby
TypedEAV.with_scope(["t1", "w1"]) do
  Project.where_typed_eav({ name: "status", value: "active" })
end

# Single-axis call still works (parent_scope = nil):
TypedEAV.with_scope("t1") do
  Contact.where_typed_eav({ name: "age", op: :gt, value: 21 })
end

# Custom resolver — MUST return [scope, parent_scope]:
TypedEAV.configure do |c|
  c.scope_resolver = -> { [Current.tenant&.id, Current.workspace&.id] }
end
```

Per-query overrides accept `parent_scope:` alongside `scope:` on
`where_typed_eav`, `with_field`, and `typed_eav_definitions`:

```ruby
Project.where_typed_eav(
  { name: "priority", value: "high" },
  scope: "t1",
  parent_scope: "w1",
)
```

When `acts_as_tenant` is loaded, the auto-detected `DEFAULT_SCOPE_RESOLVER`
returns `[ActsAsTenant.current_tenant, nil]` — the parent_scope slot is `nil`
because the tenant gem has no parent-scope analog. Configure your own resolver
when you need both axes.

### Orphan-parent invariant

A `Field` or `Section` row with `parent_scope` set and `scope` blank is
invalid — model-level validation rejects it on save. Reason: a "global field
within one workspace" has no semantic resolution path; the row would never
match any record's resolver. The paired partial unique indexes rely on this
invariant.

The shipped migration chain also includes
`EnforceParentScopeInvariant`, which declares the database check constraints
nontransactionally and validates them after its preflight, and
`UsePartialCoveringScalarIndexes`, which creates the six `*_present` indexes
before removing their legacy counterparts. Both migrations use
`disable_ddl_transaction!`; run them through the normal migration command and
do not wrap them in an application transaction.

### Name collisions across scopes

When both a global field (`scope: nil`) and a scoped field share a name, the **scoped definition wins** for the partition that owns it: forms render exactly one input (the scoped one), reads return the scoped value, and writes target the scoped row.

`TypedEAV.unscoped { Contact.where_typed_eav(...) }` OR-across every partition's matching `field_id` per filter (still AND-ing across filters), so cross-tenant audit queries see every partition's matches — they don't collapse to a single tenant.

Because that administrative path constructs work for every matching
definition, applications should narrow and batch high-cardinality audits rather
than treating `unscoped` as tenant-request routing. No built-in numeric
threshold is implied; choose operational bounds from measurements of the
consuming workload. See [ADR 0012](../adr/0012-cross-scope-administrative-query-policy.md).

## Partition helpers for custom management interfaces

These helpers take an **explicit, already-resolved tuple**; they do not consult
ambient scope or apply application authorization. For example, after authorizing
access to a tenant's field management page:

```ruby
partition = {
  entity_type: Contact.polymorphic_name,
  scope: current_tenant.id.to_s,
  parent_scope: nil
}
visible = TypedEAV::Partition.visible_fields(**partition) # AR relation
fields = TypedEAV::Partition.effective_fields_by_name(**partition) # name => Field
sections = TypedEAV::Partition.visible_sections(**partition).active.sorted
section = TypedEAV::Partition.find_visible_section!(params[:section_id], **partition)
```

`visible_fields` includes global, scope-only, and full-tuple definitions.
`effective_fields_by_name` collapses same-name collisions to the most specific
field. If you already loaded a visibility-filtered collection, use
`definitions_by_name(collection)` for the same collapse or
`definitions_multimap_by_name(collection)` for a name-to-array grouping. Those
two collection helpers do not filter the input for you.

Sections use the same visibility layers, without name-based collision collapse.
`find_visible_section!` returns a section by ID within those layers and raises
`ActiveRecord::RecordNotFound` for missing, blank, or out-of-partition IDs.
Visibility includes inherited definitions; before editing a global definition,
apply your application's permission policy for changing shared schema.

The visibility helpers accept `mode: :all_partitions` as an explicit admin bypass.
In that mode `effective_fields_by_name` returns arrays per name, not single fields.
Always supply `entity_type` for an interface serving one model: `visible_fields`
alone allows it to be omitted. Under ordinary `mode: :partition`, `scope: nil`
means global-only; a nonblank parent without a scope raises `ArgumentError`.
Unknown modes raise `ArgumentError` as well.
