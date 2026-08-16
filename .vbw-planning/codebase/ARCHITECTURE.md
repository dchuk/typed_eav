# ARCHITECTURE.md

## Big idea

`typed_eav` is a Rails Engine that implements a **hybrid Entity-Attribute-Value pattern**: instead of one `value jsonb` column on the values table, there are *eight* typed columns (`string_value`, `text_value`, `boolean_value`, `integer_value`, `decimal_value`, `date_value`, `datetime_value`, `json_value`). Each `Field` STI subclass declares which column it targets via `value_column :integer_value`. The query layer leans on Rails' built-in column-type casting through Arel — there is **no per-type caster class for queries**, just one `QueryBuilder` module.

Trade: write/read paths are slightly fancier (delegate to the right column based on `field.class.value_column`), but you get native B-tree indexes, range-scan optimization, partial GIN indexes for jsonb arrays, and zero runtime `CAST(...)` SQL. README §"Why Typed Columns?" articulates this trade explicitly.

**Multi-cell types** (Phase 05): Currency stores `{amount, currency}` across `decimal_value` + `string_value`. The cell-count is invisible to `Value`; field types expose three instance override points (`read_value`, `write_value`, `apply_default`) that single-cell types inherit unchanged and multi-cell types override in lock-step. As of the 0.3.0 refactor this entire storage seam lives in **one concern** — `TypedEAV::Field::TypedStorage` (ADR-0001) — replacing the five-participant `ColumnMapping` + `FieldStorageContract` stack.

## The 0.3.0 architecture cleanup (ADRs 0001–0005)

