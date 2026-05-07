# CONCERNS.md

## Security posture

The gem ships with several **fail-closed** defaults. Anyone working on this codebase needs to know which switches are protective and not change them lightly.

### Multi-tenant scoping (the most important guarantee)

When a host model declares `has_typed_eav scope_method: :tenant_id`, class-level queries (`Contact.where_typed_eav(...)`, `Contact.with_field(...)`) **raise** `TypedEAV::ScopeRequired` if no scope can be resolved (no explicit `scope:` kwarg, no active `with_scope` block, no configured resolver). This is in `lib/typed_eav/has_typed_eav.rb#resolve_scope` lines 339–413.

Why fail-closed: forgetting to set scope must not silently leak other tenants' data. The README §"Disabling enforcement for gradual adoption" explicitly recommends flipping `require_scope = true` back on once existing callers are audited.

**Phase 01 two-axis extension** preserves the fail-closed guarantee on both `scope` and `parent_scope` axes. Three additional defenses close silent dead-letter modes:

1. **Macro guard** — `has_typed_eav parent_scope_method: :ws` without `scope_method:` raises `ArgumentError` at class load time. Without this, ambient resolution would short-circuit to `[nil, nil]`, route every query to the global-only branch, and discard the parent_scope intent silently.
2. **Strict resolver contract** — `Config.scope_resolver` MUST return `nil` or `[scope, parent_scope]`. A bare scalar (the v0.1.x shape) raises `ArgumentError` directly inside `current_scope`, BEFORE any normalization. The shim alternative (auto-coerce scalar to `[scalar, nil]`) was rejected during Phase 1 design because it would silently swallow contract violations in user-supplied resolver code.
3. **Orphan-parent invariant** — `Field::Base#validate_parent_scope_invariant` and `Section#validate_parent_scope_invariant` reject `parent_scope.present? && scope.blank?`. Combined with the schema-level decision to omit `parent_scope` from the `scope IS NULL` partial unique index column lists, this guarantees the `(scope=NULL, parent_scope=NOT NULL)` row is unrepresentable.

Edge cases that have been thought-through:
- **Models that didn't opt in** (`scope_method:` not declared): `resolve_scope` returns `[nil, nil]` early so they don't see ambient scope state — see comment lines 376–391 explaining why honoring ambient on non-opted-in models would leak cross-model state.
- **`scope: nil` explicitly** (vs. omitted): explicit `nil` filters to global-only fields. Omitted resolves from ambient. The `UNSET_SCOPE` sentinel is what makes these distinguishable. Same axis-by-axis: `parent_scope: nil` filters to parent-scope-globals on that axis.
- **Cross-tenant audit queries**: `TypedEAV.unscoped { ... }` triggers the multimap branch in `where_typed_eav` (lines 220–257), OR-across all `field_id`s sharing a name, AND across filters. Atomic-bypass — drops both `scope` and `parent_scope` predicates simultaneously. The previous default of "wrap every spec in unscoped" hid bugs where this multimap collapsed to one tenant — see `spec/regressions/review_round_2_scope_leak_spec.rb`, `review_round_3_collision_spec.rb`, and `review_round_4_parent_scope_spec.rb`.

### Cross-tenant write guard at the row level

`TypedEAV::Value#validate_field_scope_matches_entity` (`app/models/typed_eav/value.rb` lines 441–469) is the second-line defense: even if a malicious form submits a raw `field_id` for another tenant's field, the `Value` save fails because the field's `scope` won't match the entity's `typed_eav_scope`. Globals (`scope: nil`) remain shared.

**Two-axis since Phase 01**: the same validator additionally enforces that `field.parent_scope` matches `entity.typed_eav_parent_scope` when set. The orphan-parent invariant (Field-level) means `parent_scope.present?` implies `scope.present?`, so the parent-axis check trusts that the scope-axis check has already validated the scope half.

This validation is *separate* from `validate_entity_matches_field` because matching `entity_type` alone isn't enough — two tenants' "Contact" custom fields share `entity_type` but live in different scopes.

### Admin scaffold authorization

The generated `TypedEAVController` ships with `authorize_typed_eav_admin!` returning `head :not_found` (not `403`) by default. The comments in `lib/generators/typed_eav/scaffold/templates/controllers/typed_eav_controller.rb` explain:
- 404 instead of 403 because revealing route existence is itself a leak.
- The hook is on the **generated controller**, not `ApplicationController`. Defining an `authorize_typed_eav_admin!` method in `ApplicationController` does **not** override it (Ruby looks up methods on the subclass first).
- The post-install banner instructs the user to wire it up to their auth system. If they ignore the banner, the routes return 404. Fail-closed.

### JSON value cap

`TypedEAV::Value::MAX_JSON_BYTES = 1_000_000` (1 MB) caps the worst-case row size. Without it, a malformed import could write a multi-megabyte blob into `json_value`. Enforced in `validate_json_size`.

