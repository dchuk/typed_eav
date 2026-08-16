---
phase: 6
title: "Bulk Operations & Import/Export"
type: research
confidence: high
date: 2026-05-06
---

# Phase 6 Research: Bulk Operations & Import/Export

Researched: 2026-05-06
Effort: balanced

---

## Code Anchors by Decision

### Bulk write — `bulk_set_typed_eav_values`

- **Anchor 1**: `lib/typed_eav/has_typed_eav.rb:502–534` — `typed_eav_attributes=` is the existing per-entity name-keyed setter. It resolves field names via `typed_eav_defs_by_name`, enforces `allowed_typed_eav_types`, and routes to `typed_values_attributes=` for existing values or `typed_values.build` for new ones. Bulk write must replicate this name-resolution logic per record inside a savepoint, not bypass it.
- **Anchor 2**: `lib/typed_eav/has_typed_eav.rb:57–61` — `HasTypedEAV.definitions_by_name(defs)` is the shared, class-level three-way collision precedence function. Both the instance path (`InstanceMethods#typed_eav_defs_by_name`) and the class-query path use it. Bulk write MUST call this same function per record (or cache it per partition tuple for the batch) — do not inline the sort/index_by logic.
- **Anchor 3**: `app/models/typed_eav/value.rb:306–327` — three explicit `after_commit ..., on: :X` callbacks dispatch Phase 3 events; `after_commit :_dispatch_value_change_update` (line 308) only fires if any of `field.class.value_columns` changed. Savepoint-per-record naturally wraps one entity's value changes; the `after_commit` hooks fire on the outer commit, not the savepoint release.
- **Anchor 4**: `app/models/typed_eav/value.rb:440–468` — `validate_field_scope_matches_entity` is the cross-tenant guard; two-axis check (scope + parent_scope). Bulk write does not bypass this — it fires as part of normal AR validation on each Value row.
- **Anchor 5**: `app/models/typed_eav/field/base.rb:400–408` — `backfill_default!` uses `ActiveRecord::Base.transaction(requires_new: true)` for per-batch savepoints. This is the existing gem idiom for nested savepoints; bulk write should use the same `transaction(requires_new: true)` per record for the savepoint-per-record pattern.
- **Anchor 6**: `lib/typed_eav/has_typed_eav.rb:629–631` — `typed_eav_defs_by_name` (private instance helper) delegates to the shared `HasTypedEAV.definitions_by_name`. For bulk write, call the class-level `HasTypedEAV.definitions_by_name(Field::Base.for_entity(...))` once per partition tuple (not once per record) — records sharing the same `(entity_type, scope, parent_scope)` tuple share the same definition map.
- **Anchor 7**: `lib/typed_eav/has_typed_eav.rb:504–507` — `typed_eav_attributes=` resolves scope by calling `typed_eav_defs_by_name` (which in turn calls `typed_eav_definitions` on the instance, which calls `Class.typed_eav_definitions(scope:, parent_scope:)` with the record's own scope values). Bulk write must call `typed_eav_definitions(scope: record.typed_eav_scope, parent_scope: record.typed_eav_parent_scope)` per unique partition tuple encountered.
- **Anchor 8**: `app/models/typed_eav/value.rb:92–123` — `value=` calls `field.cast(val)`, stores `@cast_was_invalid`, and dispatches through `field.write_value`. The validation in `validate_value` reads `@cast_was_invalid`. Bulk write creating/updating Value rows via the normal AR path (not `update_columns`) means this validation chain runs automatically on `save` inside each savepoint.
- **Implication**: `bulk_set_typed_eav_values` is a class-method concern on the host model. It groups records by partition tuple (for efficiency — one `definitions_by_name` call per partition), then per-record opens a savepoint, calls `record.typed_eav_attributes= values_hash` (or equivalent set_typed_eav_value calls), and `record.save`. Errors from the savepoint's rollback surface in `errors_by_record` keyed by the record (or its id). No need for a separate service object — the host model class method delegates to existing per-record instance methods.

---

### Schema export/import — `Field.export_schema` / `Field.import_schema`

- **Anchor 1**: `app/models/typed_eav/field/base.rb:12–13` — STI table is `typed_eav_fields`; `type` column is the STI discriminator. The 22 concrete subclasses are: `TypedEAV::Field::Text`, `LongText`, `Integer`, `Decimal`, `Boolean`, `Currency`, `Date`, `DateTime`, `Select`, `MultiSelect`, `Percentage`, `Reference`, `IntegerArray`, `DecimalArray`, `TextArray`, `DateArray`, `Email`, `File`, `Image`, `Url`, `Color`, `Json`. The `type` column value is the full STI class name string.
- **Anchor 2**: `app/models/typed_eav/field/base.rb:218–229` — `default_value` and `default_value=` both go through `default_value_meta["v"]` (a jsonb column). Export must include `default_value_meta` as a whole — not just `default_value` — because `default_value_meta` is the canonical storage form and re-importing via `field.default_value_meta = hash["default_value_meta"]` bypasses any re-cast. Per CONTEXT: `default_value_meta` must be in the export payload.
- **Anchor 3**: `app/models/typed_eav/field/base.rb:42–45` — `validates :name, uniqueness: { scope: %i[entity_type scope parent_scope] }`. The idempotence key for import is therefore the AR-native uniqueness constraint tuple `(name, entity_type, scope, parent_scope)`. Import can use `Field::Base.find_by(name:, entity_type:, scope:, parent_scope:)` for collision detection.
- **Anchor 4**: `lib/typed_eav/config.rb:57–80` — `BUILTIN_FIELD_TYPES` maps type symbols to STI class name strings. `export_schema` serializes the `type` column as-is (the STI class name string). Import resolves via `Config.field_class_for(type_name)` OR by passing the raw `type` string directly to the field — the STI class name string IS the `type` column value.
- **Anchor 5**: `app/models/typed_eav/option.rb:1–24` — `TypedEAV::Option` has `field_id`, `label`, `value`, `sort_order`. Export for select/multi_select fields must include `field_options` (the `has_many :field_options` association on `Field::Base`, line 34–38 of `field/base.rb`). Import must create/update option rows after creating/updating the field row.
- **Anchor 6**: `app/models/typed_eav/section.rb:13–14` — `Section` uniqueness is scoped to `%i[entity_type scope parent_scope]` on `code`. Columns: `name`, `code`, `entity_type`, `scope`, `parent_scope`, `sort_order`, `active`. Export of sections should include the same tuple; import idempotence key is `(code, entity_type, scope, parent_scope)`.
- **Anchor 7**: `app/models/typed_eav/field/base.rb:56–59` — `field_dependent` column (string, NOT NULL, default `"destroy"`). Export must include it. `options` column (jsonb) is also export-necessary — it holds all per-type configuration (min, max, pattern, allowed_currencies, target_entity_type, etc.).
- **Anchor 8** (STI type-swap detection): The `type` column on the existing field is the canonical STI class name. `import_schema` reads `existing = Field::Base.find_by(idempotence_key)` and compares `existing.type != incoming_type_string`. When they differ, raise unconditionally (data-loss guard per CONTEXT). When identical: check `on_conflict:` policy.
- **Implication**: `Field.export_schema` is a class-method on `TypedEAV::Field::Base` (or the module that gets extended onto it). It returns a plain Hash with keys: `schema_version` (integer, always `1`), `entity_type`, `scope`, `parent_scope`, `fields` (array), `sections` (array). Each field entry: `name`, `type` (STI class name), `entity_type`, `scope`, `parent_scope`, `required`, `sort_order`, `field_dependent`, `options`, `default_value_meta`, `options_data` (array of `{label, value, sort_order}` for select/multi_select). Section entries: `name`, `code`, `entity_type`, `scope`, `parent_scope`, `sort_order`, `active`. No new files needed for export beyond adding the class method.

---

### CSV mapper — `TypedEAV::CSVMapper`

- **Anchor 1** (no existing CSV code): Searched `**/*.rb` for `CSV`, `csv_`, `mapper`, `CSVMapper` — none found in the gem source tree. `TypedEAV::CSVMapper` is entirely new. Place at `lib/typed_eav/csv_mapper.rb`; add `autoload :CSVMapper` to `lib/typed_eav.rb` alongside existing autoloads at lines 14–21.
- **Anchor 2**: `app/models/typed_eav/field/base.rb:243–245` — `cast(raw)` returns `[casted_value, invalid?]`. The tuple contract is documented: `nil/empty → [nil, false]`; non-empty unparseable → `[nil, true]`; otherwise `[casted, false]`. `CSVMapper.row_to_attributes` calls `field.cast(raw_cell_value)` and treats `invalid? == true` as a coercion error that goes into `Result#errors`, not an exception.
- **Anchor 3** (error shape): The gem's `errors.add(:value, :invalid)` pattern (`app/models/typed_eav/value.rb:367`) matches AR's `{attribute => [messages]}` hash shape on `record.errors`. However, `CSVMapper::Result` is NOT an AR model — it has no `errors` object. The CONTEXT notes this is an open question. Evidence from the codebase: `validate_value` adds to `record.errors` using AR error keys (`:invalid`, `:blank`, `:inclusion`, `:too_short`, `:too_long`, `:greater_than_or_equal_to`, `:less_than_or_equal_to`). The simplest consistent shape for `Result#errors` is `{ "field_name" => ["is invalid"] }` — a plain Hash matching AR's `errors.to_h` shape. This avoids introducing a new shape while staying symmetric with `errors_by_record` (which will also produce AR-derived error messages). Recommendation: use `{ field_name => [message_string, ...] }` for both `CSVMapper::Result#errors` and `bulk_set_typed_eav_values`'s `errors_by_record` values.
- **Anchor 4**: `lib/typed_eav.rb:14–21` — existing `autoload` block where `CSVMapper` should be registered. `TypedEAV::Config` lives at `lib/typed_eav/config.rb`; `CSVMapper` follows the same file naming convention at `lib/typed_eav/csv_mapper.rb`.
- **Implication**: `CSVMapper` is a pure stateless module/class with one public method. No AR inheritance. No service-object pattern needed — it's a single functional transform. `CSVMapper::Result` is a simple value object (not AR): `attr_reader :attributes, :errors`; `def success? = errors.empty?`. The `require "csv"` must be conditional (soft-detect) or gated — Ruby's stdlib `csv` is always available, so `require "csv"` can be unconditional inside the file, but the file itself is only loaded when `CSVMapper` is first referenced (autoload).

---

### Bulk read — `typed_eav_hash_for`

- **Anchor 1**: `lib/typed_eav/has_typed_eav.rb:584–606` — `typed_eav_hash` (instance method). The collision-safe logic: `winning_ids_by_name = typed_eav_defs_by_name.transform_values(&:id)`, then iterates `loaded_typed_values_with_fields` and skips orphans / applies winning-id precedence. `typed_eav_hash_for(records)` is the class-method bulk version of exactly this logic.
- **Anchor 2**: `lib/typed_eav/has_typed_eav.rb:613–623` — `loaded_typed_values_with_fields` (private instance method). Checks `typed_values.loaded?` and falls back to `typed_values.includes(:field).to_a`. The class-method bulk variant must preload in one query: `Value.includes(:field).where(entity: records)` and then group by `entity_id`. This avoids N+1 — one query for all values + one for all fields.
- **Anchor 3**: `lib/typed_eav/has_typed_eav.rb:57–61` — `HasTypedEAV.definitions_by_name(defs)` must be called per unique partition tuple present in `records`, not once for the whole batch (different records in the batch may have different scopes). Group records by `[entity_type, typed_eav_scope, typed_eav_parent_scope]` → one `definitions_by_name` call per group.
- **Anchor 4**: `lib/typed_eav/has_typed_eav.rb:116–145` — `has_typed_eav` macro. The `typed_values` association is declared `as: :entity` (polymorphic). `Value.where(entity_type: self.name, entity_id: records.map(&:id))` is the correct preload query — or `Value.includes(:field).where(entity: records)` using AR's polymorphic-association shorthand.
- **Anchor 5** (Phase 7 collision risk): Phase 7's ROADMAP entry is `Entity.with_all_typed_values` scope wrapping `includes(typed_values: :field)` and `typed_eav_hash_cached`. `typed_eav_hash_for(records)` is a class method returning a Hash, not a scope — no API collision with Phase 7. Phase 7 cache primitives (`Field#cache_version`, `Value#cache_version`, `cache_key_for`) are additive to `typed_eav_hash_for`; Phase 7 revisit is clean. Ship preload-only here per CONTEXT.
- **Implication**: `typed_eav_hash_for(records)` lives in `ClassQueryMethods` (extended onto the host model class) alongside `where_typed_eav` and `typed_eav_definitions`. Implementation: group records by partition tuple, call `definitions_by_name` per group, preload `Value.includes(:field).where(entity_type: name, entity_id: records.map(&:id))`, group values by `entity_id`, apply the same orphan-skip + winning-id precedence as `typed_eav_hash`. Return `{ record_id => { "field_name" => value } }`.

---

### Versioning integration — `version_grouping:` + new `version_group_id` column

- **Anchor 1**: `db/migrate/20260505000000_create_typed_eav_value_versions.rb:33–94` — the Phase 4 `typed_eav_value_versions` table. Columns: `value_id` (nullable FK), `field_id` (nullable FK), `entity_type/entity_id` (polymorphic, NOT NULL), `changed_by`, `before_value` (jsonb, default `{}`), `after_value` (jsonb, default `{}`), `context` (jsonb, default `{}`), `change_type` (string, NOT NULL), `changed_at` (datetime, NOT NULL), plus `timestamps`. Three indexes: `idx_te_vvs_value`, `idx_te_vvs_entity`, `idx_te_vvs_field` (all DESC on `changed_at`). The new `version_group_id` column is additive to this table.
- **Anchor 2**: `lib/typed_eav/versioning/subscriber.rb:110–121` — `TypedEAV::ValueVersion.create!(...)` is where the new `version_group_id:` value must be injected. The subscriber currently has no mechanism to receive a group id. The bulk write code must inject the group id into the `with_context(...)` payload (keyed e.g. `:version_group_id`) so the subscriber can read it from `context[:version_group_id]` when creating the version row. This is the cleanest additive path — the subscriber reads `context` it already receives.
- **Anchor 3**: `lib/typed_eav/config.rb:144–147` — `Config.versioning` is a hand-rolled accessor with `defined?(@versioning)` idiom. The `version_grouping:` ArgumentError path is: in `bulk_set_typed_eav_values`, before the outer transaction, check `if version_grouping_arg_given && !TypedEAV.config.versioning` → raise `ArgumentError` with message following CONVENTIONS.md "tell the caller how to fix it" pattern.
- **Anchor 4**: `lib/typed_eav/versioning.rb:85–92` — `Versioning.register_if_enabled` is the conditional registration gate. `Config.versioning` is read at engine boot. The `version_grouping:` kwarg check at bulk-call time is a runtime check (not engine-boot), so it directly reads `TypedEAV.config.versioning` — no engine-boot implications.
- **Anchor 5** (UUID vs bigint): The codebase has no existing UUID columns anywhere in the gem's own tables. `ValueVersion` uses bigint PKs (standard Rails `create_table` default). The `typed_eav_value_versions` migration uses `t.references :value` (bigint FK), `t.references :entity` (bigint). There is NO precedent for `uuid` column type in any gem migration. However, `version_group_id` is NOT a FK — it's a correlation tag. UUID is appropriate because it must be globally unique across processes/threads/hosts without a shared sequence. `SecureRandom.uuid` is stdlib, no dep. Recommendation: use `uuid` (string type storing a standard UUID, or Postgres `uuid` column type). The `add_column :typed_eav_value_versions, :version_group_id, :string` approach (storing UUID as string) avoids Postgres-version UUID-default gotchas; alternatively `t.column :version_group_id, :uuid` works on Postgres without extra setup. Given the codebase is Postgres-only, `:uuid` column type is cleaner.
- **Anchor 6** (migration pattern): `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb:1–8` — the canonical production-safety migration template: `disable_ddl_transaction!`, explicit `up`/`down`, `add_index ... algorithm: :concurrently, if_not_exists: true`. PATTERNS.md line 263 confirms this. The new migration adding `version_group_id` + its index must follow this pattern.
- **Implication**: Subscriber needs one additive change: read `context[:version_group_id]` from the context hash and pass it as `version_group_id:` to `ValueVersion.create!`. Bulk write generates the UUID before the outer transaction (`per_record` → one UUID per savepoint iteration; `per_field` → one UUID per field across all records), wraps with `TypedEAV.with_context(version_group_id: generated_uuid)` around each savepoint. The subscriber gets it via `context` without requiring a new parameter in the 3-arg signature `(value, change_type, context)` — backward-compatible.

---

## Migration Template Anchor

- **File**: `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb`
- **Pattern**: `disable_ddl_transaction!` at migration class level, explicit `up`/`down` methods (no `change`), all `add_index` calls use `algorithm: :concurrently, if_not_exists: true`, all `remove_index` calls use `if_exists: true, algorithm: :concurrently`.
- **Notes for `version_group_id` migration**:
  - File name pattern: `db/migrate/2026XXXXXXXX_add_version_group_id_to_typed_eav_value_versions.rb`
  - `up`: `add_column :typed_eav_value_versions, :version_group_id, :uuid`; then `add_index :typed_eav_value_versions, :version_group_id, name: "idx_te_vvs_group", algorithm: :concurrently, if_not_exists: true`
  - `down`: `remove_index :typed_eav_value_versions, name: "idx_te_vvs_group", if_exists: true, algorithm: :concurrently`; then `remove_column :typed_eav_value_versions, :version_group_id`
  - `disable_ddl_transaction!` required because `algorithm: :concurrently` cannot run inside a transaction.
  - This migration is additive — existing rows have `version_group_id: NULL` (backward compatible; non-bulk writes remain NULL per CONTEXT).

---

## Test Infrastructure

- **Dummy app location**: `spec/dummy/` — minimal Rails app.
- **Host model definitions**: `spec/dummy/app/models/test_models.rb` — `Contact` (scoped, `scope_method: :tenant_id`), `Product` (unscoped, `types: [:text, :integer, :decimal, :boolean]`), `Project` (two-level, `scope_method: :tenant_id, parent_scope_method: :workspace_id`). Phase 6 specs will primarily use `Contact` (scoped bulk operations) and `Product` (unscoped bulk operations). `Project` covers two-level partition bulk.
- **Dummy migrations path**: `spec/dummy/db/migrate/` — new Phase 6 test-only migrations (if any host-table columns are needed) go here. Engine migrations go in `db/migrate/` and are auto-picked up by the test suite via `spec_helper.rb:17–20`.
- **Migration application in tests**: `spec/spec_helper.rb:31–33` — `ActiveRecord::MigrationContext.new(dummy_migration_path).migrate if dummy_ctx.needs_migration?` applies pending dummy-app migrations at suite start. Engine migrations are applied via `ActiveRecord::Migration.maintain_test_schema!` (line 14) — which picks up `db/migrate/` automatically.
- **Spec metadata flags** (spec_helper.rb:88–174):
  - `:unscoped` — wrap example in `TypedEAV.unscoped` for bulk operations on `Contact` where no ambient scope is set.
  - `:event_callbacks` — snapshot/restore `Config.versioning`, `Config.actor_resolver`, `EventDispatcher.value_change_internals` for bulk versioning specs. MUST combine with `:real_commits` for specs that test version row creation.
  - `:real_commits` — disables transactional fixtures; manually deletes `ValueVersion → Value → Option → Field → Section → Contact/Product/Project` in FK-respecting order (spec_helper.rb:165–173). Phase 6 bulk specs that exercise `version_group_id` must use `:real_commits`.
- **Factories**: `spec/factories/typed_eav.rb` — all 22 field types have factories; `:contact`, `:project`, `:product` host factories default scope to nil. Phase 6 specs build multi-field, multi-record setups from existing factories.
- **New spec files** (placement):
  - `spec/lib/typed_eav/bulk_operations_spec.rb` — `bulk_set_typed_eav_values` unit + integration
  - `spec/lib/typed_eav/csv_mapper_spec.rb` — `CSVMapper.row_to_attributes` unit
  - `spec/models/typed_eav/field_schema_spec.rb` — `export_schema` / `import_schema`
  - `spec/models/typed_eav/bulk_read_spec.rb` — `typed_eav_hash_for`
  - `spec/regressions/` — regression specs for any collision-precedence or scope-isolation bugs found during development

---

## Open-Question Resolutions (CONTEXT § Open)

### `errors_hash` shape

**Recommendation: `{ "field_name" => ["error message string", ...] }` plain Hash.**

Evidence: `app/models/typed_eav/value.rb:367–387` — `validate_value` calls `errors.add(:value, :invalid)` (AR model error). When `record.save` fails inside a savepoint, `record.errors.to_h` returns `{ value: ["is invalid"] }` (symbolized keys in AR 8.x). For `errors_by_record`, the value of each key is the entity's AR errors hash. For `CSVMapper::Result#errors`, the structure should match — but `Result` is not an AR model, so use a plain `Hash` with string-keyed field names: `{ "age" => ["is invalid"] }`. This is the AR `errors.messages` shape serialized to plain Ruby. Using string keys (not symbols) matches the existing `field.name` convention (all field names are strings throughout the codebase). Both `errors_by_record` values and `CSVMapper::Result#errors` use this same shape.

### `version_group_id` type (uuid vs bigint)

**Recommendation: Postgres `uuid` column type (`:uuid` in AR migration DSL).**

Evidence: no UUID columns exist in the gem today (all FKs and PKs are bigint). However `version_group_id` is a correlation tag, not a FK — it must be globally unique without a shared sequence, which is the UUID use case. `SecureRandom.uuid` generates RFC 4122 v4 UUIDs; no extra gem needed. Postgres has a native `uuid` column type that stores 16 bytes (vs 36 bytes for a string). The gem is Postgres-only (confirmed binding in CONTEXT/ROADMAP). Using `:uuid` column type is idiomatic for Postgres correlation IDs. The value `NULL` for non-bulk rows is natural for a nullable uuid column. Migration: `add_column :typed_eav_value_versions, :version_group_id, :uuid` (no `null: false`, no default).

### `Field.export_schema` `schema_version`

**Recommendation: Always include `schema_version: 1` in the export hash root. Settle at plan time.**

Evidence: no existing versioned-hash export pattern exists in the gem. The CONTEXT recommendation (yes, include it, default `1`) is correct and conservative. The schema version allows `import_schema` to validate `hash["schema_version"] == 1` and raise `ArgumentError` with a helpful message if a future incompatible version is passed. Implementation: `export_schema` always returns `{ "schema_version" => 1, "entity_type" => ..., ... }`. Import checks `hash["schema_version"]` first and raises if unrecognized. No code evidence to contradict this; CONTEXT's recommendation stands.

### `typed_eav_hash_for` Phase 7 cache integration

**Recommendation: Ship preload-only in Phase 6; no cache hooks.**

Evidence: Phase 7 ROADMAP entry introduces `Field#cache_version`, `Value#cache_version`, and `TypedEAV.cache_key_for(entity, field_names)` as NEW methods. None of these exist today — there is no cache infrastructure to integrate with. Phase 7 ROADMAP explicitly says `typed_eav_hash_for` "stays preload-only here." Phase 7 will revisit; the API name does not collide with Phase 7's `with_all_typed_values` scope or `typed_eav_hash_cached` alias. The Phase 6 implementation of `typed_eav_hash_for` is cleanly extensible: Phase 7 can add a `typed_eav_hash_for_cached` variant or patch a cache-check into `typed_eav_hash_for` without changing its public signature.

---

## Risks / Surprises

- **Savepoint-in-`after_commit` interaction**: `after_commit` hooks fire on the OUTER transaction commit, not on savepoint release. When `bulk_set_typed_eav_values` uses `transaction(requires_new: true)` per record, a record that fails validation and rolls back its savepoint will NOT fire `after_commit` for its value changes — which is correct. But the outer transaction's `after_commit` fires once for all SUCCESSFUL records together. The Phase 4 versioning subscriber runs per-value in `after_commit` — one version row per value change. This is correct behavior but means `version_group_id` must be generated BEFORE the outer transaction starts (not inside `after_commit`), stored in `with_context`, and the subscriber reads it from context. The group UUID must be stable across the outer transaction's `after_commit` chain — wrapping the entire bulk call in `TypedEAV.with_context(version_group_id: uuid)` achieves this.

- **`per_field` grouping semantics**: CONTEXT defines `:per_field` as "one uuid per field touched across the bulk set" — meaning all records that had field `"age"` updated share one UUID. This requires generating one UUID per unique field name in `values_by_field_name`, then inside each record's savepoint, injecting the per-field UUID via `with_context` on a per-field-write basis. This is more complex than `:per_record`. The planning agent should model this carefully — it likely requires a different loop structure: instead of iterating records and then fields, iterate fields and then records for the `:per_field` grouping mode.

- **`definitions_by_name` caching in bulk**: The existing `typed_eav_defs_by_name` private method calls `typed_eav_definitions` (an instance method that resolves scope per-record). For a bulk operation over 1000 records all belonging to the same partition, this would issue 1000 identical queries for field definitions. The bulk method must cache: group records by `(typed_eav_scope, typed_eav_parent_scope)` → call `Field::Base.for_entity(entity_type, scope:, parent_scope:)` once per group → call `HasTypedEAV.definitions_by_name` once per group → reuse across all records in that group.

- **`import_schema` and `accepts_nested_attributes_for` for options**: Creating option rows for select/multi_select fields during `import_schema` cannot go through `typed_values_attributes=` (that's for values, not field options). Use `field.field_options.create!({label:, value:, sort_order:})` directly. The `Option` model validates uniqueness of `value` scoped to `field_id` (option.rb:12) — import must either skip existing options (`:skip`) or destroy+recreate (`:overwrite`). For `:error` policy, any existing field with different options should raise (incompatible schema drift).

- **`Field::File` shadows `::File`**: `app/models/typed_eav/field/file.rb` — inside `module TypedEAV; module Field`, bare `File` resolves to `TypedEAV::Field::File`. The `export_schema` / `import_schema` code must NOT use bare `File` for any Ruby stdlib file operations. All Ruby stdlib file I/O must use `::File` if needed (unlikely in this feature, but the naming hazard is live for any spec or implementation code in that namespace).

- **`has_typed_eav types:` restriction and bulk write**: `allowed_typed_eav_types` is a `class_attribute` set on the host model (has_typed_eav.rb:128–129). If `Product.allowed_typed_eav_types = ["text", "integer"]`, a bulk write attempting to set a `boolean` field on a `Product` record will silently skip it (consistent with `typed_eav_attributes=` line 519: `next if allowed&.exclude?(...)`). This is correct behavior — bulk write respects the same allow-list. Document it in specs and README.

- **`Value` uniqueness validation on `(entity_type, entity_id, field_id)`**: `app/models/typed_eav/value.rb:57` — `validates :field, uniqueness: { scope: %i[entity_type entity_id] }`. If the same field appears twice for the same entity in a bulk write (duplicate in `values_by_field_name`), the second `typed_values.build` will fail this uniqueness check inside the savepoint. The bulk path should deduplicate by field name before building value records — mirrors `typed_eav_attributes=` which calls `fields_by_name[attrs[:name]]` (a hash, so last-wins on duplicate names in the input array).

- **`backfill_default!` uses `transaction(requires_new: true)` per BATCH, not per record**: This is NOT the savepoint-per-record pattern. CONTEXT explicitly specifies savepoints per record for bulk write. Use `transaction(requires_new: true)` inside the per-record loop (not the per-batch loop). The per-batch pattern in `backfill_default!` is a performance choice for that use case (backfill) and must not be cargo-culted into bulk write.

---

## Files Likely to Change

### Add (new files)
- `lib/typed_eav/csv_mapper.rb` — `TypedEAV::CSVMapper` module with `row_to_attributes` and `Result` value object
- `db/migrate/2026XXXXXXXX_add_version_group_id_to_typed_eav_value_versions.rb` — additive migration (`disable_ddl_transaction!`, `add_column :uuid` + concurrent index)
- `spec/lib/typed_eav/bulk_operations_spec.rb`
- `spec/lib/typed_eav/csv_mapper_spec.rb`
- `spec/models/typed_eav/field_schema_spec.rb`
- `spec/models/typed_eav/bulk_read_spec.rb`

### Modify (existing files)
- `lib/typed_eav/has_typed_eav.rb` — add `bulk_set_typed_eav_values` to `ClassQueryMethods`; add `typed_eav_hash_for` to `ClassQueryMethods`
- `lib/typed_eav/versioning/subscriber.rb` — read `context[:version_group_id]` and pass to `ValueVersion.create!`
- `app/models/typed_eav/field/base.rb` — add `export_schema` and `import_schema` class methods (or as a separate concern included into `Field::Base`)
- `app/models/typed_eav/value_version.rb` — no model change needed (column is additive; AR picks it up automatically from schema)
- `lib/typed_eav.rb` — add `autoload :CSVMapper, "typed_eav/csv_mapper"`
- `lib/typed_eav/config.rb` — no change needed (no new config keys for Phase 6 per CONTEXT)
- `lib/typed_eav/engine.rb` — no change needed (no new engine-boot registrations for Phase 6)
- `README.md` — Phase 6 API docs section (bulk write, schema export/import, CSV mapper, bulk read, version_grouping)
- `CHANGELOG.md` — Phase 6 entry

### New migration
- `db/migrate/2026XXXXXXXX_add_version_group_id_to_typed_eav_value_versions.rb`
  - Timestamp to be assigned at plan time (sequential after `20260505000000`)
  - Pattern: `disable_ddl_transaction!` + explicit `up`/`down` + `add_column :uuid` + `add_index algorithm: :concurrently`
