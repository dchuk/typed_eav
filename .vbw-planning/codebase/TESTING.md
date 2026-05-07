# TESTING.md

## Test framework

- **RSpec** via `rspec-rails ~> 8.0` (locked at 8.0.4).
- **`shoulda-matchers`** for AR validation/association assertions, configured for `:active_record` and `:active_model` only.
- **`factory_bot_rails`** for fixtures (factories live at `spec/factories/typed_eav.rb`).
- **Transactional fixtures** are enabled (`config.use_transactional_fixtures = true`); per-example `:real_commits` toggles `use_transactional_tests` for specs that need `after_commit` to fire durably.
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

- Dummy host models are `Contact`, `Product`, and `Project`, defined in **`spec/dummy/app/models/test_models.rb`** (one file, three classes — Zeitwerk can't autoload it because the filename doesn't match a single class, so `spec_helper.rb` does an explicit `require_relative`).
  - `Contact has_typed_eav scope_method: :tenant_id`
  - `Product has_typed_eav types: %i[text integer decimal boolean]`
  - `Project has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id` — Phase 01 two-axis host
- Engine migrations are added to `ActiveRecord::Migrator.migrations_paths` from `spec_helper.rb` so the dummy schema includes the five `typed_eav_*` tables (Phase 04 `typed_eav_value_versions` joins the original four).
- `ActiveRecord::Migration.maintain_test_schema!` runs at suite start.
- **Pending dummy-app migrations applied at suite start** — `spec_helper.rb` runs `MigrationContext.new(dummy_path).migrate` so a fresh check-out picks up new dummy-app migrations (e.g., the Phase 05 Active Storage tables) without a manual `bin/rails db:migrate`.
- **Active Storage**: pulled in via the full `rails` meta-gem so `::ActiveStorage::Blob` is always defined under the test suite. The `active_storage_soft_detect_spec.rb` exercises the absent-AS code paths via stubbing rather than runtime gem removal.

## Spec layout

```
spec/
├── dummy/                              # minimal Rails app (host environment)
│   ├── app/models/test_models.rb       # Contact + Product + Project
│   ├── config/{boot,environment,routes,database,storage.yml}
│   └── db/migrate/
│       ├── 20260330000001_create_test_entities.rb               # tables for Contact/Product/Project
│       └── 20260506000000_create_active_storage_tables.active_storage.rb
│
├── factories/typed_eav.rb              # one factory per Field subclass + host models (incl. Project)
│
├── integration/                        # cross-cutting end-to-end specs
│   ├── generators_spec.rb              # runs install/scaffold generators in temp dirs
│   └── typed_eav_lifecycle_spec.rb     # full create/assign/query/update/destroy
│
├── lib/typed_eav/                      # pure-logic tests for /lib code
│   ├── active_storage_soft_detect_spec.rb        # Phase 05 — stubs ::ActiveStorage absence
│   ├── column_mapping_spec.rb
│   ├── column_mapping_value_columns_spec.rb      # Phase 04 — value_columns plural API
│   ├── config_and_registry_spec.rb
│   ├── config_versioning_spec.rb                 # Phase 04 — master switch + actor_resolver
│   ├── event_context_spec.rb                     # Phase 03 — with_context / current_context
│   ├── event_dispatcher_spec.rb                  # Phase 03 — internals/user-proc fire order + error policy
│   ├── field_cascade_spec.rb                     # Phase 02 — destroy/nullify/restrict_with_error
│   ├── query_builder_spec.rb                     # every operator × type matrix (incl. :references, :currency_eq)
│   ├── registry_versioned_spec.rb                # Phase 04 — Registry.versioned? per-entity opt-in
│   ├── scoping_spec.rb                           # UNSET_SCOPE, ALL_SCOPES, fail-closed, with_scope, unscoped, two-axis resolver
│   ├── versioned_concern_spec.rb                 # Phase 04 — TypedEAV::Versioned mixin
│   ├── versioning/subscriber_spec.rb             # Phase 04 — Subscriber.call gates + snapshot logic
│   └── zeitwerk_loading_spec.rb
│
├── models/typed_eav/                   # AR-model specs
│   ├── field_event_spec.rb             # Phase 03 — Field after_commit branch dispatch (create/update/destroy/rename)
│   ├── field_spec.rb                   # every Field::* type's cast/validate (now incl. Currency, Percentage, Reference, Image, File)
│   ├── has_typed_eav_spec.rb
│   ├── section_and_option_spec.rb
│   ├── value_event_spec.rb             # Phase 03 — Value after_commit dispatch + update filter
│   ├── value_history_spec.rb           # Phase 04 — Value#history ordering + tie-break
│   ├── value_revert_to_spec.rb         # Phase 04 — revert_to guards + audit-trail preservation
│   ├── value_spec.rb                   # the full Value contract (incl. UNSET_VALUE sentinel paths)
│   ├── value_version_spec.rb           # Phase 04 — ValueVersion model invariants
│   └── value_versioning_integration_spec.rb     # Phase 04 — end-to-end integration
│
├── regressions/                        # tests pinned to specific historical bugs
│   ├── known_bugs_spec.rb              # `pending` for desired-but-unfixed; non-pending for already-fixed
│   ├── review_round_2_array_cast_spec.rb
│   ├── review_round_2_blank_handling_spec.rb
│   ├── review_round_2_scope_leak_spec.rb
│   ├── review_round_3_collision_spec.rb         # global+scoped name-collision precedence
│   ├── review_round_4_parent_scope_spec.rb      # Phase 01 — three-way collision precedence
│   └── review_round_5_versioning_slot_zero_spec.rb     # Phase 04 — Subscriber stays at slot 0
│
└── spec_helper.rb                      # ~175 lines — see Spec-level conventions below
```

