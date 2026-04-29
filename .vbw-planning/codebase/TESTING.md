# TESTING.md

## Test framework

- **RSpec** via `rspec-rails ~> 8.0` (locked at 8.0.4).
- **`shoulda-matchers`** for AR validation/association assertions, configured for `:active_record` and `:active_model` only.
- **`factory_bot_rails`** for fixtures (factories live at `spec/factories/typed_eav.rb`).
- **Transactional fixtures** are enabled (`config.use_transactional_fixtures = true`).
- **No mocking framework** beyond rspec-mocks (which ships with rspec-rails). The codebase prefers real ActiveRecord interactions against the dummy app's Postgres database.

## Running

```bash
bundle exec rspec
bundle exec rspec --format documentation     # CI-style verbose
bundle exec rspec spec/lib/typed_eav/scoping_spec.rb     # single file
bundle exec rubocop                          # lint (CI runs --format github)
```

CI matrix tests Ruby 3.1 / 3.2 / 3.3 / 3.4 against Postgres 16 (`.github/workflows/ci.yml`).

## Test harness

A **dummy Rails app** lives at `spec/dummy/` and is the runtime environment for every spec. `spec_helper.rb` boots it (`require_relative "dummy/config/environment"`).

- Dummy host models are `Contact` and `Product`, defined in **`spec/dummy/app/models/test_models.rb`** (one file, two classes — Zeitwerk can't autoload it because the filename doesn't match a single class, so `spec_helper.rb` does an explicit `require_relative`).
- `Contact` declares `has_typed_eav scope_method: :tenant_id` (so the scoping suite has a model that opts in).
- Engine migrations are added to `ActiveRecord::Migrator.migrations_paths` from `spec_helper.rb` so the dummy schema includes the four `typed_eav_*` tables.
- `ActiveRecord::Migration.maintain_test_schema!` runs at suite start.

## Spec layout

```
spec/
├── dummy/                              # minimal Rails app (host environment)
│   ├── app/models/test_models.rb       # Contact + Product
│   ├── config/{boot,environment,routes,database.yml}
│   └── db/migrate/20260330000001_create_test_entities.rb   # tables for Contact/Product
│
├── factories/typed_eav.rb              # 149 lines; one factory per Field subclass + host models
│
├── integration/                        # cross-cutting end-to-end specs
│   ├── generators_spec.rb              # 98 lines — runs install/scaffold generators in temp dirs
│   └── typed_eav_lifecycle_spec.rb     # 151 lines — full create/assign/query/update/destroy
│
├── lib/typed_eav/                      # pure-logic tests for /lib code
│   ├── column_mapping_spec.rb          # 64 lines
│   ├── config_and_registry_spec.rb     # 108 lines
│   ├── query_builder_spec.rb           # 451 lines — every operator × type matrix
│   ├── scoping_spec.rb                 # 313 lines — UNSET_SCOPE, ALL_SCOPES, fail-closed, with_scope, unscoped, resolver
│   └── zeitwerk_loading_spec.rb        # 38 lines — guards eager-load correctness
│
├── models/typed_eav/                   # AR-model specs
│   ├── field_spec.rb                   # 497 lines — every Field::* type's cast/validate
│   ├── has_typed_eav_spec.rb           # 358 lines — instance + class-method behavior
│   ├── section_and_option_spec.rb      # 111 lines
│   └── value_spec.rb                   # 627 lines — the largest spec; covers the full Value contract
│
├── regressions/                        # tests pinned to specific historical bugs
│   ├── known_bugs_spec.rb              # 189 lines — `pending` for desired-but-unfixed; non-pending for already-fixed
│   ├── review_round_2_array_cast_spec.rb       # 70 lines
│   ├── review_round_2_blank_handling_spec.rb   # 73 lines
│   ├── review_round_2_scope_leak_spec.rb       # 127 lines
│   └── review_round_3_collision_spec.rb        # 172 lines — global+scoped name-collision precedence
│
└── spec_helper.rb                      # 66 lines
```

Total: roughly 3,720 lines of spec across 22 files.

## Spec-level conventions

### Scope metadata contract

`spec/spec_helper.rb` defines two opt-in metadata flags (lines 46–65) that govern the `around` hook:

| Metadata | Behavior | Use when |
|---|---|---|
| `:unscoped` | Wraps the example in `TypedEAV.unscoped { ... }` | The example uses a class-level query on a scoped model (e.g. `Contact.where_typed_eav(...)`) but doesn't want to set up an ambient scope. Without this wrap, fail-closed mode raises `ScopeRequired`. |
| `:scoping` | No wrapping; example manages scope itself | The example *is* testing the scoping subsystem (`with_scope`, `unscoped`, configured resolver, fail-closed behavior). |
| (none) | No wrapping; example doesn't touch class-level scoped queries | Default. |

The default is **no wrapping**. An earlier version of the spec_helper wrapped every example in `unscoped`, which masked scoped+global name-collision bugs (the class-level query path collapsed multimap matches to a single field — see `regressions/review_round_3_collision_spec.rb`). Opt-in is the safer contract.

### Registry isolation

`Registry` is **not** reset between examples (`spec_helper.rb` line 43–44). Comment: "let `has_typed_eav` registrations from class loading persist so registration tests are meaningful." If you reset it, the registration tests would never observe a populated registry.

### Regression-test pattern

`spec/regressions/known_bugs_spec.rb` uses `pending` strategically:
- Tests marked `pending` describe the **desired** behavior for a bug that hasn't been fixed yet. They auto-un-pend when the fix lands.
- Non-pending tests verify already-fixed bugs. The describe block titles them "(FIXED)" so the historical reference is obvious.

This is a clean pattern for keeping bug history auditable.

### Factories

149 lines, one factory per Field subclass plus host-model factories (`:contact`, `:product`). Each factory uses `sequence(:name) { |n| "<type>_field_#{n}" }` so multiple definitions per spec don't trip the partial unique index. The `:contact` factory defaults `tenant_id { nil }` so unscoped tests don't accidentally activate scope-required mode.

### Integration specs

`spec/integration/typed_eav_lifecycle_spec.rb` is the canonical "if all you read was one spec, read this" — it walks the full lifecycle: create field defs → instantiate entity → bulk-assign by name → read back → query → update → cascade-delete. It uses `:unscoped` metadata throughout because the host model (`Contact`) is scoped.

`spec/integration/generators_spec.rb` exercises the install and scaffold generators end-to-end (covered by commit `f0a3233 test(generators): cover scaffold and install generator output`).

### Test plan document

`TEST_PLAN.md` (31 KB, generated 2026-04-08) is a per-spec-file breakdown of every planned test case. It documents the **comprehensive coverage target** — including factories that needed adding, dependencies that needed declaring, and per-section enumerations of what each spec needs to cover. Cross-reference this when adding new tests so coverage stays uniform across types.

## Lint config for tests

From `.rubocop.yml`:
```yaml
RSpec/ExampleLength:
  Max: 25
RSpec/MultipleExpectations:
  Max: 10
RSpec/NestedGroups:
  Max: 5
RSpec/MultipleMemoizedHelpers:
  Max: 12
RSpec/IndexedLet: { Enabled: false }       # `let(:contact_1)`, `let(:contact_2)` allowed
RSpec/VerifiedDoubles: { Enabled: false }  # codebase prefers real AR objects to doubles
```

Several specs are excluded from `RSpec/DescribeClass` and `RSpec/MultipleDescribes` because they describe behaviors rather than classes (integration/regression specs, the field-spec mega-file, the scoping spec).

## Coverage gaps to be aware of

- **No JS/Stimulus tests.** The two Stimulus controllers in `lib/generators/typed_eav/scaffold/templates/javascript/controllers/` are not exercised — they're template files copied into consumer apps. Testing them would require a host app with a JS test runner.
- **No browser/system specs.** The scaffold's HTML output is not rendered+asserted. The form-helper logic (`render_typed_value_inputs`) is part of the templates copied into host apps; behavior is verified by `generators_spec.rb` (file presence/contents) but not by rendering against a real form.
- **Postgres-only.** `spec/dummy/config/database.yml` is generated by CI to point at Postgres. The codebase has no SQLite or MySQL test path — see `DEPENDENCIES.md` for which features make Postgres mandatory.
