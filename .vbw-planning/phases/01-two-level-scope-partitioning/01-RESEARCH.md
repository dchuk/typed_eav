---
phase: "01"
title: "Two-level scope partitioning — research"
type: research
confidence: high
generated: 2026-04-29
---

# Phase 01 Research: Two-level scope partitioning

---

## 1. Current partition representation

### `scope` column on `Field` and `Section`

Both tables have a nullable `t.string :scope` column defined in the single migration file:

- `typed_eav_fields.scope` — migration line 40: `t.string :scope  # optional tenant/context scoping`
- `typed_eav_sections.scope` — migration line 12: `t.string :scope`

Migration file: `db/migrate/20260330000000_create_typed_eav_tables.rb`

### Paired partial unique indexes (current)

**`typed_eav_fields` table** (migration lines 57–66):
```ruby
t.index %i[name entity_type scope],
        unique: true,
        where: "scope IS NOT NULL",
        name: "idx_te_fields_unique_scoped"          # 30 bytes — fits 63-byte limit
t.index %i[name entity_type],
        unique: true,
        where: "scope IS NULL",
        name: "idx_te_fields_unique_global"           # 29 bytes — fits 63-byte limit
```

**`typed_eav_sections` table** (migration lines 23–29):
```ruby
t.index %i[entity_type code scope],
        unique: true,
        where: "scope IS NOT NULL",
        name: "idx_te_sections_unique_scoped"         # 32 bytes — fits 63-byte limit
t.index %i[entity_type code],
        unique: true,
        where: "scope IS NULL",
        name: "idx_te_sections_unique_global"         # 33 bytes — fits 63-byte limit
```

**`typed_eav_fields` lookup index** (migration line 66):
```ruby
t.index %i[entity_type scope sort_order name], name: "idx_te_fields_lookup"   # 22 bytes
```
This index covers the default ordering + scoped lookup in one scan. Phase 1 must also drop and recreate this index to include `parent_scope`.

### Methods constructing or comparing the partition tuple

| Location | Line(s) | Description |
|---|---|---|
| `app/models/typed_eav/field/base.rb` | 35 | AR uniqueness validation: `scope: %i[entity_type scope]` |
| `app/models/typed_eav/field/base.rb` | 44–47 | `Field::Base.for_entity` scope: `where(entity_type:, scope: [scope, nil].uniq)` |
| `app/models/typed_eav/section.rb` | 13 | AR uniqueness validation: `scope: %i[entity_type scope]` |
| `app/models/typed_eav/section.rb` | 20–22 | `Section.for_entity` scope: `where(entity_type:, scope: [scope, nil].uniq)` |
| `lib/typed_eav/has_typed_eav.rb` | 41–43 | `HasTypedEAV.definitions_by_name` — sorts by `d.scope.nil? ? 0 : 1` (global loses) |
| `lib/typed_eav/has_typed_eav.rb` | 154–158 | `where_typed_eav` — branches on `all_scopes`; calls `Field::Base.for_entity(name, scope: resolved)` |
| `app/models/typed_eav/value.rb` | 138–147 | `validate_field_scope_matches_entity` — compares `field.scope` to `entity.typed_eav_scope` |

---

## 2. Sentinel pattern (today)

### Constant definitions

Both sentinels are defined inside `TypedEAV::HasTypedEAV::ClassQueryMethods`:

```ruby
# lib/typed_eav/has_typed_eav.rb lines 99–104
UNSET_SCOPE = Object.new.freeze   # line 99
ALL_SCOPES  = Object.new.freeze   # line 104
```

Neither is `private_constant`. They live inside a nested module so consumer apps can't reference them directly — by convention only.

### Thread-local stack (current shape)

Two thread-local keys, both defined in `lib/typed_eav.rb` lines 23–25:

```ruby
THREAD_SCOPE_STACK = :typed_eav_scope_stack   # line 23
THREAD_UNSCOPED    = :typed_eav_unscoped      # line 24
private_constant :THREAD_SCOPE_STACK, :THREAD_UNSCOPED
```

The stack stores raw scalar/AR values pushed by `with_scope(value)`. `current_scope` pops `stack.last` and normalizes via `normalize_scope`. The stack stores a **single scope value per frame** today — not a tuple.

### Sentinel call sites

