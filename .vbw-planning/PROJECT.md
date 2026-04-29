# typed_eav

Add dynamic custom fields to ActiveRecord models at runtime using native database typed columns instead of jsonb. Hybrid EAV with real indexes, real types, real query performance.

**Core value:** Give Rails apps user-defined fields without trading away type safety, indexability, or query performance — the typed columns + STI design keeps native B-tree/GIN behavior that pure-jsonb EAV gives up.

## Requirements

### Validated
_(Shipped at v0.1.0)_

- Hybrid EAV with seven typed value columns (`string_value`, `text_value`, `boolean_value`, `integer_value`, `decimal_value`, `date_value`, `datetime_value`, `json_value`) on `typed_eav_values`.
- 17 STI field subclasses (Text, LongText, Integer, Decimal, Boolean, Date, DateTime, Select, MultiSelect, IntegerArray, DecimalArray, TextArray, DateArray, Email, Url, Color, Json) — one per file under `app/models/typed_eav/field/`.
- `has_typed_eav` host macro: nested-attributes write paths (`typed_eav_attributes=` by name, `typed_values_attributes=` by id), instance reads (`typed_eav_value`, `typed_eav_hash`), class queries (`where_typed_eav`, `with_field`, `typed_eav_definitions`).
- Single-level multi-tenant scoping via `scope_method:` with `UNSET_SCOPE` / `ALL_SCOPES` sentinels and `TypedEAV.with_scope { }` / `unscoped { }` blocks.
- `QueryBuilder` operator dispatch with per-column-type default operator maps (`column_mapping.rb`).
- Cast tuple contract `[casted, invalid?]` as the single API between fields and `Value`.
- Fail-closed defaults: `require_scope` raises `ScopeRequired`, scaffolded admin returns `head :not_found`, JSON cap at 1 MB, regex pattern validation under `Timeout.timeout(1)`.
- Cross-tenant write guard at the row level (`Value#validate_field_scope_matches_entity`).
- Two Rails generators: `typed_eav:install` (copies engine migrations) and `typed_eav:scaffold` (admin UI + Stimulus controllers + ERB partials per field type).
- Postgres-tuned schema: paired partial unique indexes, GIN on jsonb, btree with `text_pattern_ops`, covering indexes for index-only scans on `(field_id, <typed>_value) include (entity_id, entity_type)`.
- CI: GitHub Actions matrix on Ruby 3.1–3.4 against PostgreSQL 16; rubocop lint job. Release: trusted publishing to RubyGems on `v*` tags via `rubygems/release-gem@v1`.
- Spec suite (RSpec) with dummy Rails app at `spec/dummy/`; opt-in `:unscoped` / `:scoping` example metadata; regression specs in `spec/regressions/` named after analysis rounds.
- Zeitwerk eager-load correctness guarded by a dedicated spec.

### Active
_(M1 — start here)_

- **Two-level scope partitioning:** extend the canonical partition tuple from `(entity_type, scope)` to `(entity_type, scope, parent_scope)` for both fields and sections, with paired partial unique indexes mirroring the existing scope-NULL / scope-NOT-NULL split.

_(Planned, in roadmap order)_

- **M2 — Phase 1 completions:** default-value backfill (`Field#backfill_default!`), configurable cascade behavior on Field destroy, `position` ordering on Field (acts_as_list-style API).
- **M3 — Event system:** `on_value_change` / `on_field_change` callbacks. Dependency for the materialized index in M7.
- **M4 — Versioning:** opt-in `TypedEAV::Versioned` concern + `typed_eav_value_versions` table. Builds on the M3 event/context contract.
- **M5 — Field type expansion:** new field types beyond the v0.1.0 set.
- **M6 — Bulk operations & import/export:** `bulk_set_typed_eav_values`, batch `typed_eav_hash_for(records)`, schema import/export.
- **M7 — Read optimization:** optional materialized-view index for read-heavy use; depends on M3 field-change events.

### Out of Scope

- MySQL or SQLite support — README §"Database Support" explains why; the schema's partial unique / GIN / `text_pattern_ops` features are PG-specific and not aspirational portability targets.
- Standalone documentation site — README is the canonical user docs by design.
- Per-type caster classes for queries — there is one `QueryBuilder` module; field type only declares `value_column` + `cast`. Adding per-type query casters is a non-goal.
- Automatic backfill of defaults onto existing rows when a Field is created — gated behind the explicit `Field#backfill_default!` API in M2.
- Cross-database / multi-shard scoping — single Postgres database is assumed.

## Constraints

