---
phase: 4
title: Versioning — Implementation Research
type: research
confidence: high
date: 2026-05-05
---

## Findings

### 1. EventDispatcher / hook-ordering anchors

#### `register_internal_value_change` and `value_change_internals`

`lib/typed_eav/event_dispatcher.rb:69` — `register_internal_value_change(callable)` appends to the `@value_change_internals` array.

`lib/typed_eav/event_dispatcher.rb:50-52` — `value_change_internals` reader: lazy-init `@value_change_internals ||= []`.

The comment at line 46-49 explicitly reserves slot 0 for Phase 04: "Phase 04 reserves slot 0 of `value_change_internals` by convention." Slot 0 is not enforced mechanically — it is a convention that Phase 04's engine initializer registers first, before any other internal subscriber.

#### The Value `after_commit` chain

`app/models/typed_eav/value.rb:140-142` — three explicit `after_commit` declarations:

```ruby
after_commit :_dispatch_value_change_create,  on: :create
after_commit :_dispatch_value_change_update,  on: :update
after_commit :_dispatch_value_change_destroy, on: :destroy
```

The `:update` filter is at `value.rb:307-309`:

```ruby
def _dispatch_value_change_update
  return unless field
  return unless saved_change_to_attribute?(field.class.value_column)
  TypedEAV::EventDispatcher.dispatch_value_change(self, :update)
end
```

`field.class.value_column` is a class-level reader defined in `lib/typed_eav/column_mapping.rb:38-44`. It returns `@value_column` (a Symbol, e.g., `:string_value`, `:integer_value`). `saved_change_to_attribute?` accepts Symbol or String (Rails normalizes internally).

`EventDispatcher.dispatch_value_change` at `event_dispatcher.rb:88-109`:

1. Captures context: `context = TypedEAV.current_context` (one call, line 89).
2. Iterates `value_change_internals`: `value_change_internals.each { |cb| cb.call(value, change_type, context) }` (line 92). Exceptions propagate — no rescue.
3. Reads user proc: `user = TypedEAV::Config.on_value_change` (line 94).
4. Calls user proc last, inside `rescue StandardError` (lines 101-108). Errors logged via `Rails.logger.error`, swallowed.

The context is captured ONCE at the top of `dispatch_value_change` (line 89), then passed as the same frozen Hash instance to both internal subscribers and the user proc. All subscribers in one dispatch call receive the same `context` object identity — confirmed by the spec at `spec/lib/typed_eav/event_dispatcher_spec.rb:83-96`.

#### `with_context` / `current_context` shape

`lib/typed_eav.rb:183-198` — `with_context(**kwargs)`:
- Stack key: `THREAD_CONTEXT_STACK = :typed_eav_context_stack` (line 27).
- Shallow merge: `merged = (stack.last || EMPTY_FROZEN_CONTEXT).merge(kwargs).freeze` (line 185).
- `current_context` (line 197): returns `Thread.current[THREAD_CONTEXT_STACK]&.last || EMPTY_FROZEN_CONTEXT`.
- Return shape: always a frozen Hash, never nil. Keys are caller-supplied symbols (e.g., `actor_id:`, `source:`, `request_id:`). The gem imposes no schema on the context hash — it is a free-form keyword bag.

The versioning subscriber reads context as: `context = TypedEAV.current_context` already called by `dispatch_value_change` before calling the subscriber. The subscriber receives the pre-captured frozen Hash as its third argument. The subscriber accesses `context[:actor_id]` (or whatever key the app used) to resolve `changed_by`.

#### Engine boot registration gate pattern

`lib/typed_eav/engine.rb:7-18`:

```ruby
initializer "typed_eav.autoload" do
  require_relative "column_mapping"
  require_relative "config"
  require_relative "registry"
  require_relative "event_dispatcher"
end
```

`EventDispatcher` is eager-loaded at engine boot (not lazy autoloaded). The comment at `engine.rb:12-17` is explicit: "Phase 04 versioning will register on EventDispatcher at engine boot, before any model reference triggers autoload."

The registration gate for Phase 04 is: add a second initializer that checks `TypedEAV.config.versioning` before calling `register_internal_value_change`. If `versioning == false` (default), do not register — zero overhead.

Pattern precedent: `Config.require_scope` (config.rb:115-118) uses `defined?(@require_scope) ? @require_scope : true` — a hand-rolled class-level accessor with a default. `Config.versioning` should mirror this pattern: `defined?(@versioning) ? @versioning : false`.