| Method | File:line | How sentinel is used |
|---|---|---|
| `where_typed_eav` | `has_typed_eav.rb:120` | Default kwarg: `scope: UNSET_SCOPE`; branches on `resolved.equal?(ALL_SCOPES)` at line 152 |
| `with_field` | `has_typed_eav.rb:215` | Default kwarg: `scope: UNSET_SCOPE`; passes through to `where_typed_eav` |
| `typed_eav_definitions` (class) | `has_typed_eav.rb:230` | Default kwarg: `scope: UNSET_SCOPE`; branches on `resolved.equal?(ALL_SCOPES)` at line 232 |
| `resolve_scope` | `has_typed_eav.rb:246–279` | Checks `explicit.equal?(UNSET_SCOPE)` line 248; returns `ALL_SCOPES` if `TypedEAV.unscoped?` line 251 |

### Sentinel flow through resolver chain

`resolve_scope` (lines 246–279):
1. `explicit.equal?(UNSET_SCOPE)` — not set → proceed to ambient resolution
2. `TypedEAV.unscoped?` → return `ALL_SCOPES`
3. `typed_eav_scope_method` nil → return `nil` (non-scoped model short-circuit; lines 252–262)
4. `TypedEAV.current_scope` → from `with_scope` stack or `Config.scope_resolver`
5. Fail-closed raise if `require_scope && resolved.nil?` (lines 270–276)

---

## 3. Resolver chain

### `Config.scope_resolver` definition

`lib/typed_eav/config.rb` line 55:
```ruby
config_accessor :scope_resolver, default: DEFAULT_SCOPE_RESOLVER
```

### `Config::DEFAULT_SCOPE_RESOLVER` definition

`lib/typed_eav/config.rb` lines 22–24:
```ruby
DEFAULT_SCOPE_RESOLVER = lambda {
  ::ActsAsTenant.current_tenant if defined?(::ActsAsTenant)
}
```

Returns a single scalar (or `nil`). This must become a two-element tuple `[scope, parent_scope]` in Phase 1. When `ActsAsTenant` is present, the parent_scope slot is `nil` (no parent-scope analog in AAT).

### Consumers of `scope_resolver`

| Location | Line(s) | How it consumes the resolver |
|---|---|---|
| `lib/typed_eav.rb` | 50 | `normalize_scope(Config.scope_resolver&.call)` — one scalar today |
| `lib/typed_eav/config.rb` | 84–87 | `Config.reset!` — restores `scope_resolver` to `DEFAULT_SCOPE_RESOLVER` |
| `spec/lib/typed_eav/scoping_spec.rb` | 8, 55, 68, 80, 88, 141 | Test specs stub `scope_resolver` with `-> { "value" }` — all will break on upgrade to tuple contract |

### Where resolver result is unpacked / used

`TypedEAV.current_scope` (`lib/typed_eav.rb` lines 44–51):
```ruby
def current_scope
  return nil if Thread.current[THREAD_UNSCOPED]
  stack = Thread.current[THREAD_SCOPE_STACK]
  return normalize_scope(stack.last) if stack.present?
  normalize_scope(Config.scope_resolver&.call)
end
```

`normalize_scope` is a scalar coercion (`value.respond_to?(:id) ? value.id.to_s : value.to_s`). This must expand to return `[scope, parent_scope]` in Phase 1. All callers of `current_scope` must be updated to unpack the tuple.

The only consumer of `current_scope` in production code is `resolve_scope` at `has_typed_eav.rb` line 265:
```ruby
resolved = TypedEAV.current_scope
return resolved unless resolved.nil?
```

---

## 4. `where_typed_eav` query construction

### Single-scope branch (normal path)

File: `lib/typed_eav/has_typed_eav.rb`

**Field lookup** — line 157:
```ruby
TypedEAV::Field::Base.for_entity(name, scope: resolved)
```
`for_entity` (defined in `field/base.rb` lines 44–47) expands to:
```ruby
where(entity_type: entity_type, scope: [scope, nil].uniq)
```
After Phase 1, this must become `where(entity_type:, scope: [scope, nil].uniq, parent_scope: [parent_scope, nil].uniq)`. When `scope` is nil (global), `parent_scope` must also be nil — no orphan-parent rows.

**Field resolution** — lines 188–205:
```ruby
fields_by_name = HasTypedEAV.definitions_by_name(defs)
# ...
field = fields_by_name[name.to_s]
matching_ids = TypedEAV::QueryBuilder.entity_ids(field, operator, value)
query.where(id: matching_ids)
```
`QueryBuilder.entity_ids` → `QueryBuilder.filter` → `TypedEAV::Value.where(field: field)` (query_builder.rb line 107). No scope filtering at the Value level — the scope constraint is enforced by which `field` row is selected. Phase 1 does not change this pattern.

