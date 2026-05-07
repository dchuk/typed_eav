# CONVENTIONS.md

## Style & lint

- **`# frozen_string_literal: true`** at the top of every Ruby file. Enforced via `Style/FrozenStringLiteralComment` with `EnforcedStyle: always`. Excluded for `db/migrate/**/*` and `spec/dummy/**/*`.
- **Double-quoted strings** everywhere (`Style/StringLiterals: double_quotes`).
- **Trailing commas in multiline literals/args/hashes** — `Style/TrailingComma{InArguments,InArrayLiteral,InHashLiteral}` set to `comma`.
- **Line length 120**, with `\A\s*#` (comment-only lines) exempted — long doc comments are allowed.
- **Style/Documentation disabled** — class-level docstrings are not required.
- **Style/ClassAndModuleChildren disabled** — both `class TypedEAV::Foo` and `module TypedEAV; class Foo` shapes are accepted.
- **Naming/PredicateMethod disabled** — methods like `array_field?`, `optionable?`, `unscoped?`, `versioned?`, `previously_new_record?` follow the predicate suffix without the matcher complaining.
- **Targets**: `TargetRubyVersion: 3.1`, `TargetRailsVersion: 7.1`. NewCops enabled.

## Metrics tolerances

The `.rubocop.yml` is **deliberately lenient on metrics for migrations and generators**, where one-off "do everything" methods are appropriate:

| Metric | Default cap | Excludes |
|---|---|---|
| `MethodLength` | 25 | `db/migrate/**/*`, `lib/generators/**/*` |
| `AbcSize` | 25 | same |
| `CyclomaticComplexity` | 12 | same |
| `PerceivedComplexity` | 12 | same |
| `ClassLength` / `ModuleLength` | 250 | — |
| `BlockLength` | spec/gemspec/migrations excluded; rspec helpers allowed |

When a metric has to be silenced inline (e.g., `where_typed_eav`, `typed_eav_attributes=`, `Currency#cast`, `Field::Base` as a whole), the codebase uses paired `# rubocop:disable Metrics/...` / `# rubocop:enable ...` comments **with a justification on the disable line**:

```ruby
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity -- input normalization +
# multimap branch + filter dispatch genuinely belong together; splitting hurts readability
# of the scope-collision logic.
```

Field::Base carries a class-level `# rubocop:disable Metrics/ClassLength` with a multi-line justification (the central STI parent legitimately holds associations, validations, cascade dispatch, partition-aware ordering, default-value handling, and backfill — splitting into concerns would scatter the cross-cutting `(entity_type, scope, parent_scope)` partition contract).

The pattern is: don't disable silently, give the reason. Examples in `lib/typed_eav/has_typed_eav.rb`, `lib/typed_eav/query_builder.rb`, `app/models/typed_eav/value.rb`, `app/models/typed_eav/field/base.rb`, and `app/models/typed_eav/field/currency.rb`.

## Comments

The codebase has high-density, **rationale-first** comments. The pattern:

- Don't explain *what* a line does — explain *why* this approach was chosen, especially when a simpler approach would be wrong.
- Lots of comments that read "Without this, …" — explaining the failure mode that justifies the current code.
- Comments tied to specific commits and to specific locked phase-CONTEXT decisions (e.g., "Plan 04-02's subscriber writes value_id: nil for :destroy events because…", "locked at 03-CONTEXT.md §User-callback error policy", "locked at 04-CONTEXT.md §`Value#revert_to` semantics").

