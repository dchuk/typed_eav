# STRUCTURE.md

## Top-level layout

```
gem/
├── app/                                # AR models exposed to host apps via the engine
│   └── models/
│       └── typed_eav/
│           ├── application_record.rb   # abstract base
│           ├── field/                  # STI hierarchy (one file per type — split per commit 42c4e4c)
│           │   ├── base.rb             # validations, cast/validate_typed_value contract,
│           │   │                       # cascade dispatch, partition-aware ordering helpers,
│           │   │                       # default-value handling, backfill_default!,
│           │   │                       # multi-cell extension points (read_value/write_value/
│           │   │                       # apply_default_to), Phase 03 _dispatch_field_change
│           │   ├── boolean.rb
│           │   ├── color.rb
│           │   ├── currency.rb         # Phase 05 multi-cell: decimal_value + string_value
│           │   ├── date.rb
│           │   ├── date_array.rb
│           │   ├── date_time.rb
│           │   ├── decimal.rb
│           │   ├── decimal_array.rb
│           │   ├── email.rb
│           │   ├── file.rb             # Phase 05 Active Storage signed_id (note: shadows ::File)
│           │   ├── image.rb            # Phase 05 Active Storage signed_id + on_image_attached
│           │   ├── integer.rb
│           │   ├── integer_array.rb
│           │   ├── json.rb
│           │   ├── long_text.rb
│           │   ├── multi_select.rb
│           │   ├── percentage.rb       # Phase 05 extends Decimal: 0..1 fraction + format
│           │   ├── reference.rb        # Phase 05 FK + :references operator
│           │   ├── select.rb
│           │   ├── text.rb
│           │   ├── text_array.rb
│           │   └── url.rb
│           ├── option.rb               # per-field allowed values for select/multi_select
│           ├── section.rb              # optional UI grouping; partition-aware ordering helpers
│           ├── value.rb                # one row per (entity, field); typed columns; UNSET_VALUE
│           │                          # sentinel; history/revert_to; after_commit dispatch
│           └── value_version.rb       # Phase 04 audit log row
│
├── lib/
│   ├── typed_eav.rb                    # module entry: configure, current_scope, with_scope,
│   │                                  # unscoped, normalize_scope, with_context, current_context
│   ├── typed_eav/
│   │   ├── column_mapping.rb           # `value_column` macro, `value_columns` plural,
│   │   │                              # `operator_column(op)` dispatch, default operators
│   │   ├── config.rb                   # singleton: field_types, scope_resolver, require_scope,
│   │   │                              # versioning, actor_resolver, on_value_change,
│   │   │                              # on_field_change, on_image_attached
│   │   ├── engine.rb                   # Rails::Engine + on_load(:active_record); two
│   │   │                              # config.after_initialize blocks for Versioning +
│   │   │                              # Active Storage soft-detect
│   │   ├── event_dispatcher.rb         # Phase 03 in-process pub/sub hub
│   │   ├── has_typed_eav.rb            # the `has_typed_eav` macro + ClassQueryMethods +
│   │   │                              # InstanceMethods; definitions_by_name (single-winner)
│   │   │                              # and definitions_multimap_by_name (unscoped multimap)
│   │   ├── query_builder.rb            # operator dispatch (eq/gt/contains/any_eq/references/
│   │   │                              # currency_eq/...) with operator_column routing
│   │   ├── registry.rb                 # singleton: registered entity_types + types allow-list
│   │   │                              # + versioned? per-entity opt-in flag
│   │   ├── version.rb                  # TypedEAV::VERSION = "0.2.0"
│   │   ├── versioned.rb                # Phase 04 mixin (post-has_typed_eav opt-in)
│   │   └── versioning/
│   │       └── subscriber.rb          # Phase 04 internal subscriber (writes ValueVersion rows)
│   │   └── versioning.rb              # Phase 04 namespace + register_if_enabled helper
│   └── generators/
│       └── typed_eav/
│           ├── install/
│           │   └── install_generator.rb   # `rails g typed_eav:install`
│           └── scaffold/
│               ├── scaffold_generator.rb  # `rails g typed_eav:scaffold`
│               └── templates/             # copied verbatim into host app
│                   ├── config/initializers/typed_eav.rb
│                   ├── controllers/typed_eav_controller.rb
│                   ├── controllers/concerns/typed_eav_controller_concern.rb
│                   ├── helpers/typed_eav_helper.rb
│                   ├── javascript/controllers/typed_eav_form_controller.js
│                   ├── javascript/controllers/array_field_controller.js
│                   └── views/typed_eav/...   # admin views + per-type form/values partials
│
├── db/migrate/
│   ├── 20260330000000_create_typed_eav_tables.rb              # the four base tables + indexes
│   ├── 20260430000000_add_parent_scope_to_typed_eav_partitions.rb  # Phase 01 (concurrent DDL)
│   ├── 20260501000000_add_cascade_policy_to_typed_eav_fields.rb    # Phase 02 (FK SET NULL)
│   └── 20260505000000_create_typed_eav_value_versions.rb          # Phase 04 audit log
│
├── spec/                               # full RSpec suite (see TESTING.md)
│   ├── dummy/                          # minimal Rails app for testing
│   │   ├── app/models/test_models.rb   # Contact, Product, Project (Phase 01 two-level host)
│   │   ├── config/{boot,environment,routes,database,storage.yml}
│   │   └── db/migrate/
│   │       ├── 20260330000001_create_test_entities.rb           # Contact + Product + Project
│   │       └── 20260506000000_create_active_storage_tables.active_storage.rb  # Phase 05
│   ├── factories/typed_eav.rb
│   ├── integration/                    # full lifecycle + generators end-to-end
│   ├── lib/typed_eav/                  # query_builder, scoping, config, registry, zeitwerk,
│   │                                   # event_dispatcher, event_context, field_cascade,
│   │                                   # config_versioning, registry_versioned,
│   │                                   # versioned_concern, active_storage_soft_detect,
│   │                                   # column_mapping_value_columns
│   ├── lib/typed_eav/versioning/       # subscriber_spec.rb
│   ├── models/typed_eav/               # field, value, has_typed_eav, section_and_option,
│   │                                   # field_event, value_event, value_history,
│   │                                   # value_revert_to, value_version,
│   │                                   # value_versioning_integration
│   ├── regressions/                    # named after analysis rounds + known bugs (rounds 2–5)
│   └── spec_helper.rb
│
├── .github/workflows/                  # ci.yml (lint + matrix test) and release.yml (RubyGems)
├── .rspec
├── .rubocop.yml                        # rubocop + rails + performance + rspec plugins
├── CHANGELOG.md
├── CLAUDE.md                           # project instructions (added under v0.2.0)
├── Gemfile / Gemfile.lock
├── MIT-LICENSE
├── README.md                           # ~1200 lines, the canonical user-facing docs
├── Rakefile
├── TEST_PLAN.md                        # comprehensive test plan, per-spec-file breakdown
├── typed_eav.gemspec
├── typed_eav-0.1.0.gem                 # built artifact (committed, not necessary)
└── typed_eav-enhancement-plan.md       # phased roadmap (Phases 01–05 now shipped)
```