There is currently NO `Config.versioning` attribute — it must be added. The `Config.reset!` at `config.rb:172-185` must also reset `self.versioning = false` to prevent test-isolation leakage.

`EventDispatcher.reset!` at `event_dispatcher.rb:145-148` wipes `@value_change_internals = []`. The spec_helper `:event_callbacks` hook at `spec_helper.rb:87-104` uses snapshot-and-restore (not `reset!`) precisely to preserve engine-load registrations (Phase 04 versioning) across examples. Phase 04's subscriber is registered at engine load and must survive `Config.reset!` — it lives on `EventDispatcher.value_change_internals`, not on `Config`.

---

### 2. Registry / per-entity opt-in

#### `TypedEAV::Registry` shape

`lib/typed_eav/registry.rb:14-57` — `Registry` stores entries as:

```ruby
def entities
  @entities ||= {}
end

def register(entity_type, types: nil)
  entities[entity_type] = { types: types }
end
```

The entry hash currently has ONE key: `{ types: types }`. There is no `versioned` flag or any other key.

#### `has_typed_eav` macro call site

`lib/typed_eav/has_typed_eav.rb:96-136` — `has_typed_eav` macro:

```ruby
def has_typed_eav(scope_method: nil, parent_scope_method: nil, types: nil)
  ...
  TypedEAV.registry.register(name, types: types)
end
```

The macro currently accepts three kwargs: `scope_method:`, `parent_scope_method:`, `types:`. Adding `versioned: false` as a fourth kwarg is additive and backward compatible — existing callers pass no `versioned:` and receive the default.

`Registry.register` must be extended to accept and store `versioned:`:

```ruby
def register(entity_type, types: nil, versioned: false)
  entities[entity_type] = { types: types, versioned: versioned }
end
```

A `versioned?` lookup method:

```ruby
def versioned?(entity_type)
  entities.dig(entity_type, :versioned) || false
end
```

#### Registry lookup performance

`Registry.entities` is a plain Hash (`@entities ||= {}`). Lookup via `entities[entity_type]` or `entities.dig(entity_type, :versioned)` is O(1) hash access. The versioning subscriber will call `TypedEAV.registry.versioned?(value.entity_type)` on every Value write when `config.versioning == true`. The cost is one Hash#dig per write — negligible.

