# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-29

Two-level scope partitioning. Field and section definitions now partition on
the tuple `(entity_type, scope, parent_scope)`, so an app can scope custom
fields per workspace inside a tenant (or any second axis your domain needs)
without giving up the existing single-scope ergonomics.

### Added

- `parent_scope_method:` kwarg on `has_typed_eav` for two-level partition keys.
  Requires `scope_method:` — declaring `parent_scope_method:` without it
  raises at macro-expansion time.
- `parent_scope:` kwarg on `where_typed_eav`, `with_field`, and
  `typed_eav_definitions` for explicit per-query overrides.
- `TypedEAV.with_scope` accepts a `[scope, parent_scope]` tuple form. The
  scalar form `with_scope(value)` is preserved (treated as `[value, nil]`).
- `idx_te_sections_lookup` index for parity with `idx_te_fields_lookup`.

### Changed

- **BREAKING** `Config.scope_resolver` callables MUST return a 2-element Array
  `[scope, parent_scope]`. v0.1.x callables returning a bare scalar will raise
  `ArgumentError` at the next ambient query — there is no silent fallback. If
  you don't use parent_scope, return `[scope, nil]`.
- `TypedEAV.current_scope` now returns `[scope, parent_scope]` (or `nil`); was
  a String/nil scalar.
- `Config::DEFAULT_SCOPE_RESOLVER` (the `acts_as_tenant` auto-detect) returns
  `[ActsAsTenant.current_tenant, nil]`. The parent_scope slot is `nil`
  because the tenant gem has no parent-scope analog.
- `Field::Base.for_entity` and `Section.for_entity` accept a `parent_scope:`
  kwarg (defaults to `nil`).
- AR uniqueness validators on `Field` (on `:name`) and `Section` (on `:code`)
  include `parent_scope` in their scope key.
- Three-way collision precedence in `definitions_by_name`: full-triple wins,
  then scope-only, then global.
- Paired partial unique indexes now cover the new tuple. Old
  `idx_te_fields_unique_scoped` / `idx_te_fields_unique_global` (and the
  Section equivalents) are replaced by `_uniq_scoped_full` /
  `_uniq_scoped_only` / `_uniq_global` per table.
- `idx_te_fields_lookup` recreated with `parent_scope` between `scope` and
  `sort_order`.

### Validation

- `Field::Base#validate_parent_scope_invariant` rejects rows where
  `parent_scope.present?` and `scope.blank?` (no orphan-parent rows).
- `Section#validate_parent_scope_invariant` is the symmetric guard.
- `Value#validate_field_scope_matches_entity` extended to the parent_scope
  axis: a `Value` whose host's `typed_eav_parent_scope` doesn't match the
  field's `parent_scope` is rejected.

### Migration steps

1. Run `bin/rails typed_eav:install:migrations` to copy
   `AddParentScopeToTypedEavPartitions` into your app.
2. Run `bin/rails db:migrate`. The migration uses `CREATE INDEX CONCURRENTLY`
   for all index changes and is safe on production tables — existing rows
   are not rewritten.
3. Update any custom `TypedEAV.config.scope_resolver` lambda to return
   `[scope, parent_scope]`. If you don't use parent_scope, return
   `[scope, nil]`. A bare scalar return surfaces as `ArgumentError` at
   runtime — there is no silent fallback.
4. Optional: declare `parent_scope_method:` on hosts that have an in-tenant
   partition. Existing single-scope models continue to work without changes.

See the README ["Migrating from v0.1.x"](README.md#migrating-from-v01x)
section for the full guidance, including the orphan-parent invariant and
worked examples.

### References

- `5ff7c30` — migration scaffolding (column + paired partials + lookup index).
- `52014a3` — resolver tuple contract on `with_scope` / `Config`.
- `6c3afb5` — `Field` partition tuple + orphan-parent guard.
- `9c7e916` — `Section` partition tuple + orphan-parent guard (symmetric).
- `c628372` — `parent_scope_method:` macro, query path wiring, `Value`
  cross-axis guard.
- `e5e78a4` — spec coverage (440 examples, 0 failures).

## [0.1.0] - 2026-04-25

Initial release.

[0.2.0]: https://github.com/dchuk/typed_eav/releases/tag/v0.2.0
[0.1.0]: https://github.com/dchuk/typed_eav/releases/tag/v0.1.0
