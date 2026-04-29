# PATTERNS.md

Recurring patterns observed across the codebase. When extending or refactoring, prefer continuing these patterns rather than introducing new ones.

## Architectural patterns

### "Tuple-return for type coercion"

Every `Field::*#cast(raw)` returns `[casted_value, invalid?]`. The boolean second element is the load-bearing piece — without it, `Value#validate_value` could not distinguish "user gave us empty input" (`:blank`) from "user gave us bad input" (`:invalid`).

The contract: nil/empty raw input returns `[nil, false]`; non-empty unparseable input returns `[nil, true]`; everything else returns `[casted, false]`. See `Field::Integer#cast` for the canonical small example, `Field::IntegerArray#cast` for the all-or-nothing-array variant.

This was a refactor (commit `eef8e51 / 17dbbe1` removed the older `cast_value` side-channel). The tuple is the only API.

### "STI subclass declares its own column + operators"

Every field type subclass starts the same way:

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

### "One module dispatch instead of per-type classes"

`QueryBuilder#filter` is a single module with one big `case` statement covering all 16 operators across all field types. The earlier (Relaticle-inspired) design would have been a hierarchy of `Finder` classes per type; the rewrite collapses to a single dispatch because Rails' Arel + column-type casting handle the type-specific work. Comment at top of `query_builder.rb` lines 4–15 explains the choice.

When adding an operator, you extend this one case statement — don't introduce a new dispatch layer.

### "Configurables via `ActiveSupport::Configurable`"

Both `TypedEAV::Config` and `TypedEAV::Registry` use `include ActiveSupport::Configurable` rather than rolling their own singleton state. Members are declared with `config_accessor :foo, default: ...` and `config_accessor(:bar) { {} }` (block form for mutable defaults). This was migrated from a plain class-attribute approach in commit `13f6bcf`.

