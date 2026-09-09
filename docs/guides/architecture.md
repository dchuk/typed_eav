---
title: "Architecture"
nav_group: Project
---

# Architecture

[Documentation home](../index.md)

Current internal module layout. Most consumers never reach for these directly — the public surface is the `has_typed_eav` macro and the instance/class methods it installs — but the split matters if you're extending the gem, debugging an integration, or evaluating it for production. Decisions are anchored by ADR-0001 through ADR-0013.

## Macro entry: `HasTypedEav`

`lib/typed_eav/has_typed_eav.rb` (~120 LOC) is the macro shell. When you call `has_typed_eav` on an AR model, it:

1. `extend`s `TypedEAV::EntityQuery` onto the class (class-level query methods).
2. `include`s `TypedEAV::HasTypedEav::InstanceMethods` (per-record accessors).
3. Wires scope/parent-scope kwargs into the model's class-level configuration.
4. Registers the model with `TypedEAV::Registry`.

The macro is intentionally thin. All real behavior lives in the modules it pulls in.

## Class-level reads: two-altitude query pattern

```
Contact.where_typed_eav(...)         ← public class method
       │
       ▼
TypedEAV::EntityQuery                 ← high altitude: orchestrator
  • resolves scope/parent_scope from ambient context or explicit kwargs
  • owns the UNSET_SCOPE / ALL_SCOPES sentinels
  • delegates to FilterQuery
       │
       ▼
TypedEAV::FilterQuery                 ← multi-filter composition
  • normalizes filter input shapes (positional, hash, hash-of-hashes)
  • looks up field definitions via TypedEAV::Partition
  • per filter, asks QueryBuilder for the SQL fragment
  • unions/intersects per-field entity-id sets
  • returns an ActiveRecord::Relation scoped to the host model
       │
       ▼
TypedEAV::QueryBuilder                ← low altitude: per-field SQL primitive
  • turns a single (field, op, value) into a WHERE clause against typed_eav_values
  • knows about typed-column projections (integer_value, string_value, etc.)
  • knows about operator-specific column choice (currency-cents vs currency-code)
```

`QueryBuilder` is the single place that decides "given this field and this operator, which column and which SQL fragment?" `FilterQuery` never builds SQL fragments directly; `EntityQuery` never touches columns. Splitting the two altitudes keeps custom field types extending only the column-mapping surface (`value_column`, `operators`, `operator_column`) without ever subclassing `FilterQuery`.

Scalar ordering and summaries are a separate `EntityQuery` delegation to
`ScalarQuery`: it resolves one winning definition, checks scalar support, and
builds SQL over the field's declared native column. It does not add operators
to the filter DSL or load the host/Value graph to calculate summaries.

## Per-record reads/writes: `InstanceMethods`

`lib/typed_eav/has_typed_eav/instance_methods.rb` (~250 LOC) holds the per-record API:

- `typed_eav_value(name)` / `typed_eav_hash` — reads
- `set_typed_eav_value(name, value)` / `typed_eav_attributes=` (aliased as `typed_eav=`) — writes
- `typed_eav_definitions` — resolved field-definitions map for the host record
- `typed_eav_scope` / `typed_eav_parent_scope` — scope resolution per record

Every method uses `TypedEAV::Partition.definitions_by_name` so the collision-precedence rules for ambient/explicit/parent scopes are computed in one place.

## Partition visibility: `Partition`

Host applications that need to inspect effective schema should use the
documented-public `TypedEAV::Partition` seam rather than rebuilding tuple
predicates. It exposes `visible_fields`, `effective_fields_by_name`,
`definitions_by_name`, `definitions_multimap_by_name`, `visible_sections`,
and `find_visible_section!`. These methods preserve global, scope-only, and
full-tuple precedence; ADR-0006 additionally fixes include-missing set
composition at the `FilterQuery` altitude.

## Field types and storage: `Field::TypedStorage`

`TypedEAV::Field::Base` is the STI parent of every field type. The shared storage surface lives in the `TypedEAV::Field::TypedStorage` concern (`lib/typed_eav/field/typed_storage.rb`, ~200 LOC), auto-included on `Field::Base`. Per [ADR-0001](../adr/0001-collapse-column-mapping-stack.md), it provides:

- **Class DSL**: `value_column`, `value_columns`, `operators`, `operator_column`, `supported_operators` — describe where typed values live and which operators they support.
- **Instance override points**: `read_value(record)`, `write_value(record, casted)`, `apply_default(record)` — the three methods a multi-cell field type overrides.
- **Concrete snapshot helpers**: `value_changed?`, `before_snapshot`, `after_snapshot` — derived automatically from `value_columns`; not overridable.

Custom multi-cell field types subclass `Field::Base` directly and override only the three instance methods. See [Multi-cell field types](fields.md#multi-cell-field-types) for `Currency` as the canonical worked example.

## Field families: intermediate STI bases

Per [ADR-0004](../adr/0004-field-family-intermediate-bases.md), three intermediate STI parents factor shared validation behavior out of `Field::Base`:

- **`TypedEAV::Field::ValidatedString`** — parent of `Text`, `Email`, `Url`. Owns string-length and pattern-validation helpers including `max_gte_min_length` (which now covers Email/Url, not just Text).
- **`TypedEAV::Field::RangeBounded`** — parent of `Integer`, `Decimal`, `Date`, `DateTime` (and `Percentage < Decimal`). Owns range-validation helpers including `validates :max, comparison: { greater_than_or_equal_to: :min }` (which now covers Date/DateTime, not just Integer/Decimal).
- **`TypedEAV::Field::Optionable`** — a Rails concern included by `Select` and `MultiSelect`. Owns the public-facing sorted `allowed_values` reader and the option-inclusion validators.

`Color`, `Boolean`, `Json`, and the array field types (`TextArray`, `IntegerArray`, `DecimalArray`, `DateArray`) remain direct children of `Field::Base`. See [Family intermediate bases](fields.md#family-intermediate-bases-extension-points) for extension examples.

## Scope tuple normalization: `ScopeTuple`

`TypedEAV::ScopeTuple` (`lib/typed_eav/scope_tuple.rb`, ~120 LOC) is the canonical source of truth for the `(scope, parent_scope)` partition tuple. It provides:

- `normalize_permissive(scope)` — coerces input to a tuple; tolerates bare scalars (used by `with_scope`, `normalize_scope`, `Field#validate_parent_scope_invariant`).
- `normalize_strict(scope)` — same shape, but raises on bare-scalar input (used by `current_scope`; preserves Phase-1's asymmetric contract that `Config.scope_resolver` must return a tuple).
- `invariant_satisfied?(scope, parent_scope)` — Boolean check for the orphan-parent invariant (`parent_scope` set without `scope` = invalid).

Each calling site keeps its own response policy (raise / AR error / silent narrow) using the Boolean return — `ScopeTuple` is a predicate, not an enforcer.

## Partition tuple helpers: `Partition`

`TypedEAV::Partition` (`lib/typed_eav/partition.rb`, ~100 LOC) owns the `(entity_type, scope, parent_scope)` precedence rules:

- `definitions_by_name(model, scope, parent_scope)` — returns the field-definitions map for a single resolved partition.
- `definitions_multimap_by_name(model)` — returns the cross-partition multimap used by `unscoped { }` blocks.
- `visible_fields(model, scope, parent_scope)` / `visible_sections(...)` — scope-respecting field/section iteration with the orphan-parent invariant inlined via `ScopeTuple.invariant_satisfied?`.

The definitions helpers used to live as class methods on `HasTypedEav` before 0.3.0. They moved to `Partition` per [ADR-0002](../adr/0002-entity-query-orchestration.md) because they describe the partition domain, not the macro.

## Events: `EventDispatcher`

`TypedEAV::EventDispatcher` (`lib/typed_eav/event_dispatcher.rb`, ~150 LOC) is the broker for `on_value_change` and `on_field_change` callbacks. Per [ADR-0003](../adr/0003-keep-event-dispatcher-broker.md), it intentionally stays a broker rather than getting absorbed into either `Value` or `Field` — its multi-publisher / multi-subscriber shape doesn't belong on either model. See [Event hooks](events-and-versioning.md#event-hooks) for the public callback contract.

## Schema portability and CSV: independent modules

`TypedEAV::SchemaPortability` and `TypedEAV::CSVMapper` (Phase-6 modules) are deliberately decoupled from the core read/write path per [ADR-0005](../adr/0005-keep-phase-six-modules-independent.md). They depend on the public `has_typed_eav` macro surface, never on internal modules.

See [Bulk operations](bulk-operations.md) for bulk reads, writes, and their guarantees.