The v0.2.0 map described a `HasTypedEav` god-module and a `ColumnMapping` storage stack. The 0.3.0 arc (#9–#13) restructured both. Net effect on the layer diagram:

- **Storage seam collapsed** — `ColumnMapping` + `FieldStorageContract` + `CurrencyStorageContract` + the `storage_contract_class` macro → one `Field::TypedStorage` concern on `Field::Base` (ADR-0001). The `value_column`/`value_columns`/`operators`/`operator_column` DSL and the `read_value`/`write_value`/`apply_default` override trio all live here. Snapshot helpers (`value_changed?`, `before_snapshot`, `after_snapshot`) are concrete and derive from `value_columns` — NOT overridable (the snapshot shape is a versioning-coupled invariant).
- **Query god-module split** — `HasTypedEav` (was 881 lines) → macro + guards stays in `has_typed_eav.rb` (~117 lines); per-record API → `has_typed_eav/instance_methods.rb`; class-level orchestration → `TypedEAV::EntityQuery` (extended onto the host); `where_typed_eav` body → `TypedEAV::FilterQuery`; `typed_eav_hash_for` → `TypedEAV::BulkRead`; field-collision precedence helpers → `TypedEAV::Partition` (ADR-0002).
- **Scope-tuple semantics localized** — coercion / strict-vs-permissive normalization / orphan invariant gathered into `TypedEAV::ScopeTuple` (#10), previously smeared across five files.
- **Field family bases introduced** — `ValidatedString` (class), `RangeBounded` (class), `Optionable` (concern) absorb per-leaf duplication (ADR-0004).

## Two altitudes of query module (ADR-0002)

Deliberately two layers, picked by altitude:

- **`QueryBuilder`** — low-level SQL primitive. Given `(field, operator, value)` returns a relation/predicate. Knows nothing about scope, collision, or multiple filters. `entity_ids(field, op, value)` is its host-id projection.
- **`FilterQuery` / `BulkRead`** — high-level orchestration. Given filters + a resolved scope tuple + a model, call down into `QueryBuilder` per filter and compose. Own input normalization, partition collision precedence, multimap-vs-single-scope branching, and `include_missing:` set-complement (ADR-0006).

Future query-shape additions pick the matching altitude: per-field predicate work → `QueryBuilder`; cross-filter / cross-tuple orchestration → a top-level query class.

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
                               │ HasTypedEAV included into all AR models
                               │ by Engine initializer "typed_eav.active_record"
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::HasTypedEAV (lib/typed_eav/has_typed_eav.rb, ~117 lines)  │
│   The macro `has_typed_eav` opts the host model in:                │
│   • declares typed_values has_many + accepts_nested_attributes_for │
│   • includes HasTypedEAV::InstanceMethods (per-record API)         │
│   • extends EntityQuery (class-level query orchestration)          │
│   • registers the host with TypedEAV::Registry (versioned: flag)   │
│   • macro-time guard: parent_scope_method: without scope_method:   │
│     raises ArgumentError at class load                             │
└──────────────┬───────────────────────────────┬─────────────────────┘
               │ class queries                  │ per-record reads/writes
               ▼                                ▼
┌────────────────────────────┐   ┌──────────────────────────────────────┐
│ TypedEAV::EntityQuery      │   │ HasTypedEAV::InstanceMethods           │
│  Owns UNSET_SCOPE/ALL_     │   │  typed_eav_value, typed_eav_hash,      │
│  SCOPES + resolve_scope.   │   │  set_typed_eav_value, typed_eav_       │
│  Delegates:                │   │  attributes=, initialize_typed_values  │
│   where_typed_eav →        │   │  (with in-memory build dedup fix,      │
│     FilterQuery            │   │   0.4.0 G2)                             │
│   typed_eav_hash_for →     │   └──────────────────────────────────────┘
│     BulkRead               │
│   bulk_set_typed_eav_      │
│     values[_per_record] →  │
│     BulkWrite              │
└──────────────┬─────────────┘
               │ per-filter predicate
               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::FilterQuery → TypedEAV::QueryBuilder                      │
│   FilterQuery: multi-filter composition, partition collision via   │
│   Partition.definitions_by_name, include_missing set-complement.   │
│   QueryBuilder: one operator-dispatch case → physical column via   │
│   field.class.operator_column(operator).                           │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ scopes + filters
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ Persistence layer (app/models/typed_eav/)                          │
│   ApplicationRecord (abstract)                                     │
│   ├─ Field::Base (STI on `type`; includes Field::TypedStorage)    │
│   │  ├─ ValidatedString  → Text, Email, Url   (share string_value) │
│   │  ├─ RangeBounded      → Integer, Decimal, Date, DateTime       │
│   │  │     └─ Decimal → Percentage  (Percentage<Decimal<RangeBounded)│
│   │  ├─ Optionable (concern) ⇒ Select, MultiSelect                 │
│   │  ├─ IntegerArray, DecimalArray, TextArray, DateArray (arrays)  │
│   │  ├─ Color, Boolean, Json (true stubs, direct < Base)           │
│   │  ├─ Currency  (multi-cell: decimal_value + string_value)        │
│   │  ├─ Reference (FK in integer_value; :references operator)       │
│   │  └─ Image / File (Active Storage signed_id in string_value)    │
│   ├─ Value (polymorphic on entity; FK to field; optional has_one_  │
│   │   attached :attachment when AS loaded)                         │
│   ├─ ValueVersion (Phase 04 audit log; +version_group_id, Phase 06)│
│   ├─ Section (optional UI grouping; partition-aware ordering)       │
│   └─ Option (per-field allowed values for select/multi-select)     │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ Phase 03 after_commit
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::EventDispatcher (in-process pub/sub; ADR-0003 keeps it)  │
│   value_change_internals[] / field_change_internals[] + user procs │
│   Versioning::Subscriber sits at slot 0 of value_change_internals. │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ when entity opted in
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ TypedEAV::Versioning::Subscriber                                   │
│   One ValueVersion row per :create/:update/:destroy. Two-gate       │
│   (field non-nil + registry.versioned?). Multi-cell snapshots via   │
│   value_columns. Stamps version_group_id from current_context       │
│   (Phase 06 bulk correlation).                                      │
└────────────────────────────────────────────────────────────────────┘
```

## Engine wiring

`lib/typed_eav.rb` requires `typed_eav/version` and `typed_eav/engine`, registers the `EAV` acronym inflection, and exposes the module surface (`config`/`configure`, `registry`, `current_scope`, `with_scope`, `unscoped`, `unscoped?`, `normalize_scope`, `with_context`, `current_context`). `normalize_scope` is now a 1-line BC alias to `ScopeTuple.normalize_permissive`.

`lib/typed_eav/engine.rb`:

```ruby
class Engine < ::Rails::Engine
  isolate_namespace TypedEAV

  initializer "typed_eav.autoload" do
    require_relative "field/typed_storage"  # eager — Field::Base includes it
    require_relative "config"
    require_relative "registry"
    require_relative "event_dispatcher"      # eager — Phase 04 registers against it
  end

  initializer "typed_eav.active_record" do
    ActiveSupport.on_load(:active_record) { include TypedEAV::HasTypedEAV }
  end

  config.after_initialize { TypedEAV::Versioning.register_if_enabled }
  config.after_initialize { TypedEAV::Engine.register_attachment_associations! }
end
```

Key consequences (unchanged from v0.2.0 except `field/typed_storage` replacing `column_mapping` in the eager-require list):
- Every ActiveRecord class gains the `has_typed_eav` macro (no-op until called).
- `EventDispatcher` is **eager-required** — Phase 04 registers `Subscriber.method(:call)` at engine boot; autoloading it lazily would run a fresh `@value_change_internals = []` and wipe the registration.
- Versioning subscriber registration runs in `config.after_initialize` so it reads `TypedEAV.config.versioning` *after* the host initializer sets it. When `versioning = false` (default), the subscriber is **never registered** — zero overhead.
- Active Storage registration runs in a *second* `config.after_initialize`; block ordering preserves the versioning subscriber's slot-0 status.

## Three runtime singletons + one thread-local stack

| Singleton | File | What it holds |
|---|---|---|
| `TypedEAV::Config` | `lib/typed_eav/config.rb` | `field_types` map (built-in 22 + registered), `scope_resolver` callable, `require_scope` boolean, `versioning` master switch, `actor_resolver` callable, `on_value_change` / `on_field_change` / `on_image_attached` user procs. Hand-rolled `defined?(@var)` accessors (Configurable deprecated in Rails 8.1). |
| `TypedEAV::Registry` | `lib/typed_eav/registry.rb` | `entities` map (`entity_type_name => { types: [...], versioned: bool }`). Read at field-create time for the `types:` allow-list and by `Versioning::Subscriber` to short-circuit when `versioned?` is false. |
| `TypedEAV::EventDispatcher` | `lib/typed_eav/event_dispatcher.rb` | `value_change_internals` / `field_change_internals` arrays (versioning at slot 0; Phase 07 matview would append later). |
| Thread-local stacks | `lib/typed_eav.rb` | `:typed_eav_scope_stack` (`with_scope`), `:typed_eav_unscoped` (`unscoped`), `:typed_eav_context_stack` (`with_context` / `current_context` — audit/event metadata, now also carries `version_group_id` for Phase 06 bulk correlation). All `private_constant`. |

## Multi-tenant scoping (the careful piece, two-axis)

The most thought-through subsystem. Fail-closed by default. Phase 01 extended a single `scope` axis to a `(scope, parent_scope)` tuple with full BC. As of 0.3.0 the tuple shape/coercion/invariant logic is localized in `TypedEAV::ScopeTuple`; resolution chains stay with the adapters that know their calling context.

### Resolution priorities (`TypedEAV.current_scope`)

```
1. Inside `unscoped { }`             → ALL_SCOPES sentinel (multimap branch)
2. Innermost `with_scope(v) { }`     → tuple stored on the stack
3. `Config.scope_resolver.call`      → must return [scope, parent_scope] or nil
4. nil
```

`EntityQuery#resolve_scope` implements the **fail-closed** contract: if the model declared `scope_method:` and nothing resolved, raise `TypedEAV::ScopeRequired`. Forgetting to set scope cannot silently leak other tenants' data.

### Strict vs BC-permissive normalization (`ScopeTuple`)

- `ScopeTuple.normalize_strict(value)` — the chokepoint for `Config.scope_resolver` returns. Bare scalars / 1- or 3-element Arrays raise `ArgumentError` directly inside `current_scope`, BEFORE normalization. Makes a misshaped resolver fail loudly.
- `ScopeTuple.normalize_permissive(value)` — the `with_scope` block surface. Scalars/AR records auto-coerce to `[value, nil]`. Single-axis app code works unchanged.
- `ScopeTuple.invariant_satisfied?(scope, parent_scope)` — Boolean orphan-parent check (`false` only when `parent_scope` present and `scope` blank). Each caller picks its own response policy (raise / AR error / silent narrow); the helper never raises.

### Two-axis sentinels

| Sentinel | Owner | Meaning |
|---|---|---|
| `UNSET_SCOPE` (frozen) | `EntityQuery` | "kwarg not passed → resolve from ambient" vs "explicit `nil` → filter to global-only on this axis". |
| `ALL_SCOPES` (frozen) | `EntityQuery` | returned by `resolve_scope` inside `unscoped { }`; tells `FilterQuery` to skip the scope filter and use the **multimap** branch. Atomic-bypass — drops both `scope` and `parent_scope` predicates. |

### Orphan-parent invariant

`scope.nil? ⇒ parent_scope.nil?` enforced at three layers: (1) `Field::Base` / `Section` `validate_parent_scope_invariant` (via `ScopeTuple.invariant_satisfied?`); (2) schema — the global partial unique indexes (`WHERE scope IS NULL`) omit `parent_scope`; (3) macro guard — `parent_scope_method:` without `scope_method:` raises at class load.

### Name-collision precedence (now in `Partition`)

`Partition.definitions_by_name(defs)` sorts by `[scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` then `index_by(&:name)` (last-wins) — most-specific row wins. `Partition.definitions_multimap_by_name` keeps all variants for the unscoped OR-across-tenants branch. `Partition.visible_fields` / `effective_fields_by_name` / `visible_sections` are the partition-aware lookups; `mode: :all_partitions` is the deliberate admin bypass (distinct from `scope: nil` = global-only).

## STI field hierarchy (now with family bases — ADR-0004)

`TypedEAV::Field::Base < TypedEAV::ApplicationRecord` is the STI parent and includes `Field::TypedStorage`. The hierarchy gained an intermediate layer:

| Family base | Kind | Leaves | Shared surface |
|---|---|---|---|
| `ValidatedString < Base` | class | Text, Email, Url | `string_value` storage + `min_length`/`max_length`/`pattern` validators + `max_gte_min_length` guard + `validate_pattern_syntax` + protected `validate_length`/`validate_pattern`. |
| `RangeBounded < Base` | class | Integer, Decimal, Date, DateTime (Percentage < Decimal) | protected `validate_range`/`validate_date_range`/`validate_datetime_range`. **No** `value_column` — each leaf owns its column. |
| `Optionable` | concern | Select, MultiSelect | `optionable? => true`, sorted `allowed_values`, `validate_option_inclusion`/`validate_multi_option_inclusion`. Concern (not class) because the two leaves use different columns (`string_value` vs `json_value`). |

**The inheritance-vs-concern rule (locked):** inheritance class when children share storage; concern when they don't. True stubs (Color, Boolean, Json) stay direct `< Base`. All three family bases are **documented public extension API** — external authors subclass/include them instead of duplicating plumbing.

Each leaf subclass: declares `value_column` (or inherits one), optionally narrows `operators`, implements `cast(raw)` returning `[casted, invalid?]`, optionally implements `validate_typed_value`. `validate_array_size` stays on `Field::Base` (its callers span unrelated families — acknowledged debt).

`Config::BUILTIN_FIELD_TYPES` registers **22 types**: text, long_text, integer, decimal, boolean, currency, date, date_time, select, multi_select, percentage, reference, integer_array, decimal_array, text_array, date_array, email, file, image, url, color, json. Custom types register via `TypedEAV.configure { |c| c.register_field_type :phone, "Fields::Phone" }`.

### Multi-cell + Active Storage types (Phase 05) — unchanged behavior, relocated storage seam

| Type | Storage | Notable extras |
|---|---|---|
| `Currency` | `decimal_value` (amount) + `string_value` (ISO 4217) | normal Field subclass that overrides the `read_value`/`write_value`/`apply_default` trio + `self.value_columns` + `self.operator_column` (ADR-0001 removed its dedicated contract class). `:currency_eq` operator. Cast requires Hash input. |
| `Percentage` | `decimal_value` (now `< Decimal < RangeBounded`) | Stores 0..1 fractions. `display_as` / `decimal_places` are read-side format-only. |
| `Reference` | `integer_value` (FK) | `:references` operator accepts AR records OR ids. Constant-shadow hazard: uses `::Integer`/`::String`. |
| `Image` / `File` | `string_value` (AS `signed_id`) | Soft-detect via `defined?(::ActiveStorage::Blob)`. `cast` raises `NotImplementedError` when AS absent; `validate_typed_value` no-ops. |

## Field display label (Phase 7, issue #21)

`Field#display_name` returns `label.presence || name.humanize`. `label` is an additive nullable free-text column (`20260507000000_add_label_to_typed_eav_fields.rb`); `name` stays the immutable machine key. A blank label falls back to humanizing `name`, so existing rows (label NULL) render unchanged. A label-only edit pins to the `:update` event (NOT `:rename` — `:rename` is reserved for `name` changes; regression-pinned in `spec/regressions/issue_21_label_no_rename_spec.rb`).

## Cascade policy on Field destroy (Phase 02)

`Field::Base.field_dependent` (NOT NULL, default `"destroy"`) drives `before_destroy :dispatch_field_dependent`: `"destroy"` → explicit `values.destroy_all` (FK is now `ON DELETE SET NULL`, so without this PG would NULL the rows); `"nullify"` → no-op (FK NULLs `field_id`; read-path orphan guards skip them); `"restrict_with_error"` → error + `throw(:abort)` if Values exist. `Value.belongs_to :field, optional: true` supports orphans; write-path validators all `return unless field`.

## Value model dispatch

`TypedEAV::Value`:
- `value` reads via `field.read_value(self)`; `value=(val)` runs `field.cast(val)` → `field.write_value(self, casted)` → stashes the `invalid?` flag. `Value::UNSET_VALUE` (public frozen sentinel) lets `Value.create(field: f)` trigger the field default; `value: nil` stores nil explicitly.
- `apply_pending_value` (`after_initialize`) handles `value=` called before `field=`.
- `versions`/`history`/`revert_to` as before (revert is itself versioned).

Validations: `field` uniqueness scoped to `[entity_type, entity_id]`; `validate_value` (branches on cast `invalid?`, then required+blank, then `field.validate_typed_value`); `validate_entity_matches_field`; `validate_field_scope_matches_entity` (two-axis cross-tenant guard); `validate_json_size` (1 MB cap). Callbacks: three explicit `after_commit ..., on: :X` (Rails 8.1 alias-collision workaround) + one `after_commit :_dispatch_image_attached, on: %i[create update]` (runs last).

## Event dispatch (Phase 03, ADR-0003)

`EventDispatcher` is the in-process pub/sub hub — ADR-0003 kept it as a broker rather than collapsing it. Two channels (value, field), each with internal-subscribers array + single user-proc slot. **Fire order:** internals first (registration order), user proc last. **Error policy split (locked):** internal exceptions **propagate** (fail-closed; versioning corruption must be loud); user-proc exceptions are `rescue StandardError` + `Rails.logger.error` + swallowed (row already committed). **Signature asymmetry:** `dispatch_value_change(value, change_type, context)` carries context; `dispatch_field_change(field, change_type)` does not (`change_type ∈ {:create,:update,:destroy,:rename}`). Field rename detection: `Field::Base#_dispatch_field_change` branches `previously_new_record?`/`destroyed?`/`saved_change_to_attribute?(:name)`/else.

## Versioning (Phase 04 + Phase 06 correlation)

`TypedEAV::ValueVersion` (table `typed_eav_value_versions`) is an append-only audit log. Columns as before (`value_id`/`field_id` nullable FK ON DELETE SET NULL; `entity` polymorphic NOT NULL; `changed_by`; `before_value`/`after_value` jsonb keyed by typed-column name; `context` jsonb; `change_type` validated to `%w[create update destroy]`; `changed_at`). **Subscriber writes `value_id: nil` for `:destroy`** (the parent row is already gone by `after_commit on: :destroy`; FK validation at INSERT would fail otherwise).

**Phase 06 addition** — a nullable, indexed `version_group_id` UUID column (`20260506000001_*`). A bulk-write API injects a correlation UUID via `TypedEAV.with_context(version_group_id: uuid) { ... }`; the subscriber forwards it onto each row. Non-bulk writes leave it NULL. UUID is unkeyed (no parent `bulk_operations` table — deliberately not introduced, locked at 06-CONTEXT.md).

`Versioning::Subscriber.call(value, change_type, context)` is conditionally registered only when `Config.versioning = true`. Two runtime gates: `value.field` non-nil (orphan guard) + `registry.versioned?(value.entity_type)`. `TypedEAV::Versioned` is a post-`has_typed_eav` mixin re-registering with `versioned: true`.

## Phase 06 bulk + portability modules (ADR-0005)

Three independent toolbox utilities — deliberately NOT unified under an import-pipeline orchestrator (ADR-0005). Each owns a focused responsibility and a return shape matched to its axis:

| Module | File | Surface | Return shape |
|---|---|---|---|
| `BulkWrite` | `lib/typed_eav/bulk_write.rb` | internal executor for `bulk_set_typed_eav_values` (uniform) + `bulk_set_typed_eav_values_per_record` (per-record-varying, 0.4.0 G1). Both adapt to a shared `execute_pairs([record, vbn], grouping, uuids)` loop. Outer transaction + savepoint-per-record + version-group stamping. | `{ successes: [...], errors_by_record: { record => errors } }` |
| `BulkRead` | `lib/typed_eav/bulk_read.rb` | class-method bulk variant of `typed_eav_hash`. N+1-free: `2 + (unique partition tuples)` queries regardless of record count. Single-class invariant. | `{ record_id => { field_name => value } }` |
| `CSVMapper` | `lib/typed_eav/csv_mapper.rb` | pure stateless `row_to_attributes(row, mapping, fields_by_name: nil)`. 2-arg = passthrough mode; 3-arg = typed-coercion mode via `field.cast`. Never raises on per-row content (cast failures → `errors`). | `Result` value object (`attributes`, `errors`, `success?`/`failure?`) |
| `SchemaPortability` | `lib/typed_eav/schema_portability.rb` | `export_schema` / `import_schema` (full Field+Section defs for one partition tuple) + `export_snapshot_schema` (0.4.0 G4 — lean restore-oriented projection, no sections, no partition-identity keys). | export: envelope Hash; import: aggregate counts (`created`/`updated`/`skipped`/`unchanged`/`errors`) |

The "import pipeline" is a usage pattern when a caller composes all three — not an architectural concept the gem names.

## `include_missing:` set-complement (0.4.0 G3, ADR-0006)

`Entity.with_field`/`where_typed_eav` accept opt-in `include_missing:` (default `false`). With `:is_null`, it broadens "value column is NULL" to "no non-NULL value, **including no-row hosts**" (Reading A — the user-intuitive "is empty"). Composed as a set complement at the `FilterQuery` altitude — `query.where.not(id: QueryBuilder.entity_ids(field, :is_not_null, nil))` — `QueryBuilder` is untouched. Multimap branch unions non-missing ids across all matching field defs, then complements. `:is_not_null` + the kwarg = no-op; any other operator = silently ignored (filter UIs pass it uniformly). ADR-0006 rejects the LEFT-JOIN-in-`QueryBuilder` framing.

## Forms & nested attributes

`accepts_nested_attributes_for :typed_values, allow_destroy: true`. Two write paths: `typed_values_attributes=` (Rails, keyed by `field_id`, HTML forms) and `typed_eav_attributes=` / `typed_eav=` (gem, keyed by field `name`, console/seeds; respects `_destroy` + the `types:` allow-list, resolves via the three-way collision precedence). `initialize_typed_values` builds missing values with defaults — 0.4.0 G2 fixed a dedup defect on unsaved entities with in-memory `typed_values` builds (`spec/regressions` + `bulk_write` dedup notes).

## Display ordering (Phase 02)

`Field::Base` and `Section` expose `move_higher`/`move_lower`/`move_to_top`/`move_to_bottom`/`insert_at`. Each: opens a transaction, acquires a partition-level `FOR UPDATE` lock on `for_entity(...).order(:id)` (deterministic `:id` order avoids deadlocks), reorders in memory by `[sort_order NULLS LAST, name ASC]`, yields, normalizes `sort_order` back to `1..N`. Cross-partition ops never block each other.

## Default-value backfill (Phase 02)

`Field::Base#backfill_default!` iterates `entity_type.constantize.find_in_batches(batch_size: 1000)`; one transaction per batch; `partition_matches?(entity)` filters per-axis; per-record skip rule is "non-nil typed column already present". Idempotent.

## Generators

Two `Rails::Generators::Base` subclasses with explicit `namespace` + `source_root`: `InstallGenerator` (wraps `install:migrations`) and `ScaffoldGenerator` (copies controller + concern + helper + Stimulus controllers + views + initializer into the host; appends `resources :typed_eav_fields` to routes). The scaffold output is **opt-in admin UI** — the gem mounts no routes itself.

## What's still on the roadmap

`typed_eav-enhancement-plan.md` enumerates planned phases. Shipped: Phases 01–06 (partitioning, cascade/ordering/backfill, events, versioning, multi-cell+AS types, bulk import/export). The originally-planned read-optimization phase (materialized index for read-heavy/dashboard use — would register a second internal subscriber on `EventDispatcher` at slot ≥ 1) was **deferred** during the roadmap reconciliation (commit `fb15a77`) and **removed** from the milestone on 2026-08-15. Phase 7 (field display label, formerly Phase 8) shipped out-of-band as issue #21.
