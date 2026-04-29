# TypedEAV Enhancement Plan

A phased plan for extending the `typed_eav` gem with capabilities that benefit any consuming application. All additions must remain general-purpose and must preserve the gem's foundational contract.

> Reconciled against the codebase mapping at `.vbw-planning/codebase/` (Apr 2026). Items that were originally written as "add a new column / new feature" but where the underlying infrastructure already exists have been reframed as "complete the pipeline." Cross-references to specific files and line numbers point at the v0.1.0 codebase. Execution order is captured separately in `.vbw-planning/ROADMAP.md`.

---

## Foundational principle (non-negotiable)

The gem exists so that **end users of a consuming app** can define their own attributes at runtime. The application code built on top of the gem must never hardcode references to specific user-created attributes; doing so defeats the entire purpose of the EAV pattern.

Concretely, this means:

- The gem never ships features that assume specific attribute names, types, or semantics
- The gem never provides DSLs that encourage developers to write code like `entity.revenue` or `entity.industry`, where `revenue` and `industry` are user-defined attributes
- All access to user-defined attribute values goes through generic accessors (`typed_eav_value("name")`, `with_field("name", op, value)`, `typed_eav_hash`)
- All new field types, operators, and helpers must work for arbitrary attribute names supplied by end users at runtime
- Any feature that requires "knowing about" a specific attribute must take the attribute identifier as a parameter, never as a hardcoded reference

If a feature can only be useful when the developer hardcodes a specific attribute name in app code, that feature does not belong in the gem.

---

## Phase 1: Foundational extensions

Core capabilities that broaden the gem's applicability without altering its existing contract.

- **Two-level scope partitioning**
  - Today fields are partitioned by `entity_type` and a single `scope` column.
  - Many apps need two-level partitioning (org/team, account/project, tenant/workspace).
  - **This is the largest single milestone in Phase 1.** Change-surface includes:
    - `lib/typed_eav.rb` — extend ambient resolver (`current_scope`) to a tuple, add `with_parent_scope`, integrate with `unscoped`.
    - `lib/typed_eav/has_typed_eav.rb` — extend the `has_typed_eav` macro with `parent_scope_method:`; extend `resolve_scope` (lines 246–279); extend predicate construction in `where_typed_eav` (single-scope and `unscoped` multimap branches); extend the `for_entity` Field scope.
    - `app/models/typed_eav/value.rb` — extend `validate_field_scope_matches_entity` (line 138) to verify both scope keys.
    - `app/models/typed_eav/section.rb` — `typed_eav_sections` ALSO has a `scope` column with paired partial unique indexes (`section.rb` line 13, `for_entity` at line 20). Sections must gain `parent_scope` symmetrically with fields.
    - Migration — add `parent_scope` to BOTH `typed_eav_fields` AND `typed_eav_sections`; add new paired partial unique indexes for `(name, entity_type, scope, parent_scope)` and `(entity_type, code, scope, parent_scope)`.
    - All scoping specs under `spec/regressions/review_round_*_scope*` and `spec/lib/typed_eav/scoping_spec.rb`.
  - **Canonical partition tuple:** `(entity_type, scope, parent_scope)`.
  - **Composite resolution semantics:** `parent_scope` narrows further within `scope`. `nil parent_scope` means "all parents within scope." When `scope` is nil (global), `parent_scope` must also be nil — no orphan-parent rows.
  - **Sentinel/kwarg semantics:** the existing `UNSET_SCOPE`/`ALL_SCOPES` sentinel pattern (`has_typed_eav.rb` lines 99–104) extends to a parent-scope sentinel; the `unscoped { }` block continues to bypass both scope keys atomically.
  - Opt-in via `has_typed_eav scope_method: :tenant_id, parent_scope_method: :project_id`. Single-scope users see no API change; the new column is nullable.