### Multimap branch (`unscoped { }` path)

File: `lib/typed_eav/has_typed_eav.rb` lines 154–186

**Field lookup** — line 155:
```ruby
TypedEAV::Field::Base.where(entity_type: name)
```
No scope filter at all — ALL rows for the entity type. After Phase 1 this stays the same (atomic bypass drops both scope AND parent_scope).

**OR-collapse logic** — lines 161–185:
```ruby
fields_multimap = HasTypedEAV.definitions_multimap_by_name(defs)  # line 161
# ...
matching_fields = fields_multimap[name.to_s]                       # line 171
# ...
union_ids = matching_fields.flat_map do |f|                        # line 181
  TypedEAV::QueryBuilder.filter(f, operator, value).pluck(:entity_id)
end.uniq
query.where(id: union_ids)
```
`definitions_multimap_by_name` (lines 49–52) is `defs.to_a.group_by(&:name)` — groups all field rows for a name, across all scopes, into an array. Each element in the array is a separate `field` row, so the OR-across-field_ids happens at the `.flat_map` level. Phase 1 adds `parent_scope` to each field row but does not change the multimap logic — the OR still collapses at `field_id` level, which is correct.

### `unscoped` integration (single-scope branch)

In `resolve_scope` (line 251): `return ALL_SCOPES if TypedEAV.unscoped?` — routing the entire `where_typed_eav` call into the multimap branch. No scope or parent_scope predicates are added. The `TypedEAV.unscoped` block sets `Thread.current[THREAD_UNSCOPED] = true` (`lib/typed_eav.rb` line 67) — this flag is the single lever, unchanged.

---

## 5. `Value#validate_field_scope_matches_entity` and Value-side checks

### The validator (primary cross-scope guard)

File: `app/models/typed_eav/value.rb` lines 138–147

```ruby
def validate_field_scope_matches_entity
  return unless field && entity
  return if field.scope.nil?                                # globals are shared — no check
  return unless entity.respond_to?(:typed_eav_scope)

  entity_scope = entity.typed_eav_scope
  return if entity_scope && field.scope == entity_scope.to_s

  errors.add(:field, :invalid)
end
```

**Phase 1 changes needed:**
- Must add a parallel guard for `parent_scope`: when `field.parent_scope` is not nil, `entity.typed_eav_parent_scope` must match.
- The orphan-parent invariant (`scope=nil` implies `parent_scope=nil`) should be enforced here or in `Field::Base` validation.
- Today the validator only fires when `field.scope` is non-nil. The new logic must handle the case `field.scope != nil && field.parent_scope != nil` as a combined check.

### Other Value-side scope checks

`validate :validate_entity_matches_field` — `value.rb` lines 126–131: only checks `entity_type` vs `field.entity_type`. Scope-unaware. No changes needed.

`validate :validate_field` (uniqueness) — `value.rb` line 16: `validates :field, uniqueness: { scope: %i[entity_type entity_id] }`. Scope-unaware. No changes needed.

No other Value-side scope cross-checks exist.

---

## 6. Section parallels

### Methods mirrored on Section today

| Field-side | Section-side | Notes |
|---|---|---|
| `Field::Base.for_entity` (`field/base.rb:44–47`) | `Section.for_entity` (`section.rb:20–22`) | Identical logic: `where(entity_type:, scope: [scope, nil].uniq)` |
| `scope :sorted` (`field/base.rb:49`) | `scope :sorted` (`section.rb:23`) | Both: `order(sort_order: :asc, name: :asc)` — identical |
| `scope :required_fields` (`field/base.rb:50`) | None | Field-only |
| `validates :name, uniqueness: { scope: %i[entity_type scope] }` (`field/base.rb:35`) | `validates :code, uniqueness: { scope: %i[entity_type scope] }` (`section.rb:13`) | Both scope on `(entity_type, scope)` — note: `Section` uses `code` not `name` as the unique key |

### Methods NOT mirrored on Section

