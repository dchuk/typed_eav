# CONVENTIONS.md

## Style & lint

- **`# frozen_string_literal: true`** at the top of every Ruby file. Enforced via `Style/FrozenStringLiteralComment` with `EnforcedStyle: always`. Excluded for `db/migrate/**/*` and `spec/dummy/**/*`.
- **Double-quoted strings** everywhere (`Style/StringLiterals: double_quotes`).
- **Trailing commas in multiline literals/args/hashes** — `Style/TrailingComma{InArguments,InArrayLiteral,InHashLiteral}` set to `comma`.
- **Line length 120**, with `\A\s*#` (comment-only lines) exempted — long doc comments are allowed.
- **Style/Documentation disabled** — class-level docstrings are not required.
- **Style/ClassAndModuleChildren disabled** — both `class TypedEAV::Foo` and `module TypedEAV; class Foo` shapes are accepted.
- **Naming/PredicateMethod disabled** — methods like `array_field?`, `optionable?`, `unscoped?` follow the predicate suffix without the matcher complaining.
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
| `BlockLength` | spec/gemspec/migrations excluded; rspec helpers (`describe`, `context`, `it`, `shared_examples`, `define`, `configure`, `included`, `class_methods`, `namespace`) allowed |

When a metric has to be silenced inline (e.g., `where_typed_eav` and `typed_eav_attributes=` both legitimately span branching for normalization, scope dispatch, and type dispatch), the codebase uses paired `# rubocop:disable Metrics/AbcSize, …` / `# rubocop:enable …` comments **with a justification on the disable line**:

```ruby
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity -- input normalization +
# multimap branch + filter dispatch genuinely belong together; splitting hurts readability
# of the scope-collision logic.
```

This is the pattern: don't disable silently, give the reason. Examples in `lib/typed_eav/has_typed_eav.rb` (lines 119, 349, 397) and `lib/typed_eav/query_builder.rb` (line 31).

## Comments

The codebase has high-density, **rationale-first** comments. The pattern:

- Don't explain *what* a line does — explain *why* this approach was chosen, especially when a simpler approach would be wrong.
- Lots of comments that read "Without this, …" — explaining the failure mode that justifies the current code.
- Comments tied to specific commits (e.g., "ColumnMapping was a refactor: before commit eef8e51 there was a `cast_value` side-channel; now the tuple is the only API.").

Examples:
- `lib/typed_eav.rb` lines 38–46 explain the resolution priority order for `current_scope`.
- `lib/typed_eav/has_typed_eav.rb` lines 95–104 document the two sentinels (`UNSET_SCOPE`, `ALL_SCOPES`) and what they distinguish.
- `db/migrate/...rb` lines 17–22 explain the partial-unique-index split (PostgreSQL treats NULLs as distinct).
- `app/models/typed_eav/field/integer_array.rb` explains "all-or-nothing cast" and *why* — so a failed form re-render shows the original input intact.

Don't strip these. They are the documentation.

## Error messages

