# CONCERNS.md

## Security posture

The gem ships with several **fail-closed** defaults. Anyone working on this codebase needs to know which switches are protective and not change them lightly.

### Multi-tenant scoping (the most important guarantee)

When a host model declares `has_typed_eav scope_method: :tenant_id`, class-level queries (`Contact.where_typed_eav(...)`, `Contact.with_field(...)`) **raise** `TypedEAV::ScopeRequired` if no scope can be resolved (no explicit `scope:` kwarg, no active `with_scope` block, no configured resolver). This is in `lib/typed_eav/has_typed_eav.rb#resolve_scope` lines 270–278.

Why fail-closed: forgetting to set scope must not silently leak other tenants' data. The README §"Disabling enforcement for gradual adoption" explicitly recommends flipping `require_scope = true` back on once existing callers are audited.

Edge cases that have been thought-through:
- **Models that didn't opt in** (`scope_method:` not declared): `resolve_scope` returns `nil` early so they don't see ambient scope state — see comment lines 252–262 explaining why honoring ambient on non-opted-in models would leak cross-model state.
- **`scope: nil` explicitly** (vs. omitted): explicit `nil` filters to global-only fields. Omitted resolves from ambient. The `UNSET_SCOPE` sentinel is what makes these distinguishable.
- **Cross-tenant audit queries**: `TypedEAV.unscoped { ... }` triggers the multimap branch in `where_typed_eav` (lines 154–186), OR-across all `field_id`s sharing a name, AND across filters. The previous default of "wrap every spec in unscoped" hid bugs where this multimap collapsed to one tenant — see `spec/regressions/review_round_2_scope_leak_spec.rb` and `review_round_3_collision_spec.rb`.

### Cross-tenant write guard at the row level

`TypedEAV::Value#validate_field_scope_matches_entity` (`app/models/typed_eav/value.rb` lines 138–147) is the second-line defense: even if a malicious form submits a raw `field_id` for another tenant's field, the `Value` save fails because the field's `scope` won't match the entity's `typed_eav_scope`. Globals (`scope: nil`) remain shared.

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

## Known operational risks

### Postgres-specific features

Several capabilities are PG-only and would block alternative database support:

