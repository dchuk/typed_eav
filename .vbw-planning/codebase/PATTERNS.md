# PATTERNS.md

Recurring patterns observed across the codebase. When extending or refactoring, prefer continuing these patterns rather than introducing new ones.

## Architectural patterns

### "Tuple-return for type coercion"

Every `Field::*#cast(raw)` returns `[casted_value, invalid?]`. The boolean second element is the load-bearing piece — without it, `Value#validate_value` could not distinguish "user gave us empty input" (`:blank`) from "user gave us bad input" (`:invalid`).

The contract: nil/empty raw input returns `[nil, false]`; non-empty unparseable input returns `[nil, true]`; everything else returns `[casted, false]`. See `Field::Integer#cast` for the canonical small example, `Field::IntegerArray#cast` for the all-or-nothing-array variant, `Field::Currency#cast` for the multi-cell hash variant, `Field::Reference#cast` for the polymorphic-record-or-id variant.

This was a refactor (commit `eef8e51 / 17dbbe1` removed the older `cast_value` side-channel). The tuple is the only API.

### "STI subclass declares its own column + operators"

Every single-cell field type subclass starts the same way:

```ruby
class TypedEAV::Field::SomeType < Base
  value_column :some_value      # which typed column on the values table
  operators :eq, :is_null, ...  # optional — narrows the default operator set
  store_accessor :options, ...  # optional — surfaces option keys as methods

  def cast(raw); end
  def validate_typed_value(record, val); end   # optional
end
```

Default operators come from `ColumnMapping::DEFAULT_OPERATORS_BY_COLUMN` keyed by column name — declaring `value_column :integer_value` automatically allows `:eq, :not_eq, :gt, :gteq, :lt, :lteq, :between, :is_null, :is_not_null` unless `operators ...` narrows them. The override is explicit: don't widen by default, narrow when warranted.

### "Multi-cell extension trio (override all three or none)"

Multi-cell field types (Phase 05 Currency is the canonical example) override **three paired** instance methods on `Field::Base`:

```ruby
def self.value_columns
  %i[decimal_value string_value]   # plural — used by versioning snapshot
                                   # AND Value#_dispatch_value_change_update
end

def self.operator_column(operator)
  operator == :currency_eq ? :string_value : :decimal_value
end

def read_value(value_record);   ...; end  # compose composite from cols
def write_value(value_record, casted); ...; end  # unpack composite into cols
def apply_default_to(value_record); ...; end  # write default across cols
```

Single-cell types inherit defaults that delegate to `value_column` (singular) — every built-in type pre-Phase-05 behaves identically.

The pattern: override **all three**, or override none. Overriding only `read_value` (for example) creates an asymmetry where reads see the multi-cell shape but writes / defaults populate only one column, which would silently corrupt data. Documented inline in `field/base.rb` lines 247–309.

### "One module dispatch instead of per-type classes"

`QueryBuilder#filter` is a single module with one big `case` statement covering all 18+ operators across all field types. The earlier (Relaticle-inspired) design would have been a hierarchy of `Finder` classes per type; the rewrite collapses to a single dispatch because Rails' Arel + column-type casting handle the type-specific work.

When adding an operator, you extend this one case statement — don't introduce a new dispatch layer. For multi-cell types that need a per-operator column override, override `self.operator_column(operator)` on the field class (Phase 05 hook). The Phase 05 `:currency_eq` and `:references` operators are registered ONLY on their specific field types (Currency, Reference) — the operator-validation gate at the top of `#filter` rejects them on every other field type without any extra code.

### "Configurables via hand-rolled accessors (with `defined?(@var)`)"

`TypedEAV::Config` and `TypedEAV::Registry` use plain class instance variables behind reader/writer methods rather than `ActiveSupport::Configurable` (which was deprecated without replacement in Rails 8.1 and will be removed in Rails 8.2):

