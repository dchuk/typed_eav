# TypedEAV

Add dynamic custom fields to ActiveRecord models at runtime, backed by **native database typed columns** instead of jsonb blobs.

TypedEAV uses a hybrid EAV (Entity-Attribute-Value) pattern where each value type gets its own column (`integer_value`, `date_value`, `string_value`, etc.) in the values table. This lets PostgreSQL index, sort, and enforce constraints on custom field data while the Field owns input normalization and validation.

## Why Typed Columns?

JSONB is a useful fit when an application owns stable paths and wants expression B-tree indexes or GIN containment indexes. A single JSONB document is not inherently faster or slower than TypedEAV; the right choice depends on access patterns, selectivity, update shape, and operational constraints. For example, an application-owned expression index may support a stable path:

```sql
CAST(value_meta->>'const' AS bigint) = 42
```

This can work well for stable, known paths. It does not provide the same column-level schema and typed-value contract as TypedEAV, and arbitrary paths still require application-owned index and validation decisions. GIN is useful for containment workloads; expression B-trees are useful for selected stable scalar paths.

TypedEAV stores values in native columns, so queries become:

```sql
WHERE integer_value = 42
```

TypedEAV supplies stable typed columns and ordinary per-type indexes. Range scans and sorts can use those indexes, while each Field casts and validates the operand according to its own semantics before the query reaches the typed column. Neither design is a universal storage winner; choose from measured workload fit.

## Compatibility

The canonical support contract lives in
[`.github/compatibility.json`](.github/compatibility.json). Typed EAV supports:

| Runtime | Supported versions |
|---|---|
| Ruby | 3.3 through 4.0 (`>= 3.3`, `< 4.1`) |
| Rails | 7.2 through 8.1 (`>= 7.2`, `< 8.2`) |
| PostgreSQL | 15 through 18 |

CI proves representative floor, middle, and ceiling combinations rather than
every Cartesian product. Versions outside these ranges and prerelease versions
are outside the support guarantee. PostgreSQL compatibility claims assume the
current minor release for each supported major version.

## Installation

Add to your Gemfile:

```ruby
gem "typed_eav"
```

Run the install migration:

```bash
bin/rails typed_eav:install:migrations
bin/rails db:migrate
```

## Quick Start

### 1. Include the concern

```ruby
class Contact < ApplicationRecord
  has_typed_eav
end

# With multi-tenant scoping:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
end

# With restricted field types:
class Contact < ApplicationRecord
  has_typed_eav types: [:text, :integer, :boolean, :select]
end
```

### 2. Create field definitions

```ruby
# Simple fields
TypedEAV::Field::Text.create!(
  name: "nickname",
  entity_type: "Contact"
)

TypedEAV::Field::Integer.create!(
  name: "age",
  entity_type: "Contact",
  required: true,
  options: { min: 0, max: 150 }
)

TypedEAV::Field::Date.create!(
  name: "birthday",
  entity_type: "Contact",
  options: { max_date: Date.today.to_s }
)

# Select field with options
status = TypedEAV::Field::Select.create!(
  name: "status",
  entity_type: "Contact",
  required: true
)
status.field_options.create!([
  { label: "Active",   value: "active",   sort_order: 1 },
  { label: "Inactive", value: "inactive", sort_order: 2 },
  { label: "Lead",     value: "lead",     sort_order: 3 },
])

# Multi-select (stored as json array)
tags = TypedEAV::Field::MultiSelect.create!(
  name: "tags",
  entity_type: "Contact"
)
tags.field_options.create!([
  { label: "VIP",      value: "vip" },
  { label: "Partner",  value: "partner" },
  { label: "Prospect", value: "prospect" },
])
```

When deriving `entity_type` from a model class, use
`Contact.polymorphic_name`. Rails stores polymorphic associations under that
canonical name, which is the base-class type for STI hosts and respects the
application's namespaced-polymorphism setting.

### 3. Set values on records

```ruby
contact = Contact.new(name: "Darrin")

# Individual assignment
contact.set_typed_eav_value("age", 40)
contact.set_typed_eav_value("status", "active")

# Bulk assignment by field NAME (ergonomic for scripting / seeds)
contact.typed_eav_attributes = [
  { name: "age", value: 40 },
  { name: "status", value: "active" },
  { name: "tags", value: ["vip", "partner"] },
]

# Bulk assignment by field ID (standard Rails form contract).
# Your form templates emit this shape when you use fields_for :typed_values.
contact.typed_values_attributes = [
  { id: 12, field_id: 4, value: "40" },
  { field_id: 7, value: "active" },
]

contact.save!

# Reading
contact.typed_eav_value("age")    # => 40 (Ruby Integer)
contact.typed_eav_value("status") # => "active"
contact.typed_eav_hash              # => { "age" => 40, "status" => "active", ... }
```

### 4. Query with the DSL

Queries use native typed columns and the indexes shipped for each type. The Field remains the owner of operand casting and validation; the query builder receives a field-normalized value rather than applying a generic Active Record cast.

```ruby
# Short form - single field filter
Contact.with_field("age", :gt, 21)
Contact.with_field("status", "active")           # :eq is the default operator
Contact.with_field("nickname", :contains, "smith")

# Chain them
Contact.with_field("age", :gteq, 18)
       .with_field("status", "active")
       .with_field("tags", :any_eq, "vip")

# Multi-filter form (good for search UIs)
Contact.where_typed_eav(
  { name: "age",    op: :gt,       value: 21 },
  { name: "status", op: :eq,       value: "active" },
  { name: "city",   op: :contains, value: "port" },
)

# Compact keys (for URL params / form submissions)
Contact.where_typed_eav(
  { n: "age", op: :gt, v: 21 },
  { n: "status", v: "active" },
)

# With scoping
Contact.where_typed_eav(
  { name: "priority", op: :eq, value: "high" },
  scope: current_tenant.id
)

# Combine with standard ActiveRecord
Contact.where(company_id: 42)
       .with_field("status", "active")
       .with_field("age", :gteq, 21)
       .order(:name)
       .limit(25)
```

### Available Operators

| Operator | Works On | Description |
|----------|----------|-------------|
| `:eq` | all | Equal (default) |
| `:not_eq` | all | Not equal (NULL-safe) |
| `:gt` | numeric, date, datetime | Greater than |
| `:gteq` | numeric, date, datetime | Greater than or equal |
| `:lt` | numeric, date, datetime | Less than |
| `:lteq` | numeric, date, datetime | Less than or equal |
| `:between` | numeric, date, datetime | Between (pass Range or Array) |
| `:contains` | text, long_text | ILIKE %value% |
| `:not_contains` | text, long_text | NOT ILIKE %value% |
| `:starts_with` | text, long_text | ILIKE value% |
| `:ends_with` | text, long_text | ILIKE %value |
| `:any_eq` | json arrays | Array contains element |
| `:all_eq` | json arrays | Array contains all elements |
| `:is_null` | all | Value is NULL |
| `:is_not_null` | all | Value is not NULL |

### Optional trigram indexing for string search

TypedEAV keeps its partial-covering `text_pattern_ops` B-tree as the default
string index. Equality uses that B-tree, while `:starts_with`, `:contains`, and
`:ends_with` use `ILIKE`; `:not_contains` uses `NOT ILIKE`. The gem does not
require or install `pg_trgm` and does not create a trigram index automatically.

An application with frequent positive `ILIKE` searches containing at least
three useful characters may evaluate its own partial GIN index. This is a
workload decision: the representative benchmark used GIN for measured prefix,
contains, suffix, and escaped-literal patterns, but not for `NOT ILIKE` or
one/two-character probes. It does not prove that every positive pattern or
selectivity will benefit. A `lower(string_value) LIKE ...` expression index is
not equivalent to TypedEAV's public `ILIKE`, and the benchmark did not justify
GiST.