Examples:
- `lib/typed_eav.rb` lines 41–113 explain the resolution priority order for `current_scope` and the strict-vs-permissive contract split between `scope_resolver` and `with_scope`.
- `lib/typed_eav/has_typed_eav.rb` lines 35–61 document the three-way name-collision sort (global / scope-only / full-triple).
- `lib/typed_eav/event_dispatcher.rb` documents the internal-vs-user error policy split and why field-change dispatch deliberately omits the `context` arg (asymmetric vs value-change).
- `app/models/typed_eav/field/reference.rb` lines 92–107 document the `::Integer` / `::String` constant-shadow hazard inside `module TypedEAV; module Field`.
- `db/migrate/20260430000000_*.rb` lines 36–56 explain why three partials per partition table (Option B split) instead of two — Postgres treats NULL as distinct in unique indexes, and `nulls_not_distinct: true` (PG ≥ 15) was rejected because the gemspec doesn't pin a PG version.
- `app/models/typed_eav/field/integer_array.rb` explains "all-or-nothing cast" so a failed form re-render shows the original input intact.

Don't strip these. They are the documentation.

## Error messages

User-facing exceptions list the available options or the recovery steps. Examples:

```ruby
# has_typed_eav.rb#where_typed_eav
raise ArgumentError, "Unknown typed field '#{name}' for #{self.name}. " \
                     "Available fields: #{fields_by_name.keys.join(", ")}"

# query_builder.rb#filter
raise ArgumentError,
      "Operator :#{operator} is not supported for #{field.class.name}. " \
      "Supported operators: #{supported.map { |o| ":#{o}" }.join(", ")}"

# has_typed_eav.rb#resolve_scope
raise TypedEAV::ScopeRequired,
      "No ambient scope resolvable for #{name}. " \
      "Wrap the call in `TypedEAV.with_scope(value) { ... }`, " \
      "configure `TypedEAV.config.scope_resolver`, or use " \
      "`TypedEAV.unscoped { ... }` to deliberately bypass."

# typed_eav.rb#current_scope (Phase 1 strict resolver contract)
raise ArgumentError,
      "TypedEAV.config.scope_resolver must return a 2-element " \
      "[scope, parent_scope] Array (or nil). Got: #{raw.inspect}. " \
      "v0.1.x resolvers returning a bare scalar must be updated — " \
      "see CHANGELOG and the README migration note."

# has_typed_eav.rb#has_typed_eav (Phase 1 macro guard)
raise ArgumentError,
      "has_typed_eav: `parent_scope_method:` requires `scope_method:` to also be set. " \
      "A model declaring parent_scope without scope is a configuration error — " \
      "ambient resolution would silently return [nil, nil] and queries would dead-letter. " \
      "Either add `scope_method: :your_scope_method` or remove `parent_scope_method:`."

# value.rb#revert_to (Phase 4 audit-trail guard)
raise ArgumentError,
      "Cannot revert version##{version.id}: source Value was destroyed " \
      "(version.value_id is nil). To restore a destroyed entity's typed " \
      "values, create a new Value record manually using version.before_value " \
      "as the seed state."

# field/image.rb#cast (Phase 5 soft-detect)
raise NotImplementedError,
      "TypedEAV::Field::Image requires Active Storage. " \
      "Add `gem 'activestorage'` to your Gemfile (already " \
      "included via the `rails` meta-gem in Rails 7.1+) and " \
      "run `bin/rails active_storage:install`."
```

The error tells the caller *how to fix it*, not just what's wrong. Migration notes and CHANGELOG references are inlined for breaking-change paths.

## Naming

