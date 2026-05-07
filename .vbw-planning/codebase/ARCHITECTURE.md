# ARCHITECTURE.md

## Big idea

`typed_eav` is a Rails Engine that implements a **hybrid Entity-Attribute-Value pattern**: instead of one `value jsonb` column on the values table, there are *seven* typed columns (`string_value`, `text_value`, `boolean_value`, `integer_value`, `decimal_value`, `date_value`, `datetime_value`, `json_value`). Each `Field` STI subclass declares which column it targets via `value_column :integer_value`. The query layer then leans on Rails' built-in column-type casting through Arel — there is **no per-type caster class for queries**, just one `QueryBuilder` module.

Trade: write/read paths are slightly fancier (delegate to the right column based on `field.class.value_column`), but you get native B-tree indexes, range-scan optimization, partial GIN indexes for jsonb arrays, and zero runtime `CAST(...)` SQL. README §"Why Typed Columns?" articulates this trade explicitly.

**v0.2.0 expansion**: Phase 05 introduced *multi-cell* field types — Currency stores `{amount, currency}` across `decimal_value` + `string_value`. The cell-count is invisible to `Value`; `Field::Base` exposes three extension points (`read_value`, `write_value`, `apply_default_to`) that single-cell types inherit unchanged and multi-cell types override in lock-step. `ColumnMapping#value_columns` (plural) and `#operator_column(operator)` round out the multi-cell surface for the versioning subscriber and `QueryBuilder`.

## Layers

```
┌────────────────────────────────────────────────────────────────────┐
│ Consumer Rails app                                                 │
│   class Contact < ApplicationRecord                                │
│     has_typed_eav scope_method: :tenant_id                         │
│   end                                                              │
│   class Project < ApplicationRecord                                │
│     has_typed_eav scope_method: :tenant_id,                        │
│                   parent_scope_method: :workspace_id,              │
│                   versioned: true                                  │
│   end                                                              │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ included automatically into all AR
                               │ models by `Engine#initializer
                               │  "typed_eav.active_record"`.
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::HasTypedEAV (lib/typed_eav/has_typed_eav.rb)             │
│   Concern. The macro `has_typed_eav` opts the host model in:       │
│   • declares typed_values has_many + accepts_nested_attributes_for │
│   • includes InstanceMethods (typed_eav_value, typed_eav_scope,    │
│     typed_eav_parent_scope, set_typed_eav_value,                   │
│     typed_eav_attributes=, typed_eav_hash, initialize_typed_values)│
│   • extends ClassQueryMethods (where_typed_eav, with_field,        │
│     typed_eav_definitions; both kwargs scope:/parent_scope:)       │
│   • registers the host with TypedEAV::Registry                     │
│     (with optional versioned: true flag)                           │
│   • macro-time guard: parent_scope_method: without scope_method:   │
│     raises ArgumentError at class load                             │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ delegates queries through
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::QueryBuilder (lib/typed_eav/query_builder.rb)            │
│   Single module, one big operator-dispatch case. Validates the     │
│   operator against the field's `supported_operators`, then routes  │
│   to the correct physical column via `field.class.operator_column  │
│   (operator)` (single-cell default → value_column; Currency →      │
│   decimal_value or string_value depending on operator).            │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ scopes + filters
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ Persistence layer (app/models/typed_eav/)                          │
│   ApplicationRecord (abstract)                                     │
│   ├─ Field::Base (STI on `type`)                                   │
│   │  ├─ Text, LongText, Integer, Decimal, Boolean, Date, DateTime  │
│   │  ├─ Select, MultiSelect (optionable)                           │
│   │  ├─ IntegerArray, DecimalArray, TextArray, DateArray (arrays)  │
│   │  ├─ Email, Url, Color (string-backed with extra cast/validate) │
│   │  ├─ Json                                                        │
│   │  ├─ Currency  (multi-cell: decimal_value + string_value)        │
│   │  ├─ Percentage (extends Decimal; fraction 0..1 + format)        │
│   │  ├─ Reference (FK in integer_value; :references operator)       │
│   │  └─ Image / File (Active Storage signed_id in string_value)    │
│   ├─ Value (polymorphic on entity; FK to field; optional has_one_  │
│   │   attached :attachment when AS loaded)                         │
│   ├─ ValueVersion (Phase 04 audit log; one row per Value mutation) │
│   ├─ Section (optional UI grouping; partition-aware ordering)       │
│   └─ Option (per-field allowed values for select/multi-select)     │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ Phase 03 after_commit
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::EventDispatcher (lib/typed_eav/event_dispatcher.rb)      │
│   In-process pub/sub. Two channels:                                │
│     • value_change_internals []  → user proc (Config.on_value_     │
│       change). Internals fire FIRST in registration order;         │
│       internal exceptions PROPAGATE; user-proc exceptions are      │
│       rescued + logged.                                            │
│     • field_change_internals []  → user proc (Config.on_field_     │
│       change). Same fire order + error policy.                     │
│   Phase 04 versioning registers Subscriber.method(:call) at        │
│   slot 0 of value_change_internals via                             │
│   Versioning.register_if_enabled (engine config.after_initialize). │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ when entity opted in
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::Versioning::Subscriber                                   │
│   Writes one TypedEAV::ValueVersion row per :create/:update/       │
│   :destroy event. Two-gate: value.field is non-nil (orphan guard)  │
│   AND TypedEAV.registry.versioned?(entity_type) is true. Snapshots │
│   keyed by typed-column name; multi-cell types (Currency) emit     │
│   two-key hashes by iterating field.class.value_columns.           │
└────────────────────────────────────────────────────────────────────┘
```