User-facing exceptions list the available options. Examples:

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
```

The error tells the caller *how to fix it*, not just what's wrong.

## Naming

| Convention | Example |
|---|---|
| Boolean/predicate methods end in `?` | `array_field?`, `optionable?`, `unscoped?`, `cast_was_invalid` (instance var) |
| STI subclasses live one-per-file under `field/` | `field/integer_array.rb` (commit `42c4e4c` split a single `types.rb`) |
| Namespaced AR table names | `typed_eav_fields`, `typed_eav_values`, `typed_eav_options`, `typed_eav_sections` (snake_case, plural, prefixed) |
| Index names use `idx_te_*` prefix to fit Postgres' 63-byte limit | `idx_te_values_field_str`, `idx_te_sections_unique_global` |
| Scope-related method on host: `typed_eav_scope` | not `current_scope` (avoids clashing with host app concepts) |
| Class-level methods: `where_typed_eav`, `with_field` | DSL feel, not AR-rails-y `scope :where_typed_eav, ...` |
| Setter alias: `typed_eav=` is an alias for `typed_eav_attributes=` | both forms accepted |

## API stability signals

- **Constants made `private_constant`** when they're internal sentinels — see `THREAD_SCOPE_STACK`, `THREAD_UNSCOPED` in `lib/typed_eav.rb`, and `MAX_JSON_BYTES` in `value.rb`.
- **`UNSET_SCOPE` and `ALL_SCOPES` are NOT private_constant** because they're documented sentinels in the public API surface (callers may want `Object.equal?(UNSET_SCOPE)` checks). Note: they live inside a module — host app code wouldn't see them anyway.
- **`alias typed_eav= typed_eav_attributes=`** rather than two separate definitions — the alias makes the equivalence load-bearing.

## RSpec conventions

- **Per-spec scope-handling metadata** — opt-in `:unscoped` wraps an example in `TypedEAV.unscoped { ... }`; opt-in `:scoping` documents "I manage scope myself, don't wrap me." See `spec/spec_helper.rb` lines 46–65 for the full contract. The default is **no wrapping** because earlier the spec_helper wrapped *everything* in `unscoped`, masking scoped+global name-collision bugs in the class-level query path.
- **`spec/regressions/`** holds tests named after analysis rounds: `review_round_2_array_cast_spec.rb`, `review_round_2_blank_handling_spec.rb`, `review_round_2_scope_leak_spec.rb`, `review_round_3_collision_spec.rb`, `known_bugs_spec.rb`. The pattern in `known_bugs_spec.rb`: tests marked `pending` describe DESIRED behavior; non-`pending` tests verify already-fixed bugs. They auto-un-pend when a fix lands.
- **Factories** in `spec/factories/typed_eav.rb`. Sequences for `name` so multiple field rows can coexist without uniqueness conflicts.
- **`shoulda-matchers`** configured for `:active_record` and `:active_model` only.
- **Transactional fixtures** (`use_transactional_fixtures = true`).
- **Registry NOT reset between examples** — the comment in `spec_helper.rb` says: "let `has_typed_eav` registrations from class loading persist so registration tests are meaningful." A blanket `Registry.reset!` would invalidate the very thing the registration specs are testing.
- **`type: :model`** specified per-`describe` rather than relying on path inference for cross-cutting integration specs (`spec/integration/typed_eav_lifecycle_spec.rb` line 5).

## Documentation conventions

The README is the canonical user docs (no separate `doc/` site). It is structured as:
1. Why typed columns (the value prop)
2. Installation
3. Quick start (4 numbered steps)
4. The query DSL operator table
5. Forms / scaffold / multi-tenant (each its own section)
6. Field types table
7. Custom field types (the extensibility seam)
8. Validation behavior — explicitly lists the **non-obvious contracts** (required+blank, array all-or-nothing cast, integer rejects fractional, json string parsing, TextArray ≠ contains, orphan skip, cross-scope rejection)
9. Database support / Schema / License

The "non-obvious contracts" section is doing real work — every item there is something a careful reader would otherwise have to figure out from the code.

## File-organization rules

- One STI subclass per file under `app/models/typed_eav/field/`. Don't reintroduce a single `types.rb`.
- One generator per directory under `lib/generators/typed_eav/`. Each generator has its own `templates/` if it needs them.
- Module entry (`lib/typed_eav.rb`) is small — extends are autoloaded; concerns are required by the engine initializer; the file itself is for *module-level* APIs (`with_scope`, `unscoped`, etc.).

## Commit conventions

From `git log`:
- `<type>(<scope>): <subject>` — Conventional Commits format.
- Types observed: `chore`, `docs`, `feat` (implied), `fix`, `refactor`, `test`.
- Scopes observed: `ci`, `engine`, `field`, `generators`, `has_typed_fields`, `plan`, `release`, `rename`, `repo`, `validation`.
- `!` for breaking changes (e.g., `chore(rename)!: rename gem from typed_fields to typed_eav`, `refactor(field)!: remove cast_value scalar shim`).
- Subjects use **present-tense imperative** ("add", "rename", "split", "make ... opt-in").
