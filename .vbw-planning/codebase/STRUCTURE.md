# STRUCTURE.md

## Top-level layout

```
gem/
├── app/                                # AR models exposed to host apps via the engine
│   └── models/
│       └── typed_eav/
│           ├── application_record.rb   # abstract base
│           ├── field/                  # STI hierarchy (one file per type)
│           │   ├── base.rb             # STI parent (~664 lines); includes Field::TypedStorage;
│           │   │                       # validations, cast contract, cascade dispatch,
│           │   │                       # partition-aware ordering, default-value handling,
│           │   │                       # backfill_default!, display_name, _dispatch_field_change
│           │   ├── validated_string.rb # ADR-0004 family base (class): Text/Email/Url
│           │   ├── range_bounded.rb    # ADR-0004 family base (class): Integer/Decimal/Date/DateTime
│           │   ├── optionable.rb       # ADR-0004 family base (concern): Select/MultiSelect
│           │   ├── text.rb / email.rb / url.rb           # < ValidatedString
│           │   ├── integer.rb / decimal.rb / date.rb / date_time.rb   # < RangeBounded
│           │   ├── percentage.rb       # < Decimal < RangeBounded (0..1 fraction + format)
│           │   ├── select.rb / multi_select.rb           # include Optionable
│           │   ├── integer_array.rb / decimal_array.rb / text_array.rb / date_array.rb
│           │   ├── boolean.rb / color.rb / json.rb       # true stubs, direct < Base
│           │   ├── long_text.rb
│           │   ├── currency.rb         # multi-cell: decimal_value + string_value (ADR-0001 shape)
│           │   ├── reference.rb        # FK + :references operator (shadows ::Integer)
│           │   ├── file.rb             # Active Storage signed_id (shadows ::File)
│           │   └── image.rb            # Active Storage signed_id + on_image_attached
│           ├── option.rb               # per-field allowed values for select/multi_select
│           ├── section.rb              # optional UI grouping; partition-aware ordering helpers
│           ├── value.rb                # one row per (entity, field); typed columns; UNSET_VALUE
│           │                          # sentinel; history/revert_to; after_commit dispatch
│           └── value_version.rb       # Phase 04 audit log row (+ version_group_id Phase 06)
│
├── lib/
│   ├── typed_eav.rb                    # module entry: configure, current_scope, with_scope,
│   │                                  # unscoped, normalize_scope (BC alias → ScopeTuple),
│   │                                  # with_context, current_context; EAV inflection
│   ├── typed_eav/
│   │   ├── engine.rb                   # Rails::Engine; eager-requires field/typed_storage,
│   │   │                              # config, registry, event_dispatcher; two
│   │   │                              # config.after_initialize blocks (Versioning + AS)
│   │   ├── config.rb                   # singleton: field_types, scope_resolver, require_scope,
│   │   │                              # versioning, actor_resolver, on_* user procs
│   │   ├── registry.rb                 # singleton: registered entities + types allow-list +
│   │   │                              # versioned? per-entity flag
│   │   ├── scope_tuple.rb              # #10 — tuple coercion: normalize_permissive (BC),
│   │   │                              # normalize_strict (resolver contract), invariant_satisfied?
│   │   ├── has_typed_eav.rb            # the macro + macro-time guards (~117 lines)
│   │   ├── has_typed_eav/
│   │   │   └── instance_methods.rb     # per-record API: typed_eav_value/_hash, set_typed_eav_value,
│   │   │                              # typed_eav_attributes=, initialize_typed_values (G2 dedup)
│   │   ├── entity_query.rb             # ADR-0002 — class-level orchestration extended onto host;
│   │   │                              # owns UNSET_SCOPE/ALL_SCOPES + resolve_scope; delegates
│   │   │                              # to FilterQuery / BulkRead / BulkWrite
│   │   ├── filter_query.rb             # ADR-0002 — multi-filter SQL composition; include_missing
│   │   │                              # set-complement (ADR-0006); multimap vs single-scope branch
│   │   ├── query_builder.rb            # low-level per-field operator dispatch (one case statement);
│   │   │                              # entity_ids projection; operator_column routing
│   │   ├── partition.rb                # ADR-0002 — partition-aware visibility + collision
│   │   │                              # precedence (definitions_by_name / _multimap_by_name)
│   │   ├── bulk_read.rb                # Phase 06 — class-method bulk hash reads (N+1-free)
│   │   ├── bulk_write.rb               # Phase 06 — bulk write executor (execute / execute_per_record)
│   │   ├── csv_mapper.rb               # Phase 06 — pure stateless CSV→attributes transform
│   │   ├── schema_portability.rb       # Phase 06 — export/import + export_snapshot_schema (G4)
│   │   ├── event_dispatcher.rb         # Phase 03 in-process pub/sub hub (ADR-0003)
│   │   ├── version.rb                  # TypedEAV::VERSION = "0.4.0"
│   │   ├── versioned.rb                # Phase 04 mixin (post-has_typed_eav opt-in)
│   │   ├── versioning.rb               # Phase 04 namespace + register_if_enabled helper
│   │   ├── versioning/
│   │   │   └── subscriber.rb           # Phase 04 internal subscriber; Phase 06 version_group_id stamp
│   │   └── field/
│   │       └── typed_storage.rb        # ADR-0001 — the entire storage seam (one concern)
│   └── generators/
│       └── typed_eav/
│           ├── install/install_generator.rb     # `rails g typed_eav:install`
│           └── scaffold/
│               ├── scaffold_generator.rb        # `rails g typed_eav:scaffold`
│               └── templates/                    # copied verbatim into host app
│                   ├── config/initializers/typed_eav.rb
│                   ├── controllers/typed_eav_controller.rb
│                   ├── controllers/concerns/typed_eav_controller_concern.rb
│                   ├── helpers/typed_eav_helper.rb
│                   ├── javascript/controllers/{typed_eav_form,array_field}_controller.js
│                   └── views/typed_eav/...        # admin views + per-type form/values partials
│
├── db/migrate/                         # 6 migrations
│   ├── 20260330000000_create_typed_eav_tables.rb                          # base four tables + indexes
│   ├── 20260430000000_add_parent_scope_to_typed_eav_partitions.rb         # Phase 01 (concurrent DDL)
│   ├── 20260501000000_add_cascade_policy_to_typed_eav_fields.rb           # Phase 02 (FK SET NULL)
│   ├── 20260505000000_create_typed_eav_value_versions.rb                  # Phase 04 audit log
│   ├── 20260506000001_add_version_group_id_to_typed_eav_value_versions.rb # Phase 06 (uuid, concurrent)
│   └── 20260507000000_add_label_to_typed_eav_fields.rb                    # Phase 08 (nullable label)
│
├── docs/
│   ├── adr/                            # ADRs 0001–0006 (0.3.0–0.4.0 arc)
│   └── goals/refactor-0-3-0/           # GoalBuddy artifacts for the 0.3.0 arc
│
├── spec/                               # 48 spec files (see TESTING.md)
│   ├── dummy/                          # minimal Rails app for testing
│   ├── factories/typed_eav.rb
│   ├── integration/                    # lifecycle + generators + generated-scaffold-behavior
│   ├── lib/typed_eav/                  # /lib unit specs (incl. typed_storage, entity_query,
│   │                                   #  filter_query, partition, scope_tuple, bulk_*, csv_mapper,
│   │                                   #  schema_portability, bulk_operations)
│   ├── lib/typed_eav/versioning/       # subscriber_spec.rb
│   ├── models/typed_eav/               # AR-model specs (incl. field/{optionable,range_bounded,
│   │                                   #  validated_string}, field_schema, bulk_read)
│   ├── regressions/                    # review_round_2–5 + known_bugs + issue_21_label_no_rename
│   └── spec_helper.rb
│
├── .github/workflows/                  # ci.yml (lint + matrix test) and release.yml (RubyGems)
├── .rspec / .rubocop.yml
├── AGENTS.md                           # Codex/agent operating notes
├── CHANGELOG.md / CLAUDE.md / CONTEXT.md
├── Gemfile / Gemfile.lock / MIT-LICENSE / Rakefile
├── README.md                           # ~1200+ lines, the canonical user-facing docs
├── TEST_PLAN.md / typed_eav-enhancement-plan.md
└── typed_eav.gemspec
```