## File counts (post-exclusions: `.git`, `.vbw-planning`, `tmp`, `log`, etc.)

| Category | Count |
|---|---|
| Total source files | 145 |
| Ruby (`.rb`) | 91 |
| ERB templates (`.erb`, all under `lib/generators/.../templates/views/`) | 41 |
| YAML | 5 (`.rubocop.yml`, two CI workflows, dummy `database.yml`/`storage.yml`) |
| Markdown | 5 (`README.md`, `CHANGELOG.md`, `TEST_PLAN.md`, `typed_eav-enhancement-plan.md`, `CLAUDE.md`) |
| JavaScript | 2 (Stimulus controllers, scaffold templates) |

The 41 ERB files are all generator templates — they live in the gem source tree but are copied into consumer apps. The gem itself does not render any views.

## Module/namespace map

```
TypedEAV
├── ::ApplicationRecord                 # app/models/typed_eav/application_record.rb (abstract)
├── ::Config                            # lib/typed_eav/config.rb
├── ::ColumnMapping (concern)           # lib/typed_eav/column_mapping.rb
├── ::Engine                            # lib/typed_eav/engine.rb
├── ::EventDispatcher                   # lib/typed_eav/event_dispatcher.rb (Phase 03)
├── ::Field
│   ├── ::Base                          # STI parent
│   ├── ::Boolean / ::Color
│   ├── ::Currency                      # Phase 05 multi-cell
│   ├── ::Date / ::DateArray / ::DateTime
│   ├── ::Decimal / ::DecimalArray
│   ├── ::Email
│   ├── ::File / ::Image                # Phase 05 Active Storage
│   ├── ::Integer / ::IntegerArray
│   ├── ::Json / ::LongText / ::MultiSelect
│   ├── ::Percentage                    # Phase 05 extends Decimal
│   ├── ::Reference                     # Phase 05 FK
│   ├── ::Select / ::Text / ::TextArray / ::Url
├── ::Generators
│   ├── ::InstallGenerator
│   └── ::ScaffoldGenerator
├── ::HasTypedEAV                       # the macro concern, included into AR via on_load
│   ├── ::ClassQueryMethods             # extended into the host model class
│   └── ::InstanceMethods               # included into the host model
├── ::Option
├── ::QueryBuilder
├── ::Registry
├── ::ScopeRequired (StandardError)
├── ::Section
├── ::Value
│   └── ::UNSET_VALUE                   # public sentinel (frozen Object)
├── ::ValueVersion                      # Phase 04 audit log
├── ::Versioned                         # Phase 04 mixin (ActiveSupport::Concern)
├── ::Versioning
│   ├── ::register_if_enabled           # engine.rb after_initialize hook
│   └── ::Subscriber                    # call(value, change_type, context)
└── ::VERSION
```

