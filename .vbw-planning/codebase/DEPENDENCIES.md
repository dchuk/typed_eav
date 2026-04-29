# DEPENDENCIES.md

## Runtime dependencies (gemspec)

The gem has **one** runtime dependency:

| Gem | Constraint | Resolved | Why |
|---|---|---|---|
| `rails` | `>= 7.1` | 8.1.3 | Provides `Rails::Engine`, `ActiveRecord` (host for `has_typed_eav` concern, STI Field hierarchy, Value model), `ActiveSupport::Configurable` (used by `Config` and `Registry`), polymorphic associations, generators (Thor), and `accepts_nested_attributes_for`. |

No other runtime gems. Notably absent (intentional):
- No serialization gem (`json` ships with Ruby)
- No image/file gem (Active Storage ships with Rails; only invoked in Phase-2 plans)
- No multi-tenancy gem — `acts_as_tenant` is **auto-detected** in `Config::DEFAULT_SCOPE_RESOLVER` via `defined?(::ActsAsTenant)` but is not a hard dependency

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
| activerecord | 8.1.3 | All AR APIs in use (`store_accessor`, `accepts_nested_attributes_for`, `class_attribute`, polymorphic, STI, Arel matchers) are present in 7.1+. |
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
| `acts_as_tenant` | `lib/typed_eav/config.rb` (`DEFAULT_SCOPE_RESOLVER`) | If loaded, the default scope resolver returns `ActsAsTenant.current_tenant`. Apps using any other tenancy primitive (Rails `Current`, thread-local, subdomain lookup) override `Config.scope_resolver` in an initializer. |
| Active Storage | (Phase-2 plan only — `typed_eav-enhancement-plan.md`) | Image/file field types are planned, not yet implemented. |

## Indirect platform expectations

| Capability | Required by | Mentioned in |
|---|---|---|
| jsonb columns + `@>` containment operator | Array/MultiSelect query operators (`:any_eq`, `:all_eq`) | `query_builder.rb` lines 81–85; README §"Database Support" |
| `text_pattern_ops` btree opclass | `idx_te_values_field_str` index | `db/migrate/20260330000000_create_typed_eav_tables.rb` line 120 |
| Partial indexes (`WHERE scope IS NOT NULL` / `IS NULL`) | Paired unique constraints on `(name, entity_type, scope)` | Migration; PostgreSQL treats NULLs as distinct in plain unique indexes — see comment lines 18–22, 53–56 in the migration |
| GIN index | `idx_te_values_json_gin` (used by `:any_eq`/`:all_eq`) | Migration lines 124–129 |

These are why "MySQL/SQLite support would require removing those index types and changing the array query operators" (README §Database Support).

## Dependency surface area summary

- **One runtime dep** (`rails >= 7.1`)
- **Eight dev/test deps** (four pinned rubocop family, four floating)
- **Zero JavaScript runtime deps** — Stimulus controllers in `lib/generators/.../templates/javascript/` are template files copied into consumer apps; the gem itself has no `package.json`.