## Engine wiring

`lib/typed_eav.rb` requires `typed_eav/engine` and exposes the module surface (`config`/`configure`, `registry`, `current_scope`, `with_scope`, `unscoped`, `unscoped?`, `normalize_scope`, `with_context`, `current_context`).

`lib/typed_eav/engine.rb`:

```ruby
class Engine < ::Rails::Engine
  isolate_namespace TypedEAV

  initializer "typed_eav.autoload" do
    require_relative "column_mapping"
    require_relative "config"
    require_relative "registry"
    require_relative "event_dispatcher"  # eager — Phase 04 registers
                                         # against this at engine boot.
  end

  initializer "typed_eav.active_record" do
    ActiveSupport.on_load(:active_record) do
      include TypedEAV::HasTypedEAV
    end
  end

  config.after_initialize do
    TypedEAV::Versioning.register_if_enabled
  end

  config.after_initialize do
    TypedEAV::Engine.register_attachment_associations!
  end
end
```

Key consequences:
- Every ActiveRecord class in the host app gains the `has_typed_eav` macro. The macro itself is a no-op until called.
- `EventDispatcher` is **eager-required**, not autoloaded — Phase 04 registers Subscriber.method(:call) onto `value_change_internals` at engine boot, before any model reference would trigger autoload. Without the eager require, autoload would run a fresh `@value_change_internals = []` on first reference, wiping the registration.
- Versioning subscriber registration runs in `config.after_initialize` (not a regular `initializer` block) so it can read `TypedEAV.config.versioning` *after* the host's `config/initializers/typed_eav.rb` has set it. When `versioning = false` (default), the subscriber is **never registered** — zero callable, zero per-write dispatch overhead.
- Active Storage attachment registration runs in a *second* `config.after_initialize`. Block ordering is preserved by Rails, so versioning's slot-0 status at the EventDispatcher level is unaffected.

## Three runtime singletons + one thread-local stack