| Feature | Where | What MySQL/SQLite would need |
|---|---|---|
| jsonb `@>` containment | `query_builder.rb` (`:any_eq`, `:all_eq`) | Different array-membership SQL per adapter |
| `text_pattern_ops` btree opclass | migration line 120 | Plain btree (LIKE prefix won't be indexable) |
| Partial unique indexes (`WHERE scope IS NOT NULL`) | migration lines 22–28, 57–66 | MySQL has no partial indexes; would need a synthesized non-null sentinel column |
| GIN index on jsonb | migration line 126 | None — array containment performance would degrade |
| `IS NULL` distinct in unique index (the reason for paired partials) | — | Different semantics across adapters |

The README explicitly says "Requires PostgreSQL" — this is not aspirational.

### Index tuning assumes EAV-style read patterns

The index set in the migration is tuned for "give me values for this field across all entities" (covering indexes on `(field_id, <typed>_value) include (entity_id, entity_type)` for index-only scans). If a host app starts running `WHERE entity_id = ?` queries directly against the values table, none of those indexes match — query plans will degrade. The `(entity_type, entity_id, field_id)` unique index handles entity-side lookups but isn't tuned for typed-column ranges.

### `idx_te_values_field_str` uses `text_pattern_ops`

That opclass enables prefix matches (`ILIKE 'value%'`) but **does not** support locale-aware sort. If a future feature adds `ORDER BY string_value` with non-ASCII data, the index won't help.

### N+1 risks

The README explicitly tells consumers: `Contact.includes(typed_values: :field).all` for list pages. Without this, every `typed_eav_value("name")` triggers a query per record per call.

`InstanceMethods#loaded_typed_values_with_fields` (`has_typed_eav.rb` lines 464–473) defends against this by **respecting an already-loaded association** — if you preloaded with `includes`, it reuses; if you didn't, it does a fresh `includes(:field).to_a`. But it can't reach across to the field-options table — for select/multi-select with many options, callers should preload `typed_values: { field: :field_options }` themselves.

## Validation surprises (documented for users, but worth knowing for contributors)

The README §"Validation Behavior" lists the non-obvious contracts. Don't change these without thinking through downstream impact:

- **Required + blank** treats whitespace-only and arrays-of-blanks as missing. `Value#blank_typed_value?` is the canonical predicate.
- **Array all-or-nothing cast**: integer/decimal/date arrays mark the *whole* value invalid when any element fails to cast — never a silently-pruned partial. The `IntegerArray#cast` comment explains why (failed form re-render with bad elements removed would confuse the user).
- **Integer rejects fractional**: `"1.9"` is rejected, not truncated. `Integer#cast` uses `BigDecimal#frac != 0` as the check.
- **Json parses string input**: a JSON string posted from a form is `JSON.parse`d; failures surface as `:invalid` rather than being stored verbatim.
- **TextArray does not support `:contains`**: it backs `json_value`; SQL `LIKE` doesn't work. Use `:any_eq`. The class declaration comments explain why.
- **Orphans skipped on read, not deleted**: if a field row is deleted while values remain, `typed_eav_value` and `typed_eav_hash` silently skip them rather than raising. This is *intentional* fail-soft for read paths but creates a slow-leak: the "Configurable cascade behavior on Field destroy" plan in `typed_eav-enhancement-plan.md` Phase 1 addresses it.
- **Cross-scope writes rejected**: see security section above.

## Technical debt / open questions

These are honest assessments based on the codebase as it stands at v0.1.0:

- **No `default_value` reuse path yet**: the schema has `default_value_meta` jsonb, the field model has `default_value`/`default_value=`, but nothing automatically populates new `Value` rows from defaults *for existing records when a Field is created*. The enhancement plan's Phase 1 "Default values on Field" item proposes the `Field#backfill_default!` API. Until then, defaults only apply when a host caller explicitly does `typed_values.build(field: f, value: f.default_value)` (which `initialize_typed_values` already does).
- **No versioning / audit trail**: `Value` mutations leave no history. Phase 1 of the enhancement plan proposes an opt-in `TypedEAV::Versioned` concern with a `typed_eav_value_versions` table.
- **No `position` ordering on Field**: `sort_order` exists on the column and is used as a sort key, but there's no `acts_as_list`-style `move_higher`/`insert_at` API. Phase 1 proposes adding it.
- **No bulk APIs**: no `bulk_set_typed_eav_values`, no `typed_eav_hash_for(records)` batch. `typed_eav_attributes=` is per-record. Heavy bulk operations N+1 today. Phase 3 of the plan addresses this.
- **No event hooks**: nothing fires `on_value_change` or `on_field_change` callbacks. Phase 5 proposes them.
- **No materialized index for read-heavy use**: every query joins `typed_eav_values` against the host table. For dashboards/analytics on millions of records this will hit a wall. Phase 4 proposes an optional materialized view.
- **`typed_eav-0.1.0.gem` is committed to the repo**. This is the built artifact from `gem build`. It is not strictly necessary in version control — the `.github/workflows/release.yml` rebuilds it from source. Worth a `.gitignore` entry on next pass.
- **Two-level scope partitioning** (org/team, account/project) is a Phase-1 plan item. Today only single `scope` is supported.

## Concerns specific to evolution

- **Adding a new field type**: must declare `value_column`, optionally narrow `operators`, implement `cast(raw)` returning the `[casted, invalid?]` tuple, optionally implement `validate_typed_value`. **Don't** add a new value column to the migration without thinking through the operator-default map in `column_mapping.rb` — the default operator list is keyed by column name. A new column means new defaults need to be declared.
- **Adding a new operator**: changes touch `query_builder.rb#filter` (the case dispatch) AND `column_mapping.rb` (`DEFAULT_OPERATORS_BY_COLUMN` if the operator should be on by default for some column type) AND every Field subclass that needs to allow it. Test coverage in `spec/lib/typed_eav/query_builder_spec.rb` is the matrix to extend.
- **Schema changes**: index names use `idx_te_*` to fit Postgres' 63-byte limit. Don't drop the prefix. Paired partial unique indexes are required wherever a `(name, entity_type, scope)` triple needs uniqueness — see migration comments lines 17–22.
- **Renaming the gem**: the gem was renamed from `typed_fields` to `typed_eav` (commits `7d843be`, `54efdb3`). The acronym inflection (`inflect.acronym "EAV"`) was added so `TypedEAV` round-trips through underscore/camelize. If you rename again, that line needs to follow.
