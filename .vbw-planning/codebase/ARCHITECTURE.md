# ARCHITECTURE.md

## Big idea

`typed_eav` is a Rails Engine that implements a **hybrid Entity-Attribute-Value pattern**: instead of one `value jsonb` column on the values table, there are *seven* typed columns (`string_value`, `text_value`, `boolean_value`, `integer_value`, `decimal_value`, `date_value`, `datetime_value`, `json_value`). Each `Field` STI subclass declares which column it targets via `value_column :integer_value`. The query layer then leans on Rails' built-in column-type casting through Arel — there is **no per-type caster class for queries**, just one `QueryBuilder` module.

Trade: write/read paths are slightly fancier (delegate to the right column based on `field.class.value_column`), but you get native B-tree indexes, range-scan optimization, partial GIN indexes for jsonb arrays, and zero runtime `CAST(...)` SQL. README §"Why Typed Columns?" articulates this trade explicitly.

## Layers

```
┌────────────────────────────────────────────────────────────────────┐
│ Consumer Rails app                                                 │
│   class Contact < ApplicationRecord                                │
│     has_typed_eav scope_method: :tenant_id                         │
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
│   • includes InstanceMethods (typed_eav_value, set_typed_eav_value,│
│     typed_eav_attributes=, typed_eav_hash, initialize_typed_values)│
│   • extends ClassQueryMethods (where_typed_eav, with_field,        │
│     typed_eav_definitions)                                         │
│   • registers the host with TypedEAV::Registry                     │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ delegates queries through
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::QueryBuilder (lib/typed_eav/query_builder.rb)            │
│   Single module, one big operator-dispatch case. Reads the         │
│   field's value_column, validates the operator against the field's │
│   supported_operators, builds the predicate via Arel.              │
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
│   │  └─ Json                                                        │
│   ├─ Value (polymorphic on entity; FK to field)                    │
│   ├─ Section (optional UI grouping)                                │
│   └─ Option (per-field allowed values for select/multi-select)     │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ all on PostgreSQL
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ Schema (db/migrate/20260330000000_create_typed_eav_tables.rb)      │
│   typed_eav_sections, typed_eav_fields, typed_eav_options,         │
│   typed_eav_values (with seven typed value columns + jsonb)        │
└────────────────────────────────────────────────────────────────────┘
```

## Engine wiring

`lib/typed_eav.rb` requires `typed_eav/engine` and exposes a tiny module surface (`config`/`configure`, `registry`, `current_scope`, `with_scope`, `unscoped`, `unscoped?`, `normalize_scope`).

`lib/typed_eav/engine.rb`:

```ruby
class Engine < ::Rails::Engine
  isolate_namespace TypedEAV

  initializer "typed_eav.autoload" do
    require_relative "column_mapping"
    require_relative "config"
    require_relative "registry"
  end

  initializer "typed_eav.active_record" do
    ActiveSupport.on_load(:active_record) do
      include TypedEAV::HasTypedEAV
    end
  end
end
```

Key consequence: **every** ActiveRecord class in the host app gains the `has_typed_eav` macro. The macro itself is a no-op until called.

## Three runtime singletons

| Singleton | File | What it holds |
|---|---|---|
| `TypedEAV::Config` | `lib/typed_eav/config.rb` | `field_types` map (built-in 17 + any registered), `scope_resolver` callable, `require_scope` boolean. Backed by `ActiveSupport::Configurable`. |
| `TypedEAV::Registry` | `lib/typed_eav/registry.rb` | `entities` map (`entity_type_name => { types: [...] }`). Populated when host models call `has_typed_eav`. Read at field-create time to enforce the `types:` allow-list. |
| Thread-local scope stack | `lib/typed_eav.rb` | `Thread.current[:typed_eav_scope_stack]` (used by `with_scope`) and `Thread.current[:typed_eav_unscoped]` (used by `unscoped`). |

## Multi-tenant scoping (the careful piece)

The scope subsystem is the most thought-through part of the codebase. It is fail-closed by default and built around four resolution priorities (from `lib/typed_eav.rb#current_scope`):

```
1. Inside `unscoped { }`             → nil (hard bypass; Class queries see ALL_SCOPES sentinel)
2. Innermost `with_scope(v) { }`     → v
3. `Config.scope_resolver.call`      → whatever the app configured
4. nil
```

`HasTypedEAV::ClassQueryMethods#resolve_scope` (lines 246-279) implements the **fail-closed** contract: if the model declared `scope_method:` and nothing resolved, raise `TypedEAV::ScopeRequired`. This is the whole point of the design — forgetting to set scope cannot silently leak other tenants' data.

Two sentinels protect against ambiguity:

| Sentinel | Meaning |
|---|---|
| `UNSET_SCOPE` (frozen Object) | distinguishes "kwarg not passed → resolve from ambient" from "explicitly passed `nil` → filter to global-only fields". Without this, you could not distinguish those two cases. |
| `ALL_SCOPES` (frozen Object) | returned by `resolve_scope` inside `unscoped { }`. Tells `where_typed_eav` to skip the scope filter entirely and use the **multimap** branch (a single field name may legitimately exist across multiple tenants — collapsing to one would silently drop matches). |

The `unscoped` branch in `where_typed_eav` (lines 154-186) does an **OR-across all `field_id`s sharing a name, AND across filters** — preserving cross-tenant audit semantics while not collapsing per-name multiplicity.

## STI field hierarchy

`TypedEAV::Field::Base < TypedEAV::ApplicationRecord` is the STI parent. Each subclass:

1. Declares `value_column :something_value` (via the `ColumnMapping` concern).
2. Optionally narrows operators via `operators :eq, :contains, ...` (default operators come from the column type — see `ColumnMapping::DEFAULT_OPERATORS_BY_COLUMN`).
3. Implements `cast(raw)` returning `[casted_value, invalid?]`. The tuple shape is critical: `Value#validate_value` reads the `invalid?` flag to decide between `:invalid` and `:blank` errors.
4. Optionally implements `validate_typed_value(record, val)` for type-specific constraints. Helpers live on `Field::Base` (`validate_length`, `validate_pattern`, `validate_range`, `validate_date_range`, `validate_array_size`, `validate_option_inclusion`, `validate_multi_option_inclusion`).

The `cast` tuple was a refactor: before commit `eef8e51 / 17dbbe1` there was a `cast_value` side-channel; now the tuple is "the only API."

`Config::BUILTIN_FIELD_TYPES` is the registration map (17 types). Custom types register via `TypedEAV.configure { |c| c.register_field_type :phone, "Fields::Phone" }`.

## Value model dispatch

`TypedEAV::Value`:
- `value` reads `self[field.class.value_column]`.
- `value=(val)` runs `field.cast(val)` → writes the casted result to the right typed column → stashes the `invalid?` flag for the next validation pass.
- `apply_pending_value` (an `after_initialize` callback) handles the case where `value=` was called before `field=` (Rails attribute-assign order is not guaranteed in nested-attributes flows).

Validations on `Value`:
- `field` uniqueness scoped to `[entity_type, entity_id]` (one value per entity per field).
- `validate_value` — branches on the cast `invalid?` flag, then the required+blank check (`blank_typed_value?` treats whitespace-only strings and arrays-of-blanks as blank), then delegates to `field.validate_typed_value(self, val)`.
- `validate_entity_matches_field` — sanity check that the `entity_type` column matches the `Field`'s `entity_type`.
- `validate_field_scope_matches_entity` — **cross-tenant guard.** Even if the `entity_type` matches, if the field is scoped, the entity's `typed_eav_scope` must match the field's `scope` (globals with `scope: nil` remain shared).
- `validate_json_size` — caps `json_value` at 1 MB to bound the worst-case row size.

## Forms & nested attributes

The host's `has_typed_eav` macro declares `accepts_nested_attributes_for :typed_values, allow_destroy: true`. Two write paths coexist deliberately (`has_typed_eav.rb` lines 319–387):

| Path | Keyed by | Audience |
|---|---|---|
| `typed_values_attributes=` (via Rails) | `field_id` | HTML forms — the standard Rails contract |
| `typed_eav_attributes=` (gem-defined alias `typed_eav=`) | field `name` | Console / seeds / scripts; ergonomic; respects `_destroy` and the `types:` allow-list |

The gem-defined setter resolves names → field rows, optionally filters by `allowed_typed_eav_types`, and routes to `typed_values_attributes=` for existing rows or builds new ones in-memory.

## Generators

Two `Rails::Generators::Base` subclasses with explicit `namespace` and explicit `source_root` (commit `ccb04b3` made the namespaces explicit so Thor's lookup works under recent Rails):

- `TypedEAV::Generators::InstallGenerator` — wraps the engine's `install:migrations` rake task.
- `TypedEAV::Generators::ScaffoldGenerator` — copies a controller + concern + helper + Stimulus controllers + views + initializer into the host app, and appends a `resources :typed_eav_fields` block to `config/routes.rb`. Its post-install banner walks the user through the four wiring steps (auth hook, scope resolver, controller concern include, form helper render).

The scaffold output is **opt-in admin UI** — the gem does not mount any routes itself.

## What's deliberately not in the gem (yet)

`typed_eav-enhancement-plan.md` enumerates planned phases (two-level scope partitioning, position ordering, default-value backfill, value versioning, dependent-destroy semantics, image/reference/currency/percentage field types, bulk import/export, materialized index, event hooks). None of these are implemented in v0.1.0 — they're a roadmap.