| Singleton | File | What it holds |
|---|---|---|
| `TypedEAV::Config` | `lib/typed_eav/config.rb` | `field_types` map (built-in 22 + any registered), `scope_resolver` callable, `require_scope` boolean, `versioning` master switch (Phase 04), `actor_resolver` callable (Phase 04), `on_value_change` / `on_field_change` / `on_image_attached` user procs (Phases 03/05). Hand-rolled accessors via `defined?(@var)` (Configurable was deprecated in Rails 8.1). |
| `TypedEAV::Registry` | `lib/typed_eav/registry.rb` | `entities` map (`entity_type_name => { types: [...], versioned: bool }`). Populated when host models call `has_typed_eav`; read at field-create time to enforce the `types:` allow-list, and by `Versioning::Subscriber` to short-circuit when `versioned?(entity_type)` is false. |
| `TypedEAV::EventDispatcher` | `lib/typed_eav/event_dispatcher.rb` | `value_change_internals` / `field_change_internals` arrays of internal subscribers (Phase 04 versioning at slot 0; Phase 07 matview will append later). Dispatch helpers `dispatch_value_change(value, type)` and `dispatch_field_change(field, type)`. |
| Thread-local stacks | `lib/typed_eav.rb` | `:typed_eav_scope_stack` (used by `with_scope`), `:typed_eav_unscoped` (used by `unscoped`), `:typed_eav_context_stack` (used by `with_context` / `current_context` — Phase 03 audit/event metadata). All three constants are `private_constant`. |

## Multi-tenant scoping (the careful piece, now two-axis)

The scope subsystem is the most thought-through part of the codebase. It is fail-closed by default. Phase 01 extended it from a single `scope` axis to a `(scope, parent_scope)` tuple while preserving full BC for single-axis callers.

### Resolution priorities

```
1. Inside `unscoped { }`             → ALL_SCOPES sentinel (multimap branch)
2. Innermost `with_scope(v) { }`     → tuple stored on the stack
3. `Config.scope_resolver.call`      → must return [scope, parent_scope] or nil
4. nil
```

`HasTypedEAV::ClassQueryMethods#resolve_scope` (lines 339–413) implements the **fail-closed** contract: if the model declared `scope_method:` and nothing resolved, raise `TypedEAV::ScopeRequired`. This is the whole point of the design — forgetting to set scope cannot silently leak other tenants' data.

### Two-axis kwarg semantics

Both `where_typed_eav` and `typed_eav_definitions` accept `scope:` and `parent_scope:` kwargs:

| Kwarg state | Meaning |
|---|---|
| omitted (`UNSET_SCOPE` sentinel) | Resolve from ambient (`with_scope` → resolver → raise/nil). |
| explicit value | Use verbatim (admin/test path). Mixing explicit + ambient within one call is rejected — explicit wins for the *whole tuple*. |
| explicit `nil` | Filter to global-only on that axis (preserves prior behavior). |

### Two-axis sentinels and shape contracts

| Sentinel | Meaning |
|---|---|
| `UNSET_SCOPE` (frozen Object) | distinguishes "kwarg not passed → resolve from ambient" from "explicitly passed `nil` → filter to global-only on this axis". |
| `ALL_SCOPES` (frozen Object) | returned by `resolve_scope` inside `unscoped { }`. Tells `where_typed_eav` to skip the scope filter entirely and use the **multimap** branch (a single field name may legitimately exist across multiple tenants — collapsing to one would silently drop matches). Atomic-bypass — drops both `scope` and `parent_scope` predicates simultaneously. |

The resolver-callable contract (`Config.scope_resolver`) is **strict**: must return `nil` or a 2-element Array. A bare scalar (the v0.1.x shape) raises `ArgumentError` directly inside `current_scope`, BEFORE normalization. The `with_scope(value)` block API is **BC-permissive**: scalars/AR records are auto-coerced into `[value, nil]`. Two surfaces, two contracts — the strict raise is the chokepoint that makes the breaking change visible; the BC permissiveness keeps single-axis app code working unchanged.

### Orphan-parent invariant

`scope.nil? ⇒ parent_scope.nil?` is enforced at three layers:

1. **Field-model validator** (`Field::Base#validate_parent_scope_invariant`) and **Section-model validator** (`Section#validate_parent_scope_invariant`) — `parent_scope.present? && scope.blank?` adds `errors.add(:parent_scope, "cannot be set when scope is blank")`.
2. **Schema** — the global partial unique indexes (`WHERE scope IS NULL`) deliberately omit `parent_scope` from their column list, so the invariant guarantees no `(scope=NULL, parent_scope=NOT NULL)` row is ever indexed.
3. **Macro guard** — `has_typed_eav parent_scope_method: :ws` without `scope_method:` raises `ArgumentError` at class load time. Closes the silent dead-letter mode where ambient resolution would short-circuit to `[nil, nil]` and route every parent-scope-aware query to the global-only branch.

### Three-way name-collision precedence

`HasTypedEAV.definitions_by_name(defs)` sorts by `[scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` then `index_by(&:name)` (last-wins). So when global, scope-only, and full-triple fields share a name, the most-specific row wins for both write paths and read paths. The unscoped multimap branch (`HasTypedEAV.definitions_multimap_by_name`) keeps all variants — needed for the OR-across-tenants semantics inside `unscoped { }`.

## STI field hierarchy

`TypedEAV::Field::Base < TypedEAV::ApplicationRecord` is the STI parent. Each subclass:

1. Declares `value_column :something_value` (via the `ColumnMapping` concern).
2. Optionally narrows operators via `operators :eq, :contains, ...` (default operators come from the column type — see `ColumnMapping::DEFAULT_OPERATORS_BY_COLUMN`).
3. Implements `cast(raw)` returning `[casted_value, invalid?]`. The tuple shape is critical: `Value#validate_value` reads the `invalid?` flag to decide between `:invalid` and `:blank` errors.
4. Optionally implements `validate_typed_value(record, val)` for type-specific constraints. Helpers live on `Field::Base` (`validate_length`, `validate_pattern`, `validate_range`, `validate_date_range`, `validate_array_size`, `validate_option_inclusion`, `validate_multi_option_inclusion`).
5. **Multi-cell types** override three paired extension points: `self.value_columns`, `self.operator_column(op)`, and the instance trio `read_value(record)` / `write_value(record, casted)` / `apply_default_to(record)`. Single-cell types inherit defaults that delegate to `value_column` and behave identically to the pre-Phase-05 direct-column-access shape.

`Config::BUILTIN_FIELD_TYPES` is the registration map (**22 types as of v0.2.0**: text, long_text, integer, decimal, boolean, currency, date, date_time, select, multi_select, percentage, reference, integer_array, decimal_array, text_array, date_array, email, file, image, url, color, json). Custom types register via `TypedEAV.configure { |c| c.register_field_type :phone, "Fields::Phone" }`.

### Phase 05 multi-cell + Active Storage types

| Type | Storage | Notable extras |
|---|---|---|
| `Currency` | `decimal_value` (amount) + `string_value` (ISO 4217 code) | `:currency_eq` operator (rejected on every other field type by the operator-validation gate). `default_currency` / `allowed_currencies` options. Cast requires Hash input; bare numerics rejected. |
| `Percentage` | `decimal_value` (extends `Decimal` STI) | Stores 0..1 fractions. `display_as: :percent | :fraction` + `decimal_places` are **read-side format-only** options; storage is always the fraction. Re-declares `value_column :decimal_value` because Ruby class instance vars don't inherit. |
| `Reference` | `integer_value` (FK) | `:references` operator accepts AR record instances OR integer FKs (normalized via `cast`). `target_entity_type` (required) + `target_scope` (optional with field-save guard: `target_scope` set + unscoped target → fail). Constant-shadow hazard: uses `::Integer`/`::String` because bare `Integer` resolves to `TypedEAV::Field::Integer` inside the namespace. |
| `Image` | `string_value` (Active Storage `signed_id`) | Soft-detect via `defined?(::ActiveStorage::Blob)`. `cast` raises `NotImplementedError` with install instructions when AS absent; `validate_typed_value` no-ops. `allowed_content_types` (supports `image/*` wildcards) + `max_size_bytes`. Triggers the `on_image_attached(value, blob)` hook from `Value#_dispatch_image_attached`. |
| `File` | `string_value` (Active Storage `signed_id`) | Same shape as `Image` — shares the `:attachment` association. **No** parallel `on_file_attached` hook (image-specific by design). Namespace-shadows top-level `::File` inside `TypedEAV::Field`. |

