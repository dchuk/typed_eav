# STACK.md

## Project Type

**Ruby gem** — `typed_eav` v0.2.0. Distributed as a Rails Engine; published to RubyGems via GitHub Actions trusted publishing.

Summary (from gemspec):
> "Add dynamic custom fields to ActiveRecord models at runtime using native database typed columns instead of jsonb blobs. Hybrid EAV with real indexes, real types, real query performance."

Homepage: https://github.com/dchuk/typed_eav
License: MIT
Author: Darrin Chuk

## Core Runtime

| Component | Version | Notes |
|---|---|---|
| Ruby | `>= 3.1` | `required_ruby_version` in gemspec; CI matrix tests 3.1, 3.2, 3.3, 3.4 |
| Rails | `>= 7.1` | Single hard dependency; resolves to `8.1.3` in `Gemfile.lock` |
| PostgreSQL | required | The README states "Requires PostgreSQL"; jsonb `@>`, `text_pattern_ops` btree, partial GIN/unique indexes, `algorithm: :concurrently`, and `FOR UPDATE` row locking are PG-specific |
| Zeitwerk | `~> 2.6` (via Rails) | Standard Rails autoloading; a dedicated spec (`spec/lib/typed_eav/zeitwerk_loading_spec.rb`) guards eager-load correctness |

## Test / Dev Stack

| Component | Pin | Purpose |
|---|---|---|
| RSpec / rspec-rails | `~> 8.0` | Test framework (declared in `Gemfile`, no version pin; lock at 8.0.4) |
| factory_bot_rails | unpinned in `Gemfile`; lock at 6.5.1 | Factories live in `spec/factories/typed_eav.rb` |
| shoulda-matchers | unpinned in `Gemfile`; lock at 7.0.1 | AR validation/association matchers |
| pg | unpinned in `Gemfile`; lock at 1.6.3 | Postgres adapter for the dummy app |
| rubocop | `~> 1.86` | Plus `rubocop-rails ~> 2.34`, `rubocop-performance ~> 1.26`, `rubocop-rspec ~> 3.9`. CI runs `bundle exec rubocop --format github` |

## Test Harness

- **Dummy Rails app at `spec/dummy/`** — minimal Rails environment for the engine's specs (config in `spec/dummy/config/{boot,environment,routes,database,storage.yml}`). Test models (`Contact`, `Product`, `Project`) live in `spec/dummy/app/models/test_models.rb` and are explicitly required from `spec_helper.rb` because Zeitwerk can't autoload three classes from one file.
  - `Contact` — `has_typed_eav scope_method: :tenant_id` (scoped, single-axis).
  - `Product` — `has_typed_eav types: [:text, :integer, :decimal, :boolean]` (unscoped, type-restricted).
  - `Project` — `has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id` (Phase 01 two-level partition host).
- **Engine migrations are added to the test schema** by `spec_helper.rb` (`ActiveRecord::Migrator.migrations_paths << TypedEAV::Engine.root.join("db/migrate")`).
- **Pending dummy-app migrations applied at suite start** — Phase 05 added `spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb`; `spec_helper.rb` runs `MigrationContext.new(dummy_path).migrate` so a fresh check-out doesn't fail on the missing `active_storage_blobs` table.
- **Transactional fixtures** + per-example metadata flags `:unscoped`, `:scoping`, `:event_callbacks`, `:real_commits` (see TESTING.md).
- **Active Storage soft-detect**: `Engine.register_attachment_associations!` registers `has_one_attached :attachment` on `TypedEAV::Value` only when `::ActiveStorage::Blob` is defined. The dummy app pulls the full `rails` meta-gem so AS is always loaded under the test suite; production hosts that exclude AS get a no-op.

## Generators (consumer-facing)

The gem ships two Rails generators, both registered with explicit `namespace` declarations (Thor lookup correctness fix per `ccb04b3`):

| Generator | Namespace | Purpose |
|---|---|---|
| `typed_eav:install` | copies engine migrations | Wraps `rake typed_eav:install:migrations`; prints next-steps banner |
| `typed_eav:scaffold` | controller + concern + helper + Stimulus controllers + views + initializer + routes | Mounts an admin UI at `/typed_eav_fields`; **fail-closed** authorization hook (`authorize_typed_eav_admin!` returns `head :not_found`) by design |

## Front-end (in scaffold output only)

| Component | Notes |
|---|---|
| Hotwire / Stimulus | Two Stimulus controllers ship as scaffold templates: `typed_eav_form_controller.js`, `array_field_controller.js`. The gem itself has no front-end runtime — it just emits JS files when the consumer runs the scaffold generator. |
| ERB partials | Per-type form input partials (`_text.html.erb`, `_integer.html.erb`, etc.) and admin views, copied into the host app's `app/views/typed_eav/`. |

## CI / Release

| Tool | File | Trigger |
|---|---|---|
| GitHub Actions — CI | `.github/workflows/ci.yml` | push/PR to `main`. Lint job + RSpec matrix job (Ruby 3.1–3.4) against Postgres 16. |
| GitHub Actions — Release | `.github/workflows/release.yml` | tags matching `v*`. Verifies tag matches `TypedEAV::VERSION`, then publishes via `rubygems/release-gem@v1` (trusted publishing — no API key in repo). |

## Versioning

Single source of truth: `lib/typed_eav/version.rb` (`TypedEAV::VERSION = "0.2.0"`). The gemspec reads it directly. Release workflow asserts `git tag` matches.