### Reserved field names

`TypedEAV::Field::Base::RESERVED_NAMES = %w[id type class created_at updated_at]`. Excluded by validation. Stops users from creating a "type" field that would collide with STI dispatch.

### Pattern validation timeout

`Field::Base#validate_pattern` runs user-supplied regex inside `Timeout.timeout(1)` and rescues `RegexpError` and `Timeout::Error`. Without this, a ReDoS-style pattern in a `Field::Text` `pattern` option could hang requests. The catch reports an error against the *value* validation rather than crashing.

### Phase 04 versioning error policy

`TypedEAV::EventDispatcher` enforces a deliberate split:
- **Internal subscribers** (Phase 04 `Versioning::Subscriber`, future Phase 07 matview): exceptions **propagate**. Versioning corruption must be loud — silent failure leaves the audit log inconsistent with the live row.
- **User proc** (`Config.on_value_change` / `Config.on_field_change` / `Config.on_image_attached`): wrapped in `rescue StandardError`, logged to `Rails.logger.error`, and swallowed. The Value/Field row is already committed by the time the after_commit fires; re-raising would surface a misleading "save failed" error to the caller.

This split is locked at `03-CONTEXT.md §User-callback error policy`. Don't unify — it's load-bearing for both the Phase 04 corruption-detection guarantee and the principle-of-least-surprise for user procs.

### Phase 05 Image/File signed_id storage