| Field-side method | Why absent from Section |
|---|---|
| `validate_field_scope_matches_entity` (on Value) | This is a `Value` validation — sections are not referenced by values |
| `for_entity` on `Field::Base` used by `ClassQueryMethods` in `has_typed_eav.rb` | Section is not exposed through `has_typed_eav` at all — it is queried directly by admin/form code |
| `Field::Base` STI dispatch, `value_column`, `cast`, `operators`, `validate_typed_value` | Field-specific concepts — no Section equivalent |

**Key implication for Phase 1:** Both `Field::Base.for_entity` and `Section.for_entity` must be updated to accept `parent_scope:` and include `parent_scope: [parent_scope, nil].uniq` in the where clause. Both `Field::Base` and `Section` uniqueness validators must be updated to `scope: %i[entity_type scope parent_scope]`. The CONTEXT.md decision to inline-duplicate (not extract `Scopable`) means both files get identical changes independently.

---

## 7. `Field.sorted` and ordering APIs

### Current implementation

`scope :sorted, -> { order(sort_order: :asc, name: :asc) }` — `app/models/typed_eav/field/base.rb` line 49.

This is a pure ordering scope with no partition filtering. Phase 2 owns the `acts_as_list`-style helpers that operate within a partition. Phase 1 must not break `Field.sorted` — it remains valid (ordering is partition-agnostic).

### `idx_te_fields_lookup` index

Migration line 66:
```ruby
t.index %i[entity_type scope sort_order name], name: "idx_te_fields_lookup"
```
This index supports `Field::Base.for_entity(...).sorted` in one scan. After Phase 1 adds `parent_scope`, this index must also include `parent_scope` to remain selective. New column order: `%i[entity_type scope parent_scope sort_order name]` — name `idx_te_fields_lookup` is 20 bytes, no rename required. The existing index must be dropped and recreated.

### Section's `sorted` scope

`scope :sorted, -> { order(sort_order: :asc, name: :asc) }` — `app/models/typed_eav/section.rb` line 23.

No corresponding lookup index exists on `typed_eav_sections` today (only `idx_te_sections_entity_active` on `[entity_type, active]`). Phase 1 should add `idx_te_sections_lookup` on `%i[entity_type scope parent_scope sort_order name]` for parallel treatment.

---

## 8. Existing scope-related specs

### `spec/regressions/review_round_2_scope_leak_spec.rb`

Coverage: ambient scope must NOT leak into models without `scope_method:` declared.
- Tests `Product` (no `scope_method:`): verifies `with_scope`, explicit `scope:` kwarg override, explicit `scope: nil`, `unscoped { }`, `require_scope = true`, configured resolver — all against Product's field definitions.
- Tests `Contact` (has `scope_method:`): verifies `with_scope` honors tenant scope, `ScopeRequired` raise, globals-only fallback, `unscoped { }` semantics.

**Phase 1 must add**: parallel `parent_scope` column in these scenarios — particularly the `Product` short-circuit path (which returns `nil` for `parent_scope` too since `typed_eav_scope_method` is unset) and the `Contact` path (which must also resolve `parent_scope` from the tuple).

### `spec/regressions/review_round_3_collision_spec.rb`

Coverage: field-name collisions across scope partitions.
- Bug 1: `TypedEAV.unscoped { where_typed_eav(...) }` across 3 tenants — verifies OR-across-field_ids multimap, AND across filters, ArgumentError on unknown names.
- Bug 2: global+scoped name collision on a scoped record — verifies `initialize_typed_values` builds exactly one row, `typed_eav_value` preference for scoped winner, `typed_eav_hash` preference, orphan-skip on read.

**Phase 1 must add**: per CONTEXT.md decisions, parallel coverage for the `parent_scope` axis:
- Multimap under `unscoped { }` must OR-across all `field_id`s sharing a name across (scope, parent_scope) combinations.
- Collision resolution (scoped wins) must account for `(scope, parent_scope)` tuple — when a field with matching `parent_scope` and a field without (`parent_scope: nil`) share a name, the more-specific one wins.
- CONTEXT.md §"Open" item: extend `review_round_2_*` and `review_round_3_*` OR open a new round file. Recommend `review_round_4_parent_scope_spec.rb` to keep the round naming clean.

### `spec/lib/typed_eav/scoping_spec.rb`