## File counts (post-exclusions: `.git`, `.vbw-planning`)

| Category | Count |
|---|---|
| Ruby (`.rb`) | 120 |
| ERB templates (generator view templates) | 41 |
| Spec files (`*_spec.rb`) | 48 |
| Built-in field types | 22 (+ 3 family bases: ValidatedString, RangeBounded, Optionable) |
| Migrations | 6 |
| ADRs | 6 |

The 41 ERB files are all generator templates — they live in the gem source tree but are copied into consumer apps. The gem itself renders no views.

## Module/namespace map

```
TypedEAV
├── ::ApplicationRecord                 # abstract
├── ::Config / ::Registry / ::Engine
├── ::ScopeTuple                        # #10 tuple coercion
├── ::EventDispatcher                   # Phase 03 (ADR-0003)
├── ::EntityQuery                       # ADR-0002 class-query orchestration (owns UNSET_SCOPE/ALL_SCOPES)
├── ::FilterQuery / ::QueryBuilder      # ADR-0002 two-altitude query split
├── ::Partition                         # ADR-0002 partition visibility + collision precedence
├── ::BulkRead / ::BulkWrite / ::CSVMapper / ::SchemaPortability   # Phase 06 (ADR-0005)
├── ::Field
│   ├── ::TypedStorage (concern)        # ADR-0001 storage seam
│   ├── ::Base                          # STI parent (includes TypedStorage)
│   ├── ::ValidatedString               # family base → Text, Email, Url
│   ├── ::RangeBounded                  # family base → Integer, Decimal, Date, DateTime
│   ├── ::Optionable (concern)          # → Select, MultiSelect
│   ├── ::Percentage                    # < Decimal
│   ├── ::Currency / ::Reference / ::Image / ::File   # multi-cell + AS
│   ├── ::Boolean / ::Color / ::Json    # true stubs
│   └── ::{Integer,Decimal,Text,Date}Array / ::LongText
├── ::Generators::{Install,Scaffold}Generator
├── ::HasTypedEAV                       # macro concern; ::InstanceMethods
├── ::Option / ::Section
├── ::ScopeRequired (StandardError)
├── ::Value (::UNSET_VALUE) / ::ValueVersion
├── ::Versioned / ::Versioning (::register_if_enabled, ::Subscriber)
└── ::VERSION
```

