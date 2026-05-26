# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-05-26

Closes four follow-up gaps (PRD #15) surfaced when a downstream Rails app
consolidated onto 0.3.2 and found four places where the gem's public
surface forced workarounds: a missing per-record-varying bulk-write entry
point, a dedup defect on unsaved entities with in-memory `typed_values`
builds, an `:is_null` operator that couldn't honor the user-intuitive "is
empty" semantic, and a portable-schema shape that was wrong for in-app
snapshot stores. A fifth gap (G5) was scoped down to a documentation
promotion on the existing `Partition` module rather than a new wrapper.

All five changes are additive — no public-API breakage. New entry points
default to current shapes; existing callers of `bulk_set_typed_eav_values`,
`with_field`/`where_typed_eav` (without the new kwarg), `export_schema`,
and `initialize_typed_values` (on persisted records with no in-memory
builds) keep their behavior byte-for-byte. New ADR: ADR-0006 pins the G3
`include_missing` strategy as set-complement at the `FilterQuery` altitude
(rejects the LEFT JOIN framing the PRD originally sketched).

### Added

- `Entity.bulk_set_typed_eav_values_per_record(values_by_record,
  version_grouping: :default)` — per-record-varying sibling to
  `bulk_set_typed_eav_values`. Takes a `Hash<host_record,
  Hash<field_name, value>>` and routes each record's value-set through
  the same outer-transaction-plus-savepoint-per-record envelope,
  returning the same `{ successes: [...], errors_by_record: { record
  => errors_hash } }` shape. Supports sparse-update semantics
  (unlisted fields untouched), `{ _destroy: true }` value-removal
  shorthand, mixed-scope records (each record honors its own
  `[scope, parent_scope]` even inside `TypedEAV.unscoped { ... }`),
  and `:per_field` UUID allocation across the union of field names.
  Empty input short-circuits without opening a transaction. Internally,
  both public executors (`BulkWrite.execute` and
  `BulkWrite.execute_per_record`) now share a single
  `execute_pairs(pairs, effective_grouping, field_uuids)` helper that
  takes ordered `[record, vbn]` pairs — preserving `execute`'s byte-
  for-byte behavior on duplicate in-memory instances of the same
  persisted row (Hash-key collision is documented as a gotcha only
  on the new API). G1 (issue #18).

- `Entity.with_field` and `Entity.where_typed_eav` accept an opt-in
  `include_missing:` keyword (default `false`). Threaded through to
  `FilterQuery#initialize`. When paired with `:is_null`, the operator
  matches hosts with **no non-NULL value** for the field — including
  hosts that have no `typed_eav_values` row at all (Reading A: the
  user-intuitive "is empty" semantic). Implemented as a set-complement
  against `:is_not_null` at the `FilterQuery` altitude; `QueryBuilder`
  is not modified. With `:is_not_null` the kwarg is a no-op; with any
  other operator (`:eq`, `:gt`, `:contains`, `:references`, `:between`,
  `:starts_with`, etc.) it is silently ignored — filter UIs can pass
  the kwarg uniformly without branching per operator. On the multimap
  (`ALL_SCOPES`) branch, "no non-NULL value" reads across all matching
  field definitions for the name: a host matches iff none of the
  per-tenant field defs have a non-NULL value for it. G3 (issue #19).
  See ADR-0006.

- `TypedEAV::SchemaPortability.export_snapshot_schema(entity_type:,
  scope: nil, parent_scope: nil)` — sibling to `export_schema` that
  returns a lean, restore-oriented projection in a versioned envelope:
  `{ "snapshot_schema_version" => 1, "fields" => [...] }`. Per-field
  entries carry only `name`, `field_type_name`, `required`,
  `sort_order`, `options`, and (for optionable types) `options_data`
  — `entity_type`, `scope`, `parent_scope`, `type` (AR STI class name),
  `field_dependent`, and `default_value_meta` are omitted. Non-optionable
  fields omit the `options_data` key entirely (absent, not nil). The
  `snapshot_schema_version` integer will be bumped explicitly when the
  inner shape evolves — it is not frozen forever. Fields are ordered by
  `sort_order` and `options_data` mirrors the loaded/unloaded ordering
  rule used by `export_schema`. G4 (PRD #15).

### Documentation

- `TypedEAV::Partition.find_visible_section!` is **documented-public**
  going forward. Apps building admin UIs that need to authorize a
  section lookup before editing, rendering, or destroying it should
  call this rather than `Section.find(id)`. Method shape and behavior
  do not change — this is a documentation clarification that promotes
  an existing, already-shipping method into the documented surface
  area, alongside the sibling `Partition` methods (`visible_fields`,
  `effective_fields_by_name`, `definitions_by_name`,
  `definitions_multimap_by_name`, `visible_sections`). G5 (issue #20).

### Fixed

- `InstanceMethods#initialize_typed_values` no longer builds duplicate
  rows on entities that already have in-memory `typed_values` builds
  (form path with `field_id`, scripting path via `typed_eav_attributes=`,
  or direct `typed_values.build(...)` on a persisted record). Covers
  three cases: (1) new record + nested attributes, (2) new record +
  scripting setter, (3) persisted record + unloaded association + a
  build that lives in `target` without flipping `@loaded`. The
  persisted-no-builds fast path still uses `pluck` only — no extra
  association load. Dedup also tolerates an in-memory build whose
  `field_id` is nil but whose `field` association is set
  (`field_id || field&.id` fallback). G2 (PRD #15).

## [0.3.2] - 2026-05-25

Documentation-only release. No code or behavior changes.

### Fixed

- README §"Architecture" — Per-record reads/writes subsection erroneously
  listed `typed_eav_changes` as a public `InstanceMethods` API (added in
  0.3.1). That method does not exist on `InstanceMethods`. Replaced with
  the actual existing methods (`typed_eav_definitions` and noting the
  `typed_eav=` alias). Dirty tracking for typed-EAV writes is tracked as
  a feature request — not implemented in this release.

## [0.3.1] - 2026-05-25

Documentation-only release. No code or behavior changes.

### Added

- README §"Architecture" — full overview of the post-0.3.0 internal
  module layout: macro entry (`HasTypedEav`), the two-altitude query
  pattern (`EntityQuery` → `FilterQuery` → `QueryBuilder`), `BulkRead`
  and `BulkWrite` siblings, `InstanceMethods`, `Field::TypedStorage`
  concern, family intermediate bases (`ValidatedString`, `RangeBounded`,
  `Optionable`), `ScopeTuple`, `Partition`, `EventDispatcher`, and the
  Phase-6 modules (`SchemaPortability`, `CSVMapper`). Anchored to ADRs
  0001–0005 throughout.

### Removed

- `TEST_PLAN.md` — pre-0.3.0 test-sweep planning artifact (2026-04-08).
  Described specs for modules deleted in #9. Git history preserves it.
- `typed_eav-enhancement-plan.md` — pre-0.3.0 phased roadmap. References
  v0.1.0 line numbers and Phase-1 work that has since shipped. Git
  history preserves it.

## [0.3.0] - 2026-05-25

Pre-1.0 architecture cleanup arc (issues #9–#13). No public-API breakage
for host AR models or registered custom field types; behavior changes are
limited to two latent-bug fixes (now raised at field-save) and one
internal helper relocation (see "Changed" below). Anchored by ADRs
0001–0005.

### Added

- New `TypedEAV::Field::TypedStorage` concern (auto-included on
  `Field::Base`) collapses the prior storage stack into three paired
  override points: `read_value(record)`, `write_value(record, casted)`,
  `apply_default(record)`. Custom multi-cell field types now extend
  `Field::Base` directly and override only these methods. See README
  §"Multi-cell field types" and ADR-0001 (issue #9).
- New top-level `TypedEAV::ScopeTuple` module exposes the
  `[scope, parent_scope]` normalization surface: `normalize_permissive`,
  `normalize_strict`, and `invariant_satisfied?`. Used by `Partition`,
  `TypedEAV.with_scope`, `Config#resolve_scope`, and the query path
  (issue #10).
- New top-level query objects extracted from `HasTypedEAV`:
  `TypedEAV::EntityQuery` (class-method orchestration on host AR models),
  `TypedEAV::FilterQuery` (multi-filter SQL composition for
  `where_typed_eav` / `with_field`), and `TypedEAV::BulkRead` (bulk
  per-record reads via `eav_values_for`). See ADR-0002 (issue #11).
- New field family intermediate bases collapse per-leaf duplication:
  - `TypedEAV::Field::ValidatedString` — min/max-length + regex-pattern
    validation surface for `string_value`-backed types (parent of
    `Email` and `Url`).
  - `TypedEAV::Field::RangeBounded` — min/max-bound validation helpers
    for comparable single-value types (parent of `Integer`, `Decimal`,
    `Date`, `DateTime`).
  - `TypedEAV::Field::Optionable` — concern (not parent) for types that
    draw values from a `Field::Option` set; included by `Select` and
    `MultiSelect`.

  See README §"Family intermediate bases (extension points)" and
  ADR-0004 (issue #12).

### Changed

- **Internal helper move.** `TypedEAV::HasTypedEAV.definitions_by_name`
  and `TypedEAV::HasTypedEAV.definitions_multimap_by_name` moved to
  `TypedEAV::Partition.definitions_by_name` /
  `TypedEAV::Partition.definitions_multimap_by_name`. These helpers were
  technically callable from application code but not documented;
  partition-tuple precedence is a partition concept and the new home
  reflects that. External callers (if any) should update the call site.
  See ADR-0002 (issue #11).
- `TypedEAV::HasTypedEAV` is now a slim macro module
  (`lib/typed_eav/has_typed_eav.rb`) that delegates to a per-instance
  methods file (`lib/typed_eav/has_typed_eav/instance_methods.rb`) plus
  the new `EntityQuery` / `FilterQuery` / `BulkRead` objects. Public
  class-method and instance-method signatures on host AR models are
  unchanged. See ADR-0002 (issue #11).
- Field validation now runs paired-bound checks at field-save time, not
  only at value-write time:
  - `Field::Email` / `Field::Url` (via `ValidatedString`) reject
    `max_length < min_length` when the field record is saved.
  - `Field::Date` / `Field::DateTime` (via `RangeBounded` leaves) reject
    inverted `min_date`/`max_date` (and `min_datetime`/`max_datetime`)
    bounds when the field record is saved.

  Both were latent bugs prior to v0.3.0 — the bound mismatch was only
  surfaced when a `Value` was written. Authors of custom field types
  that store inverted bounds will now see the validation fail earlier.
  See ADR-0004 (issue #12).

### Removed

- `TypedEAV::Field::FieldStorageContract`,
  `TypedEAV::Field::CurrencyStorageContract`, and
  `TypedEAV::Field::ColumnMapping` are deleted; their surface lives on
  `Field::TypedStorage`. ADR-0001 (issue #9).
- `TypedEAV::Partition.validate_tuple!` is deleted; callers use
  `TypedEAV::ScopeTuple.normalize_strict` directly. Issue #10.

### Internal

- `TypedEAV::EventDispatcher` is retained as the synchronous broker
  between `TypedEAV::Hooks` and `ActiveSupport::Notifications`. The
  cleanup arc explicitly considered collapsing it and rejected that:
  the broker is the seam where event-name normalization and the
  `notifications: false` opt-out live. See ADR-0003.
- The Phase-6 modules — `TypedEAV::BulkWrite`,
  `TypedEAV::Importers::CSVMapper`, and
  `TypedEAV::SchemaPortability::*` — remain independent top-level
  modules. The cleanup arc explicitly considered consolidating them
  under a single `TypedEAV::Operations` namespace and rejected that:
  the modules share no internal contract and the namespace would be
  cosmetic. See ADR-0005.
- Cyclomatic-complexity rubocop disables that previously masked the
  `HasTypedEAV` mega-module are gone — the split files clear the
  default complexity thresholds.

### References

- Issue #9 — `Field::TypedStorage` concern.
- Issue #10 — `ScopeTuple` extraction.
- Issue #11 — `EntityQuery` / `FilterQuery` / `BulkRead` split.
- Issue #12 — Field family intermediate bases.
- Issue #13 — release coordination.
- ADR-0001 — collapse field storage stack.
- ADR-0002 — split `HasTypedEAV` into query objects.
- ADR-0003 — retain `EventDispatcher` as broker.
- ADR-0004 — field family intermediate bases.
- ADR-0005 — keep Phase-6 modules independent.

## [0.2.1] - 2026-05-08

Metadata-only release.

### Changed

- Updated the RubyGems package author metadata to `dchuk`.

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

[0.3.2]: https://github.com/dchuk/typed_eav/releases/tag/v0.3.2
[0.3.1]: https://github.com/dchuk/typed_eav/releases/tag/v0.3.1
[0.3.0]: https://github.com/dchuk/typed_eav/releases/tag/v0.3.0
[0.2.1]: https://github.com/dchuk/typed_eav/releases/tag/v0.2.1
[0.2.0]: https://github.com/dchuk/typed_eav/releases/tag/v0.2.0
[0.1.0]: https://github.com/dchuk/typed_eav/releases/tag/v0.1.0