Application owners should check extension availability and deploy-role
privileges in preproduction, then create the extension and index in their own
migrations. Use nontransactional `CREATE INDEX CONCURRENTLY`, a stable
application-specific name, and workload-specific `EXPLAIN (ANALYZE, BUFFERS,
WAL, SETTINGS)` plus storage and write-WAL measurements. Rollback should drop
only the application-owned index concurrently; do not drop the database-wide
extension because other objects may share it. See
[ADR 0009](docs/adr/0009-string-search-indexing.md) and the
[benchmark guide](bench/README.md#phase-3-string-search-benchmark) for the
operator matrix, measured costs, SQL, and evidence limits.

### Optional planner statistics for correlated field/value predicates

TypedEAV does not install PostgreSQL extended-statistics objects. An application
whose own plans persistently misestimate `field_id = ... AND typed_value = ...`
may evaluate application-owned `dependencies` statistics for that exact typed
column. Dependency statistics apply to compatible equality and `IN` clauses,
not range predicates. `mcv` describes common value combinations, while
`ndistinct` primarily informs distinct-group estimates; neither should be added
without workload evidence.

The representative PostgreSQL 17 benchmark found better aggregate equality
estimates from dependencies, but no plan-shape or demonstrated runtime benefit.
Its combined object mirrored MCV on the four changed probes because matching MCV
groups supplied those estimates. The experiment's target of 100 was a controlled
input, not a universal recommendation. One probe labeled common-date equality
actually queried an absent date and returned zero rows; it is not evidence about
common-date estimates.

Applications should own stable names and DDL, select targets from representative
data, run `ANALYZE`, and compare estimated/actual rows, plans, runtime, planning
cost, maintenance cost, and data churn before retaining an object. Coordinate
ownership in shared databases, inspect catalog definitions before changing
objects, and drop only application-owned statistics during rollback. See
[ADR 0010](docs/adr/0010-planner-statistics-policy.md) and the
[benchmark guide](bench/README.md#phase-4a-planner-extended-statistics) for safe
evaluation SQL and evidence limits.

### Multi-filter query strategy

TypedEAV retains its current multi-filter query shape: it resolves each field,
builds the corresponding typed value subquery, and chains those results onto
the host relation with `id IN (...)`. There is no adaptive strategy or alternate
production query API.

A PostgreSQL 17 benchmark compared the shipped shape with `INTERSECT`,
correlated `EXISTS`, and direct grouped `HAVING` under resource-capped
co-tenancy. The run retained 2,940 attempts, including 622 right-censored
timeouts, and 294 representative identity oracles. Twelve oracles timed out, so
representative equivalence is unproved even though all 282 completed oracles
matched and the smaller 98-oracle smoke matched. Alternatives remain
research-only. Grouped `HAVING` is additionally ineligible for missing-value,
host-universe complement, and empty-filter semantics.

The result also does not establish valid buffer comparisons or 20-distinct-
field scaling. A parser defect made every derived buffer total a false zero;
nonzero counters remain recoverable from the retained raw plans. The
20-predicate workloads repeat ten fields, and the skewed 10/20 workloads repeat
five. Future research must repair and validate buffer extraction, exercise
actual 10/20 distinct fields, complete every representative equivalence oracle,
cover the full scope/NULL/missing/polymorphic/error contract, and show the
pre-registered p95, planning-time, buffer, and plan-shape gates before any
adaptive or replacement proposal. See
[ADR 0011](docs/adr/0011-multi-filter-query-strategy.md) and the
[benchmark guide](bench/README.md#phase-4b-multi-filter-query-shapes).

### How Type Inference Works

The owning Field casts and validates query operands before SQL generation;
Active Record supplies the SQL bind plumbing:

```ruby
# The Integer Field casts and validates the operand before SQL generation
Contact.with_field("age", :gt, "21")
# SQL: WHERE integer_value > 21  (not '21')

# The Date Field owns date parsing and validation
Contact.with_field("birthday", :lt, "2000-01-01")
# SQL: WHERE date_value < '2000-01-01'::date

# The Boolean Field owns truthy/falsy casting
Contact.with_field("active", "true")
# SQL: WHERE boolean_value = TRUE
```

Field-owned casting keeps query operands aligned with write semantics, including strict range/array shapes and specialized fields such as Currency and Reference. The resulting normalized operand is bound against the Field's typed column; Active Record supplies SQL bind plumbing, not the field's domain semantics.

## Forms

Wire typed fields into Rails forms via nested attributes:

```erb
<%= form_with model: @contact do |f| %>
  <%= f.text_field :name %>

  <%= render_typed_value_inputs(form: f, record: @contact) %>

  <%= f.submit %>
<% end %>
```

The helper emits one input per available field, including the hidden `id` / `field_id` markers required by `accepts_nested_attributes_for`. Permit the nested shape in your controller — the `value: []` form is required for array/multi-select types:

```ruby
def contact_params
  params.require(:contact).permit(
    :name,
    typed_values_attributes: [
      :id, :field_id, :_destroy, :value, { value: [] }
    ]
  )
end
```

For list pages, preload the field association to avoid N+1:

```ruby
@contacts = Contact.includes(typed_values: :field).all
```

## Admin Scaffold

To manage field definitions through a UI, run the scaffold generator:

```bash
bin/rails g typed_eav:scaffold
bin/rails db:migrate
```

This copies a controller, views, helper, Stimulus controllers, and an initializer into your app, and adds routes mounted at `/typed_eav_fields`.

**Security**: the generated controller ships with `authorize_typed_eav_admin!` returning `head :not_found` by default — fail-closed. Edit the method directly in `app/controllers/typed_eav_controller.rb` to wire it to your auth system:

```ruby
def authorize_typed_eav_admin!
  return if current_user&.admin?
  head :not_found
end
```

Defining `authorize_typed_eav_admin!` in `ApplicationController` does **not** override it — the scaffold sets it on its own controller.

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
  # c.scope_resolver = -> { ActsAsTenant.current_tenant&.id }

  # Rails CurrentAttributes
  # c.scope_resolver = -> { Current.account&.id }

  # Custom class
  # c.scope_resolver = -> { MyApp::Tenancy.current_workspace_id }

  # Subdomain / session / thread-local
  # c.scope_resolver = -> { Thread.current[:org_id] }

  # Disable ambient resolution entirely
  # c.scope_resolver = nil

  c.require_scope = true  # fail-closed (default). Set false for gradual adoption.
end
```

The resolver MUST return a 2-element Array `[scope, parent_scope]`. Each slot
accepts a raw value (`"t1"`, `42`), an AR record (TypedEAV calls `.id.to_s`
on anything that responds to `#id`), or `nil`. If you don't use parent_scope,
return `[scope, nil]`. A bare scalar return raises `ArgumentError` at the
next ambient query — see [Migrating from v0.1.x](#migrating-from-v01x) for
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

### Migrating from v0.1.x

The resolver-callable contract is a **breaking change**: any custom
`Config.scope_resolver` lambda must now return `[scope, parent_scope]` (a
2-element Array) instead of a bare scalar. A scalar return raises
`ArgumentError` at the next ambient query so the failure is loud, not silent.
If you don't use parent_scope, return `[scope, nil]`.

Run `bin/rails typed_eav:install:migrations` to copy the new
`AddParentScopeToTypedEavPartitions` migration into your app, then
`bin/rails db:migrate`. The migration is safe on production: it adds a
nullable `parent_scope` column (catalog-only, instantaneous) and uses
`CREATE INDEX CONCURRENTLY` for all index changes, so existing rows aren't
rewritten. Existing fields end up with `parent_scope = NULL` (the
global-parent shape) and continue to work for every single-scope caller.

See the [CHANGELOG](CHANGELOG.md) for the full upgrade checklist.

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
consuming workload. See [ADR 0012](docs/adr/0012-cross-scope-administrative-query-policy.md).

## Field Types

| Type | Column | Ruby Type | Options |
|------|--------|-----------|---------|
| `Text` | `string_value` | String | `min_length`, `max_length`, `pattern` |
| `LongText` | `text_value` | String | `min_length`, `max_length` |
| `Integer` | `integer_value` | Integer | `min`, `max` |
| `Decimal` | `decimal_value` | BigDecimal | `min`, `max`, `precision_scale` |
| `Boolean` | `boolean_value` | Boolean | |
| `Date` | `date_value` | Date | `min_date`, `max_date` |
| `DateTime` | `datetime_value` | Time | `min_datetime`, `max_datetime` |
| `Select` | `string_value` | String | options via `TypedEAV::Option` |
| `MultiSelect` | `json_value` | Array | options via `TypedEAV::Option` |
| `IntegerArray` | `json_value` | Array | `min_size`, `max_size`, `min`, `max` |
| `DecimalArray` | `json_value` | Array | `min_size`, `max_size` |
| `TextArray` | `json_value` | Array | `min_size`, `max_size` |
| `DateArray` | `json_value` | Array | `min_size`, `max_size` |
| `Email` | `string_value` | String | auto-downcases, strips whitespace |
| `Url` | `string_value` | String | strips whitespace |
| `Color` | `string_value` | String | hex color values |
| `Json` | `json_value` | Hash/Array | arbitrary JSON |
| `Currency` | `decimal_value` + `string_value` | `{amount: BigDecimal, currency: String}` | `default_currency`, `allowed_currencies` |
| `Percentage` | `decimal_value` | BigDecimal (0..1 range) | `decimal_places`, `display_as: :fraction \| :percent` |
| `Image` | `string_value` (signed_id) + `:attachment` has_one_attached | String (Active Storage signed_id) | `allowed_content_types`, `max_size_bytes` |
| `File` | `string_value` (signed_id) + `:attachment` has_one_attached | String (Active Storage signed_id) | `allowed_content_types`, `max_size_bytes` |
| `Reference` | `integer_value` (FK) | Integer (target record ID) | `target_entity_type`, `target_scope` |

## Sections (Optional UI Grouping)

```ruby
general = TypedEAV::Section.create!(
  name: "General Info",
  code: "general",
  entity_type: "Contact",
  sort_order: 1
)

social = TypedEAV::Section.create!(
  name: "Social Media",
  code: "social",
  entity_type: "Contact",
  sort_order: 2
)

TypedEAV::Field::Text.create!(
  name: "twitter_handle",
  entity_type: "Contact",
  section: social
)
```

## Custom Field Types

Override `cast(raw)` to return a `[casted_value, invalid?]` tuple.
`invalid?` tells `Value#validate_value` whether to surface `:invalid`
(vs `:blank`) when raw input can't be coerced. For types that never
fail to coerce, always return `[value, false]`.

```ruby
# app/models/fields/phone.rb
module Fields
  class Phone < TypedEAV::Field::Base
    value_column :string_value
    operators :eq, :contains, :starts_with, :is_null, :is_not_null

    def cast(raw)
      # Strip everything but digits and +; never rejects as invalid
      [raw&.to_s&.gsub(/[^\d+]/, ""), false]
    end
  end
end

# Register it
TypedEAV.configure do |c|
  c.register_field_type :phone, "Fields::Phone"
end
```

### Family intermediate bases (extension points)

`Field::Base` is the universal parent, but three intermediate family
bases collapse the most common per-leaf duplication. Pick the right
parent and you inherit the family's validation surface for free.

- **`TypedEAV::Field::ValidatedString`** — subclass when your custom
  type stores in `string_value` and wants a min/max-length + regex-pattern
  validation surface. Inherits `value_column :string_value`,
  `store_accessor :options, :min_length, :max_length, :pattern`,
  numericality validators on `min_length` / `max_length`, a
  `max_gte_min_length` guard that rejects inverted bounds at field-save,
  and a `validate_pattern_syntax` guard that rejects bad regexes at
  field-save. The default `validate_typed_value(record, val)` runs
  `validate_length` plus `validate_pattern if pattern.present?`. Override
  it and call `super` to layer on a format-specific check (the built-in
  `Field::Email` / `Field::Url` are the canonical pattern).

  ```ruby
  class Fields::Slug < TypedEAV::Field::ValidatedString
    SLUG_FORMAT = /\A[a-z0-9-]+\z/

    def cast(raw)
      [raw&.to_s&.strip&.downcase, false]
    end

    def validate_typed_value(record, val)
      super  # length + pattern from the family base
      record.errors.add(:value, "is not a valid slug") unless SLUG_FORMAT.match?(val.to_s)
    end
  end
  ```

- **`TypedEAV::Field::RangeBounded`** — subclass when your custom type
  stores a single comparable value (numeric or temporal) constrained by
  a min/max bound. Each leaf still declares its own `value_column` and
  its own `store_accessor` (key names vary by family member: `:min`/`:max`
  for numeric; `:min_date`/`:max_date` for date;
  `:min_datetime`/`:max_datetime` for datetime). The family base
  provides protected `validate_range` / `validate_date_range` /
  `validate_datetime_range` helpers. Each leaf should pair its
  `store_accessor` with the macro
  `validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min`
  (or the analogous form for the leaf's key names) so inverted bounds
  fail at field-save.

  ```ruby
  class Fields::Score < TypedEAV::Field::RangeBounded
    value_column :integer_value

    store_accessor :options, :min, :max
    validates :max, comparison: { greater_than_or_equal_to: :min }, allow_nil: true, if: :min

    def cast(raw)
      raw.nil? ? [nil, false] : [Integer(raw.to_s, exception: false), raw.to_s.empty? ? false : true]
    end

    def validate_typed_value(record, val)
      validate_range(record, val)
    end
  end
  ```

- **`TypedEAV::Field::Optionable`** — `include` this concern when your
  custom type's valid values are drawn from a `Field::Option` set.
  Provides `optionable? = true`, a public-facing sorted
  `allowed_values` helper, and protected
  `validate_option_inclusion` / `validate_multi_option_inclusion`
  helpers. Mixin (not inheritance) because option-set field types may
  use different `value_column`s — the built-in `Field::Select` stores in
  `string_value` while `Field::MultiSelect` stores in `json_value`, and
  both stay as direct children of `Field::Base`.

  ```ruby
  class Fields::Tag < TypedEAV::Field::Base
    include TypedEAV::Field::Optionable

    value_column :string_value
    operators :eq, :not_eq, :is_null, :is_not_null

    def cast(raw)
      [raw&.to_s, false]
    end

    def validate_typed_value(record, val)
      validate_option_inclusion(record, val)
    end
  end
  ```

The rule of thumb: subclass an intermediate family base when the new
field type shares its storage and validation surface with the family;
include `Optionable` when it draws values from an option set; subclass
`Field::Base` directly (as the `Phone` example above does) when none of
the family surfaces fit. `validate_array_size` lives on `Field::Base`
itself — its callers span unrelated families.

### Multi-cell field types

External field types may store their logical value across multiple typed
columns. The entire storage surface lives directly on `Field::Base` via
the `Field::TypedStorage` concern, so a custom multi-cell type is just a
`Field::Base` subclass that overrides three instance methods.

**Class-level DSL** (declared at class load time):

- `value_column :col` – single-cell sugar; declares the primary cell.
- `value_columns :a, :b, ...` – plural form for multi-cell types. The
  primary cell is `value_columns.first`. Both forms share storage;
  `value_column` and `value_columns` are interchangeable getters/setters.
- `operators :eq, :gt, ...` – restrict the supported operator set.
- `self.operator_column(op)` – override to route different operators to
  different cells. Defaults to `value_columns.first`.

**Override-point instance methods** (the entire extension surface for
multi-cell types):

- `read_value(record)` – compose the logical value from the cells.
- `write_value(record, casted)` – unpack the casted value across cells.
- `apply_default(record)` – populate cells from `default_value`.

The defaults target `value_columns.first`, so single-cell field types
keep working without overrides. The three methods are paired – override
all three or your reads will see a multi-cell shape that writes / defaults
cannot produce.

**Concrete snapshot helpers** (NOT overridable; derived from
`value_columns`):

- `value_changed?(record)` – true iff any cell saw a saved change.
- `before_snapshot(record, change_type)` / `after_snapshot(record, change_type)`
  – per-cell hashes keyed by string column names; powers the versioning
  jsonb shape.

Custom multi-cell type example (matches the built-in `Field::Currency`):

```ruby
class Fields::Money < TypedEAV::Field::Base
  AMOUNT_COLUMN = :decimal_value
  CURRENCY_COLUMN = :string_value

  value_columns AMOUNT_COLUMN, CURRENCY_COLUMN
  operators :eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq, :is_null, :is_not_null

  def self.operator_column(operator)
    operator == :currency_eq ? CURRENCY_COLUMN : AMOUNT_COLUMN
  end

  def read_value(value_record)
    amount = value_record[AMOUNT_COLUMN]
    currency = value_record[CURRENCY_COLUMN]
    return nil if amount.nil? && currency.nil?

    { amount: amount, currency: currency }
  end

  def write_value(value_record, casted)
    if casted.nil?
      value_record[AMOUNT_COLUMN] = nil
      value_record[CURRENCY_COLUMN] = nil
    else
      value_record[AMOUNT_COLUMN] = casted[:amount]
      value_record[CURRENCY_COLUMN] = casted[:currency]
    end
  end

  def apply_default(value_record)
    default = default_value
    return unless default.is_a?(Hash)

    value_record[AMOUNT_COLUMN] = default[:amount] || default["amount"]
    value_record[CURRENCY_COLUMN] = default[:currency] || default["currency"]
  end
end
```

The built-in `Field::Currency` is the canonical multi-cell consumer of
these extension points and reads as a normal `Field::Base` subclass with
exactly three method overrides.

### Built-in field types

- **`Currency`:** Stores `{amount: BigDecimal, currency: String}` across two typed columns (`decimal_value` for the amount; `string_value` for the ISO 4217 currency code). Multi-cell storage is declared via `value_columns :decimal_value, :string_value`; reads, writes, and default application override `read_value`, `write_value`, and `apply_default` directly on `Field::Currency`. Operators: `:eq`, `:gt`, `:lt`, `:gteq`, `:lteq`, `:between` target the amount; `:currency_eq` targets the currency code; `:is_null` / `:is_not_null` target the amount column (a Currency value is null when its amount is null). Cast input MUST be a hash with `:amount` and/or `:currency` keys — bare numeric/string values are rejected with `:invalid` to enforce explicit currency dimension at write time. Options: `default_currency` (String ISO code, applied as fallback only when an amount is given without an explicit currency), `allowed_currencies` (Array of ISO codes; `validate_typed_value` enforces inclusion). Versioning snapshots automatically capture both columns because the snapshot helpers iterate `value_columns`. The `:currency_eq` operator is registered ONLY on `Field::Currency`; the QueryBuilder operator-validation gate rejects it with a clear `ArgumentError` if invoked on any other field type.

  ```ruby
  Contact.where_typed_eav(name: "price", op: :currency_eq, value: "USD")
  Contact.where_typed_eav(name: "price", op: :between,     value: [50, 150])
  ```

- **`Percentage`:** A `Field::Decimal` subclass storing the underlying fraction in 0..1 (inclusive). The `:percent` representation is a format-time concern — call `field.format(value)` with `display_as: :percent` to render `0.75` as `"75.0%"`. Options: `decimal_places` (Integer >= 0, default 2; format-time precision only — does NOT alter what's stored in `decimal_value`), `display_as` (`:fraction` default, or `:percent`). Validation: out-of-range values (e.g., `1.5`) fail with the message `"must be between 0.0 and 1.0"`. Storage and operator semantics inherit from `Field::Decimal`.

  ```ruby
  pf = TypedEAV::Field::Percentage.create!(
    name: "discount", entity_type: "Order", scope: tenant_id,
    options: { display_as: :percent, decimal_places: 1 },
  )
  pf.format(BigDecimal("0.755")) # => "75.5%"
  ```

- **`Image`:** Active Storage-backed field type. Stores the attached blob's `signed_id` (a String) in `string_value`. Operators: `:eq`, `:is_null`, `:is_not_null`. Options: `allowed_content_types` (Array of strings; supports exact matches like `"image/png"` and `image/*` family wildcards), `max_size_bytes` (Integer; nil disables the cap). The single `:attachment` has_one_attached association is declared on `TypedEAV::Value` at engine boot when Active Storage is loaded; otherwise `Field::Image#cast` raises `NotImplementedError` with an actionable install message. The `:attachment` association is shared with `Field::File` — Image vs File is a class-identity distinction (used by the `on_image_attached` hook), not a separate association.

  ```ruby
  field = TypedEAV::Field::Image.create!(
    name: "avatar", entity_type: "Contact",
    options: { allowed_content_types: %w[image/png image/jpeg image/webp], max_size_bytes: 5_000_000 },
  )
  value = TypedEAV::Value.create!(entity: contact, field: field)
  value.attachment.attach(io: file_io, filename: "avatar.png", content_type: "image/png")
  value.update!(string_value: value.attachment.blob.signed_id)
  value.value # => the signed_id String
  ```

- **`File`:** Same shape as `Field::Image` but without image-specific semantics. Stores `signed_id` in `string_value`; same operator set; same options (`allowed_content_types`, `max_size_bytes`). The Image vs File distinction is by `value.field.class` at runtime — apps that want strict image-only validation set `allowed_content_types: ["image/*"]` on `Field::Image`; `Field::File` is a general-purpose attachment slot.

- **Active Storage dependency:** Lazy soft-detect via `defined?(::ActiveStorage::Blob)`. The gem does NOT add Active Storage as a hard dependency — apps that never use Image/File never need to install it. To use Image or File fields, add `gem "activestorage"` to your Gemfile (included in supported Rails versions via the `rails` meta-gem) and run `bin/rails active_storage:install` to create the `active_storage_blobs` / `active_storage_attachments` / `active_storage_variant_records` tables. The mirror precedent is `acts_as_tenant`, which is also soft-detected (see `Config::DEFAULT_SCOPE_RESOLVER`).

- **`on_image_attached` hook:** Fires from `after_commit` on `TypedEAV::Value` when a `Field::Image`-typed Value's attachment is added or replaced. Receives `(value, blob)`. Configure via `TypedEAV.configure { |c| c.on_image_attached = ->(v, b) { ... } }`. Hook ordering: runs AFTER versioning (Phase 4) and AFTER `on_value_change` (Phase 3) so it sees the persisted version row and the user-callback context. File attachments do NOT fire this hook — the name is image-specific by design. Use `on_value_change` for a generic value-mutation signal that covers File-typed Values too.

  ```ruby
  TypedEAV.configure do |c|
    c.on_image_attached = ->(value, blob) {
      ProcessImageJob.perform_later(value.id, blob.id)
    }
  end
  ```

- **`Reference`:** Foreign-key field type. Stores the target record's integer ID in `integer_value`. Operators: `:eq`, `:is_null`, `:is_not_null`, `:references` (explicit narrowing — does NOT inherit `:integer_value`'s `:gt`/`:lt`/`:between` defaults; arithmetic comparisons on FKs don't carry useful semantics). The `:references` operator accepts AR record instances OR Integer IDs at query time, normalizing via `field.cast` (a class-mismatched record routes to `base.none` rather than `:is_null`). Options: `target_entity_type` (REQUIRED — String class name of the target model, validated to constantize at field save), `target_scope` (OPTIONAL — when set, the field is REJECTED at save time if `target_entity_type` is not registered with `has_typed_eav scope_method:` (Gating Decision 2); when set with a scoped target, value-time validation rejects writes whose target's `typed_eav_scope` does not match `target_scope` via a `target_partition_matches?` helper structurally parallel to Phase 1's `entity_partition_axis_matches?` but on the target axis). Cross-scope safety mirrors the existing `Value#validate_field_scope_matches_entity` guard pattern applied to the target rather than the source.

  ```ruby
  rf = TypedEAV::Field::Reference.create!(
    name: "manager", entity_type: "Contact", scope: tenant_id,
    options: { target_entity_type: "Contact", target_scope: tenant_id },
  )
  TypedEAV::Value.create!(entity: alice, field: rf, value: bob)         # accepts AR record
  TypedEAV::Value.create!(entity: alice, field: rf, value: bob.id)      # accepts Integer FK
  Contact.where_typed_eav(name: "manager", op: :references, value: bob) # filter by record
  Contact.where_typed_eav(name: "manager", op: :references, value: 42)  # filter by FK
  ```

- **Summary:** The built-in field types **Image, File, Reference, Currency, Percentage** all preserve the cast-tuple contract (`[casted, invalid?]`), the operator-dispatch model (`supported_operators` + `operator_column` for multi-cell types), and the no-hardcoded-attribute-references foundational principle. The multi-cell extension surface (`read_value`, `write_value`, `apply_default`, and `operator_column`) is the canonical way to build any future external multi-cell field type.

## Validation Behavior

A few non-obvious contracts worth knowing about up front:

- **Required + blank**: `required: true` fields reject empty strings, whitespace-only strings, and arrays whose every element is nil/blank/whitespace.
- **Array all-or-nothing cast**: integer/decimal/date arrays mark the **whole** value invalid (stored as `nil`) when any element fails to cast. There is no silent partial — a failed form re-renders with the original input intact so the user can correct the bad element.
- **`Integer` array rejects fractional input**: `"1.9"` is rejected rather than truncated to `1`. Same rules as the scalar `Integer` field.
- **`Json` parses string input**: a JSON string posted from a form is parsed; parse failures surface as `:invalid` rather than being stored as the literal string.
- **`TextArray` does not support `:contains`**: it backs a jsonb column where SQL `LIKE` doesn't apply. Use `:any_eq` for "array contains element".
- **Orphaned values are skipped**: if a field row is deleted while values remain, `typed_eav_value` and `typed_eav_hash` silently skip the orphans rather than raising.
- **Cross-scope writes are rejected**: assigning a `Value` to a record whose `typed_eav_scope` doesn't match the field's `scope` adds a validation error on `:field`. The same guard covers the `parent_scope` axis.
- **Orphan-parent rows rejected**: a `Field` or `Section` row with `parent_scope` set but `scope` blank is invalid. The `Value`-side guard rejects cross-`(scope, parent_scope)` writes too.
- **Event hooks fire from `after_commit`**: the `on_value_change` and `on_field_change` callbacks fire after the database write is durable; their exceptions never break a save. See §"Event hooks" for the full contract.
- **Versioning is opt-in**: When enabled (`TypedEAV.config.versioning = true` on the gem; `versioned: true` per host), every `:create` / `:update` / `:destroy` event on a Value writes an append-only audit row in `typed_eav_value_versions`. See §"Versioning" for the full contract.
- **`label` is cosmetic, `name` is the machine key**: A field's optional `label` is free-text human display, independent of the slug `name`. Render via `display_name`, which returns `label` when present else `name.humanize`. `label` has no uniqueness or format constraints (only a 255-char max) and never affects ordering, lookup, partitioning, or rename detection — editing only `label` fires `on_field_change` with `:update`, never `:rename`. Existing rows (`label` NULL) render unchanged. Schema export round-trips the raw `label` (legacy payloads without a `label` key import as NULL); snapshot export carries the resolved `display_name`.

## Event hooks

`typed_eav` fires `after_commit` events for value and field changes. Use them
for audit logs, search-index synchronization, cache invalidation, or any
out-of-band reaction that must wait until the database write is durable.

### Public callback slots

```ruby
TypedEAV.configure do |c|
  c.on_value_change = ->(value, change_type, context) {
    # change_type ∈ [:create, :update, :destroy]
    # context is a frozen Hash (see `with_context` below) — read-only
  }

  c.on_field_change = ->(field, change_type) {
    # change_type ∈ [:create, :update, :destroy, :rename]
    # NOTE: no context arg — field changes are CRUD-on-config, not
    # per-entity user actions
  }
end
```

The `:rename` change_type fires whenever the field's `name` column changed
in the just-committed save, even when bundled with other attribute changes
(options, sort_order, default_value, etc.). The detection is intentionally
escalating so any registered consumer receives a rename event whenever the
persisted name changes.

`:update` on Value fires only when the typed value column changed. Saving
a Value record without modifying its typed column (e.g., touching only
bookkeeping columns) is a no-op for event dispatch.

`field_dependent: :nullify` cascades produce **no** Value `:destroy`
events. The FK `ON DELETE SET NULL` runs at the database level and
bypasses AR callbacks. Only the Field `:destroy` event fires. Use
`field_dependent: :destroy` if your consumer needs per-Value events on
field deletion.

For a persisted `field_dependent: :destroy` field with a large population,
call `field.destroy_with_values_in_batches!(batch_size: 1_000)` outside an
open transaction. The opt-in API selects only that exact `field_id` in ordered
primary-key batches, calls `Value#destroy!` for callback/version behavior, and
commits each batch independently. A retry resumes from the remaining rows. The
Field is retained until a locked, bounded residual drain proves zero rows, then
its ordinary callback-preserving `destroy!` runs. The API rejects unsaved or
non-destroy fields, open transactions, invalid batch sizes, and mismatched
connection pools. Existing `destroy`/`destroy!`, `:nullify`, and `:restrict`
behavior is unchanged.

### Thread-local context with `with_context`

```ruby
TypedEAV.with_context(request_id: request.uuid, actor_id: current_user.id) do
  contact.update!(typed_eav: { phone: "555-1234" })
  # on_value_change receives { request_id: "...", actor_id: 42 } as context
end
```

`with_context` is a thread-local stack with shallow per-key merge:

```ruby
TypedEAV.with_context(request_id: "abc") do
  TypedEAV.with_context(source: :bulk) do
    # current context: { request_id: "abc", source: :bulk }
  end
  # current context: { request_id: "abc" }
end
# current context: {}
```

The current-context hash is frozen — callbacks cannot mutate it. Outer
context is restored on exit even if the inner block raises.

`TypedEAV.current_context` returns the current frozen Hash (or a shared
frozen `{}` when no `with_context` block is active). It's safe to call
from any code path; it never returns nil.

### Error policy

User callbacks (`Config.on_value_change`, `Config.on_field_change`) are
rescued — exceptions are logged via `Rails.logger.error` and **do not
propagate** to the user's save call. The save row is already committed
when `after_commit` fires; re-raising would surface a misleading
"save failed" error.

This is the deliberate split with first-party features. Internal
observers used by `typed_eav` itself follow a different rule: their exceptions
**propagate**. Transactional version-writing errors are separate: they
propagate inside and roll back the source transaction.

### Ordering guarantee

When multiple subscribers are registered, they fire in this order:

1. First-party generic observers, in registration order. Errors propagate.
2. The user proc on `Config.on_value_change` / `Config.on_field_change`,
   last. Errors are rescued and logged.

Reassigning `Config.on_value_change` after gem initialization does **not**
disable internal subscribers — they live on a separate dispatcher list
and survive `Config.reset!`.

### Test isolation

Test files that exercise event hooks should opt in to the `:event_callbacks`
metadata:

```ruby
RSpec.describe "my feature", :event_callbacks do
  it "fires the hook" do
    captured = []
    TypedEAV::Config.on_value_change = ->(v, t, _ctx) { captured << [v.id, t] }
    contact.update!(typed_eav: { phone: "555-1234" })
    expect(captured).to include([be_a(Integer), :update])
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshots and
restores Config user procs and the internal-subscriber lists around each
example, so test mutations don't leak across examples and engine-load
registrations from later phases stay intact.

Integration specs that create real AR records and need `after_commit` to
fire durably should additionally opt in to `:real_commits`:

```ruby
RSpec.describe "my model", :event_callbacks, :real_commits do
  # ...
end
```

`:real_commits` disables transactional fixtures for the example and
manually deletes typed_eav rows in FK order after.

### Reset semantics

| Method | What it resets |
|---|---|
| `TypedEAV::Config.reset!` | User procs (`on_value_change`, `on_field_change`) plus `field_types`, `scope_resolver`, `require_scope`. Does **not** clear internal subscribers. |
| `TypedEAV::EventDispatcher.reset!` | Internal subscribers only. Does **not** touch Config. |

Production code rarely calls either — they exist for test isolation and
for the rare case where a host app wants to fully unwire the gem in a
specific request lifecycle.

## Versioning

`typed_eav` ships an opt-in append-only audit log for changes to typed
values. When enabled, each `:create` / `:update` / `:destroy` event on
a Value writes a row to `typed_eav_value_versions` capturing the
before-state, after-state, actor, context, and timestamp.

Default off. Apps that don't enable it pay zero overhead — transactional
Value callbacks are not installed at boot
at all when `Config.versioning = false`. Zero callable in the dispatcher
chain, zero per-write method dispatch, zero per-write config read.

### Enabling versioning

Two steps:

```ruby
# 1. Set the gem-level master switch in an initializer.
#    config/initializers/typed_eav.rb
TypedEAV.configure do |c|
  c.versioning = true
  c.actor_resolver = -> { Current.user }   # optional; nil is permissive
end

# 2. Opt the host model in. Either via the kwarg form:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id, versioned: true
end

# Or via the concern (equivalent — pick whichever fits your conventions):
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
  include TypedEAV::Versioned
end
```

The two opt-in forms produce identical Registry state. The kwarg form is
preferred for new code; the concern form fits codebases with established
mixin-based feature wiring.

### Querying history

```ruby
contact.typed_eav_attributes = [{ name: "age", value: 41 }]
contact.save!
contact.typed_eav_attributes = [{ name: "age", value: 42 }]
contact.save!

value = contact.typed_values.find_by(field: age_field)
value.history          # most-recent-first relation
# => [<ValueVersion change_type: "update" before: {"integer_value" => 41} after: {"integer_value" => 42}>,
#     <ValueVersion change_type: "create" before: {} after: {"integer_value" => 41}>]

value.history.first.changed_by   # => "42" (User#42 — coerced to id.to_s)
value.history.first.context      # => { "request_id" => "abc-123" } if with_context was active
```

`value.history` is a chainable relation. Filter, paginate, pluck:

```ruby
value.history.where(change_type: "update").pluck(:changed_at, :changed_by)
value.history.limit(5).each { |v| ... }
```

### Querying full audit history (including destroy events)

`Value#history` returns versions where `value_id` matches the live Value
record. After the live Value is destroyed, the FK `ON DELETE SET NULL`
nullifies `value_id` on the existing version rows, and the new `:destroy`
version is written by the transactional destroy callback with `value_id: nil`
before the parent row is removed. So `Value#history`
cannot surface destroy versions, and after Value destruction it can no
longer be called at all.

To query the FULL audit history for a given (entity, field), including
destroy events and post-destruction lookup, use the entity-scoped query
directly:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.polymorphic_name, entity_id: contact.id, field_id: age_field.id)
  .order(changed_at: :desc, id: :desc)
# => [<ValueVersion change_type: "destroy" before: {"integer_value" => 42} after: {} value_id: nil>,
#     <ValueVersion change_type: "update"  before: {"integer_value" => 41} after: {"integer_value" => 42} value_id: nil>,
#     <ValueVersion change_type: "create"  before: {} after: {"integer_value" => 41} value_id: nil>]
```

This pattern is the canonical way to surface "what happened to this
field on this entity" across the full lifecycle, including post-destroy.
The `entity_type` + `entity_id` columns remain the durable identity even
after the parent Value row is gone, and `field_id` survives because
destroying a Value does not destroy its Field.

For broader audit views — "show all version history across all fields
for a given entity" (e.g., admin entity-history pages, compliance
exports) — drop the `field_id` filter:

```ruby
TypedEAV::ValueVersion
  .where(entity_type: contact.class.polymorphic_name, entity_id: contact.id)
  .order(changed_at: :desc, id: :desc)
# => all version rows for every typed field on this contact, most-recent-first.
# Includes :create, :update, and :destroy events across every field the
# entity has ever had a typed value for.
```

The field-scoped query (with `field_id:`) is the common case for
"history of a single field"; the entity-scoped query (without `field_id:`)
is the broad-audit case for "all version history across all fields for
this entity".

### Version row jsonb shape

`before_value` and `after_value` are jsonb hashes keyed by typed-column
name:

| Field type | Snapshot shape (single key) |
|---|---|
| `text`, `email`, `url`, `color` | `{"string_value": "..."}` |
| `long_text` | `{"text_value": "..."}` |
| `integer` | `{"integer_value": 42}` |
| `decimal` | `{"decimal_value": "10.5"}` |
| `boolean` | `{"boolean_value": true}` |
| `date` | `{"date_value": "2026-05-05"}` |
| `date_time` | `{"datetime_value": "2026-05-05T12:00:00Z"}` |
| `select` | `{"string_value": "..."}` |
| `multi_select`, `*_array`, `json` | `{"json_value": [...]}` |

Multi-cell field types (e.g., `Currency`) produce two-key snapshots:
`{"decimal_value": "99.99", "string_value": "USD"}`. The version row's
snapshot asks the field's storage contract for its cells, so new field
types get the right shape automatically.

`{}` (empty hash) and `{"<col>": null}` are distinct semantics:

- `{}` means **no recorded value** — typical of `before_value` on a
  `:create` event, or `after_value` on a `:destroy` event.
- `{"<col>": null}` means **recorded nil** — the user explicitly
  cleared the cell.

### Reverting

```ruby
target = value.history.find_by(change_type: "update")
value.revert_to(target)
# value's typed columns now match target.before_value.
# A NEW version row is written capturing the revert (append-only).
```

`revert_to` writes the targeted version's `before_value` columns back
via `self[col] = …` and `save!`. The transactional version callback writes a
NEW version row whose
`after_value` reflects the targeted version's `before_value`. The
audit log is append-only — every revert is itself versioned.

To record the intent of the revert, wrap the call in `with_context`:

```ruby
TypedEAV.with_context(reverted_from_version_id: target.id, actor: current_user) do
  value.revert_to(target)
end
# The new version row's `context` column captures both keys.
```

`revert_to` raises `ArgumentError` in three documented conditions, checked in order:

- when `version.value_id` is nil (the source Value was destroyed — destroy
  versions have `value_id: nil` per the locked subscriber contract; you
  can't restore a destroyed AR record by `save!`);
- when the version's `before_value` is empty (the version represents a
  `:create` event with no before-state to revert to);
- when the version belongs to a different Value (`value_id` mismatch).

In practice only `:update` versions are revertable. To restore a
destroyed entity's typed values, create a new `TypedEAV::Value` record
manually using `version.before_value` as the seed state.

### Hook ordering guarantee

Versioning is installed as boot-latched transactional callbacks on `Value`,
and the public callback remains an after-commit observer. The version row is
written in the source transaction.
```
Value#save! → transactional Value callback → ValueVersion.create!
          → after_commit → EventDispatcher.dispatch_value_change:
  1. ... any other generic internal observers ...
  2. Config.on_value_change user proc        # sees the persisted version
```

Internal observer errors propagate. Transactional version-writing errors also
propagate inside and roll back the source transaction.
User proc errors are rescued and logged via `Rails.logger.error` —
the save itself already committed.

### Actor resolution

`Config.actor_resolver` mirrors `Config.scope_resolver`'s callable shape
but returns whatever the app chooses (an AR record, a string, an integer,
nil). The subscriber coerces non-nil returns via `id.to_s` (for AR
records) or `to_s` (for scalars) before storing in the `changed_by`
column (string, nullable).

`nil` is the documented permissive sentinel: system writes, migrations,
console-without-actor, and background jobs without a `with_context(actor:
...)` wrap all flow through with `changed_by: nil`. This is intentional —
forcing every Versioned write to have an actor would reject every console
save and every migration backfill, which is hostile-by-default for a gem.

Apps that need stricter enforcement do it inside the resolver:

```ruby
c.actor_resolver = -> { Current.user || raise(MyApp::ActorRequired) }
```

`Config.reset!` (documented in §"Event hooks") also resets `Config.versioning`
to `false` and `Config.actor_resolver` to `nil`.

### What versioning does not do

- **No branching/merging across version chains.** Phase 4 ships event-log
  shape only. Roadmap explicitly defers branching to a future design.
- **No snapshot storage by default.** `typed_eav_value_versions` is an
  event log — one row per change, not a full-row snapshot. For
  high-volume apps that want snapshot storage, extend `ValueVersion` in
  your own code (the gem keeps the event-log shape canonical so future
  upgrades don't break your extension).
- **No automatic `reverted_from_version_id` injection.** Use
  `with_context` to record revert intent; the gem captures whatever
  context the caller set.
- **No per-Field versioning toggle.** Opt-in is per-entity (host model)
  in Phase 4. Per-field granularity may land later if a real need
  surfaces.
- **No GIN indexes on `before_value` / `after_value` content.** Apps
  that need to query inside the snapshot jsonb add their own indexes.
  Phase 4 ships only the temporal indexes (`changed_at DESC` keyed on
  `value_id`, `(entity_type, entity_id)`, and `field_id`).

### Test isolation

Specs that exercise versioning should opt into the `:event_callbacks`
and `:real_commits` metadata flags (see §"Event hooks" — same pattern):

```ruby
RSpec.describe "my versioning behavior", :event_callbacks, :real_commits do
  before do
    TypedEAV.registry.register("Contact", versioned: true)
    TypedEAV::Config.versioning = true
    # Transactional Value callbacks are boot-latched and remain installed;
    # the hook isolates only public and generic EventDispatcher observers.
  end
  after { TypedEAV.registry.register("Contact", versioned: false) }

  it "writes a version row" do
    # ...
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshots and
restores `Config.versioning`, `Config.actor_resolver`, and generic
EventDispatcher observer lists around each example. Transactional Value
callback installation is tested independently through callback-chain and
boot-latch specs. The
`:real_commits` hook disables transactional fixtures (so `after_commit`
fires durably) and cleans up `TypedEAV::ValueVersion` rows in
FK-respecting order between examples.

## Database Support

Requires PostgreSQL. The `text_pattern_ops` index on `string_value` and the jsonb `@>` containment operator are Postgres-specific. MySQL/SQLite support would require removing those index types and changing the array query operators.

As of v0.2.0, the paired partial unique indexes cover the three-key partition tuple `(entity_type, scope, parent_scope)`. The orphan-parent invariant means the `WHERE scope IS NULL` partials don't include `parent_scope` — a global row always has `parent_scope` NULL too.

## Schema

The gem creates five tables:

- `typed_eav_fields` - field definitions (STI, one row per field per entity type)
- `typed_eav_values` - values (one row per entity per field, with typed columns)
- `typed_eav_options` - allowed values for select/multi-select fields
- `typed_eav_sections` - optional UI grouping
- `typed_eav_value_versions` - opt-in, append-only audit history for Value
  create, update, and destroy events; it retains durable entity identity even
  when the live Value row is later removed

## Architecture

Internal module layout as of 0.7.0. Most consumers never reach for these directly — the public surface is the `has_typed_eav` macro and the instance/class methods it installs — but the split matters if you're extending the gem, debugging an integration, or evaluating it for production. Decisions are anchored by ADR-0001 through ADR-0013.

### Macro entry: `HasTypedEav`

`lib/typed_eav/has_typed_eav.rb` (~120 LOC) is the macro shell. When you call `has_typed_eav` on an AR model, it:

1. `extend`s `TypedEAV::EntityQuery` onto the class (class-level query methods).
2. `include`s `TypedEAV::HasTypedEav::InstanceMethods` (per-record accessors).
3. Wires scope/parent-scope kwargs into the model's class-level configuration.
4. Registers the model with `TypedEAV::Registry`.

The macro is intentionally thin. All real behavior lives in the modules it pulls in.

### Class-level reads: two-altitude query pattern

```
Contact.where_typed_eav(...)         ← public class method
       │
       ▼
TypedEAV::EntityQuery                 ← high altitude: orchestrator
  • resolves scope/parent_scope from ambient context or explicit kwargs
  • owns the UNSET_SCOPE / ALL_SCOPES sentinels
  • delegates to FilterQuery
       │
       ▼
TypedEAV::FilterQuery                 ← multi-filter composition
  • normalizes filter input shapes (positional, hash, hash-of-hashes)
  • looks up field definitions via TypedEAV::Partition
  • per filter, asks QueryBuilder for the SQL fragment
  • unions/intersects per-field entity-id sets
  • returns an ActiveRecord::Relation scoped to the host model
       │
       ▼
TypedEAV::QueryBuilder                ← low altitude: per-field SQL primitive
  • turns a single (field, op, value) into a WHERE clause against typed_eav_values
  • knows about typed-column projections (integer_value, string_value, etc.)
  • knows about operator-specific column choice (currency-cents vs currency-code)
```

`QueryBuilder` is the single place that decides "given this field and this operator, which column and which SQL fragment?" `FilterQuery` never builds SQL fragments directly; `EntityQuery` never touches columns. Splitting the two altitudes keeps custom field types extending only the column-mapping surface (`value_column`, `operators`, `operator_column`) without ever subclassing `FilterQuery`.

### Bulk reads: `BulkRead`

`typed_eav_hash_for(records)` (the plural read) routes through `TypedEAV::BulkRead`. Given a record collection and an effective `(scope, parent_scope)`, it:

1. Resolves visible definitions and groups the requested field IDs.
2. Loads definitions, values, and field associations through one batched
   definition query, one values query, and one field-association preload
   (three SQL queries total; no host-table query).
3. Returns a `{record_id => {field_name => value}}` map while skipping orphaned
   values and preserving logical missingness.

Definitions, filters, reads, registry entries, and writes all use the host's
Rails `polymorphic_name`, so an STI leaf class reads and queries the same rows
written under its base-class polymorphic type.

The final production characterization reduced the 1,002 SQL statements observed
across 1,000 scopes to three for the same BulkRead shape. This is a statement-
count result, not a representative throughput claim; applications should still
measure their own scope cardinality, selected fields, hydration, and contention.

Single-record reads (`typed_eav_value`, `typed_eav_hash`) live on `InstanceMethods` and use the same partition helpers but without batching.

Use `fields:` to load only the values needed by a view or export:

```ruby
Contact.typed_eav_hash_for(contacts, fields: [:name, :score])
# => {123 => {"name" => "Ada", "score" => 42}, ...}
```

Omitting `fields:` (or passing `nil`) retains the all-fields behavior. A single
String/Symbol or an enumerable of names is accepted; duplicates are removed.
Unknown names and names unavailable in an individual record's partition are
omitted, as are missing value rows. An explicitly stored NULL remains `nil`.
`fields: []` returns an empty inner hash for each record without definition or
value queries (the supplied collection itself may still need loading). Selected
winning field IDs constrain the value query before hydration, so unrequested
values and their field readers are not loaded or evaluated. Definition lookup
remains batched across the records' partitions.

### Bulk writes: `BulkWrite`

`bulk_set_typed_eav_values(records, attrs)` routes through `TypedEAV::BulkWrite`,
and `bulk_set_typed_eav_values_per_record(values_by_record)` is its sibling for
record-varying hashes. Both are semantic writers that:

1. Memoizes field definitions for the call via `Thread.current[:typed_eav_bulk_defs_memo]`.
2. Validates each attribute against its field type's cast contract.
3. Saves each host through the normal callback/validation path inside an outer
   transaction with per-record savepoints.

`bulk_set_typed_eav_values_per_record` uses records as Hash keys, so two AR
instances of the same persisted row collapse to one entry; sequence separate
calls for two ordered updates, while the uniform Array API preserves duplicate
instances and caller order.

Under `transaction: :all`, per-record validation failures are captured at their
savepoints while other successes can commit, but an uncaught exception rolls
the entire outer transaction back. The default `transaction: :all` commits the
whole successful batch or rolls it back;
`transaction: :chunks, chunk_size: N` commits completed chunks while isolating
later failures, preserving earlier committed chunks. Both forms require the
host, Field, and Value pools to match.
`bulk_upsert_typed_eav_values` is a separate reduced-semantics fast path: it
casts and validates typed values, then performs one PostgreSQL upsert while
omitting host saves, persistence callbacks, delete shorthand, and versioning.

Callers must pass `acknowledge_reduced_semantics: true`. The same values hash
applies to every record; records must be persisted and unique, and string or
symbol field keys that normalize to the same name are rejected. The return
value is the integer number of value rows upserted, not a semantic
`successes`/`errors_by_record` result. Value casting, domain/entity/partition
checks, and Value validation callbacks remain; host callbacks and validations,
Value persistence callbacks, versioning, delete shorthand, and per-record
savepoint isolation are skipped.

Within each `transaction: :all` unit—or each requested chunk—the upsert path
resolves every record partition through one batched field-definition SELECT.
It shares BulkRead's internal tuple resolver, retaining global, scope-only, and
full-tuple precedence independently for each record without broadening tenant
visibility.

`BulkWrite` and `BulkRead` are siblings — one read path, one write path — but they don't share a base class. Per [ADR-0005](docs/adr/0005-keep-phase-six-modules-independent.md), keeping them independent preserves the option to evolve each on its own schedule.

### Per-record reads/writes: `InstanceMethods`

`lib/typed_eav/has_typed_eav/instance_methods.rb` (~250 LOC) holds the per-record API:

- `typed_eav_value(name)` / `typed_eav_hash` — reads
- `set_typed_eav_value(name, value)` / `typed_eav_attributes=` (aliased as `typed_eav=`) — writes
- `typed_eav_definitions` — resolved field-definitions map for the host record
- `typed_eav_scope` / `typed_eav_parent_scope` — scope resolution per record

Every method uses `TypedEAV::Partition.definitions_by_name` so the collision-precedence rules for ambient/explicit/parent scopes are computed in one place.

### Partition visibility: `Partition`

Host applications that need to inspect effective schema should use the
documented-public `TypedEAV::Partition` seam rather than rebuilding tuple
predicates. It exposes `visible_fields`, `effective_fields_by_name`,
`definitions_by_name`, `definitions_multimap_by_name`, `visible_sections`,
and `find_visible_section!`. These methods preserve global, scope-only, and
full-tuple precedence; ADR-0006 additionally fixes include-missing set
composition at the `FilterQuery` altitude.

### Field types and storage: `Field::TypedStorage`

`TypedEAV::Field::Base` is the STI parent of every field type. The shared storage surface lives in the `TypedEAV::Field::TypedStorage` concern (`lib/typed_eav/field/typed_storage.rb`, ~200 LOC), auto-included on `Field::Base`. Per [ADR-0001](docs/adr/0001-collapse-column-mapping-stack.md), it provides:

- **Class DSL**: `value_column`, `value_columns`, `operators`, `operator_column`, `supported_operators` — describe where typed values live and which operators they support.
- **Instance override points**: `read_value(record)`, `write_value(record, casted)`, `apply_default(record)` — the three methods a multi-cell field type overrides.
- **Concrete snapshot helpers**: `value_changed?`, `before_snapshot`, `after_snapshot` — derived automatically from `value_columns`; not overridable.

Custom multi-cell field types subclass `Field::Base` directly and override only the three instance methods. See §[Multi-cell field types](#multi-cell-field-types) for `Currency` as the canonical worked example.

### Field families: intermediate STI bases

Per [ADR-0004](docs/adr/0004-field-family-intermediate-bases.md), three intermediate STI parents factor shared validation behavior out of `Field::Base`:

- **`TypedEAV::Field::ValidatedString`** — parent of `Text`, `Email`, `Url`. Owns string-length and pattern-validation helpers including `max_gte_min_length` (which now covers Email/Url, not just Text).
- **`TypedEAV::Field::RangeBounded`** — parent of `Integer`, `Decimal`, `Date`, `DateTime` (and `Percentage < Decimal`). Owns range-validation helpers including `validates :max, comparison: { greater_than_or_equal_to: :min }` (which now covers Date/DateTime, not just Integer/Decimal).
- **`TypedEAV::Field::Optionable`** — a Rails concern included by `Select` and `MultiSelect`. Owns the public-facing sorted `allowed_values` reader and the option-inclusion validators.

`Color`, `Boolean`, `Json`, and the array field types (`TextArray`, `IntegerArray`, `DecimalArray`, `DateArray`) remain direct children of `Field::Base`. See §[Family intermediate bases](#family-intermediate-bases-extension-points) for extension examples.

### Scope tuple normalization: `ScopeTuple`

`TypedEAV::ScopeTuple` (`lib/typed_eav/scope_tuple.rb`, ~120 LOC) is the canonical source of truth for the `(scope, parent_scope)` partition tuple. It provides:

- `normalize_permissive(scope)` — coerces input to a tuple; tolerates bare scalars (used by `with_scope`, `normalize_scope`, `Field#validate_parent_scope_invariant`).
- `normalize_strict(scope)` — same shape, but raises on bare-scalar input (used by `current_scope`; preserves Phase-1's asymmetric contract that `Config.scope_resolver` must return a tuple).
- `invariant_satisfied?(scope, parent_scope)` — Boolean check for the orphan-parent invariant (`parent_scope` set without `scope` = invalid).

Each calling site keeps its own response policy (raise / AR error / silent narrow) using the Boolean return — `ScopeTuple` is a predicate, not an enforcer.

### Partition tuple helpers: `Partition`

`TypedEAV::Partition` (`lib/typed_eav/partition.rb`, ~100 LOC) owns the `(entity_type, scope, parent_scope)` precedence rules:

- `definitions_by_name(model, scope, parent_scope)` — returns the field-definitions map for a single resolved partition.
- `definitions_multimap_by_name(model)` — returns the cross-partition multimap used by `unscoped { }` blocks.
- `visible_fields(model, scope, parent_scope)` / `visible_sections(...)` — scope-respecting field/section iteration with the orphan-parent invariant inlined via `ScopeTuple.invariant_satisfied?`.

The definitions helpers used to live as class methods on `HasTypedEav` before 0.3.0. They moved to `Partition` per [ADR-0002](docs/adr/0002-entity-query-orchestration.md) because they describe the partition domain, not the macro.

### Events: `EventDispatcher`

`TypedEAV::EventDispatcher` (`lib/typed_eav/event_dispatcher.rb`, ~150 LOC) is the broker for `on_value_change` and `on_field_change` callbacks. Per [ADR-0003](docs/adr/0003-keep-event-dispatcher-broker.md), it intentionally stays a broker rather than getting absorbed into either `Value` or `Field` — its multi-publisher / multi-subscriber shape doesn't belong on either model. See §[Event hooks](#event-hooks) for the public callback contract.

### Schema portability and CSV: independent modules

`TypedEAV::SchemaPortability` and `TypedEAV::CSVMapper` (Phase-6 modules) are deliberately decoupled from the core read/write path per [ADR-0005](docs/adr/0005-keep-phase-six-modules-independent.md). They depend on the public `has_typed_eav` macro surface, never on internal modules.

### Bulk operation guarantees

`bulk_upsert_typed_eav_values` is an explicit reduced-semantics API: it
prevalidates/casts values and performs a PostgreSQL upsert, while intentionally
omitting host callbacks and versioning. Use the regular bulk writer when those
semantics are required; chunked semantic transactions are opt-in.

The fast path still casts and runs domain, entity, partition, and validation
callbacks before its single upsert against the exact entity/field conflict
target; it omits host saves/host callbacks, Value persistence callbacks,
delete shorthand, and versioning. It requires one shared connection pool and
returns validation errors before SQL. `:all` is one unit; `:chunks` commits
completed chunks before a later failure. Semantic writes retain host saves,
per-record savepoint/error isolation, and one outer `:all` transaction.

BulkWrite evidence is intentionally bounded to the exercised 100- and 1,000-host
lanes. It does not establish 10,000- or 100,000-host throughput, nor does it
justify a universal batch size or storage choice.

### Operational guarantees

The semantic writer preserves the caller's transaction and callback/versioning
contract. Version rows are written in the source transaction, so a rollback
rolls back the Value mutation and its audit row together. The reduced-semantics
upsert is intentionally separate and does not claim those callbacks or audit
guarantees.

Field deletion has a callback-preserving, keyset-batched path that locks and
destroys only the exact field's Values before bounded finalization. It scales by
bounded primary-key batches and preserves the Field if a batch fails; it is not
a claim of unbounded deletion throughput.

### Default backfill narrowing

`Field::Base#backfill_default!` optionally accepts an exact-host
`ActiveRecord::Relation` to SQL-narrow eligible entities before batching. The default
all-host behavior remains unchanged; partition checks, batch transactions,
callbacks, validations, idempotence, versions, and errors remain in force.
Typed storage defines logical missingness across all declared cells, so a
partially populated multi-cell value is present while a fully empty Currency
value is missing.

## License

MIT
