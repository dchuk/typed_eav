# TypedEAV Enhancement Plan

A phased plan for extending the `typed_eav` gem with capabilities that benefit any consuming application. All additions must remain general-purpose and must preserve the gem's foundational contract.

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
  - Today fields are partitioned by `entity_type` and a single `scope` column
  - Many apps need two-level partitioning (org/team, account/project, tenant/workspace)
  - Add an optional `parent_scope` column to `typed_eav_fields` and extend the resolver chain to read both
  - Opt-in via `has_typed_eav scope_method: :tenant_id, parent_scope_method: :project_id`
  - Single-scope users see no API change
  - Composite resolution: parent_scope narrows further within scope; nil parent_scope means "all parents within scope"

- **Display ordering on Field**
  - Add a `position` column to `typed_eav_fields` with `acts_as_list`-style helpers (`move_higher`, `move_lower`, `insert_at`)
  - Add a `Field.ordered` scope that returns fields in user-configured order
  - Used by any UI that renders fields in a deterministic, user-controlled sequence
  - Position is per `entity_type` + `scope` combination

- **Default values on Field**
  - New `default_value` column on `typed_eav_fields` (json type to handle all field types uniformly)
  - When a Value record is created without an explicit value, populate from the field's default
  - When a new Field is added to an entity_type with existing records, optionally backfill values with the default via `Field#backfill_default!` (explicit call, never automatic, to avoid surprise writes)
  - Default values respect the field's type validation rules

- **Built-in versioning at the Value level**
  - Optional `TypedEAV::Versioned` concern that adds a `typed_eav_value_versions` table
  - Each version row captures: `value_id`, `field_id`, polymorphic entity reference, `changed_by` (configurable resolver), `before_value`, `after_value`, `changed_at`, `change_type` (create/update/destroy)
  - Opt-in per app via `TypedEAV.configure { |c| c.versioning = true }`
  - Provide a `Value#history` association and a `Value#revert_to(version)` method
  - Default storage strategy: event log. Document the snapshot pattern as an extension for apps with large history volumes
  - Configurable `changed_by` resolver via `TypedEAV.config.actor_resolver = -> { Current.user&.id }`
  - Branching and merging are explicit non-goals in v1

- **Configurable cascade behavior on Field destroy**
  - Today orphaned values are silently skipped on read but never cleaned up
  - Add `dependent:` semantics on Field: `:destroy` (delete values), `:nullify` (current behavior), `:restrict_with_error`
  - Default to `:destroy` for new installs since it matches developer expectations
  - Document the migration path for existing installs that depend on the current orphan-tolerant behavior

---

## Phase 2: Field type expansion

New field types that broaden the range of data that can be modeled. Each new type must work for arbitrary user-defined attributes.

- **Image/Attachment field type**
  - New `TypedEAV::Field::Image` and `TypedEAV::Field::File` types
  - Each Value `has_one_attached` for the typed image/file column via Active Storage
  - Storage column references the blob signed_id
  - Field options: `max_size`, `allowed_content_types`, `auto_process_variants` (boolean)
  - Variant generation lives in the consuming app via a configurable hook: `TypedEAV.config.on_image_attached = ->(value, blob) { ... }`
  - The gem ships no image processing logic; it ships the storage primitive and the hook
  - The hook receives the Value and blob, never specific attribute names

- **Reference field type**
  - New `TypedEAV::Field::Reference` that stores a foreign key to another entity within the same partition
  - Stored in `integer_value` or `string_value` depending on the target's primary key type
  - Field options: `target_entity_type`, `target_scope` (defaults to the field's own scope)
  - Adds a `:references` operator and an eager-loading helper: `Entity.with_field("any_field_name", :references, other_entity)`
  - The field name is supplied by the end user; the gem never assumes specific names

- **Currency field type**
  - Stores amount + currency code (two columns or a structured value)
  - Field options: `default_currency`, `allowed_currencies`
  - Formatting helper available but does not assume display context

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
  - `Field.export_schema(entity_type:, scope:)` returns a serializable hash containing all field definitions, their options, and (for select/multi-select) their options/choices
  - `Field.import_schema(hash, entity_type:, scope:)` recreates fields, idempotent on field name match
  - Useful for templating, seeding, dataset duplication, environment-to-environment migration
  - Schema export does not include data values, only the schema structure

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
  - `Entity.with_all_typed_values` scope that preloads `typed_values` joined with `field` in one query
  - `Entity#typed_eav_hash_cached` that uses the preloaded association rather than re-querying
  - Avoids the N+1 trap when rendering many records with all their custom fields

- **Materialized value index (optional Postgres feature)**
  - Optional `typed_eav_value_index` materialized view flattening the EAV structure into a wide table per entity_type
  - Generated dynamically based on registered fields per scope
  - Refreshed on Value mutations or on a configurable schedule
  - Significant query speedup for bulk reads, analytics, and dashboard use cases
  - Opt-in via `TypedEAV.config.materialize_index = true` since it adds storage cost
  - The view is generated from the schema; the consuming app does not need to define columns by hand

- **Query result caching primitives**
  - `Field#cache_version` returns a stable cache key fragment that invalidates when the field definition changes
  - `Value#cache_version` invalidates on value change
  - Helper: `TypedEAV.cache_key_for(entity, field_names)` builds a composite cache key from current field versions
  - Lets consuming apps wrap `where_typed_eav` results in `Rails.cache.fetch` with correct invalidation
  - The gem provides the cache key generation; cache strategy stays with the consuming app

- **Query plan helpers**
  - `Entity.with_field(...).explain` exposes the actual query plan for debugging
  - `TypedEAV.benchmark(name) { block }` utility for measuring EAV query performance
  - Useful for any app validating that typed-column performance gains are real for their workload

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
  - Postgres-first remains the supported path
  - Document any features that depend on Postgres-specific capabilities (jsonb operators, materialized views, text_pattern_ops indexes)
  - MySQL/SQLite support may be added but is not required for these phases

- **Testing discipline**
  - Every new feature ships with specs that exercise the runtime-defined-attribute contract
  - Spec scenarios use arbitrary field names to verify nothing in the gem assumes specific attributes
  - Performance regressions are caught by benchmark specs on the query DSL

- **Documentation discipline**
  - Every new feature documents its intended use case generically
  - Examples in README and inline docs use placeholder field names
  - The principle from the top of this document is restated in the documentation for each phase