41 spec files total.

## Spec-level conventions

### Metadata flags

`spec/spec_helper.rb` defines four opt-in metadata flags that govern around-hook behavior:

| Metadata | Behavior | Use when |
|---|---|---|
| `:unscoped` | Wraps the example in `TypedEAV.unscoped { ... }` | The example uses a class-level query on a scoped model (e.g. `Contact.where_typed_eav(...)`) but doesn't want to set up an ambient scope. Without this wrap, fail-closed mode raises `ScopeRequired`. |
| `:scoping` | No wrapping; example manages scope itself | The example *is* testing the scoping subsystem (`with_scope`, `unscoped`, configured resolver, fail-closed behavior, two-axis resolution). |
| `:event_callbacks` | Snapshots/restores Phase 03 + Phase 04 dispatch state per example | Specs that exercise `EventDispatcher`, `Config.on_*` user procs, `Config.versioning`, `Config.actor_resolver`, or the internal-subscribers arrays. Uses snapshot+restore (NOT `EventDispatcher.reset!`) so Phase 04's engine-load registration survives across specs. |
| `:real_commits` | Disables `use_transactional_tests` for the example; manually deletes ValueVersion → Value → Option → Field → Section → Contact/Product/Project rows after | Integration specs that need `after_commit` to fire durably. Combine with `:event_callbacks` when exercising Phase 03/04 dispatch. |
| (none) | No wrapping; example doesn't touch class-level scoped queries | Default. |

The default is **no wrapping**. An earlier version of the spec_helper wrapped every example in `unscoped`, which masked scoped+global name-collision bugs (the class-level query path collapsed multimap matches to a single field — see `regressions/review_round_3_collision_spec.rb`). Opt-in is the safer contract.

The `:real_commits` toggle MUST be `use_transactional_tests`, NOT `use_transactional_fixtures`. The latter is the global RSpec.configure slot; rspec-rails 8 copies that slot into the per-example-group attribute `use_transactional_tests` at example startup and consults `use_transactional_tests` at runtime. Setting `use_transactional_fixtures` on the example group has no effect — the runtime never reads it.

### Registry isolation

`Registry` is **not** reset between examples (`spec_helper.rb`). Comment: "let `has_typed_eav` registrations from class loading persist so registration tests are meaningful." If you reset it, the registration tests would never observe a populated registry.

### Internal-subscriber isolation

`EventDispatcher.value_change_internals` and `field_change_internals` are populated at engine boot by Phase 04 versioning (when `Config.versioning = true`) and will be populated by Phase 07 matview later. The `:event_callbacks` around-hook **snapshots** these arrays per example via `dup` and restores via `instance_variable_set` — it does **not** call `EventDispatcher.reset!` (which would wipe Phase 04+'s engine-load registrations and break every following spec that depends on them).

### Regression-test pattern

`spec/regressions/known_bugs_spec.rb` uses `pending` strategically:
- Tests marked `pending` describe the **desired** behavior for a bug that hasn't been fixed yet. They auto-un-pend when the fix lands.
- Non-pending tests verify already-fixed bugs. The describe block titles them "(FIXED)" so the historical reference is obvious.

The numbered review-round files (`review_round_2_*` … `review_round_5_*`) capture analysis-pass discoveries: when a review uncovers a class of bugs, file a spec under `spec/regressions/` named after the review round. The describe block titles reference specific issue identifiers ("ANALYSIS 1.1", "ANALYSIS 2.6", "Slot 0 invariant", "Three-way collision precedence") so there's a paper trail from review notes to test cases.

### Factories

One factory per Field subclass plus host-model factories (`:contact`, `:product`, `:project`). Each field factory uses `sequence(:name) { |n| "<type>_field_#{n}" }` so multiple definitions per spec don't trip the partial unique index. Host factories default scope axes to `nil` so unscoped tests don't accidentally activate scope-required mode. The `:project` factory defaults both `tenant_id` and `workspace_id` to nil — tests opt in by passing values explicitly.

### Integration specs

`spec/integration/typed_eav_lifecycle_spec.rb` is the canonical "if all you read was one spec, read this" — it walks the full lifecycle: create field defs → instantiate entity → bulk-assign by name → read back → query → update → cascade-delete. It uses `:unscoped` metadata throughout because the host model (`Contact`) is scoped.

`spec/integration/generators_spec.rb` exercises the install and scaffold generators end-to-end (covered by commit `f0a3233 test(generators): cover scaffold and install generator output`).

`spec/models/typed_eav/value_versioning_integration_spec.rb` is the canonical Phase 04 integration spec — covers master switch + per-entity opt-in + Subscriber writes + `Value#history` reads + `revert_to` round-trip with audit-trail preservation. Uses `:real_commits` + `:event_callbacks` together.

### Test plan document

`TEST_PLAN.md` (~31 KB) is a per-spec-file breakdown of every planned test case. Generated 2026-04-08 against an earlier point in the suite — the "Current State" section is now well behind the present 41-file suite, but the plan document is still useful as a target/checklist when adding new tests so coverage stays uniform across types.

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
- **No multi-process concurrency spec.** Phase 02's `FOR UPDATE` partition locking is exercised single-process; the deadlock-avoidance argument (deterministic `:id` ordering) is verified by code review and the `move_*` specs, not by a real multi-process race.
- **Active Storage tests run with AS loaded** (`rails` meta-gem provides it). The `active_storage_soft_detect_spec.rb` exercises the absent-AS branches via stubbing of `defined?(::ActiveStorage::Blob)` rather than gem removal.