- **Display ordering on Field**
  - The `typed_eav_fields.sort_order` column already exists (`db/migrate/20260330000000_create_typed_eav_tables.rb` line 45) and is used by `Field::Base.sorted` (`app/models/typed_eav/field/base.rb` line 49), the `idx_te_fields_lookup` covering index (migration line 66), the scaffold form (`lib/generators/typed_eav/scaffold/templates/views/typed_eav/forms/_common_fields.html.erb` line 55), and `render_typed_value_inputs` (`lib/generators/typed_eav/scaffold/templates/helpers/typed_eav_helper.rb` line 24). **Do not add a parallel `position` column.**
  - Add `acts_as_list`-style helpers on top of the existing `sort_order`: `move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at(n)`.
  - Add `Field.ordered` as an alias of `Field.sorted` (preserve the existing scope name for backwards compatibility).
  - Position is per `(entity_type, scope, parent_scope)` combination — see the two-level scope item above for `parent_scope`.

- **Default values on Field**
  - The infrastructure already exists: `typed_eav_fields.default_value_meta` jsonb column (migration line 51, stored as `{"v": <raw>}`), `Field::Base#default_value` / `default_value=` accessors (`app/models/typed_eav/field/base.rb` lines 56–62), `validate_default_value` runs `cast` to detect invalid defaults (line 211), and `InstanceMethods#initialize_typed_values` builds new typed_values with `field.default_value` (`lib/typed_eav/has_typed_eav.rb` line 307). **Do not add a new column.**
  - Complete the auto-populate pipeline: add a `before_validation` on `Value` that fills the typed column from `field.default_value` when (a) the record is new, (b) the typed column is unset, AND (c) the caller did not explicitly assign a value. This covers non-form code paths (e.g. `typed_values.create(field: f)` without a value) that bypass `initialize_typed_values`.
  - **Sentinel decision (must land before code):** auto-populate must distinguish "value never assigned" from "value explicitly set to nil." Mirror the existing `UNSET_SCOPE` sentinel pattern (`lib/typed_eav/has_typed_eav.rb` lines 99–104). Without this distinction, a user explicitly clearing a value to nil would get the default re-applied — wrong.
  - `Field#backfill_default!` for retroactive backfill on existing records when a field's default is added or changed. Explicit call only, never automatic. Idempotent: skip records that already have a non-nil typed value.
  - Existing default-value type validation (`validate_default_value`) is preserved.

- **Built-in versioning at the Value level**
  - Optional `TypedEAV::Versioned` concern that adds a `typed_eav_value_versions` table
  - Each version row captures: `value_id`, `field_id`, polymorphic entity reference, `changed_by` (configurable resolver), `before_value`, `after_value`, `changed_at`, `change_type` (create/update/destroy)
  - Opt-in per app via `TypedEAV.configure { |c| c.versioning = true }`
  - Provide a `Value#history` association and a `Value#revert_to(version)` method
  - Default storage strategy: event log. Document the snapshot pattern as an extension for apps with large history volumes
  - Configurable `changed_by` resolver via `TypedEAV.config.actor_resolver = -> { Current.user&.id }`
  - Branching and merging are explicit non-goals in v1

- **Configurable cascade behavior on Field destroy**
  - **Current state correction:** the cascade is already `:destroy` today, at TWO levels:
    - Rails: `Field::Base has_many :values, dependent: :destroy` (`app/models/typed_eav/field/base.rb` line 19).
    - DB FK: `foreign_key: { to_table: :typed_eav_fields, on_delete: :cascade }` (migration line 88).
    - Spec coverage: `spec/models/typed_eav/has_typed_eav_spec.rb` line 340 verifies field destroy removes values.
  - The "orphans skipped on read" guard in `typed_eav_value` and `typed_eav_hash` is a defensive read-path safeguard for edge cases (raw SQL deletes, dev-mode reload churn, partial replication) — NOT the operational default.
  - Add a configurable cascade choice on `has_typed_eav` (e.g. `field_dependent: :destroy | :nullify | :restrict_with_error`). Default remains `:destroy` (preserves current behavior).
  - **`:nullify` requires two coordinated migration changes**, not just dropping the FK cascade:
    1. Make `typed_eav_values.field_id` nullable (it is `null: false` today; see migration line 88).
    2. Change the FK from `on_delete: :cascade` to `on_delete: :nullify` (or remove and re-add).
    Document the migration path for existing installs explicitly.
  - `:restrict_with_error` blocks destroy with `errors[:base]` populated.