Current coverage (13 describe blocks, ~60 examples):
- `with_scope` block nesting, error-safe restore, AR-record normalization
- `unscoped` block semantics, `current_scope` returns nil inside
- Resolver chain: nil, configured resolver, `with_scope` wins over resolver, AR-record normalization from resolver
- `acts_as_tenant` bridge (DEFAULT_SCOPE_RESOLVER)
- Fail-closed enforcement: `ScopeRequired` on scoped models, bypasses via `with_scope`/`unscoped`/explicit kwarg/resolver/`require_scope=false`, non-scoped models never raise
- `typed_eav_definitions` scope behavior: `with_scope` filters, `unscoped` returns all, explicit `scope: nil` means global-only
- Name-collision resolution in instance methods: scoped wins, `typed_eav_attributes=` routes to scoped, falls back to global
- Name-collision resolution in class query methods: `where_typed_eav` and `with_field` pick scoped definition, global-only path, reverse-creation-order determinism
- `Section#for_entity`: scoped+global returned for given scope, global-only when scope omitted

**Phase 1 must extend this spec with:**
- `with_scope` accepting a tuple `[scope, parent_scope]` and exposing both via the new API
- Tuple returning from `current_scope` (or the replacement API)
- `DEFAULT_SCOPE_RESOLVER` returning `[scope, nil]` tuple
- `typed_eav_definitions` with `parent_scope:` kwarg — `[scope, parent_scope]` filters to matching triple; `parent_scope: nil` means global-parent-only
- `Section#for_entity` with `parent_scope:` kwarg — same semantics
- `validate_field_scope_matches_entity` rejecting orphan-parent writes (parent_scope non-nil when scope nil)

### Other scope-adjacent specs

- `spec/models/typed_eav/value_spec.rb` — the `:unscoped` metadata block "REVIEW: nested typed-value must not attach across scope" at line 96 directly tests `validate_field_scope_matches_entity`. This block needs a companion for the `parent_scope` axis.
- `spec/models/typed_eav/field_spec.rb` line 19–30 — "enforces name uniqueness per entity_type and scope": after Phase 1, a test for `(name, entity_type, scope, parent_scope)` tuple uniqueness is needed.
- `spec/regressions/known_bugs_spec.rb` — no scope-specific `pending` tests currently; may receive new `pending` tests during Phase 1 if bugs surface.

---

## 9. Migration tooling and conventions

### Migration file format and location

The gem ships one migration file: `db/migrate/20260330000000_create_typed_eav_tables.rb`. It is an engine migration — consumer apps copy it via `bin/rails typed_eav:install:migrations` (the `InstallGenerator` wraps the `install:migrations` rake task).

The convention for a new migration is a separate timestamped file alongside the existing one. There is no precedent in this gem for an `add_column` migration (the initial migration is the only one today). Phase 1 will establish the gem's first follow-on migration.

### `disable_ddl_transaction!` / `algorithm: :concurrently` — status

**Absent from the codebase today.** The initial migration runs inside a transaction. There is no use of `disable_ddl_transaction!` or `algorithm: :concurrently` anywhere.

CONTEXT.md §"Open" specifies Phase 1 should use `CREATE INDEX CONCURRENTLY` outside a transaction for production-safe index operations on large tables. This means:
- The new migration must call `disable_ddl_transaction!`
- `add_column` for nullable `parent_scope` is safe inside a transaction (Postgres adds nullable columns instantaneously via catalog-only change — no table rewrite)
- The old paired partial unique indexes (`idx_te_fields_unique_scoped`, `idx_te_fields_unique_global`, `idx_te_sections_unique_scoped`, `idx_te_sections_unique_global`) and `idx_te_fields_lookup` must be **dropped** before the new triple-column indexes are created
- New indexes must use `algorithm: :concurrently` (requires being outside a transaction)
- Rails migration `remove_index` and `add_index` with `algorithm: :concurrently` must be used; `change` method is not reversible with `concurrently` — use `up`/`down` pair

### Index name length analysis for new triple-column indexes

63-byte Postgres identifier limit. Current index names and their byte counts:

| Index name | Bytes | Status after Phase 1 |
|---|---|---|
| `idx_te_fields_unique_scoped` | 28 | Drop — triple replaces it |
| `idx_te_fields_unique_global` | 29 | Drop — triple replaces it |
| `idx_te_sections_unique_scoped` | 31 | Drop — triple replaces it |
| `idx_te_sections_unique_global` | 32 | Drop — triple replaces it |
| `idx_te_fields_lookup` | 21 | Drop — needs `parent_scope` added |

Proposed new index names (all within 63 bytes):

