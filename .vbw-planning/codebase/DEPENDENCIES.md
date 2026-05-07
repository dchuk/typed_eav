# DEPENDENCIES.md

## Runtime dependencies (gemspec)

The gem has **one** runtime dependency:

| Gem | Constraint | Resolved | Why |
|---|---|---|---|
| `rails` | `>= 7.1` | 8.1.3 | Provides `Rails::Engine`, `ActiveRecord` (host for `has_typed_eav` concern, STI Field hierarchy, Value model), polymorphic associations, generators (Thor), `accepts_nested_attributes_for`, and Active Storage (used soft-detected by Phase 05 Image/File field types). |

No other runtime gems. Notably absent (intentional):
- No serialization gem (`json` ships with Ruby).
- No image/file gem — Active Storage ships with Rails and is **soft-detected**: `Engine.register_attachment_associations!` only attaches the `has_one_attached :attachment` macro when `::ActiveStorage::Blob` is defined at engine boot. Apps that exclude AS pay zero cost.
- No multi-tenancy gem — `acts_as_tenant` is **auto-detected** in `Config::DEFAULT_SCOPE_RESOLVER` via `defined?(::ActsAsTenant)` but is not a hard dependency. As of v0.2.0 the resolver returns the Phase 1 tuple `[ActsAsTenant.current_tenant, nil]` instead of a bare scalar.
- No `ActiveSupport::Configurable` reliance — Configurable was deprecated in Rails 8.1; `Config` and `Registry` use hand-rolled `defined?(@var)` accessors instead so the public API stays stable across Rails 8.1 → 8.2 migration.

## Development & test dependencies (Gemfile)

```ruby
group :development, :test do
  gem "factory_bot_rails"
  gem "pg"
  gem "rspec-rails"
  gem "shoulda-matchers"

  gem "rubocop", "~> 1.86", require: false
  gem "rubocop-performance", "~> 1.26", require: false
  gem "rubocop-rails", "~> 2.34", require: false
  gem "rubocop-rspec", "~> 3.9", require: false
end
```

Pinning rationale: only the rubocop family is pinned (lint stability across CI runs). The four test gems float — their major versions are stable and `Gemfile.lock` is committed.

## Resolved versions worth knowing (from `Gemfile.lock`)

| Gem | Version | Notes |
|---|---|---|
| rails | 8.1.3 | Lock target. The `>= 7.1` constraint means consumers on Rails 7.1+ can install; CI does not currently matrix-test multiple Rails majors. |
| activerecord | 8.1.3 | All AR APIs in use (`store_accessor`, `accepts_nested_attributes_for`, `class_attribute`, polymorphic, STI, Arel matchers, `previously_new_record?`, `attribute_before_last_save`) are present in 7.1+. **Note**: Rails 8.1 has an alias-collision bug where reusing one method across `after_create_commit`/`after_update_commit`/`after_destroy_commit` aliases lets only the LAST registration win — `Value` works around this with three explicit `after_commit ..., on: :X` declarations. |
| activestorage | 8.1.3 | Soft-detected at runtime via `defined?(::ActiveStorage::Blob)`. Used by `Field::Image`/`Field::File` and the `on_image_attached` hook. Dummy app loads it via the full `rails` meta-gem. |
| pg | 1.6.3 | Postgres-only — no MySQL/SQLite adapter declared. |
| rspec-rails | 8.0.4 | |
| factory_bot_rails | 6.5.1 | |
| shoulda-matchers | 7.0.1 | Configured for `:active_record` and `:active_model`. |
| zeitwerk | 2.7.5 | Pulled transitively via Rails. Spec coverage at `spec/lib/typed_eav/zeitwerk_loading_spec.rb`. |
| factory_bot | 6.5.6 | |
| rubocop | 1.86.1 | |

## Optional / soft dependencies

These are **detected but not required** at runtime — the gem checks `defined?(...)` and adapts:

| Gem | Where | Behavior |
|---|---|---|
| `acts_as_tenant` | `lib/typed_eav/config.rb` (`DEFAULT_SCOPE_RESOLVER`) | If loaded, the default scope resolver returns `[::ActsAsTenant.current_tenant, nil]` (Phase 1 tuple shape — never a bare scalar). Apps using any other tenancy primitive (Rails `Current`, thread-local, subdomain lookup) override `Config.scope_resolver` in an initializer; resolver shape is **strictly checked** in `TypedEAV.current_scope` and a bare-scalar return raises `ArgumentError`. |
| Active Storage | `lib/typed_eav/engine.rb` (`register_attachment_associations!`), `app/models/typed_eav/field/image.rb`, `app/models/typed_eav/field/file.rb`, `app/models/typed_eav/value.rb` (`_dispatch_image_attached`) | If `::ActiveStorage::Blob` is defined at the engine's `config.after_initialize`, `has_one_attached :attachment` is registered on `TypedEAV::Value`. `Field::Image#cast` raises `NotImplementedError` with an actionable install message when AS is absent; `validate_typed_value` silently no-ops. |

## Indirect platform expectations

| Capability | Required by | Mentioned in |
|---|---|---|
| jsonb columns + `@>` containment operator | Array/MultiSelect query operators (`:any_eq`, `:all_eq`); `before_value`/`after_value`/`context` columns on `typed_eav_value_versions` | `query_builder.rb` lines 116–122; README §"Database Support"; `db/migrate/20260505000000` |
| `text_pattern_ops` btree opclass | `idx_te_values_field_str` index | `db/migrate/20260330000000_create_typed_eav_tables.rb` |
| Partial unique indexes (`WHERE scope IS NOT NULL` / `IS NULL` / `parent_scope IS NOT NULL`) | The Phase 01 paired-triple unique constraints on `(name, entity_type, scope, parent_scope)` — three partials per partition table (`*_uniq_scoped_full`, `*_uniq_scoped_only`, `*_uniq_global`) | `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb`. NB: `nulls_not_distinct: true` (PG ≥ 15) was rejected — the gemspec's Rails floor doesn't pin a PG-server-version, so the gem stays compatible with PG 12/13/14. |
| GIN index | `idx_te_values_json_gin` (used by `:any_eq`/`:all_eq`) | `db/migrate/20260330000000_create_typed_eav_tables.rb` |
| `algorithm: :concurrently` (CREATE INDEX CONCURRENTLY) | Phase 01 parent_scope migration | `db/migrate/20260430000000_*` uses `disable_ddl_transaction!` so production rollouts on million-row tables stay online. |
| `FOR UPDATE` row locking | `Field::Base` and `Section` partition-aware ordering helpers (`move_higher`/`move_lower`/`move_to_top`/`move_to_bottom`/`insert_at`) | Locks the partition's rows in `:id` order — deterministic acquisition order avoids deadlocks across concurrent reorders within the same partition. |
| `ON DELETE SET NULL` | `typed_eav_values.field_id` (Phase 02 cascade policy), `typed_eav_value_versions.value_id` and `field_id` (Phase 04 audit log) | Allows orphan-tolerant rows when `field_dependent: :nullify` is chosen, and preserves audit history when the live Value is destroyed. |

These are why "MySQL/SQLite support would require removing those index types and changing the array query operators" (README §Database Support).

## Dependency surface area summary

- **One runtime dep** (`rails >= 7.1`).
- **Eight dev/test deps** (four pinned rubocop family, four floating).
- **Zero JavaScript runtime deps** — Stimulus controllers in `lib/generators/.../templates/javascript/` are template files copied into consumer apps; the gem itself has no `package.json`.
- **Two soft-detected ecosystem gems** (`acts_as_tenant`, `activestorage`) — both opt-in via `defined?` checks; neither is required.