---

## Phase 2: Field type expansion

New field types that broaden the range of data that can be modeled. Each new type must work for arbitrary user-defined attributes.

- **Image/Attachment field type**
  - New `TypedEAV::Field::Image` and `TypedEAV::Field::File` types.
  - Each Value `has_one_attached` for the typed image/file column via Active Storage.
  - Storage column references the blob signed_id (likely `string_value`; confirm at milestone start).
  - Field options: `max_size`, `allowed_content_types`, `auto_process_variants` (boolean).
  - **Active Storage operational dependency:** consumers must have Active Storage tables (`active_storage_blobs`, `active_storage_attachments`) installed in the host app. The gemspec currently declares only `rails >= 7.1` (`typed_eav.gemspec` line 34). **Decision required at milestone start:** either (a) hard-depend on Active Storage being installed and fail fast with an install message, or (b) lazy-load these field types via `defined?(::ActiveStorage::Blob)` mirroring the `acts_as_tenant` auto-detect pattern in `Config::DEFAULT_SCOPE_RESOLVER` (`lib/typed_eav/config.rb` line 22). Recommend (b) for consistency with the existing soft-dependency pattern.
  - Variant generation lives in the consuming app via a configurable hook: `TypedEAV.config.on_image_attached = ->(value, blob) { ... }`.
  - The gem ships no image processing logic; it ships the storage primitive and the hook.
  - The hook receives the Value and blob, never specific attribute names.