Field::Image and Field::File store the Active Storage `signed_id` (a message-verified opaque token) in `string_value`, not the bare blob `id`. This means:
- Tampering with the stored value invalidates the signature → `ActiveStorage::Blob.find_signed` returns nil → validate_typed_value adds `:invalid`.
- Storage data shape is decoupled from Active Storage's internal blob-id format — UUID-typed blobs would not require a typed_eav schema migration.
- Operators are explicitly narrowed to `[:eq, :is_null, :is_not_null]` — string-pattern operators (`:contains`, `:starts_with`) on signed_ids would be meaningless (they're signed opaque tokens).

## Known operational risks

### Postgres-specific features

Several capabilities are PG-only and would block alternative database support:

| Feature | Where | What MySQL/SQLite would need |
|---|---|---|
| jsonb `@>` containment | `query_builder.rb` (`:any_eq`, `:all_eq`); `typed_eav_value_versions.before_value`/`after_value`/`context` | Different array-membership SQL per adapter |
| `text_pattern_ops` btree opclass | base migration | Plain btree (LIKE prefix won't be indexable) |
| Partial unique indexes (`WHERE scope IS NOT NULL AND parent_scope IS NULL`, etc.) | Three partials per partition table from Phase 01 migration | MySQL has no partial indexes; would need a synthesized non-null sentinel column |
| GIN index on jsonb | base migration | None — array containment performance would degrade |
| `IS NULL` distinct in unique index | The reason for triple-paired partials | Different semantics across adapters |
| `algorithm: :concurrently` (CREATE/DROP INDEX CONCURRENTLY) | Phase 01 migration | MySQL has its own `ALGORITHM=INPLACE`/`LOCK=NONE` syntax |
| `FOR UPDATE` row locking | `Field::Base` and `Section` partition-aware ordering helpers (`reorder_within_partition`) | Different lock semantics per adapter |
| `ON DELETE SET NULL` | Phase 02 cascade FK on `typed_eav_values.field_id`; Phase 04 audit-log FKs | Standard SQL; supported broadly but PG semantics are the locked reference |

The README explicitly says "Requires PostgreSQL" — this is not aspirational.

### Index tuning assumes EAV-style read patterns

The index set in the migrations is tuned for "give me values for this field across all entities" (covering indexes on `(field_id, <typed>_value) include (entity_id, entity_type)` for index-only scans). If a host app starts running `WHERE entity_id = ?` queries directly against the values table, none of those indexes match — query plans will degrade. The `(entity_type, entity_id, field_id)` unique index handles entity-side lookups but isn't tuned for typed-column ranges.

### `idx_te_values_field_str` uses `text_pattern_ops`

That opclass enables prefix matches (`ILIKE 'value%'`) but **does not** support locale-aware sort. If a future feature adds `ORDER BY string_value` with non-ASCII data, the index won't help.

### N+1 risks

The README explicitly tells consumers: `Contact.includes(typed_values: :field).all` for list pages. Without this, every `typed_eav_value("name")` triggers a query per record per call.

`InstanceMethods#loaded_typed_values_with_fields` defends against this by **respecting an already-loaded association** — if you preloaded with `includes`, it reuses; if you didn't, it does a fresh `includes(:field).to_a`. But it can't reach across to the field-options table — for select/multi-select with many options, callers should preload `typed_values: { field: :field_options }` themselves.

### Phase 04 versioning write amplification

When `Config.versioning = true` and a host opted in via `versioned: true`, every `:create` / `:update` / `:destroy` event on its Values writes one row to `typed_eav_value_versions`. For high-write workloads (bulk imports, frequent edits), this can multiply DB writes. Mitigations:
- The master switch (`Config.versioning`) defaults to **false** so apps that don't opt in pay zero cost (no callable registered, no Hash#dig per write).
- The per-entity `versioned?` flag means apps can enable versioning on audit-sensitive entity types (e.g., contracts, financial records) while leaving high-volume entities (telemetry, analytics events) unversioned.
- The `:update` filter (`field.class.value_columns.any? { |col| saved_change_to_attribute?(col) }`) skips no-op updates that didn't touch any typed column — bookkeeping changes don't generate audit rows.

### Phase 04 `:destroy` event writes `value_id: nil`

By the time `after_commit on: :destroy` fires, the parent row in `typed_eav_values` has already been deleted. The audit-log FK is `ON DELETE SET NULL`, but the FK is validated **at INSERT time** against the current state of `typed_eav_values` — which no longer contains the destroyed row. Writing `value.id` (still readable in-memory on the destroyed AR record) would FK-fail at INSERT. Subscriber writes `nil` instead. The audit trail stays queryable via `(entity_type, entity_id)` and `field_id` (Field is not destroyed by Value destruction).

This is documented inline in `lib/typed_eav/versioning/subscriber.rb` lines 87–110. Don't "fix" it by writing `value.id` — it's a real Postgres FK-validation timing constraint, not a bug.

### Active Storage cleanup on Image/File destroy

Field::Image and Field::File store the `signed_id` in `string_value` but do not declare `dependent: :purge` on the `:attachment` association. When a Value with an attached image is destroyed, the AS blob may be orphaned. Apps that need automatic blob cleanup register a `Config.on_value_change` hook that purges on `:destroy`, or run a periodic AS cleanup job. The gem deliberately doesn't do this automatically — purging is an irreversible operation and the audit log (Phase 04 versioning) preserves the signed_id reference, so future "restore" operations could re-attach a still-extant blob.

## Validation surprises (documented for users, but worth knowing for contributors)

The README §"Validation Behavior" lists the non-obvious contracts. Don't change these without thinking through downstream impact:

- **Required + blank** treats whitespace-only and arrays-of-blanks as missing. `Value#blank_typed_value?` is the canonical predicate.
- **Array all-or-nothing cast**: integer/decimal/date arrays mark the *whole* value invalid when any element fails to cast — never a silently-pruned partial. The `IntegerArray#cast` comment explains why (failed form re-render with bad elements removed would confuse the user).
- **Integer rejects fractional**: `"1.9"` is rejected, not truncated. `Integer#cast` uses `BigDecimal#frac != 0` as the check. `Reference#cast` mirrors this — fractional FKs are nonsense.
- **Json parses string input**: a JSON string posted from a form is `JSON.parse`d; failures surface as `:invalid` rather than being stored verbatim.
- **TextArray does not support `:contains`**: it backs `json_value`; SQL `LIKE` doesn't work. Use `:any_eq`. The class declaration comments explain why.
- **Orphans skipped on read, not deleted**: if a field row is deleted while values remain (the Phase 02 `:nullify` policy is the canonical case), `typed_eav_value` and `typed_eav_hash` silently skip them rather than raising. This is *intentional* fail-soft for read paths.
- **Cross-scope writes rejected**: see security section above. Two-axis since Phase 01.
- **Currency requires Hash input**: `Currency#cast` rejects bare numerics or strings — explicit currency dimension is required at write time. Silently defaulting to `default_currency` would invite bugs where users forget the currency dimension entirely.
- **Currency co-population**: `validate_typed_value` requires both `:amount` and `:currency` populated. A half-populated row is invalid even though either column alone is technically storable.
- **Reference accepts records OR ids**: `Reference#cast` accepts AR record instances of the target type AND integer/string IDs. Class-mismatched records are rejected at cast time as `:invalid` — catches typos at write time. The `:references` operator at query time also accepts both shapes (normalized via the same `cast` path).
- **Percentage stores fractions, formats as percent**: `Percentage` extends `Decimal` and stores 0..1 in `decimal_value`. `display_as: :percent` and `decimal_places` are **read-side format-only** — they never change what's stored.
- **Image/File `cast` raises NotImplementedError when AS is absent**: the only path to a hard fail. `validate_typed_value` silently no-ops. Apps that want to discover the absence at app-boot time should reference `defined?(::ActiveStorage::Blob)` themselves in an initializer.

## Technical debt / open questions

These are honest assessments based on the codebase as it stands at v0.2.0:

- **No bulk APIs**: no `bulk_set_typed_eav_values`, no `typed_eav_hash_for(records)` batch. `typed_eav_attributes=` is per-record. Heavy bulk operations N+1 today. Phase 06 of the enhancement plan addresses this.
- **No materialized index for read-heavy use**: every query joins `typed_eav_values` against the host table. For dashboards/analytics on millions of records this will hit a wall. Phase 07 proposes an optional materialized view that would register a second internal subscriber on `EventDispatcher` (slot ≥ 1; Phase 04 versioning holds slot 0 by engine `config.after_initialize` declaration order).
- **`typed_eav-0.1.0.gem` is committed to the repo** (the v0.1.0 build artifact). Not strictly necessary in version control — the `.github/workflows/release.yml` rebuilds from source. Worth a `.gitignore` entry on next pass.
- **Active Storage blob cleanup is manual** — see "Active Storage cleanup on Image/File destroy" above.
- **No `register/deregister` API for runtime versioning toggle** — `Config.versioning` flips at runtime are not a documented use case (the subscriber registration runs in `config.after_initialize`, so toggling after that has no effect until process restart). Apps that need late toggle would have to add their own subscriber-registration helper.
- **`shared partition-axis matcher` duplication** — `Field::Base#entity_partition_axis_matches?` (used by `backfill_default!`) and `Field::Reference#target_partition_matches?` use structurally parallel logic but read from different option surfaces. Acceptable for v0.2.0; possible Phase 07 ergonomics consolidation.
- **No `position` ordering helpers on Section's scope axis collisions** — Section has the same partition-aware move helpers as Field, but has no equivalent of Phase 01's three-way collision precedence (because Section.code is the uniqueness key, not Section.name; collision semantics differ).

## Concerns specific to evolution

- **Adding a single-cell field type**: must declare `value_column`, optionally narrow `operators`, implement `cast(raw)` returning the `[casted, invalid?]` tuple, optionally implement `validate_typed_value`. **Don't** add a new value column to the migration without thinking through the operator-default map in `column_mapping.rb` — the default operator list is keyed by column name. A new column means new defaults need to be declared.
- **Adding a multi-cell field type**: must override **all three** of `self.value_columns` (plural), `self.operator_column(operator)`, and the instance trio `read_value`/`write_value`/`apply_default_to`. Overriding only one creates an asymmetry where reads see the multi-cell shape but writes / defaults populate only one column (or vice versa). Currency is the canonical example. The Phase 04 versioning subscriber iterates `value_columns` to build snapshots, and the Phase 03 `Value#_dispatch_value_change_update` filter iterates `value_columns` to detect cross-cell changes — both work transparently for new multi-cell types as long as the trio is paired.
- **Adding a new operator**: changes touch `query_builder.rb#filter` (the case dispatch) AND `column_mapping.rb` (`DEFAULT_OPERATORS_BY_COLUMN` if the operator should be on by default for some column type) AND every Field subclass that needs to allow it (or wants to register an override of `operator_column` to route it). Test coverage in `spec/lib/typed_eav/query_builder_spec.rb` is the matrix to extend.
- **Adding a Phase 04 internal subscriber** (Phase 07 matview is the next planned consumer): register via `EventDispatcher.register_internal_value_change(callable)` from a `config.after_initialize` block in `engine.rb` declared **after** versioning's block (Rails runs `after_initialize` blocks in declaration order — versioning holds slot 0 by virtue of being declared first). Internal-subscriber exceptions **propagate**; user-proc exceptions are **rescued+logged**. Don't unify the error policies. Test by snapshotting `EventDispatcher.value_change_internals.dup` (NOT calling `EventDispatcher.reset!`).
- **Schema changes**: index names use `idx_te_*` to fit Postgres' 63-byte limit (`idx_te_vvs_*` for the audit log). Don't drop the prefix. Three paired partial unique indexes are required wherever a `(name, entity_type, scope, parent_scope)` tuple needs uniqueness — see Phase 01 migration comments lines 36–56. New migrations on partition tables should use `disable_ddl_transaction!` + `algorithm: :concurrently` for production safety.
- **Renaming the gem**: the gem was renamed from `typed_fields` to `typed_eav` (commits `7d843be`, `54efdb3`). The acronym inflection (`inflect.acronym "EAV"`) was added so `TypedEAV` round-trips through underscore/camelize. If you rename again, that line needs to follow.
- **Constant-shadow hazards**: inside `module TypedEAV; module Field`, bare `Integer`/`String`/`Date`/`File` etc. resolve to `TypedEAV::Field::*` subclasses, NOT to Ruby's top-level constants. New field-type code that needs a Ruby class must use `::Integer`, `::String`, `::File`, etc. The `Field::Reference` and `Field::Image`/`Field::File` source files document this hazard inline; mirror their pattern in any new field type that does runtime type checking.