- **PostgreSQL required.** jsonb `@>` containment, `text_pattern_ops` btree, partial unique indexes, GIN on jsonb. The README's "Requires PostgreSQL" is load-bearing.
- **Ruby `>= 3.1`, Rails `>= 7.1`.** CI matrix tests Ruby 3.1–3.4. `Gemfile.lock` resolves to Rails 8.1.3.
- **Single hard dependency:** Rails (`>= 7.1`). No other runtime dependencies in the gemspec.
- **Fail-closed by default.** `require_scope` raises rather than silently leaks; scaffold admin returns 404 (not 403) so route existence isn't a leak; opting *out* of these defaults is an explicit decision.
- **Reserved field names:** `id`, `type`, `class`, `created_at`, `updated_at` — `RESERVED_NAMES` validation rejects them so users can't shadow STI dispatch or AR timestamps.
- **JSON value cap:** `MAX_JSON_BYTES = 1_000_000` (1 MB) on `json_value` writes.
- **Regex pattern validation runs under `Timeout.timeout(1)`** — guards against ReDoS in user-supplied `pattern` options.
- **Index name prefix `idx_te_*`** required on every index to fit Postgres' 63-byte identifier limit.
- **Style:** `# frozen_string_literal: true` at the top of every file (excluded only for `db/migrate/**` and `spec/dummy/**`); double-quoted strings; trailing commas in multiline literals; line length 120; rubocop with `rubocop-rails`, `-performance`, `-rspec`.
- **Inline rubocop disables must include a justification on the disable line** and be paired with a matching `enable`.
- **Comments are rationale-first** ("why", not "what"); often phrased "Without this, …"; tied to specific commits where helpful.
- **Conventional Commits** (`<type>(<scope>): <subject>`, present-tense imperative; `!` for breaking changes). Types: `feat`, `fix`, `test`, `refactor`, `perf`, `docs`, `style`, `chore`.
- **One STI subclass per file** under `app/models/typed_eav/field/`. Don't reintroduce a single `types.rb`.
- **Generators ship with explicit Thor `namespace`** declarations (Thor lookup correctness fix per `ccb04b3`).
- **Release pipeline:** RubyGems trusted publishing only — no `RUBYGEMS_API_KEY` in repo. Release workflow asserts `git tag` matches `TypedEAV::VERSION`.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Hybrid EAV with seven typed value columns instead of a single `value jsonb` | Native B-tree/GIN indexes, range-scan optimization, no runtime `CAST(...)` SQL — README §"Why Typed Columns?" articulates the trade explicitly | One `QueryBuilder` module dispatches by `field.class.value_column`; per-field-type query casters are a non-goal |
| STI per field type (one file per subclass) | Each type owns `value_column`, `operators`, `cast`, optional `validate_typed_value` together; one-file-per-class keeps Zeitwerk happy and makes new types easy to add | 17 subclasses under `app/models/typed_eav/field/`; commit `42c4e4c` split a previous single `types.rb` |
| `UNSET_SCOPE` / `ALL_SCOPES` sentinels (NOT `private_constant`) | Need to distinguish "scope omitted → resolve from ambient" from "scope: nil → globals only"; `nil` alone can't carry that distinction | Public sentinels by design; `unscoped { }` block triggers the multimap branch in `where_typed_eav` for cross-tenant audit queries |
| Fail-closed `require_scope = true` (raises `ScopeRequired`) | Forgetting to set scope must not silently leak other tenants' data; the README §"Disabling enforcement" explicitly recommends flipping it back on after audit | `resolve_scope` raises (lines 270–278); cross-tenant write guard at row-level via `Value#validate_field_scope_matches_entity` is the second-line defense |
| Scaffold admin returns `head :not_found`, not `403` | Revealing route existence is itself a leak | `authorize_typed_eav_admin!` is on the generated controller (not `ApplicationController`) so users wire it explicitly to their auth |
| Cast tuple `[casted, invalid?]` as the only contract | Pre-`eef8e51` there was a `cast_value` side-channel; collapsing to one tuple removed a duplicate code path | `Value#value=` and `Value#validate_value` consume the tuple; field subclasses return it from `cast` |
| Array cast is all-or-nothing (`IntegerArray`, `DecimalArray`, `DateArray`) | Failed form re-render with bad elements silently removed would confuse the user | The whole array is marked `:invalid` if any element fails to cast — never a partial cast |
| Registry not reset between specs | `has_typed_eav` registrations from class loading must persist or registration tests are meaningless | `spec_helper.rb` deliberately omits the reset; the comment documents why |
| Earlier "wrap every spec in `unscoped`" → opt-in `:unscoped` / `:scoping` metadata | Blanket wrapping masked scope+global name-collision bugs in the class-level query path | Default is no wrapping; `spec/regressions/review_round_2_*` and `review_round_3_collision_spec.rb` are the tests that surfaced when the default flipped |
| Renamed `typed_fields` → `typed_eav` (commits `7d843be`, `54efdb3`) | The "EAV" framing is more honest about what the gem is and avoids collision with `typed-form` / `typed_field`-style names | `inflect.acronym "EAV"` so `TypedEAV` round-trips through underscore/camelize; CHANGELOG starts cleanly at `[0.1.0] - 2026-04-25` |
| RubyGems trusted publishing via `rubygems/release-gem@v1` | No long-lived API key in the repo or CI secrets | Release workflow on `v*` tags asserts `git tag` matches `TypedEAV::VERSION`, then publishes |
| Pattern validation under `Timeout.timeout(1)` | A ReDoS regex in a `Field::Text` `pattern` option could hang requests | `validate_pattern` rescues `RegexpError` + `Timeout::Error`, reports against the value |