## Cascade policy on Field destroy (Phase 02)

`Field::Base.field_dependent` (string column, NOT NULL, default `"destroy"`) drives a `before_destroy :dispatch_field_dependent` callback:

| Policy | Behavior | Notes |
|---|---|---|
| `"destroy"` | Explicit `values.destroy_all` before the field row is deleted. | Required because the FK is now `ON DELETE SET NULL`; without the explicit `destroy_all`, Postgres would NULL the rows out instead. |
| `"nullify"` | No-op. | The FK does the work — Value rows survive with `field_id IS NULL`. Read-path orphan guards (`InstanceMethods#typed_eav_value` / `#typed_eav_hash`) silently skip them. |
| `"restrict_with_error"` | Adds an error and `throw(:abort)` if any Value rows exist. | Mirrors AR's `dependent: :restrict_with_error`. |

`Value.belongs_to :field` is `optional: true` to support orphans. Write-path validators (`validate_value`, `validate_entity_matches_field`, `validate_field_scope_matches_entity`) all `return unless field` already, so optional belongs_to does not weaken any write-path invariant.

## Value model dispatch

`TypedEAV::Value`:
- `value` reads via `field.read_value(self)` — single-cell types fall through to `self[field.class.value_column]`; Currency composes `{amount, currency}` from two columns.
- `value=(val)` runs `field.cast(val)` → calls `field.write_value(self, casted)` → stashes the `invalid?` flag for the next validation pass. The `UNSET_VALUE` sentinel (frozen Object exposed publicly via `Value::UNSET_VALUE`) lets `Value.create(field: f)` (no `value:` kwarg) trigger the field's configured default; `Value.create(field: f, value: nil)` stores nil explicitly. The sentinel is substituted in `initialize` when `attributes.is_a?(Hash)` and `:value` key is missing.
- `apply_pending_value` (`after_initialize`) handles the case where `value=` was called before `field=` (Rails attribute-assign order is not guaranteed in nested-attributes flows).
- `versions` (`has_many`) returns the audit log; `history` returns `versions.order(changed_at: :desc, id: :desc)`; `revert_to(version)` restores typed columns from `version.before_value` and saves (which generates a new audit row — revert is itself versioned).

Validations on `Value`:
- `field` uniqueness scoped to `[entity_type, entity_id]` (one value per entity per field).
- `validate_value` — branches on the cast `invalid?` flag, then the required+blank check (`blank_typed_value?` treats whitespace-only strings and arrays-of-blanks as blank), then delegates to `field.validate_typed_value(self, val)`.
- `validate_entity_matches_field` — sanity check that the `entity_type` column matches the `Field`'s `entity_type`.
- `validate_field_scope_matches_entity` — **cross-tenant guard**. Two-axis: when `field.scope.present?`, requires the entity's `typed_eav_scope` to match; when `field.parent_scope.present?`, also requires `typed_eav_parent_scope` to match. Globals (`scope: nil`) remain shared.
- `validate_json_size` — caps `json_value` at 1 MB to bound the worst-case row size.

Callbacks:
- **Three explicit `after_commit ..., on: :X`** for value-change dispatch (Rails 8.1 alias-collision workaround — see DEPENDENCIES.md note).
- **One `after_commit :_dispatch_image_attached, on: %i[create update]`** for the Phase 05 image hook (declared after the value-change callbacks so it runs LAST in the chain).

## Event dispatch (Phase 03)