`value.entity_type` is a String (the AR polymorphic `entity_type` column value, e.g., `"Contact"`). Registry keys are also Strings — set via `name` in `register(name, ...)` where `name` is `self.name` (the AR model's class name). No key normalization issue.

#### `include TypedEAV::Versioned` path

The CONTEXT mentions `include TypedEAV::Versioned` as an alternative opt-in. This module does not exist yet — it must be created. Its `included` hook should call `has_typed_eav versioned: true` (or the underlying `Registry.register` directly if `has_typed_eav` was already called). Lead must decide whether `TypedEAV::Versioned` is a standalone include that implies `has_typed_eav`, or a second-step include that sets the `versioned` flag on an already-registered entity. Given that `has_typed_eav` sets up the `has_many :typed_values` association, `include TypedEAV::Versioned` alone cannot replace `has_typed_eav` — it should be a second-step concern that sets the `versioned` flag on a model that has already called `has_typed_eav`.

---

### 3. Field#value_column → value_columns surface

#### Current `value_column` (singular)

`lib/typed_eav/column_mapping.rb:38-44` — class-level DSL method:

```ruby
def value_column(column_name = nil)
  unless column_name
    return @value_column || raise(NotImplementedError,
                                  "#{name} must declare `value_column :column_name`")
  end
  @value_column = column_name.to_sym
end
```

Every Field subclass calls `value_column :some_column` in its class body:
- `Field::Text`: `value_column :string_value` (`app/models/typed_eav/field/text.rb:6`)
- `Field::Integer`: `value_column :integer_value` (`app/models/typed_eav/field/integer.rb:6`)
- `Field::MultiSelect`: `value_column :json_value` (`app/models/typed_eav/field/multi_select.rb:6`)
- (All 17 built-in types follow the same pattern.)

`Value#value_column` at `value.rb:92-94` delegates to the class:

```ruby
def value_column
  field.class.value_column
end
```

This is an instance method on Value that reads the class-level reader on the Field STI subclass.

#### `value_columns` (plural) — does NOT exist

There is no `value_columns` method anywhere in the codebase. It must be added in Phase 04.

The natural home is `lib/typed_eav/column_mapping.rb`, as a class method on the `class_methods` block, defaulting to `[value_column]`:

```ruby
def value_columns
  [value_column]
end
```

All 17 current field types inherit this default. Phase 05 Currency overrides it to return `[:decimal_value, :string_value]`. No Phase 04 subclass changes are needed unless a field type already uses two columns (none do today).

#### The `:update` filter and multi-column change detection

The current `:update` filter at `value.rb:307-309` uses:

```ruby
return unless saved_change_to_attribute?(field.class.value_column)
```

This is a single-column check keyed off `field.class.value_column` (singular). For all 17 current field types (all single-cell), this is correct. For Phase 05 Currency (two cells), Phase 04's versioning subscriber must not miss a change to either cell.

The versioning subscriber's own change detection must use `field.class.value_columns` (plural), checking if ANY of the listed columns changed:

```ruby
changed = field.class.value_columns.any? { |col| value.saved_change_to_attribute?(col) }
```

The existing `_dispatch_value_change_update` filter at `value.rb:308` still uses the singular `value_column`. This means Phase 04's versioning subscriber will only be called (via `EventDispatcher`) when the single-cell check already passed — which is correct for all current field types. For Phase 05 Currency, the `_dispatch_value_change_update` filter must be updated to check ANY of `value_columns`. Lead should decide:

- Option A: Update `_dispatch_value_change_update` in Phase 04 to use `value_columns.any? { |col| saved_change_to_attribute?(col) }`. This is forward-compatible and the right fix; versioning subscriber then doesn't need its own loop.
- Option B: Leave `_dispatch_value_change_update` singular; have versioning subscriber do its own multi-column check. This means a Currency change on the second column (only) would fail to fire the event entirely — a bug introduced by Phase 05 if Phase 04 doesn't fix this.

⚠ DISCREPANCY: The CONTEXT says the versioning subscriber reads `field.class.value_columns` (plural). But the dispatch gate at `value.rb:308` uses the singular `field.class.value_column`. For single-cell types these are equivalent. For Phase 05 Currency they diverge. Phase 04 should fix `_dispatch_value_change_update` to use `value_columns.any?` — or accept the bug and defer to Phase 05. Lead must make this call.

---

### 4. Phase 1 scope_resolver shape (template for actor_resolver)

#### `Config.scope_resolver` definition and call contract

`lib/typed_eav/config.rb:105-108`:

```ruby
def scope_resolver
  defined?(@scope_resolver) ? @scope_resolver : DEFAULT_SCOPE_RESOLVER
end
attr_writer :scope_resolver
```

The resolver is a callable (lambda or proc). It takes NO arguments — it is called as `Config.scope_resolver&.call` (see `lib/typed_eav.rb:94`). Return shape: `nil` OR a 2-element Array `[scope, parent_scope]`.

`actor_resolver` mirrors this shape with one difference: the return shape is any value the app chooses (AR object, String, nil). The caller (versioning subscriber) uses `TypedEAV.config.actor_resolver&.call` and stores the result as `changed_by`. When the return is nil, `changed_by` is stored as nil (nullable column).

Config accessor pattern to add:

```ruby
def actor_resolver
  defined?(@actor_resolver) ? @actor_resolver : nil
end
attr_writer :actor_resolver
```

Default is `nil` (no resolver — all writes have `changed_by: nil`). `Config.reset!` must set `self.actor_resolver = nil`.

The callable is invoked with no arguments, exactly like `scope_resolver`. The `defined?(@var)` idiom (rather than `@var || default`) is the established codebase pattern — it preserves the "never set vs. explicitly nil" distinction. `Config.reset!` must use explicit assignment (`self.actor_resolver = nil`) not reliance on the `defined?` fallback, to match how `on_value_change = nil` is set (line 183-184 of config.rb).

---

### 5. Migration delivery (Phase 2 precedent)

#### Phase 2 cascade migration location and generator

From the Phase 02 research (02-RESEARCH.md Area 3): the cascade migration has timestamp `20260501000000` in the filename `add_cascade_policy_to_typed_eav_fields.rb`. The migration lives in `db/migrate/` in the engine root.

The install generator is at `lib/generators/typed_eav/install/install_generator.rb:1-28`:

```ruby
def copy_migrations
  rake "typed_eav:install:migrations"
end
```

It invokes `rake typed_eav:install:migrations` — the standard Rails engine migration copy task. This task copies migrations from the engine's `db/migrate/` into the host app's `db/migrate/` with timestamps adjusted to the current time, preventing collisions with existing host app migrations.

**Idempotence on re-run:** The `typed_eav:install:migrations` Rake task is the standard Rails `railties:install:migrations` task bound to the engine. Rails' implementation is idempotent: it checks whether a migration with the same name (ignoring timestamp) already exists in the host's `db/migrate/` and skips copying if so. A host that has already installed Phase 1-3 migrations and runs the generator again after Phase 4 is released will get only the new `create_typed_eav_value_versions.rb` migration copied — pre-existing migrations are not duplicated.

This means the Phase 04 delivery model is: add `db/migrate/YYYYMMDDHHMMSS_create_typed_eav_value_versions.rb` to the engine, and existing hosts pick it up by re-running `bin/rails generate typed_eav:install` followed by `bin/rails db:migrate`. Greenfield apps that run the generator once get all migrations automatically.

---

### 6. Polymorphic entity reference precedent

#### Existing polymorphic association

`app/models/typed_eav/value.rb:25`:

```ruby
belongs_to :entity, polymorphic: true, inverse_of: :typed_values
```

The Value table already has `entity_type` (string) and `entity_id` (bigint) columns — the standard Rails polymorphic pair. This is the direct precedent for the version row's entity reference.

`has_typed_eav` macro at `has_typed_eav.rb:125-132`:

```ruby
has_many :typed_values,
         class_name: "TypedEAV::Value",
         as: :entity,
         inverse_of: :entity,
         ...
```

The `as: :entity` establishes the polymorphic interface name. The version table's `entity` polymorphic reference follows the same Rails convention.

#### Migration syntax for polymorphic columns

From `typed_eav_values` creation (precedent): Rails generates `entity_type` (string, `null: false`) and `entity_id` (bigint, `null: false`) from `t.references :entity, polymorphic: true, null: false`. The version table migration should use the same form:

```ruby
t.references :entity, polymorphic: true, null: false
t.references :value, null: true, foreign_key: { to_table: :typed_eav_values, on_delete: :nullify }
t.references :field, null: true, foreign_key: { to_table: :typed_eav_fields, on_delete: :nullify }
```

`null: true` on `value_id` and `field_id` because: (a) `value_id` should be nullable so version history survives Value destruction (ON DELETE SET NULL matches Phase 04 CONTEXT recommendation); (b) `field_id` on the version row similarly nullable for the same reason.

---

### 7. Test infrastructure for opt-in features

#### Config toggle pattern between examples

`spec/spec_helper.rb:87-104` — `:event_callbacks` around hook uses snapshot-and-restore:

```ruby
config.around(:each, :event_callbacks) do |example|
  saved_on_value_change = TypedEAV::Config.on_value_change
  saved_on_field_change = TypedEAV::Config.on_field_change
  saved_value_internals = TypedEAV::EventDispatcher.value_change_internals.dup
  saved_field_internals = TypedEAV::EventDispatcher.field_change_internals.dup

  TypedEAV::Config.on_value_change = nil
  TypedEAV::Config.on_field_change = nil
  TypedEAV::EventDispatcher.value_change_internals.clear
  TypedEAV::EventDispatcher.field_change_internals.clear

  example.run
ensure
  TypedEAV::Config.on_value_change = saved_on_value_change
  TypedEAV::Config.on_field_change = saved_on_field_change
  TypedEAV::EventDispatcher.instance_variable_set(:@value_change_internals, saved_value_internals)
  TypedEAV::EventDispatcher.instance_variable_set(:@field_change_internals, saved_field_internals)
end
```

Phase 04 specs that need to toggle `Config.versioning` should follow the same snapshot-restore pattern — an `:versioning` metadata hook (or within `:event_callbacks`). The `Config.versioning` flag controls whether the subscriber registers at boot; in tests the subscriber will be pre-registered (engine already loaded), so toggling `Config.versioning` at example time only controls whether version rows are written (the subscriber checks the flag on each call), not whether the subscriber is registered.

#### Dummy app integration test pattern

`spec/dummy/app/models/test_models.rb` — three host models:
- `Contact` — `has_typed_eav scope_method: :tenant_id`
- `Product` — `has_typed_eav types: %i[text integer decimal boolean]`
- `Project` — `has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id`

Phase 04 integration tests need a host model with `has_typed_eav versioned: true`. Options:
- Add `versioned: true` to an existing model (changes semantics for other specs that use that model).
- Add a new host model `VersionedContact` or similar in `test_models.rb` with `has_typed_eav scope_method: :tenant_id, versioned: true`. Requires a corresponding dummy app migration for the table.
- Alternatively, test via the Registry directly (unit) and use a `Contact`-with-versioned-flag approach only in integration tests that specifically toggle the registry entry.

The `:real_commits` metadata at `spec_helper.rb:130-143` disables transactional fixtures and cleans up in FK order: `TypedEAV::Value.delete_all`, then Options, then Fields, then Sections, then Contact/Product/Project. Phase 04 integration tests using `:real_commits` must also clean up `TypedEAV::ValueVersion.delete_all` (or whatever the AR model name is) before Value cleanup (value versions reference values via FK).

#### Regression spec numbering

The `spec/regressions/` directory contains:
- `known_bugs_spec.rb` — original v0.1.0 bugs from ANALYSIS.md.
- `review_round_2_scope_leak_spec.rb` — Phase 01 round 2 bug.
- `review_round_3_collision_spec.rb` — Phase 01 round 3.
- `review_round_4_parent_scope_spec.rb` — Phase 01 round 4.

Phase 02 research references `spec/regressions/known_bugs_spec.rb` and notes it has no Phase 02 cascade-specific entries. Phase 03 doesn't reference any specific regression file. Phase 04 regressions should use the filename scheme `review_round_NN_<topic>_spec.rb` matching the review round number. No universal phase-keyed prefix is in use — the numbering is sequential across all phases. Lead should assign the next round number at plan time.

---

### 8. Open-item code anchors

#### `changed_by` column shape (string vs polymorphic)

Phase 01 `scope_resolver` returns a String (or nil): `scope` and `parent_scope` are always String or nil throughout the codebase. The actor_resolver has no such constraint — it returns whatever the app provides (an AR object, an integer, a string, nil).

String coercion precedent: `normalize_one` at `lib/typed_eav.rb:239-243`:
```ruby
def normalize_one(value)
  return nil if value.nil?
  value.respond_to?(:id) ? value.id.to_s : value.to_s
end
```

This is how `scope` converts AR objects to Strings. If `changed_by` is a `string` column, the versioning subscriber calls the same `normalize_one`-style coercion on the actor_resolver return before storing.

Polymorphic alternative: `changed_by_type` (string) + `changed_by_id` (bigint). Matches Rails AR polymorphic convention. Lets the app query `WHERE changed_by_type = 'User' AND changed_by_id = 42` natively.

No existing polymorphic actor/user reference exists in the gem. The only polymorphic association is `Value.entity` (a host entity, not a "user who made a change" concept).

String is the simpler option (matches `scope` coercion) and avoids a two-column schema. Polymorphic is more queryable for actor-centric queries but adds a column. This is a Lead discretion decision per CONTEXT.

#### Indexing strategy — partial index precedent

Phase 01 introduced partial unique indexes. From `CHANGELOG.md`:
- `idx_te_fields_unique_scoped_full` — partial on `(scope IS NOT NULL AND parent_scope IS NOT NULL)`.
- `idx_te_fields_unique_scoped_only` — partial on `(scope IS NOT NULL AND parent_scope IS NULL)`.
- `idx_te_fields_unique_global` — partial on `(scope IS NULL)`.
- `idx_te_fields_lookup` — covering `(entity_type, scope, parent_scope, sort_order, name)`.

Phase 04 indexes follow the `idx_te_*` naming convention. Reasonable defaults per CONTEXT:
- `idx_te_vvs_value` covering `(value_id, changed_at DESC)` for `Value#history`.
- `idx_te_vvs_entity` covering `(entity_type, entity_id, changed_at DESC)` for entity-scoped history.
- `idx_te_vvs_field` covering `(field_id, changed_at DESC)` for field-history queries.

No GIN indexes on `before_value`/`after_value` per CONTEXT (deferred).

#### FK behavior on `value_id` when source Value is destroyed

Phase 02 migration changed `typed_eav_values.field_id` to `ON DELETE SET NULL`. The migration used:

```ruby
remove_foreign_key :typed_eav_values, column: :field_id
add_foreign_key :typed_eav_values, :typed_eav_fields, column: :field_id, on_delete: :nullify
```

(Per 02-RESEARCH.md Area 3, §"Lead questions answered".) The exact syntax is `on_delete: :nullify` (Rails helper) → `ON DELETE SET NULL` in Postgres.

Phase 04 `typed_eav_value_versions.value_id` FK:

```ruby
add_foreign_key :typed_eav_value_versions, :typed_eav_values, column: :value_id, on_delete: :nullify
```

Same pattern: FK with `ON DELETE SET NULL` so version history survives Value destruction. The CONTEXT recommends this over `ON DELETE CASCADE`.

`typed_eav_value_versions.field_id` FK (if added): same `on_delete: :nullify` pattern per Phase 02 precedent.

#### Migration delivery on re-run

Already covered in section 5. The `typed_eav:install:migrations` Rake task is idempotent — it skips migration files whose names (without timestamp) already exist in the host's `db/migrate/`. Running the generator again after Phase 04 is released copies only the new version-table migration.

---

### 9. Surprises and discrepancies

#### ⚠ DISCREPANCY: `EventDispatcher.reset!` scope

`event_dispatcher.rb:145-148` — `reset!` clears `@value_change_internals` and `@field_change_internals`. The spec_helper `:event_callbacks` hook at `spec_helper.rb:87-104` does NOT call `reset!` — it uses manual snapshot-and-restore, including restoring `@value_change_internals` via `instance_variable_set`. The hook comment explicitly says this is to preserve Phase 04 engine-load registrations. However, the `EventDispatcher.reset!` implementation as currently written would wipe Phase 04's subscriber if called. Tests must NEVER call `EventDispatcher.reset!` directly — only the snapshot-restore hook is safe.

Phase 04 must not introduce any test teardown that calls `EventDispatcher.reset!`. Any Phase 04 test helper that needs to clear versioning state should snapshot-restore, not reset.

#### ⚠ DISCREPANCY: `value_change_internals` is NOT slot-0-enforced

The CONTEXT says versioning "reserves slot 0 by convention." The convention is only by registration ORDER: whichever internal subscriber registers first is slot 0. The engine initializer sequence determines this. Phase 04's initializer must run before any Phase 07 initializer to hold slot 0. Since Phase 07 is not yet implemented, this is not currently at risk, but the implementation must be documented as "Phase 04 registers first, Phase 07 registers after."

There is no API to insert at a specific slot index. If Phase 07 accidentally registers before Phase 04, versioning would be slot 1. Lead should structure the Phase 04 initializer to run before Phase 07's (initialize named `"typed_eav.versioning"` to precede a future `"typed_eav.matview"` initializer alphabetically, or use `before:` / `after:` Rails initializer ordering).

#### ⚠ DISCREPANCY: `_dispatch_value_change_update` uses singular `value_column`

`value.rb:308`: `return unless saved_change_to_attribute?(field.class.value_column)` — singular. This is the gate that controls whether the EventDispatcher is even called. The CONTEXT's `value_columns` (plural) design is for the versioning subscriber's snapshot logic. But if `_dispatch_value_change_update` never fires for a Currency field whose `string_value` changed (and only `decimal_value` is `value_column`), the versioning subscriber never sees the change. This is a latent Phase 05 bug. Phase 04 should either fix `_dispatch_value_change_update` now or document the dependency explicitly in the plan.

#### `Config.reset!` does not yet include `versioning` or `actor_resolver`

`config.rb:172-185` — `Config.reset!` resets `field_types`, `scope_resolver`, `require_scope`, `on_value_change`, `on_field_change`. It does not reset `versioning` or `actor_resolver` because they don't exist yet. Phase 04 must add both to `reset!`.

#### `spec/regressions/` — no Phase 02 or Phase 03 files with those names

The only review-round files found are: `review_round_2_scope_leak_spec.rb`, `review_round_3_collision_spec.rb`, `review_round_4_parent_scope_spec.rb`. The numbering is sequential across ALL phases — there is no per-phase reset. Phase 04 regressions would be `review_round_5_*` or higher depending on what round numbering was used in Phase 02/03 (Phase 01 used rounds 1-4, Phase 02/03 may have continued or not created regression files). Lead should check the actual directory listing before assigning a number.

#### `value.entity_type` is a string column, Registry keys are strings

Registry is keyed by `entity_type` (String from `name` — the class name, e.g., `"Contact"`). `value.entity_type` in the polymorphic association is also a String. No coercion issue. `TypedEAV.registry.versioned?(value.entity_type)` works directly.

---

## Relevant Patterns

- **`value_column` DSL pattern**: `lib/typed_eav/column_mapping.rb:38-44`. `value_columns` class method goes in the same `class_methods` block, defaulting to `[value_column]`.
- **Hand-rolled Config accessors**: `config.rb:105-118`. `actor_resolver` and `versioning` follow the `defined?(@var)` idiom. Do NOT use `ActiveSupport::Configurable` (deprecated in Rails 8.1, will be removed in 8.2 — see config.rb:17-20 comment).
- **Engine boot registration**: `engine.rb:7-18`. Phase 04 adds an `initializer "typed_eav.versioning"` block that conditionally calls `EventDispatcher.register_internal_value_change(...)` if `TypedEAV.config.versioning`.
- **Snapshot-restore in specs**: `spec_helper.rb:87-104`. Phase 04 adds `versioning` and `actor_resolver` to the snapshot list.
- **Polymorphic `entity` reference**: `value.rb:25` + `has_typed_eav.rb:125-132`. Version table mirrors this exactly with `t.references :entity, polymorphic: true, null: false`.
- **`idx_te_*` index naming**: CHANGELOG.md. All Phase 04 indexes use `idx_te_vvs_*` prefix.
- **`on_delete: :nullify` FK**: Phase 02 precedent. `add_foreign_key ..., on_delete: :nullify` maps to `ON DELETE SET NULL`.

## Risks

1. **`Config.versioning` check in the subscriber must be explicit**: The subscriber is registered at engine boot. The check `TypedEAV.config.versioning` must happen inside the subscriber callback (not at registration time), so apps that set `config.versioning = false` after boot still work.
2. **`EventDispatcher.reset!` wipes Phase 04's subscriber**: Any test that calls `reset!` directly breaks Phase 04 versioning. The `:event_callbacks` hook already avoids this. Phase 04 tests must use the same snapshot pattern.
3. **Version table cleanup in `:real_commits` teardown**: Phase 04 integration tests must add `TypedEAV::ValueVersion.delete_all` (or equivalent) BEFORE `TypedEAV::Value.delete_all` in the `:real_commits` cleanup — version rows FK-reference value rows.
4. **`value_columns` default on `Field::Base`**: `value_columns` does not exist. Adding it to `ColumnMapping` is the correct location. Subclasses that don't override it automatically return `[value_column]`. No backward-compatibility issue (new method, no callers yet).
5. **Registration ordering (slot 0)**: No mechanical enforcement. Phase 04's initializer name (`"typed_eav.versioning"`) must sort before Phase 07's (`"typed_eav.matview"` or similar) if both need to co-exist in an app. Rails initializer `before:` / `after:` options are available if alphabetic ordering is insufficient.

## Recommendations

These are observations for Lead's use — Lead writes the PLAN.md, not Scout.

- The cheapest `versioned:` extension point is adding one key to the Registry entry hash (`{ types: ..., versioned: ... }`) and one kwarg to `has_typed_eav` and `Registry.register`. No structural change to Registry.
- `value_columns` belongs in `lib/typed_eav/column_mapping.rb` in the existing `class_methods` block. The default `[value_column]` requires `value_column` to already be declared — safe because every subclass declares `value_column` before instantiation.
- The `_dispatch_value_change_update` singular-vs-plural issue is a latent Phase 05 bug. Phase 04 is the right time to fix it (`value_columns.any? { |col| saved_change_to_attribute?(col) }`), since Phase 04 introduces `value_columns`.
- `Config.actor_resolver` default should be `nil`, not `DEFAULT_SCOPE_RESOLVER`-style. Missing actor is permissive (CONTEXT §"actor_resolver returning nil").
- The `:real_commits` cleanup block in `spec_helper.rb:135-143` needs `TypedEAV::ValueVersion.delete_all` added before `TypedEAV::Value.delete_all`. This is a load-bearing change for any Phase 04 integration spec that uses `:real_commits`.