```ruby
def scope_resolver
  defined?(@scope_resolver) ? @scope_resolver : DEFAULT_SCOPE_RESOLVER
end
attr_writer :scope_resolver
```

The `defined?(@var)` idiom on the readers preserves the **"never set vs explicitly nil" distinction** — callers can assign `nil` and the reader returns `nil` rather than silently falling through to the default. This matters for spec snapshot/restore hooks that explicitly assign `nil` and expect to see it back.

When introducing new module-level configuration, follow this pattern. Don't reintroduce Configurable — it's deprecated.

### "Sentinel objects for distinguishing kwarg states"

The codebase uses three frozen-Object sentinels:

| Sentinel | Distinguishes |
|---|---|
| `HasTypedEAV::ClassQueryMethods::UNSET_SCOPE` | "kwarg not passed → resolve from ambient" vs "explicitly nil → filter to global-only on this axis" |
| `HasTypedEAV::ClassQueryMethods::ALL_SCOPES` | "normal scoped query" vs "inside `unscoped { }` → use multimap branch" |
| `Value::UNSET_VALUE` | "no `value:` kwarg given → trigger `field.apply_default_to(self)`" vs "explicit `value: nil` → store nil" |

This is the alternative to adding multiple positional parameters or a "mode" symbol — a sentinel is cheap, identifiable via `.equal?`, and self-documenting via its constant name.

When you need to distinguish "argument not given" from "given as nil/false", reach for this pattern.

### "Resolution priority chain"

`TypedEAV.current_scope` walks a four-level resolution chain (unscoped → with_scope stack → configured resolver → nil). The pattern: a method returns the *first* non-nil result, with explicit comments numbering each level. See `lib/typed_eav.rb` lines 51–55.

Replicate this when adding a new resolver-style API. Don't bury the priority order in nested ifs.

### "Strict surface vs BC-permissive surface (two contracts, one feature)"

Phase 01 introduced the `(scope, parent_scope)` tuple. Two surfaces accept "scope":
- `Config.scope_resolver` callable — **strict**: must return `nil` or `[scope, parent_scope]`. Bare scalar raises `ArgumentError` directly inside `current_scope`, BEFORE normalization. The shim alternative was rejected because it would silently swallow contract violations in user-supplied resolver code.
- `with_scope(value) { }` block — **BC-permissive**: scalars/AR records are auto-coerced into `[value, nil]`. Apps that have only ever passed a scalar do not need to update on upgrade.

The split is intentional: **app-supplied callables get strict contracts** (their code is yours, you can update it); **block APIs get BC-permissive contracts** (call sites are scattered across an unknown number of host apps). Locked design at `01-CONTEXT.md §"Deferred Ideas"`.

When introducing a new feature with both a callable surface and a block surface, follow this pattern — strict for callable returns, permissive for block inputs.

### "Concerns layered onto AR via `on_load`"

The engine includes `HasTypedEAV` into every AR class via:

```ruby
ActiveSupport.on_load(:active_record) do
  include TypedEAV::HasTypedEAV
end
```

The macro itself is a no-op until called. This is the canonical Rails-engine pattern for "every AR class can opt in" without requiring users to `include` anything.

### "Polymorphic-on-entity, FK-on-field"

`Value` and `ValueVersion` are both `belongs_to :entity, polymorphic: true` (host model could be anything) **but** `belongs_to :field, class_name: "TypedEAV::Field::Base"` (always points at a known table). The asymmetry is deliberate: polymorphism is used where the type genuinely varies (host model class names) and avoided where it doesn't (fields are always rows in `typed_eav_fields`).

### "Eager require for engine-boot registrations"

`lib/typed_eav/engine.rb` `require_relative`s `event_dispatcher` (Phase 03) inside the autoload initializer rather than relying on Zeitwerk autoload. Phase 04 versioning registers `Subscriber.method(:call)` onto `EventDispatcher.value_change_internals` at engine boot via a `config.after_initialize` block — if the autoload fired for the first time DURING that registration, a fresh `@value_change_internals = []` would wipe out the registration.