When introducing new module-level configuration, follow this pattern (don't add `attr_accessor` on a constant).

### "Sentinel objects for distinguishing kwarg states"

`UNSET_SCOPE = Object.new.freeze` and `ALL_SCOPES = Object.new.freeze` in `has_typed_eav.rb`. They distinguish:
- "kwarg not passed" (resolve from ambient) vs. "explicitly nil" (filter to global-only)
- "normal scoped query" vs. "inside `unscoped { }` — use multimap branch"

This is the alternative to adding multiple positional parameters or a "mode" symbol — a sentinel is cheap, identifiable via `.equal?`, and self-documenting via its constant name.

When you need to distinguish "argument not given" from "given as nil/false", reach for this pattern.

### "Resolution priority chain"

`TypedEAV.current_scope` walks a four-level resolution chain (unscoped → with_scope stack → configured resolver → nil). The pattern: a method returns the *first* non-nil result, with explicit comments numbering each level. See `lib/typed_eav.rb` lines 38–46.

Replicate this when adding a new resolver-style API. Don't bury the priority order in nested ifs.

### "Concerns layered onto AR via `on_load`"

The engine includes `HasTypedEAV` into every AR class via:

```ruby
ActiveSupport.on_load(:active_record) do
  include TypedEAV::HasTypedEAV
end
```

The macro itself is a no-op until called. This is the canonical Rails-engine pattern for "every AR class can opt in" without requiring users to `include` anything.

### "Polymorphic-on-entity, FK-on-field"

`Value` is `belongs_to :entity, polymorphic: true` (host model could be anything) **but** `belongs_to :field, class_name: "TypedEAV::Field::Base"` (always points at a known table). The asymmetry is deliberate: polymorphism is used where the type genuinely varies (host model class names) and avoided where it doesn't (fields are always rows in `typed_eav_fields`).

## Naming patterns

| Pattern | Examples |
|---|---|
| Predicate methods end with `?` | `array_field?`, `optionable?`, `unscoped?`, `email_format_valid?` |
| Macros start with `has_*` to mirror AR | `has_typed_eav` (compares to `has_many`) |
| DSL methods feel like Arel | `with_field`, `where_typed_eav` |
| Internal sentinels are CONSTANT_CASE | `UNSET_SCOPE`, `ALL_SCOPES`, `RESERVED_NAMES`, `MAX_JSON_BYTES` |
| AR table names: `typed_eav_<plural>` | `typed_eav_fields`, `typed_eav_values` |
| Index names: `idx_te_*` (prefix shortened to fit Postgres' 63-byte limit) | `idx_te_values_field_int`, `idx_te_sections_unique_global` |
| Thread-locals namespaced and `private_constant` | `THREAD_SCOPE_STACK`, `THREAD_UNSCOPED` |
| Spec metadata as Ruby symbols, not strings | `:scoping`, `:unscoped` |
| Aliases preserve the documented name + the AR-style name | `alias typed_eav= typed_eav_attributes=` |

## Quality patterns

### "Disable rubocop with a justification, not silently"

Every inline `# rubocop:disable …` comment in the codebase has a `--` justification on the same line. Examples:

```ruby
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength,
#   Metrics/PerceivedComplexity -- input normalization + multimap branch + filter
#   dispatch genuinely belong together; splitting hurts readability of the
#   scope-collision logic.
```

Don't disable cops without saying why. The pattern is `--` separator after the cop list, then the justification.

### "Comment the failure mode, not the code"

Comments answer "what would break if I changed this?" rather than "what does this do?". Pattern:

```ruby
# `class_attribute` rather than `cattr_accessor`: class variables are
# copied-on-write across subclasses and reload well under Rails'
# code reloader. Normalize the types list to strings once so hot
# paths (type-restriction validation, `typed_eav_attributes=`)
# don't have to re-map per call.
```

That's three justifications stacked: why `class_attribute`, why normalize once, where the hot paths are. Density over brevity.

### "Errors tell you how to fix it"

Every raised error message includes either the available options or the recovery steps:

- `"Unknown typed field 'X' for Y. Available fields: a, b, c"`
- `"Operator :foo is not supported. Supported operators: :eq, :not_eq, ..."`
- `"No ambient scope resolvable. Wrap the call in `TypedEAV.with_scope(value) { ... }`, configure `TypedEAV.config.scope_resolver`, or use `TypedEAV.unscoped { ... }`"`

Pattern: state the problem, then list the recovery options inline. Don't make the user grep the docs.

### "Defend the read path; let the write path catch you"

`InstanceMethods#typed_eav_value` and `typed_eav_hash` **silently skip orphan values** (`v.field` nil — definition deleted out from under the value). Read paths fail soft. Write paths are protected by validations that fail hard (`validate_entity_matches_field`, `validate_field_scope_matches_entity`).

The asymmetry is the pattern: never let a stray DB row crash a render, but never let a bad write get persisted.

### "Already-loaded preload reuse"

`InstanceMethods#loaded_typed_values_with_fields` checks `typed_values.loaded?` before deciding whether to re-query. If the caller did `Contact.includes(typed_values: :field)`, the helper reuses; if not, it does its own includes. This is the documented N+1 escape hatch.

When adding a method that reads `typed_values`, consult this helper rather than calling the association directly.

## Concern patterns

### "Fail-closed by default; document the bypass"

Three places follow this rule:

1. **`require_scope = true`** by default. Bypass per-call via `TypedEAV.unscoped { ... }`. Documented in `Config.require_scope` and surfaced in the `ScopeRequired` error message.
2. **Admin scaffold's `authorize_typed_eav_admin!`** returns `head :not_found` by default. Bypass by editing the method on the generated controller.
3. **Type-restriction enforcement** (`validate_type_allowed_for_entity`) skips when the entity isn't registered yet — but this is documented as "intentional fail-open" because *registration* hasn't happened, not *validation*. Comment at `field/base.rb` line 222 explicitly calls this out.

The pattern: lock it down by default, document the lever to flip it, surface the bypass in error messages.

### "Paired partial unique indexes for nullable scope columns"

Whenever a unique constraint includes a nullable `scope` column, **two** partial indexes are needed (PG treats NULLs as distinct in plain unique indexes — the `(name, entity_type, scope=NULL)` row would not deduplicate). Pattern in the migration:

```ruby
t.index %i[name entity_type scope], unique: true, where: "scope IS NOT NULL", name: "idx_te_*_unique_scoped"
t.index %i[name entity_type],       unique: true, where: "scope IS NULL",     name: "idx_te_*_unique_global"
```

If a future feature adds a nullable column to a uniqueness key, this paired-index pattern must be preserved.

### "Covering indexes for read patterns"

The values table's per-typed-column indexes are `(field_id, <typed>_value) include (entity_id, entity_type)`. The `INCLUDE` makes them covering for the dominant read pattern: "give me the entity_id+entity_type for all values matching this field with this filter." Index-only scans avoid heap fetches.

When adding a new typed column, follow the same shape (and watch index cardinality on a real workload).

## Test patterns

### "Regression spec named after analysis round"

`spec/regressions/review_round_2_*.rb`, `review_round_3_*.rb`, `known_bugs_spec.rb`. The pattern: when an analysis pass uncovers a class of bugs, file a spec under `spec/regressions/` named after the analysis round. The describe block titles map to specific issue identifiers ("ANALYSIS 1.1", "ANALYSIS 2.6") so there's a paper trail from review notes to test cases.

### "Pending-as-target"

`known_bugs_spec.rb` uses `pending` to encode desired-but-unfixed behavior. When the fix lands, the test auto-un-pends. This is cheaper than tracking bugs in a tracker and is naturally synced with the codebase.

### "`:unscoped` metadata for class-query specs"

For specs that exercise class-level queries against a scoped model (`Contact`) but don't want to set up an ambient scope, mark the example `:unscoped`. The around hook in `spec_helper.rb` wraps it in `TypedEAV.unscoped { ... }`. Don't restore the old "wrap everything by default" pattern — it hid bugs.

## Dependency patterns

### "One hard dep, soft-detect everything else"

Gemspec declares one runtime dep (`rails`). Anything else (multi-tenancy primitives, image processing) is **soft-detected via `defined?(...)`**. The `Config::DEFAULT_SCOPE_RESOLVER` lambda checks `defined?(::ActsAsTenant)` rather than `require`ing it.

When adding integration with a new ecosystem gem, follow this pattern: detect-don't-require, fail gracefully when absent, document the override hook.

### "Plugin family pinning, individual gems floating"

Rubocop and its plugins (`rubocop-rails`, `rubocop-performance`, `rubocop-rspec`) are pinned (`~> 1.86`, `~> 2.34`, etc.) for lint stability across CI runs. Test gems (`rspec-rails`, `factory_bot_rails`, `pg`, `shoulda-matchers`) are unpinned because their major versions are stable and the `Gemfile.lock` is committed.

When adding a dev tool with brittle output (linters, formatters), pin it. When adding a stable dev gem, let it float.