`TypedEAV::EventDispatcher` is the in-process pub/sub hub. Two channels (value, field), each with an internal-subscribers array (first-party hooks for in-gem features) and a single-proc user slot (`Config.on_value_change` / `Config.on_field_change`).

**Fire ordering (locked):** internals first, in registration order; user proc last.

**Error policy split (locked at `03-CONTEXT.md §User-callback error policy`):**
- Internal subscribers: exceptions **propagate** (fail-closed). Versioning corruption must be loud.
- User proc: `rescue StandardError`, log via `Rails.logger.error`, swallowed. The row is already committed — re-raising would surface a misleading "save failed" error.

**Signature asymmetry (locked):**
- `dispatch_value_change(value, change_type, context)` — `change_type ∈ {:create, :update, :destroy}`. Context is `TypedEAV.current_context` (frozen Hash from the `with_context` thread-local stack), injected by the dispatcher.
- `dispatch_field_change(field, change_type)` — `change_type ∈ {:create, :update, :destroy, :rename}`. **No context arg** — field changes are CRUD-on-config, not per-entity user actions.

**Field rename detection:** `Field::Base#_dispatch_field_change` (a single after_commit callback, not three) branches by `previously_new_record?` → `:create`, `destroyed?` → `:destroy`, `saved_change_to_attribute?(:name)` → `:rename`, else `:update`. The plan referenced `created?` but that alias does not exist on AR 8.1.3; `previously_new_record?` is the correct documented form.

**Update filter:** `Value#_dispatch_value_change_update` only fires when ANY of `field.class.value_columns` shows `saved_change_to_attribute?` true. Forward-compat with Phase 05 Currency: a change to either cell correctly fires the event without no-op rows from bookkeeping-only writes.

## Versioning (Phase 04)

`TypedEAV::ValueVersion` (table `typed_eav_value_versions`) is an append-only audit log:

| Column | Notes |
|---|---|
| `value_id` | nullable, FK ON DELETE SET NULL — preserves history when live Value is destroyed. **Subscriber writes `nil` for `:destroy` events** because the parent row is already deleted by the time `after_commit on: :destroy` fires; FK validation at INSERT would fail otherwise. |
| `field_id` | nullable, FK ON DELETE SET NULL. |
| `entity` (polymorphic) | NOT NULL — durable identity across Value/Field destruction. |
| `changed_by` | string, nullable. Apps resolve to AR records on the read side (`User.find_by(id: version.changed_by)`). Coerced from `Config.actor_resolver` via the same `normalize_one`-style String coercion as `lib/typed_eav.rb`. |
| `before_value` / `after_value` | jsonb, default `{}`. Keyed by typed-column name (e.g., `{"integer_value": 42}`). Empty `{}` = "no recorded value" (a `:create` before, or a `:destroy` after); `{"<col>": null}` = "recorded nil". Distinct semantics. |
| `context` | jsonb, default `{}`. Captures `TypedEAV.current_context` at write time. |
| `change_type` | string, validated to `%w[create update destroy]` (enum-as-string for additive forward compat). |
| `changed_at` | datetime, NOT NULL. Distinct from `created_at` so backfill scripts can record event-time. |

Three indexes (`idx_te_vvs_value`, `idx_te_vvs_entity`, `idx_te_vvs_field`), all DESC on `changed_at` to match `Value#history`'s most-recent-first ordering.

`TypedEAV::Versioning::Subscriber.call(value, change_type, context)` is **conditionally registered** by `Versioning.register_if_enabled` (engine `config.after_initialize`) only when `Config.versioning = true`. When false (default), the callable is never registered — the locked CONTEXT contract is "zero overhead for apps that don't use versioning", which means literally no callable, not "callable that early-returns".

Two runtime gates inside `Subscriber.call`:
1. `value.field` is non-nil (orphan guard — `field_id` may have been NULLed by Phase 02 cascade).
2. `TypedEAV.registry.versioned?(value.entity_type) == true` (per-entity opt-in via `has_typed_eav versioned: true` or `include TypedEAV::Versioned`).