The pattern: **anything that's registered against at engine-boot time must be eager-required**, not autoloaded. Documented inline in `engine.rb` lines 11–17.

### "Conditional registration in `config.after_initialize`"

Phase 04 versioning subscriber registration runs in `config.after_initialize` (not a regular `initializer` block) so it can read `TypedEAV.config.versioning` *after* the host's `config/initializers/typed_eav.rb` has set it:

```ruby
config.after_initialize do
  TypedEAV::Versioning.register_if_enabled
end
```

Phase 05 Active Storage soft-detect uses the same pattern (a second `config.after_initialize` block, declared after versioning's so block-ordering preserves slot 0 for the versioning subscriber).

The pattern: **anything that needs to read host-set config must run in `after_initialize`, not `initializer`**. The trade-off is that runtime config toggles AFTER `after_initialize` has fired (e.g., a Rails console flip) won't take effect until process restart — that's an acceptable trade because runtime toggle is not a documented use case for any current consumer.

### "Internal-vs-user error policy split (locked at 03-CONTEXT.md)"

`EventDispatcher` runs internal subscribers (Phase 04 versioning, future Phase 07 matview) FIRST in registration order. **Internal exceptions propagate** — fail-closed because corruption must be loud. The user proc fires LAST, **wrapped in `rescue StandardError` and logged via `Rails.logger.error`** — the row is already committed, re-raising would surface a misleading "save failed" error.

When adding a Phase 03-style event dispatcher in another subsystem, follow this split. Don't unify.

## Naming patterns

| Pattern | Examples |
|---|---|
| Predicate methods end with `?` | `array_field?`, `optionable?`, `unscoped?`, `versioned?`, `email_format_valid?`, `previously_new_record?` |
| Macros start with `has_*` to mirror AR | `has_typed_eav` (compares to `has_many`) |
| DSL methods feel like Arel | `with_field`, `where_typed_eav` |
| Internal sentinels are CONSTANT_CASE | `UNSET_SCOPE`, `ALL_SCOPES`, `UNSET_VALUE`, `RESERVED_NAMES`, `MAX_JSON_BYTES`, `EMPTY_FROZEN_CONTEXT` |
| AR table names: `typed_eav_<plural>` | `typed_eav_fields`, `typed_eav_values`, `typed_eav_value_versions` |
| Index names: `idx_te_*` (prefix shortened to fit Postgres' 63-byte limit) | `idx_te_values_field_int`, `idx_te_fields_uniq_scoped_full`, `idx_te_vvs_value` (vvs = value versions) |
| Thread-locals namespaced and `private_constant` | `THREAD_SCOPE_STACK`, `THREAD_UNSCOPED`, `THREAD_CONTEXT_STACK` |
| Spec metadata as Ruby symbols, not strings | `:scoping`, `:unscoped`, `:event_callbacks`, `:real_commits` |
| Aliases preserve the documented name + the AR-style name | `alias typed_eav= typed_eav_attributes=` |
| Phase 03 dispatch internals: `_dispatch_*` prefix | `_dispatch_value_change_create`, `_dispatch_field_change`, `_dispatch_image_attached` |
| Phase 04 first-party hooks: `register_internal_*` | `register_internal_value_change` (signals first-party-only without forcing privacy) |
| Plural columns method: `value_columns` | (singular `value_column` is the per-type macro; plural is the runtime accessor for multi-cell forward-compat) |

## Quality patterns

### "Disable rubocop with a justification, not silently"

Every inline `# rubocop:disable …` comment in the codebase has a `--` justification on the same line. Examples:

```ruby
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength,
#   Metrics/PerceivedComplexity -- input normalization + multimap branch + filter
#   dispatch genuinely belong together; splitting hurts readability of the
#   scope-collision logic.
```

Don't disable cops without saying why. The pattern is `--` separator after the cop list, then the justification. Class-level disables (`# rubocop:disable Metrics/ClassLength` on `Field::Base`) carry multi-line justifications explaining what the class is doing and why the metric isn't a useful signal there.

### "Comment the failure mode, not the code"

Comments answer "what would break if I changed this?" rather than "what does this do?". Pattern:

```ruby
# `class_attribute` rather than `cattr_accessor`: class variables are
# copied-on-write across subclasses and reload well under Rails'
# code reloader. Normalize the types list to strings once so hot
# paths (type-restriction validation, `typed_eav_attributes=`)
# don't have to re-map per call.
```

Density over brevity. Phase 03/04/05 expanded this pattern with **locked-decision references** — comments cite specific phase-CONTEXT files (e.g., "locked at 03-CONTEXT.md §User-callback error policy", "locked plan-time decision §1 in plan 04-01-PLAN") so future readers can find the original design rationale. Use this when committing to a non-obvious choice.

### "Errors tell you how to fix it"

Every raised error message includes either the available options or the recovery steps:

- `"Unknown typed field 'X' for Y. Available fields: a, b, c"`
- `"Operator :foo is not supported. Supported operators: :eq, :not_eq, ..."`
- `"No ambient scope resolvable. Wrap the call in `TypedEAV.with_scope(value) { ... }`, configure `TypedEAV.config.scope_resolver`, or use `TypedEAV.unscoped { ... }`"`
- `"TypedEAV.config.scope_resolver must return a 2-element [scope, parent_scope] Array (or nil). Got: …. v0.1.x resolvers returning a bare scalar must be updated — see CHANGELOG and the README migration note."`
- `"has_typed_eav: parent_scope_method: requires scope_method: to also be set. … Either add scope_method: :your_scope_method or remove parent_scope_method:."`
- `"Cannot revert version#X: source Value was destroyed (version.value_id is nil). To restore a destroyed entity's typed values, create a new Value record manually using version.before_value as the seed state."`
- `"TypedEAV::Field::Image requires Active Storage. Add gem 'activestorage' to your Gemfile (already included via the rails meta-gem in Rails 7.1+) and run bin/rails active_storage:install."`

Pattern: state the problem, then list the recovery options inline. Don't make the user grep the docs. Breaking-change errors include CHANGELOG/migration-note pointers.

### "Defend the read path; let the write path catch you"

`InstanceMethods#typed_eav_value` and `typed_eav_hash` **silently skip orphan values** (`v.field` nil — definition deleted out from under the value, or Phase 02 `:nullify` cascade left the row behind). Read paths fail soft. Write paths are protected by validations that fail hard (`validate_entity_matches_field`, `validate_field_scope_matches_entity`).

The asymmetry is the pattern: never let a stray DB row crash a render, but never let a bad write get persisted. Phase 02's `field_dependent: :nullify` policy made this pattern load-bearing — the orphan is now an expected outcome of a configured choice, not just a defensive guard against schema corruption.

### "Already-loaded preload reuse"

`InstanceMethods#loaded_typed_values_with_fields` checks `typed_values.loaded?` before deciding whether to re-query. If the caller did `Contact.includes(typed_values: :field)`, the helper reuses; if not, it does its own includes. This is the documented N+1 escape hatch.

When adding a method that reads `typed_values`, consult this helper rather than calling the association directly.

### "Snapshot+restore (NOT reset) for spec isolation of engine-boot state"

`spec/spec_helper.rb`'s `:event_callbacks` around-hook **snapshots** `EventDispatcher.value_change_internals.dup` and restores via `instance_variable_set` — it does **not** call `EventDispatcher.reset!`. Why: Phase 04 versioning registers internal subscribers at engine load, and a blanket reset would wipe Phase 04+'s engine-load registrations and break every following spec.

When introducing per-spec state isolation for engine-boot-registered state, snapshot+restore. Don't add a `reset!` and call it in a global `after`.

## Concern patterns

### "Fail-closed by default; document the bypass"

Five places follow this rule (was three; Phase 01–04 added two):

1. **`require_scope = true`** by default. Bypass per-call via `TypedEAV.unscoped { ... }`. Documented in `Config.require_scope` and surfaced in the `ScopeRequired` error message.
2. **Admin scaffold's `authorize_typed_eav_admin!`** returns `head :not_found` by default. Bypass by editing the method on the generated controller.
3. **Type-restriction enforcement** (`validate_type_allowed_for_entity`) skips when the entity isn't registered yet — but this is documented as "intentional fail-open" because *registration* hasn't happened, not *validation*. Comment at `field/base.rb` line 524 explicitly calls this out.
4. **Strict resolver contract** (Phase 01) — `Config.scope_resolver` returning a bare scalar raises `ArgumentError` rather than auto-coercing. Bypass by updating the resolver to return `[scope, parent_scope]`.
5. **Macro guard** (Phase 01) — `has_typed_eav parent_scope_method: :ws` without `scope_method:` raises at class load. Bypass by adding `scope_method:` or removing `parent_scope_method:`.

The pattern: lock it down by default, document the lever to flip it, surface the bypass in error messages.

### "Paired partial unique indexes for nullable scope columns (now triple-paired)"

Whenever a unique constraint includes nullable scope columns, **multiple** partial indexes are needed (PG treats NULLs as distinct in plain unique indexes — the `(name, entity_type, scope=NULL)` row would not deduplicate). Original pattern (one nullable column) was paired:

```ruby
t.index %i[name entity_type scope], unique: true, where: "scope IS NOT NULL", name: "..."
t.index %i[name entity_type],       unique: true, where: "scope IS NULL",     name: "..."
```

Phase 01 extended to **triple-paired** for two nullable columns (`scope`, `parent_scope`):

```ruby
add_index ..., where: "scope IS NOT NULL AND parent_scope IS NOT NULL", name: "*_uniq_scoped_full"
add_index ..., where: "scope IS NOT NULL AND parent_scope IS NULL",     name: "*_uniq_scoped_only"
add_index ..., where: "scope IS NULL",                                  name: "*_uniq_global"
```

The orphan-parent invariant (model-level + macro-level) guarantees the missing fourth combination `(scope IS NULL AND parent_scope IS NOT NULL)` is unrepresentable, so three partials are exhaustive. `nulls_not_distinct: true` (PG ≥ 15) was rejected — gemspec floor doesn't pin a PG version.

If a future feature adds a nullable column to a uniqueness key, this paired-index pattern must be preserved. Each new nullable column doubles the partial-count requirement (or scales by paired invariants like Phase 01).

### "Concurrent index DDL for production safety"

Phase 01 migration uses `disable_ddl_transaction!` + `algorithm: :concurrently` on every `add_index`/`remove_index` call. Production deployments may carry millions of rows in `typed_eav_fields` / `typed_eav_sections` by the time they upgrade — concurrent DDL keeps writes online during the rebuild. The trade-off: concurrent index operations cannot run inside a DDL transaction, so the migration explicitly implements `up`/`down` (since `algorithm: :concurrently` is not auto-reversible from a `change` block).

When introducing new partition-table indexes in future migrations, follow this pattern. Same applies if Phase 06+ introduces new audit-log indexes against a table that's already large.

### "Covering indexes for read patterns"

The values table's per-typed-column indexes are `(field_id, <typed>_value) include (entity_id, entity_type)`. The `INCLUDE` makes them covering for the dominant read pattern. The Phase 04 audit log indexes (`idx_te_vvs_*`) follow the same idea but with DESC on `changed_at` because `Value#history` returns most-recent-first.

When adding a new typed column or audit-log index, follow the same shape (and watch index cardinality on a real workload).

### "Partition-level FOR UPDATE locking"

Phase 02's display-ordering helpers acquire `for_entity(...).order(:id).lock("FOR UPDATE")` to serialize concurrent reorders within the same partition. The `:id` ordering of the lock acquisition is **load-bearing** — without it, two threads acquiring locks on the same partition could deadlock on different acquisition orders. Postgres documents `FOR UPDATE` ordering as the canonical deadlock-avoidance technique.

Cross-partition operations never block each other because they lock disjoint row sets.

When introducing a new operation that mutates multiple rows within a logical partition, use this pattern. Don't reach for advisory locks unless you specifically need cross-table coordination.

## Test patterns

### "Regression spec named after analysis round"

`spec/regressions/review_round_2_*.rb`, `review_round_3_*.rb`, `review_round_4_parent_scope_spec.rb`, `review_round_5_versioning_slot_zero_spec.rb`, `known_bugs_spec.rb`. The pattern: when an analysis pass uncovers a class of bugs, file a spec under `spec/regressions/` named after the analysis round. The describe block titles map to specific issue identifiers ("ANALYSIS 1.1", "ANALYSIS 2.6", "Three-way collision precedence", "Slot 0 invariant") so there's a paper trail from review notes to test cases.

### "Pending-as-target"

`known_bugs_spec.rb` uses `pending` to encode desired-but-unfixed behavior. When the fix lands, the test auto-un-pends. This is cheaper than tracking bugs in a tracker and is naturally synced with the codebase.

### "`:event_callbacks` metadata for Phase 03/04 dispatch specs"

For specs that touch `EventDispatcher`, `Config.on_*` user procs, `Config.versioning`, `Config.actor_resolver`, or the internal-subscribers arrays, mark the example `:event_callbacks`. The around-hook in `spec_helper.rb` snapshots+restores all dispatch state per example. Use **snapshot+restore**, not `EventDispatcher.reset!`, so Phase 04's engine-load registration survives across specs.

Combine with `:real_commits` for end-to-end integration specs that need `after_commit` to fire durably.

### "`:unscoped` metadata for class-query specs"

For specs that exercise class-level queries against a scoped model (`Contact`, `Project`) but don't want to set up an ambient scope, mark the example `:unscoped`. The around hook in `spec_helper.rb` wraps it in `TypedEAV.unscoped { ... }`. Don't restore the old "wrap everything by default" pattern — it hid bugs.

## Dependency patterns

### "One hard dep, soft-detect everything else"

Gemspec declares one runtime dep (`rails`). Anything else (multi-tenancy primitives, Active Storage, image processing) is **soft-detected via `defined?(...)`**. Examples:
- `Config::DEFAULT_SCOPE_RESOLVER` checks `defined?(::ActsAsTenant)` rather than `require`ing it.
- `Engine.register_attachment_associations!` checks `defined?(::ActiveStorage::Blob)` before registering the `has_one_attached :attachment` macro.
- `Field::Image#cast` and `Field::File#cast` check `defined?(::ActiveStorage::Blob)` and raise `NotImplementedError` (with install instructions) when absent.
- `Value#_dispatch_image_attached` checks `defined?(::ActiveStorage::Blob)` before invoking the hook.

When adding integration with a new ecosystem gem, follow this pattern: detect-don't-require, fail gracefully when absent (no-op for hooks; raise with install instructions for must-haves), document the override hook. Never add to the gemspec runtime deps.

### "Plugin family pinning, individual gems floating"

Rubocop and its plugins (`rubocop-rails`, `rubocop-performance`, `rubocop-rspec`) are pinned (`~> 1.86`, `~> 2.34`, etc.) for lint stability across CI runs. Test gems (`rspec-rails`, `factory_bot_rails`, `pg`, `shoulda-matchers`) are unpinned because their major versions are stable and the `Gemfile.lock` is committed.

When adding a dev tool with brittle output (linters, formatters), pin it. When adding a stable dev gem, let it float.