| Convention | Example |
|---|---|
| Boolean/predicate methods end in `?` | `array_field?`, `optionable?`, `unscoped?`, `versioned?`, `previously_new_record?` |
| STI subclasses live one-per-file under `field/` | `field/integer_array.rb`, `field/currency.rb`, `field/percentage.rb` |
| Namespaced AR table names | `typed_eav_fields`, `typed_eav_values`, `typed_eav_options`, `typed_eav_sections`, `typed_eav_value_versions` (snake_case, plural, prefixed) |
| Index names use `idx_te_*` prefix to fit Postgres' 63-byte limit | `idx_te_values_field_str`, `idx_te_fields_uniq_scoped_full`, `idx_te_vvs_value`, `idx_te_vvs_entity`, `idx_te_vvs_field` |
| Phase 04 audit log indexes use `idx_te_vvs_*` | `vvs` = "value versions" — keeps the four-character partition fits in 63 bytes |
| Scope-related method on host: `typed_eav_scope` / `typed_eav_parent_scope` | unconditionally defined (returns nil when `*_method` not declared) so callers can `respond_to?` and read uniformly |
| Class-level methods: `where_typed_eav`, `with_field`, `typed_eav_definitions` | DSL feel, not AR-rails-y `scope :where_typed_eav, ...` |
| Setter alias: `typed_eav=` is an alias for `typed_eav_attributes=` | both forms accepted |
| Phase 03 dispatch internals: `_dispatch_*` prefix | `_dispatch_value_change_create`, `_dispatch_value_change_update`, `_dispatch_value_change_destroy`, `_dispatch_field_change`, `_dispatch_image_attached` — leading underscore signals private dispatch glue |
| Phase 04 first-party hooks: `register_internal_*` | `register_internal_value_change`, `register_internal_field_change` — the `_internal_` infix signals first-party-only intent (not strictly enforced via `private_class_method` because Phase 04 lives in a different namespace and would not be able to call a truly-private method) |
| Multi-cell extension points: paired `read_value` / `write_value` / `apply_default_to` | Override **all three** when adding a multi-cell field type — overriding only one creates an asymmetry where reads see the multi-cell shape but writes / defaults populate only one column |

## API stability signals

- **Constants made `private_constant`** when they're internal sentinels — see `THREAD_SCOPE_STACK`, `THREAD_UNSCOPED`, `THREAD_CONTEXT_STACK`, `EMPTY_FROZEN_CONTEXT` in `lib/typed_eav.rb`, and `MAX_JSON_BYTES` in `value.rb`.
- **`UNSET_SCOPE`, `ALL_SCOPES`, `Value::UNSET_VALUE` are NOT private_constant** because they're documented sentinels in the public API surface (callers may want `Object.equal?(UNSET_VALUE)` checks in their own code). Note: they live inside a module — host app code wouldn't see them anyway.
- **`alias typed_eav= typed_eav_attributes=`** rather than two separate definitions — the alias makes the equivalence load-bearing.

## RSpec conventions

- **Per-spec metadata flags** govern around-hook behavior. See `spec/spec_helper.rb`:
  - `:unscoped` wraps an example in `TypedEAV.unscoped { ... }`.
  - `:scoping` documents "I manage scope myself, don't wrap me."
  - `:event_callbacks` snapshots/restores Phase 03 + Phase 04 dispatch state (Config.on_value_change / on_field_change / on_image_attached / versioning / actor_resolver, plus the EventDispatcher internal-subscribers arrays). Uses **snapshot+restore**, not `EventDispatcher.reset!` — Phase 04 versioning registers internal subscribers at engine load, and a blanket reset would wipe them for every following spec.
  - `:real_commits` disables the transactional-fixtures wrap so `after_commit` fires durably; cleans up rows in FK-respecting order after (ValueVersion → Value → Option → Field → Section → Contact/Product/Project).
  The default is **no wrapping**. An earlier version of the spec_helper wrapped every example in `unscoped`, which masked scoped+global name-collision bugs (the class-level query path collapsed multimap matches to a single field — see `regressions/review_round_3_collision_spec.rb`). Opt-in is the safer contract.