## Inflection note

`lib/typed_eav.rb` adds an `EAV` acronym inflection at load time so `TypedEAV` round-trips through `underscore`/`camelize`. Consuming apps inherit the inflection — relevant if a host class contains "Eav".

## Constant-shadow hazards inside `module TypedEAV; module Field`

Inside `TypedEAV::Field`, bare `Integer`/`String`/`Date`/`DateTime`/`File`/`Json` resolve to the `TypedEAV::Field::*` subclasses, NOT Ruby's top-level constants. Code needing the Ruby class **must** anchor with `::` (e.g. `Field::Reference#cast` uses `raw.is_a?(::Integer)`; `Field::Image`/`File` use `defined?(::ActiveStorage::Blob)`). `TypedEAV::Field::File` shadows top-level `::File`.

## Key entry points

| What you want | Where to start |
|---|---|
| The macro a consumer calls | `lib/typed_eav/has_typed_eav.rb#has_typed_eav` |
| Class-level query orchestration | `lib/typed_eav/entity_query.rb` |
| Multi-filter SQL composition + include_missing | `lib/typed_eav/filter_query.rb` |
| How a single operator becomes SQL | `lib/typed_eav/query_builder.rb#filter` |
| Partition visibility + collision precedence | `lib/typed_eav/partition.rb` |
| Scope-tuple coercion (strict vs permissive) | `lib/typed_eav/scope_tuple.rb` |
| The storage seam (single/multi-cell columns) | `lib/typed_eav/field/typed_storage.rb` |
| How a single-cell field type declares itself | `app/models/typed_eav/field/integer.rb` (now `< RangeBounded`) |
| How a multi-cell field type declares itself | `app/models/typed_eav/field/currency.rb` |
| Family extension bases | `field/validated_string.rb`, `field/range_bounded.rb`, `field/optionable.rb` |
| Bulk reads / writes | `lib/typed_eav/bulk_read.rb`, `lib/typed_eav/bulk_write.rb` |
| CSV import transform / schema export-import | `lib/typed_eav/csv_mapper.rb`, `lib/typed_eav/schema_portability.rb` |
| Field display label | `app/models/typed_eav/field/base.rb#display_name` |
| Value casting & validation flow | `app/models/typed_eav/value.rb` + `field/base.rb#validate_typed_value` |
| Versioning subscriber | `lib/typed_eav/versioning/subscriber.rb` |
| Schema | `db/migrate/*` (6 migrations) |
| End-to-end behavior | `spec/integration/typed_eav_lifecycle_spec.rb` |