`TypedEAV::Versioned` is a post-`has_typed_eav` mixin: `included do ... end` re-registers the entity with `versioned: true` while preserving any existing `types:` restriction. The `included` hook raises `ArgumentError` if `has_typed_eav` hasn't run first (checked via `respond_to?(:typed_eav_scope_method)`).

## Forms & nested attributes

The host's `has_typed_eav` macro declares `accepts_nested_attributes_for :typed_values, allow_destroy: true`. Two write paths coexist deliberately (`has_typed_eav.rb` lines 469–537):

| Path | Keyed by | Audience |
|---|---|---|
| `typed_values_attributes=` (via Rails) | `field_id` | HTML forms — the standard Rails contract |
| `typed_eav_attributes=` (gem-defined alias `typed_eav=`) | field `name` | Console / seeds / scripts; ergonomic; respects `_destroy` and the `types:` allow-list |

The gem-defined setter resolves names → field rows via `typed_eav_defs_by_name` (which uses the three-way collision precedence), optionally filters by `allowed_typed_eav_types`, and routes to `typed_values_attributes=` for existing rows or builds new ones in-memory.

## Display ordering (Phase 02)

`Field::Base` and `Section` both expose `move_higher`/`move_lower`/`move_to_top`/`move_to_bottom`/`insert_at(position)`. Each operation:

1. Opens a transaction.
2. Acquires a partition-level `FOR UPDATE` lock on `for_entity(entity_type, scope:, parent_scope:).order(:id)`. The deterministic `:id` order is load-bearing — without it, two threads reordering the same partition could deadlock on different acquisition orders.
3. Reorders the locked snapshot in memory by `[sort_order NULLS LAST, name ASC]`.
4. Yields to the caller's mutation.
5. Normalizes the partition's `sort_order` back to consecutive integers `1..N` (skips no-op writes).

`insert_at` clamps to `[1, partition_count]` (acts_as_list parity). Boundary moves are no-ops, not errors. Cross-partition operations never block each other because they lock disjoint row sets.

## Default-value backfill (Phase 02)

`Field::Base#backfill_default!` populates existing entities with the field's configured default. Iterates `entity_type.constantize.find_in_batches(batch_size: 1000)`; one transaction per batch (not per record); `partition_matches?(entity)` filters per-axis; per-record skip rule is "non-nil typed column already present" (a Value row whose typed column is nil is still a backfill candidate). Idempotent — caller can re-run after interruption.

## Generators

Two `Rails::Generators::Base` subclasses with explicit `namespace` and explicit `source_root` (commit `ccb04b3` made the namespaces explicit so Thor's lookup works under recent Rails):

- `TypedEAV::Generators::InstallGenerator` — wraps the engine's `install:migrations` rake task.
- `TypedEAV::Generators::ScaffoldGenerator` — copies a controller + concern + helper + Stimulus controllers + views + initializer into the host app, and appends a `resources :typed_eav_fields` block to `config/routes.rb`. Its post-install banner walks the user through the four wiring steps (auth hook, scope resolver, controller concern include, form helper render).

The scaffold output is **opt-in admin UI** — the gem does not mount any routes itself.

## What's still on the roadmap

`typed_eav-enhancement-plan.md` enumerates planned phases. As of v0.2.0, Phases 01–05 have shipped:
- ✓ Phase 01: Two-level scope partitioning (`parent_scope_method:`)
- ✓ Phase 02: Cascade policy + display ordering + default-value backfill
- ✓ Phase 03: Event hooks + `with_context`
- ✓ Phase 04: Value versioning + `revert_to`
- ✓ Phase 05: Currency / Percentage / Reference / Image / File field types

Still planned (not yet implemented):
- Phase 06: Bulk import/export, batch APIs (`bulk_set_typed_eav_values`, `typed_eav_hash_for(records)`).
- Phase 07: Materialized index for read-heavy/dashboard use cases (will register a second internal subscriber on `EventDispatcher`).