- **`spec/regressions/`** holds tests named after analysis rounds: `review_round_2_array_cast_spec.rb`, `review_round_2_blank_handling_spec.rb`, `review_round_2_scope_leak_spec.rb`, `review_round_3_collision_spec.rb`, `review_round_4_parent_scope_spec.rb`, `review_round_5_versioning_slot_zero_spec.rb`, `known_bugs_spec.rb`. The pattern in `known_bugs_spec.rb`: tests marked `pending` describe DESIRED behavior; non-`pending` tests verify already-fixed bugs. They auto-un-pend when a fix lands.
- **Factories** in `spec/factories/typed_eav.rb`. Sequences for `name` so multiple field rows can coexist without uniqueness conflicts. Host factories (`:contact`, `:project`) default scope axes to `nil` so a bare `create(:contact)` doesn't activate scope-required mode.
- **`shoulda-matchers`** configured for `:active_record` and `:active_model` only.
- **Transactional fixtures** (`use_transactional_fixtures = true`) — but per-example `:real_commits` toggles `use_transactional_tests` (the rspec-rails 8 runtime slot — `use_transactional_fixtures` on the example group has no effect because the runtime never reads it).
- **Registry NOT reset between examples** — the comment in `spec_helper.rb` says: "let `has_typed_eav` registrations from class loading persist so registration tests are meaningful." A blanket `Registry.reset!` would invalidate the very thing the registration specs are testing.
- **Pending dummy migrations applied at suite start** — `spec_helper.rb` runs `MigrationContext.new(dummy_path).migrate` so a fresh check-out picks up new dummy-app migrations (e.g., the Phase 05 Active Storage tables) without manual intervention.
- **`type: :model`** specified per-`describe` rather than relying on path inference for cross-cutting integration specs (`spec/integration/typed_eav_lifecycle_spec.rb`).

## Documentation conventions

The README is the canonical user docs (no separate `doc/` site). It has grown to ~1200 lines as of v0.2.0 to cover the new subsystems:
1. Why typed columns (the value prop)
2. Installation
3. Quick start
4. The query DSL operator table (now includes `:references`, `:currency_eq`)
5. Forms / scaffold / multi-tenant (each its own section; multi-tenant covers two-axis scoping + parent_scope_method)
6. Field types table (22 entries)
7. Custom field types (the extensibility seam)
8. **Versioning** (Phase 04: master switch, per-entity opt-in, `with_context`, `actor_resolver`, `Value#history`, `Value#revert_to`, querying full audit history including post-destroy)
9. **Cascade & ordering** (Phase 02: `field_dependent`, partition-aware move helpers, `backfill_default!`)
10. **Events** (Phase 03: `on_value_change`, `on_field_change`, `on_image_attached`, `with_context`)
11. Validation behavior — explicitly lists the **non-obvious contracts** (required+blank, array all-or-nothing cast, integer rejects fractional, json string parsing, TextArray ≠ contains, orphan skip, cross-scope rejection, Currency Hash-only cast, Reference accepts records or ids)
12. Database support / Schema / License

The "non-obvious contracts" section is doing real work — every item there is something a careful reader would otherwise have to figure out from the code.

## File-organization rules

- One STI subclass per file under `app/models/typed_eav/field/`. Don't reintroduce a single `types.rb`.
- One generator per directory under `lib/generators/typed_eav/`. Each generator has its own `templates/` if it needs them.
- Module entry (`lib/typed_eav.rb`) is small — extends are autoloaded; concerns are required by the engine initializer; the file itself is for *module-level* APIs (`with_scope`, `unscoped`, `with_context`, `current_scope`, `current_context`, etc.).
- Phase 04 versioning subsystem under `lib/typed_eav/versioning/` — namespace shell + Subscriber, **plus** an `autoload :Subscriber` in `lib/typed_eav/versioning.rb` because top-level `autoload :Versioning` only resolves the namespace shell (it does NOT recursively autoload nested constants); without the explicit nested autoload, the engine's `config.after_initialize` block would `NameError` at boot.

## Commit conventions

From `git log`:
- `<type>(<scope>): <subject>` — Conventional Commits format.
- Types observed: `chore`, `docs`, `feat` (implied), `fix`, `refactor`, `test`.
- Scopes observed: `ci`, `engine`, `field`, `generators`, `has_typed_fields`, `plan`, `release`, `rename`, `repo`, `validation`, plus per-phase scopes (`vbw` for VBW planning workflow chores, `readme` for docs).
- `!` for breaking changes (e.g., `chore(rename)!: rename gem from typed_fields to typed_eav`, `refactor(field)!: remove cast_value scalar shim`).
- Subjects use **present-tense imperative** ("add", "rename", "split", "make ... opt-in").