- **Reference field type**
  - New `TypedEAV::Field::Reference` that stores a foreign key to another entity within the same partition.
  - Stored in `integer_value` or `string_value` depending on the target's primary key type.
  - Field options: `target_entity_type`, `target_scope` (defaults to the field's own scope).
  - Adds a `:references` operator and an eager-loading helper: `Entity.with_field("any_field_name", :references, other_entity)`.
  - **Cross-scope safety validation:** mirror the existing `Value#validate_field_scope_matches_entity` pattern (`app/models/typed_eav/value.rb` line 138). When a Reference Value is set, validate that the referenced entity's `typed_eav_scope` matches the field's `target_scope`. Reject the assignment otherwise — the same fail-closed posture used for field-vs-entity scope mismatch. Specify behavior for unscoped target entity types explicitly (a Reference whose target type does NOT declare `has_typed_eav scope_method:` should permit any partition's caller, since the target has no scope of its own).
  - The field name is supplied by the end user; the gem never assumes specific names.

- **Currency field type**
  - Stores amount + currency code in `decimal_value` (amount) + `string_value` (currency code).
  - **This is the only field type that uses two typed columns per Value row.** The current convention is one typed column per row (see migration line 90 comment, and `Value#value` reading a single `value_column` at `app/models/typed_eav/value.rb` line 32). Currency must define explicitly:
    - `value` shape: a structured `{amount, currency}` Ruby object/struct, returned by a Currency-specific override of `Value#value` (or by the field type's accessor layer).
    - Operators it supports: `:eq`, `:gt`, `:lt`, `:gteq`, `:lteq`, `:between` on amount; `:eq` on currency code.
    - Validation: both cells must be co-populated; currency code must be in `allowed_currencies`; cross-cell consistency enforced at save.
    - Indexing: keep native B-tree on `decimal_value` (already in place); plain btree on `string_value` is fine for currency-code filters.
    - Alternative considered: storing in `json_value` as `{amount, currency}`. Rejected because it loses native amount indexing (the entire point of typed columns).
  - Field options: `default_currency`, `allowed_currencies`.
  - Formatting helper takes (value, locale) and emits a string — does not assume display context.

- **Percentage field type**
  - Stores 0-1 decimal value with display metadata
  - Field options: `decimal_places`, `display_as` (`:fraction` or `:percent`)
  - Thin wrapper around Decimal with consistent formatting

> Note: A calculated/computed field type is planned as a separate, larger feature with its own design document. See `typed_eav-calculated-fields-plan.md`.

---

## Phase 3: Bulk operations and import/export

Generic primitives for moving data in and out of the EAV store. None of these features assume specific attributes; all operate on arbitrary user-defined schemas.

- **Bulk attribute assignment**
  - `Entity.bulk_set_typed_eav_values(records, values_by_field_name)` for batch updates
  - Batches inserts/updates to avoid N+1
  - Wraps in a single transaction
  - When versioning is enabled, supports a "batch" version mode that creates one version per record rather than per field change, configurable via a `version_grouping:` option
  - Returns a result object with successes and per-record errors

- **Schema export and import**
  - `Field.export_schema(entity_type:, scope:, parent_scope:)` returns a serializable hash containing all field definitions, their options, `default_value_meta`, section associations, and (for select/multi-select) their options/choices.
  - `Field.import_schema(hash, entity_type:, scope:, parent_scope:)` recreates fields idempotently.
  - **Idempotence key:** `(name, entity_type, scope, parent_scope)`. The current schema enforces field-name uniqueness within a scope via paired partial indexes (migration line 57). Two scopes can hold same-named fields — keying idempotence on field name alone would collapse two tenants' identically-named fields into one on import.
  - Useful for templating, seeding, dataset duplication, environment-to-environment migration.
  - Schema export does not include data values, only the schema structure.

- **CSV mapping helper**
  - `TypedEAV::CSVMapper` utility takes a CSV row plus a column-to-field mapping and produces nested attributes ready for `typed_eav_attributes=`
  - Type coercion routed through the existing field type system
  - Returns per-row errors for invalid values rather than failing the whole import
  - The mapping itself is supplied by the consuming app; the gem provides the coercion and error reporting layer
  - The mapping is a hash of CSV column name to field name, both supplied at runtime

- **Bulk read API**
  - `Entity.typed_eav_hash_for(records)` returns a hash of `{ entity_id => { field_name => value, ... } }` in a single query
  - Avoids N+1 when serializing many records with all their custom field values
  - Internally uses preloaded values; respects scope

---

## Phase 4: Query and rendering optimization

Performance primitives for read-heavy use cases.

- **Eager-load helpers**
  - **Reframe:** the underlying preload-aware behavior is already partly implemented. `InstanceMethods#typed_eav_hash` and `typed_eav_value` use `loaded_typed_values_with_fields` (`lib/typed_eav/has_typed_eav.rb` lines 464–473), which respects an already-loaded `typed_values` association if the caller preloaded with `includes(typed_values: :field)`. README §"Forms" line 251 already documents this manual pattern.
  - This phase ships the ergonomic API, not new caching logic:
    - `Entity.with_all_typed_values` scope wrapping `includes(typed_values: :field)`.
    - Optionally surface `typed_eav_hash_cached` as a public alias of `typed_eav_hash` (they are functionally equivalent under preload).
  - Avoids the N+1 trap when rendering many records with all their custom fields.

- **Materialized value index (optional Postgres feature)**
  - Optional `typed_eav_value_index_<entity>` materialized view per `(entity_type, scope, parent_scope)` flattening the EAV structure into a wide table.
  - Opt-in via `TypedEAV.config.materialize_index = true` since it adds storage cost.
  - **Dependency:** Phase 5 field-change events must exist before this milestone. The view depends on `on_field_change` to trigger DDL regeneration.
  - **Refresh strategy** (must be specified, not handwaved):
    - DDL regeneration: triggered on `on_field_change` for `:create`/`:destroy`/`:rename`. Runs via Active Job by default; falls back to inline-sync when Active Job is unavailable so the gem never hard-depends on a job system.
    - Data refresh: `REFRESH MATERIALIZED VIEW CONCURRENTLY typed_eav_value_index_<entity>` on a configurable schedule (default: every 5 minutes), or on demand.
  - **SQL-injection safety on column generation:** field names are runtime user data with minimal name constraints today (validation only excludes `RESERVED_NAMES` from `Field::Base`). Generating column DDL from arbitrary field names is unsafe without an identifier-quoting and whitelist strategy. Specify: (a) for fields targeted by materialization, restrict the name to `[A-Za-z0-9_]` and reject reserved SQL identifiers; (b) always quote with PG `format("%I", name)`; (c) reject names that would generate ambiguous SQL or collide with synthetic columns.
  - Significant query speedup for bulk reads, analytics, and dashboard use cases.
  - The view is generated from the schema; the consuming app does not need to define columns by hand.

- **Query result caching primitives**
  - `Field#cache_version` returns a stable cache key fragment that invalidates when the field definition changes
  - `Value#cache_version` invalidates on value change
  - Helper: `TypedEAV.cache_key_for(entity, field_names)` builds a composite cache key from current field versions
  - Lets consuming apps wrap `where_typed_eav` results in `Rails.cache.fetch` with correct invalidation
  - The gem provides the cache key generation; cache strategy stays with the consuming app

- **Query plan helpers**
  - **`.explain` already works:** `with_field` and `where_typed_eav` return ActiveRecord relations (`lib/typed_eav/has_typed_eav.rb` line 215), so `Entity.with_field(...).explain` is available today via Rails' built-in Relation#explain. Keep this plan item only if a TypedEAV-specific interpretation is added (e.g., highlighting which `idx_te_values_field_*` indexes were used, summarizing scope hits, calling out missed covering-index opportunities). Otherwise drop.
  - `TypedEAV.benchmark(name) { block }` utility for measuring EAV query performance — wraps `Benchmark.realtime` with EAV-aware structured output (counts of value rows touched, fields touched, scope hits).
  - Useful for any app validating that typed-column performance gains are real for their workload.

---

## Phase 5: Event system

Generic event primitives that let consuming apps react to changes in the EAV store. The gem ships the events; what the app does with them (real-time UI, audit feeds, cache invalidation, downstream triggers) stays in the app.

- **Value change events**
  - Configurable callback: `TypedEAV.config.on_value_change = -> (value, change_type, context) { ... }`
  - Fires after_commit on Value saves
  - `change_type` is one of `:create`, `:update`, `:destroy`
  - `context` is a hash that consuming apps can populate via `TypedEAV.with_context(source: :user) { ... }` so the callback knows the origin of the change
  - The callback receives the Value and Field; the consuming app inspects the field name at runtime if needed, never hardcoded

- **Field change events**
  - Companion callback: `TypedEAV.config.on_field_change = -> (field, change_type) { ... }`
  - Fires when fields are created, updated, or destroyed
  - Useful for invalidating caches, recomputing dependent calculated fields, refreshing materialized views, and similar reactive concerns

---

## Cross-cutting requirements

The following apply to every phase:

- **No hardcoded attribute references in any gem code**
  - All accessors take field names or field IDs as parameters
  - All callbacks receive the Value and Field as parameters; consuming code inspects them at runtime
  - All examples in documentation use generic placeholders like `"any_field_name"` to reinforce the runtime-defined nature of attributes

- **Backwards compatibility**
  - Every phase must ship without breaking the existing public API
  - New columns are added with safe defaults
  - New features are opt-in via configuration
  - Migration scripts handle the transition for existing installs

- **Database support**
  - **Postgres-only** for the foreseeable future. Existing PG-specific features (jsonb `@>` containment for array operators, `text_pattern_ops` btree opclass, partial unique indexes for nullable scope columns, GIN partial index, `INCLUDE` covering indexes) plus Phase 1's two-level scope (more partial indexes) plus Phase 4's materialized views together make MySQL/SQLite a near-rewrite. README already states "Requires PostgreSQL" (`README.md` line 481).
  - Document Postgres-specific capabilities clearly in feature docs; do not pretend to support other adapters.
  - If a host app needs adapter-portable EAV, that is a different gem.

- **Testing discipline**
  - Every new feature ships with specs that exercise the runtime-defined-attribute contract
  - Spec scenarios use arbitrary field names to verify nothing in the gem assumes specific attributes
  - Performance regressions are caught by benchmark specs on the query DSL

- **Documentation discipline**
  - Every new feature documents its intended use case generically
  - Examples in README and inline docs use placeholder field names
  - The principle from the top of this document is restated in the documentation for each phase