## Inflection note

`lib/typed_eav.rb` adds an `EAV` acronym inflection at load time:

```ruby
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "EAV"
end
```

This is why `TypedEAV` (not `TypedEav`) round-trips through `underscore`/`camelize` cleanly. It also means consuming apps inherit the inflection — relevant if any host classes happen to contain "Eav" in their name.

## Constant-shadow hazards inside `module TypedEAV; module Field`

Inside `TypedEAV::Field`, bare `Integer` resolves to `TypedEAV::Field::Integer` (a Field subclass), not Ruby's `::Integer`. Same for `String`, `Date`, `DateTime`, `File`, `Json`. Code that needs the Ruby class **must** anchor with `::`:

- `Field::Reference#cast` uses `raw.is_a?(::Integer)` and `raw.is_a?(::String)` — without `::`, the check is always false.
- `Field::Image#cast` and `Field::File#cast` use `defined?(::ActiveStorage::Blob)` — top-level constant lookup.

`TypedEAV::Field::File` shadows the top-level `::File` constant inside the namespace. Internal code that needs Ruby's File class must reference it as `::File`.

## Key entry points

| What you want | Where to start |
|---|---|
| The macro a consumer calls on a model | `lib/typed_eav/has_typed_eav.rb#has_typed_eav` |
| How a single-cell field type declares itself | `app/models/typed_eav/field/integer.rb` (smallest example) |
| How a multi-cell field type declares itself | `app/models/typed_eav/field/currency.rb` |
| How an Active Storage field type declares itself | `app/models/typed_eav/field/image.rb` |
| How a query operator becomes SQL | `lib/typed_eav/query_builder.rb#filter` |
| Schema | `db/migrate/20260330000000_create_typed_eav_tables.rb` (base), Phase 01–04 incremental migrations |
| Two-axis scope resolution rules | `lib/typed_eav/has_typed_eav.rb#resolve_scope` (lines 339–413) |
| Three-way name-collision precedence | `lib/typed_eav/has_typed_eav.rb.definitions_by_name` (lines 57–61) |
| Value casting & validation flow | `app/models/typed_eav/value.rb` + `app/models/typed_eav/field/base.rb#validate_typed_value` |
| Event dispatch | `lib/typed_eav/event_dispatcher.rb` + `app/models/typed_eav/value.rb#_dispatch_value_change_*` + `app/models/typed_eav/field/base.rb#_dispatch_field_change` |
| Versioning subscriber | `lib/typed_eav/versioning/subscriber.rb` (registered via `lib/typed_eav/versioning.rb#register_if_enabled` from `engine.rb`) |
| Cascade policy on Field destroy | `app/models/typed_eav/field/base.rb#dispatch_field_dependent` |
| Display ordering | `app/models/typed_eav/field/base.rb` and `app/models/typed_eav/section.rb` (both implement the same five movement methods + private `reorder_within_partition`) |
| Default-value backfill | `app/models/typed_eav/field/base.rb#backfill_default!` |
| Active Storage soft-detect | `lib/typed_eav/engine.rb#register_attachment_associations!` |
| End-to-end behavior | `spec/integration/typed_eav_lifecycle_spec.rb` |