| Proposed name | Columns | `where` predicate | Bytes |
|---|---|---|---|
| `idx_te_fields_uniq_scoped` | `[name, entity_type, scope, parent_scope]` | `scope IS NOT NULL` | 26 |
| `idx_te_fields_uniq_global` | `[name, entity_type]` | `scope IS NULL` | 26 |
| `idx_te_sections_uniq_scoped` | `[entity_type, code, scope, parent_scope]` | `scope IS NOT NULL` | 29 |
| `idx_te_sections_uniq_global` | `[entity_type, code]` | `scope IS NULL` | 29 |
| `idx_te_fields_lookup` | `[entity_type, scope, parent_scope, sort_order, name]` | (none) | 21 |

Note: `parent_scope` is only present in the `scope IS NOT NULL` partial indexes — when `scope IS NULL`, `parent_scope` must also be NULL (orphan-parent invariant), so the global index on `[name, entity_type]` is still correct. Adding `parent_scope` to the global partial would be redundant (always NULL).

The multimap OR strategy (inline two separate `where` partials rather than one three-way) requires exactly this paired structure.

---

## 10. Postgres dependency surface

### Where the Postgres-only commitment is expressed

| Location | Content |
|---|---|
| `README.md` lines 479–481 | "Requires PostgreSQL. The `text_pattern_ops` index on `string_value` and the jsonb `@>` containment operator are Postgres-specific." |
| `CONCERNS.md` lines 46–55 | Explicit table of PG-only features: jsonb `@>`, `text_pattern_ops`, partial unique indexes, GIN index, NULL-distinct semantics |
| `typed_eav.gemspec` | No DB-specific runtime dep; Postgres enforced implicitly by migration features |
| `spec/dummy/config/database.yml` | Uses PG adapter (not read directly here, but implied by `pg` in Gemfile dev deps) |

### Phase 1 deepens the Postgres commitment

The new paired partial unique indexes on the triple `(entity_type, scope, parent_scope)` with `WHERE scope IS NOT NULL` predicates are PostgreSQL-specific. No adapter-compat code exists or is planned.

### Adapter checks that need updating

None today — there are no runtime adapter checks (`ActiveRecord::Base.connection.adapter_name` checks, etc.). The `CONCERNS.md` documents the PG-only dependency as a known operational constraint. Phase 1 should add a brief README §"Database Support" note that partial indexes now cover a three-column scope tuple (Phase 1 deepens the dependency; no new adapter abstraction required).

---

## Open questions for Lead

1. **`Section.for_entity` exposure in `has_typed_eav`.** Today `Section.for_entity` is queried directly by admin/form code — it is not wired through `ClassQueryMethods`. Is `parent_scope:` a kwarg the consumer passes directly (i.e., `Section.for_entity("Contact", scope: s, parent_scope: ps)`), or does Phase 1 add a parallel `InstanceMethods#typed_eav_sections` that resolves via the ambient resolver? The CONTEXT.md does not specify.

2. **`InstanceMethods#typed_eav_scope` for `parent_scope`.** Today `InstanceMethods#typed_eav_scope` reads `send(self.class.typed_eav_scope_method)`. Phase 1 needs a `typed_eav_parent_scope` instance method on the host model. The `has_typed_eav` macro presumably gains `parent_scope_method:` kwarg. The method body is symmetric but not specified in CONTEXT.md — confirm the kwarg name and whether it follows the same `&.to_s` normalization pattern.

3. **`definitions_by_name` collision priority with three-dimensional partition.** Today scoped beats global (`d.scope.nil? ? 0 : 1`). With `(scope, parent_scope)` there are potentially three precedence levels: `(scope, parent_scope)` both set > `(scope, nil)` > `(nil, nil)`. The sort key in `definitions_by_name` (line 42) needs a three-way comparator. This is deterministic code, but the exact priority rule is Lead's decision.

4. **Migration class name.** The gem's single existing migration is `CreateTypedEAVTables`. The Phase 1 migration needs a conventional name — suggest `AddParentScopeToTypedEavPartitions` (follows Rails convention, fits comfortably under 63-byte AR internal name limits).

5. **`typed_eav_parent_scope` on host models without `parent_scope_method:`.** Should it return `nil` (graceful no-op — the natural default), or should `InstanceMethods` not define the method at all unless `parent_scope_method:` is declared? The choice affects `validate_field_scope_matches_entity`'s `respond_to?` pattern.
