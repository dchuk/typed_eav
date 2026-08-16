---
phase: 02
plan: phase-wide
title: Phase 02 Pipeline Completions Research
researched: 2026-04-29
researcher: vbw-scout
---

# Phase 02 Research: Pipeline Completions

## Summary

Phase 02 delivers three items whose database infrastructure already exists — `sort_order` columns and lookup indexes were added in Phase 01's migration, `default_value_meta` jsonb has been on the schema since v0.1.0, and the FK / cascade mechanism is the existing `ON DELETE CASCADE`. The Ruby surface across all three is minimal in scope but touches `field/base.rb`, `value.rb`, `section.rb`, a new migration, and multiple spec files. The codebase is well-prepared: the sentinel pattern, `for_entity` scope, and `with_lock` style are already established. No new hard dependencies are needed. The primary risks are race-condition correctness in the ordering module, and the drop-and-recreate FK sequence for the cascade migration.

---

## Area 1: Display ordering helpers (in-house, partition-aware)

### Current state

**`field/base.rb`** (281 lines):
- `scope :sorted, -> { order(sort_order: :asc, name: :asc) }` — line 70.
- `scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil| ... }` — lines 62–68. This is the partition anchor.
- `sort_order` column: nullable integer (no `null: false` in the original migration, no default). The Phase 01 lookup index `idx_te_fields_lookup` covers `(entity_type, scope, parent_scope, sort_order, name)` — already optimized for the sorted read path.
- No `acts_as_list` reference anywhere in the codebase. `DEPENDENCIES.md` confirms one runtime dep (`rails`). Confirmed not present.
- No `move_higher`, `move_lower`, `insert_at`, or any list-helper method anywhere in the codebase.

**`section.rb`** (47 lines):
- `scope :sorted, -> { order(sort_order: :asc, name: :asc) }` — line 32 (verbatim mirror of `field/base.rb` line 70).
- `scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil| ... }` — lines 25–31. Structurally identical to the Field version — same keyword defaults, same `[val, nil].uniq` expansion.
- `sort_order` column: nullable integer (added in the base migration, line 13 of `create_typed_eav_tables.rb`).
- The Phase 01 migration added `idx_te_sections_lookup` covering `(entity_type, scope, parent_scope, sort_order, name)`.
- No ordering helpers; no `acts_as_list`.

**Partition-tuple symmetry (deferred Scopable pattern):** `Field::Base` and `Section` have identical:
- `for_entity(entity_type, scope: nil, parent_scope: nil)` scope (lines 62–68 in base, 25–31 in section)
- `scope :sorted` (line 70 base, 32 section)
- `validate_parent_scope_invariant` (private method, inline-duplicated per Phase 01 CONTEXT.md)

The decision to NOT extract a shared `Scopable` concern stands. Both `for_entity` and `sorted` are duplicated inline today and the new ordering helpers will follow the same pattern.

**Existing `.sorted` call sites:**
- `TypedEAV::Option.scope :sorted` — `option.rb` line 14 (unrelated; `Option#sorted` is on the options table, not the fields table)
- `@field.field_options.sorted` — scaffold view `edit.html.erb` line 14
- `described_class.sorted` — `spec/models/typed_eav/section_and_option_spec.rb` line 63 (the "orders by sort_order then name" spec)
- `TypedEAV::Option.sorted` — `spec/models/typed_eav/section_and_option_spec.rb` line 99
- The scaffold index controller uses `.order(:entity_type, :scope, :sort_order, :name)` directly (line 34 of `typed_eav_controller.rb`) — not using `.sorted` scope, so it is not a `Field::Base.sorted` call site per se.
- No `Field::Base.sorted` or `Section.sorted` call site in the scaffold controller or any spec file. The `sorted` scope exists but is only tested indirectly (the Section spec at line 61–70).

**Sentinel constants (for Area 2 shape reference):**
- `UNSET_SCOPE = Object.new.freeze` — `lib/typed_eav/has_typed_eav.rb` line 146, inside `module ClassQueryMethods`.
- `ALL_SCOPES = Object.new.freeze` — same file, line 151, same module.
- Neither is `private_constant` — per CONVENTIONS.md §"API stability signals": "documented sentinels intentionally are not `private_constant`." `UNSET_VALUE` should mirror this: NOT `private_constant`, inside the `TypedEAV::Value` class body (analogous to sentinels living inside the module where they are used).

**Existing ordering spec coverage:** The Section spec has one test for `.sorted` (lines 61–70 in `section_and_option_spec.rb`). No `Field::Base.sorted` spec exists. No `sort_order` assignment spec exists for either model. No tests for `move_higher`, `move_lower`, etc. (they don't exist yet).

**`with_lock` pattern reference:** The scaffold controller's `add_option` action (`typed_eav_controller.rb` lines 92–98) uses `@field.with_lock do ... end` to serialize concurrent option creation. This is the exact `with_lock` pattern to replicate for move operations — lock the moving record row, execute the swap/shift, normalize within the partition.

### Files and line ranges to touch

| File | Operation | Scope |
|---|---|---|
| `app/models/typed_eav/field/base.rb` | Add ordering instance methods (new private partition helpers + public `move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, `insert_at`) | Lines 44–70 area (after scopes); new methods block |
| `app/models/typed_eav/section.rb` | Add symmetric ordering instance methods (duplicate inline, NOT shared concern) | Lines 17–32 area (after scopes) |
| `spec/models/typed_eav/field_spec.rb` | Add ordering spec block (new `RSpec.describe` at end of file) | New block after line 540 |
| `spec/models/typed_eav/section_and_option_spec.rb` | Extend existing `.sorted` scope describe block; add move helper specs | After line 70 (within or adjacent to "scopes" describe) |

No new file is needed if helpers are added inline (per the decision to duplicate rather than extract). If Lead prefers a concern, `app/models/typed_eav/concerns/listable.rb` is the natural path (no `concerns/` directory exists under `app/models/typed_eav/` yet — would need to be created and `require`d in the engine initializer or autoloaded). **Recommendation:** inline in both `field/base.rb` and `section.rb` — this matches the established "duplicate across both files" pattern from Phase 01 (the `validate_parent_scope_invariant` precedent), avoids introducing a new `concerns/` directory, and keeps each file self-contained.

### Lead questions answered

**Q: Where does `Listable` (or equivalent) module physically live?**
Recommendation: inline on `Field::Base` and `Section`. The established pattern from Phase 01 is explicit inline duplication (see `validate_parent_scope_invariant` comment in `section.rb` lines 39–45). No `concerns/` directory exists today. Creating one for ~80 LoC spread over two files adds file-system ceremony without meaningful maintenance benefit at this scale. If the "extract Scopable" deferred idea from Phase 01 ever ships, both the partition methods AND the ordering helpers can move together.

**Q: What `with_lock` granularity?**
Lock the moving record's partition using `lock!` on the moving record row (which issues a `SELECT ... FOR UPDATE`). The scaffold's `add_option` pattern (`@field.with_lock { }`) locks a single row; for multi-row swaps (e.g., `move_higher` must swap positions with the neighbor), the pattern should be: `transaction { lock!; reload; ... }`. This serializes all ordering operations within the partition while holding only row-level locks (not table locks). The `sort_order` column is not unique-constrained, so a brief moment of duplicate values within a transaction is safe.

**Q: `insert_at(n)` clamp behavior?**
Clamp `n` to `[1, partition_count]`. `insert_at(0)` → behaves as `move_to_top`. `insert_at(999)` on a 5-item partition → behaves as `move_to_bottom`. No error raised. This mirrors `acts_as_list` behavior.

**Q: How does normalization to consecutive integers interact with concurrent inserts of new Field rows not yet positioned?**
New Field rows are created with `sort_order: nil` by default (nullable column, no default in schema). The normalization step — assigning consecutive integers 1..N within the partition — reads `where(entity_type:, scope:, parent_scope:).order(:sort_order, :name)` and assigns positions. Nil `sort_order` values sort last in Postgres (`NULLS LAST` is the default). Policy: normalization during a move operation treats nil-sort-order rows as "at the end" by ordering them after all positioned rows. A concurrent insert of an unpositioned row during a move's normalization step lands at the end on the next normalization. This is safe because: (a) each move wraps in a transaction with a row lock, (b) the normalization assigns consecutive integers to all non-nil rows + nil rows get assigned positions at the end; (c) a concurrent un-positioned create doesn't race the normalization because its sort_order is nil and the move's lock covers only the moving record's row.

### Risks / unknowns

- **Normalization cost:** Re-normalizing `sort_order` on every move (assigning 1..N) issues an UPDATE per row in the partition. For large partitions (hundreds of fields per entity/scope/parent_scope), this is acceptable but worth documenting. Bulk moves (future) should batch-normalize.
- **nil sort_order rows after normalization:** If a `move_higher` fires on a record with `sort_order: nil`, the "boundary move is a no-op" rule should handle it — a nil-position record is effectively "at the end" so `move_higher` is meaningful. Lead needs to decide: does `move_higher` on a nil-sorted record assign it to position N-1 (last meaningful move) or treat it as a no-op? Recommend: assign it position `count - 1` (move it up one from the implicit last position).
- **No backward-compat risk for `Field.sorted` / `Section.sorted`:** these scopes are not renamed; the new helpers are additive instance methods only.

---

## Area 2: Default values + UNSET_VALUE sentinel + Field#backfill_default!

### Current state

**`value.rb`** (177 lines):
- `belongs_to :field` — line 11–13. Note: `optional:` is NOT set — field is currently required (`NOT NULL` in DB, not `optional: true` in AR). This changes in Area 3.
- `value=` method — lines 38–49. When `field` is assigned: runs `field.cast(val)`, writes to `value_column`, stores `@cast_was_invalid`. When `field` is nil: stashes in `@pending_value`.
- `after_initialize :apply_pending_value` — line 58. `apply_pending_value` (lines 62–67): checks `@pending_value && field`; if both present, calls `self.value = @pending_value` and clears.
- `@pending_value` instance variable: the only place stashed-pre-field values live. The sentinel `UNSET_VALUE` inserts cleanly here — a new branch in `value=` before the `field` check: if `val.equal?(UNSET_VALUE)` AND field is present, apply `field.default_value`; if field is not yet present, stash `UNSET_VALUE` as `@pending_value` (to be re-applied via `apply_pending_value`). If `val.equal?(UNSET_VALUE)` AND `field.default_value` is nil, write nil to the column (no special behavior — `nil` is the correct default for "no default configured").
- No `UNSET_VALUE` constant anywhere in the codebase today.
- `MAX_JSON_BYTES = 1_000_000` — line 112, `private_constant :MAX_JSON_BYTES` — line 113. This is the model for internal sentinel constants. But per convention, `UNSET_VALUE` should NOT be `private_constant` (mirrors `UNSET_SCOPE` / `ALL_SCOPES` which are not `private_constant`).

**`field/base.rb`** `default_value` / `default_value=`:
- `default_value` — lines 77–79: `cast(default_value_meta["v"]).first`.
- `default_value=` — lines 81–83: `default_value_meta["v"] = val`.
- `validate_default_value` — lines 232–240: returns early if `default_value_meta` blank or no `"v"` key; skips validation if raw nil; calls `cast(raw)` and adds `:default_value` error if `invalid?` is true.
- The cast-tuple semantics for default: `field.default_value` calls `cast(default_value_meta["v"]).first`. If the stored raw value is invalid (e.g., `"not_a_number"` for an Integer field), `cast` returns `[nil, true]` — `.first` returns `nil`. The `validate_default_value` catches this at field save time so an invalid default is never persisted. When `UNSET_VALUE` triggers default population, it reads `field.default_value` which is already-cast and always valid (validated at field save) or `nil` (no default). So the `[nil, true]` invalid case cannot appear at Value-creation time when defaults are read through this path — only when storing a bad raw value via `default_value=` (which `validate_default_value` blocks at field save).

**`initialize_typed_values`** in `has_typed_eav.rb` — lines 448–458:
```ruby
def initialize_typed_values
  existing_field_ids = ...
  typed_eav_defs_by_name.each_value do |field|
    next if existing_field_ids.include?(field.id)
    typed_values.build(field: field, value: field.default_value)
  end
  typed_values
end
```
This is the **pre-form path**: it calls `typed_values.build(field: field, value: field.default_value)` passing the **already-cast** default value (or `nil`). This does NOT use `UNSET_VALUE` — it always passes an explicit value (either the cast default or `nil`). The sentinel is NOT needed here because the caller is passing an explicit value. This path remains unchanged.

The 02-CONTEXT.md note on `initialize_typed_values` is resolved: **leave it as-is**. It already correctly populates defaults for form pre-rendering. `UNSET_VALUE` only affects the non-form `typed_values.create(field: f)` path (no `value:` kwarg given), where `create` calls `build` which calls `initialize` which, without a `value:` kwarg, leaves the value-column nil. Currently there is no mechanism to populate defaults on that path — that is precisely what `UNSET_VALUE` fixes.

**`typed_values.create(field: f)` callers in specs:**
- `spec/models/typed_eav/value_spec.rb` lines 17–21: `TypedEAV::Value.create!(entity: contact, field: field)` then separately `value.value = 42; value.save!`. This pattern creates a value with no initial value, then sets it explicitly. After the sentinel change, the create will trigger default population — but since these specs are testing value storage, the field factories do NOT set `default_value_meta`. Thus `field.default_value` returns `nil`, and `UNSET_VALUE` → `nil` default → no behavior change. These specs are safe.
- `spec/regressions/known_bugs_spec.rb` lines 17–20: `TypedEAV::Value.create!(entity: contact, field: field)` with value set separately. Same reasoning — test fields have no default, so `UNSET_VALUE` → nil, unchanged behavior.
- No callers pass `value: nil` explicitly in any spec that would be distinguishing sentinel from explicit-nil. The key behavioral difference (sentinel vs explicit nil) is not currently tested anywhere because the feature doesn't exist yet.

**Backfill iteration pattern:** `Field#backfill_default!` iterates entity rows (not Value rows directly). The for-entity lookup uses `for_entity` from Phase 01. The iteration pattern:
1. Resolve the entity AR class from `field.entity_type` (via `field.entity_type.constantize`).
2. Use `find_each(batch_size: 1000)` on the entity class.
3. Within each batch, use a `transaction do ... end`.
4. Skip rule: within the batch, skip entities that already have a non-nil typed value for this field. The SQL is: `typed_eav_values WHERE field_id = ? AND <value_column> IS NOT NULL`. The relevant index is `idx_te_values_field_int` (or `_dec`, `_str`, etc. depending on the field type) — these are all covering indexes on `(field_id, <typed>_value)`. A `LEFT OUTER JOIN` or a subquery on `typed_eav_values` filtered by `field_id` and non-null value column gives the skip set.
5. For non-skipped entities: find or create the Value row (`typed_values.find_or_create_by!(entity: entity)` or a targeted `create!` using the sentinel so default population fires automatically).

**No prior backfill/migration-style script exists in the gem.** This is the first `find_each` + batch-transaction method. No existing pattern to copy from.

**Partition-aware iteration:** The `backfill_default!` method must scope iteration to entities whose `typed_eav_scope` and `typed_eav_parent_scope` match the field's `scope` and `parent_scope`. However, `entity_type.constantize.find_each` iterates all entity rows — the scope filtering is on the Value side (skip if already has non-nil value) and the write side (only write Values when the entity's scope/parent_scope resolve to match). The simplest correct approach: iterate all entities, then for each entity check if its scope matches the field, and skip if not. Alternatively, if the entity class has `typed_eav_scope_method:` declared, scope the `find_each` query with a `where` on the scope column directly (e.g., `where(tenant_id: field.scope)`). But this requires knowing the column name from the method name — fragile. Cleaner: use `for_entity` (a scope on Field, not on entity). **Lead decision required:** the iteration approach is: `entity_class.find_each` with a per-record scope check (call `entity.typed_eav_scope` and `entity.typed_eav_parent_scope` and skip if they don't match), OR narrow the entity query using raw SQL if practical. The per-record check is safe and simple; it is O(N entities) not O(N Values). Document in the plan.

### Files and line ranges to touch

| File | Operation | Scope |
|---|---|---|
| `app/models/typed_eav/value.rb` | Add `UNSET_VALUE = Object.new.freeze` constant; modify `value=` (lines 38–49) to branch on `UNSET_VALUE`; extend `apply_pending_value` (lines 62–67) to handle `@pending_value.equal?(UNSET_VALUE)` | Lines 1–67 |
| `app/models/typed_eav/field/base.rb` | Add `backfill_default!` public instance method (new block after existing public methods) | After line 129 |
| `spec/models/typed_eav/value_spec.rb` | Add sentinel behavior specs: `UNSET_VALUE` triggers default, explicit nil does not, `UNSET_VALUE` with no default → nil | New `describe` block at end |
| `spec/models/typed_eav/field_spec.rb` | Add `Field#backfill_default!` specs: skips non-nil rows, fills nil rows, idempotent re-run | New `RSpec.describe` block at end |

### Lead questions answered

**Q: Where exactly does `UNSET_VALUE` get declared?**
Inside `TypedEAV::Value` class body, at the top of the constants section, after `self.table_name`. NOT `private_constant` — mirrors the `UNSET_SCOPE`/`ALL_SCOPES` convention (public sentinels, documented). Literal declaration:
```ruby
UNSET_VALUE = Object.new.freeze
```
On line ~5, after `self.table_name = "typed_eav_values"`. No other files need to import/reference it — the only call site is `typed_values.create(field: f)` (no `value:` kwarg), which produces `UNSET_VALUE` through the default-kwarg mechanism. Callers that read `UNSET_VALUE` directly are only advanced users checking `val.equal?(TypedEAV::Value::UNSET_VALUE)` in their own code — documented in README.

**Q: Does `Value#value=` need refactoring or is a sentinel branch sufficient?**
A sentinel branch is sufficient. Minimum diff: add a guard clause at the top of `value=`:
```
if val.equal?(UNSET_VALUE)
  # apply default if field present; stash sentinel for apply_pending_value if not
  ...
else
  # existing logic
end
```
`apply_pending_value` needs a parallel branch: if `@pending_value.equal?(UNSET_VALUE)`, apply `field.default_value` (not `@pending_value` directly). The existing structure (stash in `@pending_value`, resolve in `apply_pending_value`) works without restructuring. No refactor needed.

**Q: What's the partition-aware iteration for `backfill_default!`?**
The Phase 01 `for_entity` helper is a scope on `Field::Base`, not on the entity class. For backfill, the iteration is on entity rows. The recommended approach: iterate all entities of `field.entity_type`, then for each entity check scope compatibility via `entity.respond_to?(:typed_eav_scope)` and `entity.typed_eav_scope == field.scope` (with nil-scope global fields skipping the check). This is safe, simple, and does not require knowing the entity's DB column name for the scope.

**Q: Idempotence — re-run safety.**
Re-running `backfill_default!` picks up where it left off because each batch skips records with non-nil typed column. A Value row whose typed column is nil (e.g., was explicitly set to nil) is still a candidate for backfill — per 02-CONTEXT.md: "Skip rule: non-nil typed column, not Value row exists." So a Value row with `integer_value IS NULL` would be filled on re-run. This is correct: it only runs if the default is non-nil (no-op if `field.default_value` is nil).

### Risks / unknowns

- **`Value.create!` without `value:` kwarg:** The current call site `TypedEAV::Value.create!(entity: contact, field: field)` in specs does NOT pass `value:`. After the change, `UNSET_VALUE` fires. Since test field factories have no `default_value_meta`, `field.default_value` → `nil`, so the net result is `nil` stored — same as today. No test assertions break. But Lead should verify this reasoning is correct for each spec that uses this pattern.
- **`accepts_nested_attributes_for` path:** The nested-attrs path (`typed_values_attributes=`) always assigns explicit values via `value:` kwarg in the hash. It never goes through `UNSET_VALUE`. Safe.
- **`set_typed_eav_value` path** (`has_typed_eav.rb` line 555–565): calls `typed_values.build(field: field, value: value)` with explicit value. Safe — explicit nil is passed when value is nil.
- **`backfill_default!` for global fields (scope nil):** The entity class scope check: when `field.scope` is nil (global field), any entity matches — no scope filter needed. The iteration covers all entities of `field.entity_type`.

---

## Area 3: Cascade wiring + migration delivery

### Current state

**Current `typed_eav_values.field_id`** (in `create_typed_eav_tables.rb`):
- Line 88: `t.references :field, null: false, foreign_key: { to_table: :typed_eav_fields, on_delete: :cascade }`
- This creates: column `field_id bigint NOT NULL`, and FK constraint with `ON DELETE CASCADE`.
- The FK constraint name generated by Rails is **`fk_rails_<hash>`** — the exact name is NOT specified in the migration (no `name:` keyword). Rails auto-generates it. To find the exact constraint name, it must be read from the PG schema at runtime (`information_schema.table_constraints` or `\d typed_eav_values`). The migration for Phase 02 must drop this constraint by name, then recreate with `ON DELETE SET NULL`. The name will be in the form `fk_rails_XXXXXXXX`.

  **Action for Lead:** The migration code must use `execute` with the actual constraint name, OR use `remove_foreign_key :typed_eav_values, :typed_eav_fields` (Rails helper that looks up the name automatically) followed by `add_foreign_key :typed_eav_values, :typed_eav_fields, column: :field_id, on_delete: :nullify`. The Rails `remove_foreign_key` / `add_foreign_key` helpers are preferred — they handle the name lookup automatically.

**Current `has_many :values` association** (`field/base.rb` line 19–24):
```ruby
has_many :values,
         class_name: "TypedEAV::Value",
         foreign_key: :field_id,
         inverse_of: :field,
         dependent: :destroy
```
`dependent: :destroy` is the AR-level cascade. In Phase 02:
- For `field_dependent: "destroy"` (default): AR `dependent: :destroy` must still fire — OR the `before_destroy` hook replicates it. The simplest approach: replace `dependent: :destroy` with NO `dependent:` option and implement the full dispatch in `before_destroy`. This avoids double-destroy for the `:destroy` case (AR cascade fires, then `before_destroy` also fires if both are kept).
- For `field_dependent: "nullify"`: the DB FK `ON DELETE SET NULL` handles this automatically when the Field row is deleted. No AR callback needed for nullify — the FK does the work.
- For `field_dependent: "restrict_with_error"`: `before_destroy` checks `values.exists?`, adds error, `throw(:abort)`.
- **The existing `dependent: :destroy` on `has_many :values` MUST be removed** (replaced with custom `before_destroy` dispatch) so the same AR `dependent:` option doesn't fire unconditionally regardless of `field_dependent` value.

**Current `belongs_to :field` in `value.rb`** (line 11–13):
```ruby
belongs_to :field,
           class_name: "TypedEAV::Field::Base",
           inverse_of: :values
```
Currently no `optional: true` — AR requires `field_id` to be non-nil for a valid Value. After the migration makes `field_id` nullable, this must become `optional: true` to allow orphaned Value rows (where `field_id IS NULL`) to be read without validation failure.

**Existing read-path orphan guard:** `typed_eav_value` and `typed_eav_hash` in `has_typed_eav.rb` already check `v.field` before using it:
- `typed_eav_value`: line 544 `loaded_typed_values_with_fields.select { |v| v.field && v.field.name == name.to_s }` — already skips orphans.
- `typed_eav_hash`: line 581 `next unless tv.field` — already skips orphans.
- `apply_pending_value` in `value.rb`: line 63 `return unless @pending_value && field` — safe.
These guards do NOT need changes.

**`before_destroy` pattern:** No existing `before_destroy` callbacks in the gem. The pattern from AR core: `before_destroy` + `errors.add` + `throw(:abort)`. This exactly mirrors what AR itself generates for `dependent: :restrict_with_error`. The error message to add: `"Cannot delete field '%{name}' because it has associated values. Use field_dependent: :nullify or destroy values first."` (following the "errors tell you how to fix it" convention from CONVENTIONS.md).

**`field_dependent` validation:** New `validates :field_dependent, inclusion: { in: %w[destroy nullify restrict_with_error] }` on `Field::Base`. Straightforward.

**Known bugs spec for cascade/orphan:**
- `spec/regressions/known_bugs_spec.rb` has NO `pending` tests for cascade or orphan behavior. The file covers ANALYSIS.md items 1.1, 1.2, 2.6, 2.7, 3.1, 3.3, 2.4, and review items (scope leak, required blank, JSON parsing, IntegerArray fractions).
- `spec/regressions/review_round_2_scope_leak_spec.rb`, `review_round_3_collision_spec.rb`, `review_round_4_parent_scope_spec.rb` — all scope-related, not cascade-related.
- No `pending` cascade spec exists to auto-un-pend. Phase 02 will create a new spec file: `spec/lib/typed_eav/field_cascade_spec.rb` (as documented in 02-CONTEXT.md). This is additive, not a fix of a pending spec.

**Changeability of `field_id` from NOT NULL to nullable:**
`change_column_null :typed_eav_values, :field_id, true` is reversible in a `change` block (Rails supports it). However, the FK ON DELETE change requires drop-and-recreate which is NOT reversible through the `change` block. The migration must use explicit `up`/`down` methods (same pattern as the Phase 01 `add_parent_scope` migration which used `disable_ddl_transaction!` and explicit `up`/`down`). This migration does NOT need `disable_ddl_transaction!` (no `algorithm: :concurrently` needed — adding a column default and changing FK are fast operations on a live table; no index rebuilds).

### Files and line ranges to touch

| File | Operation | Scope |
|---|---|---|
| `db/migrate/YYYYMMDDHHMMSS_add_cascade_policy_to_typed_eav.rb` | New migration: add `field_dependent` string column; change `field_id` to nullable; drop FK; recreate FK `ON DELETE SET NULL` | New file |
| `app/models/typed_eav/field/base.rb` | Remove `dependent: :destroy` from `has_many :values` (line 23); add `field_dependent` validation; add `before_destroy` dispatch hook | Lines 19–24, 31–41, new private method |
| `app/models/typed_eav/value.rb` | Add `optional: true` to `belongs_to :field` (line 11–13) | Lines 11–13 |
| `spec/lib/typed_eav/field_cascade_spec.rb` | New spec: cascade × 3 policies × partition variations | New file |
| `spec/models/typed_eav/field_spec.rb` | Add `field_dependent` validation spec | New `describe` block |
| `spec/models/typed_eav/value_spec.rb` | Update `belongs_to :field` association test (no longer required) | Line 8 `it { is_expected.to belong_to(:field) }` — may need `optional: true` annotation |

### Lead questions answered

**Q: What is the exact name of the existing FK constraint on `typed_eav_values.field_id`?**
The constraint name is auto-generated by Rails (no `name:` specified in the migration). The form is `fk_rails_XXXXXXXX` where the hash is deterministic from `(typed_eav_values, typed_eav_fields, field_id)`. **Lead must use `remove_foreign_key :typed_eav_values, column: :field_id` (the column-form which handles name lookup automatically)** rather than hardcoding the constraint name. This is safe and idiomatic.

**Q: Migration timestamp?**
Following the pattern from existing migrations (`20260330000000_create_typed_eav_tables.rb`, `20260430000000_add_parent_scope_to_typed_eav_partitions.rb`): next in sequence would be `20260501000000_add_cascade_policy_to_typed_eav_fields.rb` (using 2026-05-01 with zeroed HH:MM:SS). Lead should pick the actual timestamp at plan time.

**Q: Does `has_many :values, dependent: :destroy` need to change?**
Yes. It must be removed (`dependent:` option dropped entirely). The custom `before_destroy` on `Field::Base` replaces it for all three policies:
- `"destroy"`: `values.destroy_all` (or leave AR to handle via DB cascade after field row deleted — but with `ON DELETE SET NULL` now on the FK, DB no longer does cascade delete; AR `destroy_all` must be called explicitly in the `before_destroy`).
- `"nullify"`: no-op in `before_destroy` — the DB FK `ON DELETE SET NULL` handles it automatically when the field row is deleted.
- `"restrict_with_error"`: `errors.add(:base, "..."); throw(:abort)` if `values.exists?`.

Wait — critical nuance: with `ON DELETE SET NULL` on the FK, if `field_dependent` is `"destroy"`, the DB will NULL out `field_id` BEFORE the AR `destroy_all` fires (since the DB FK fires at the SQL DELETE level, before AR callbacks). To make `"destroy"` work correctly, the `before_destroy` hook must call `values.destroy_all` BEFORE the field row is deleted (i.e., in `before_destroy`, not `after_destroy`). This is the correct ordering: `before_destroy` runs, values are destroyed (Value rows deleted), then the field row is deleted (DB FK fires but no value rows remain to nullify).

**Q: For `:restrict_with_error`: where is the canonical AR pattern?**
AR itself implements `dependent: :restrict_with_error` in `ActiveRecord::Associations::Builder::Association`. The pattern is: add an AR `before_destroy` callback that calls `raise ActiveRecord::DeleteRestrictionError` OR (the gem's approach) use `errors.add(:base, ...)` + `throw(:abort)`. The gem uses the `errors` approach (not the exception approach) because it integrates with standard AR validation error rendering in forms. This mirrors the 02-CONTEXT.md decision exactly.

### Risks / unknowns

- **`ON DELETE SET NULL` + `"destroy"` double-write risk:** If the `before_destroy` hook for `"destroy"` calls `values.destroy_all`, and then the field row DELETE triggers `ON DELETE SET NULL` on any remaining value rows (race or missed row), the FK still fires cleanly (no rows → no nullification). Safe. But if `destroy_all` misses a row (concurrent insert between `before_destroy` and the DELETE), that row's `field_id` gets NULLified by the FK rather than deleted. This is a race condition risk. Document in the plan. Mitigation: wrap the `before_destroy` for `"destroy"` in a transaction (AR callbacks run inside the save/destroy transaction by default, so this is automatic).
- **`optional: true` on `belongs_to :field`:** Once nullable, `Value` rows with `field_id IS NULL` (orphaned) will validate successfully. The `validate_entity_matches_field` validator (line 126) guards `return unless field && entity_type`, so it short-circuits safely for orphans. `validate_field_scope_matches_entity` (line 147) guards `return unless field && entity`. Safe. `validate_value` (line 69) guards `return unless field`. Safe. `value` reader (line 33) guards `return nil unless field`. Safe. Full orphan-safety audit: no validator or reader crashes on nil field.
- **Postgres FK on_delete option name:** Rails `add_foreign_key` uses `:nullify` (Symbol) for `ON DELETE SET NULL`. The migration should use `add_foreign_key :typed_eav_values, :typed_eav_fields, column: :field_id, on_delete: :nullify`.

---

## Area 4: Roadmap goal language refinement

### Current state

**ROADMAP.md**, Phase 2 goal text (lines 32–33):
```
**Goal:** Complete three "infrastructure already exists" items (display ordering, default values,
cascade behavior) without adding new columns or breaking the v0.1.0 API.
```
The phrase "without adding new columns" is the one that the 02-CONTEXT.md decision relaxes to "additive schema changes only, never removal or renaming, defaults preserve v0.1.0 behavior."

**Other places that quote or paraphrase this language:**
- `.vbw-planning/STATE.md` — does not quote the Phase 2 goal text directly (checked indirectly via git status showing it as modified, but content was not read — Lead should verify).
- `.vbw-planning/phases/02-pipeline-completions/02-CONTEXT.md` — lines 14–17 explicitly document the refinement and call it "hereby refined." This is the authoritative capture.
- `.vbw-planning/REQUIREMENTS.md` — not read; may reference REQ-07 language. Lead should check.
- `typed_eav-enhancement-plan.md` — the original strategic document; also not read in full. May contain the original "no new columns" language. Lead should check.

### Lead questions surfaced (decision deferred)

**Should the ROADMAP goal language be rewritten as part of Phase 02 work?**

Arguments for rewriting ROADMAP.md:
- The ROADMAP is the canonical planning artifact; the refinement is architecturally binding (the cascade migration adds two schema changes).
- Leaving a contradiction between ROADMAP and 02-CONTEXT.md creates confusion for future phases.
- The ROADMAP is in `.vbw-planning/` and is maintained by the VBW workflow.

Arguments for leaving it as-is:
- 02-CONTEXT.md already captures the refinement with explicit "hereby refined" language.
- The ROADMAP goal text is aspirational scope-setting, not a binding API contract.
- A chore task to update documentation wording is low-ROI compared to implementation tasks.

**Recommendation for Lead:** Add a single chore task to Phase 02 to update the ROADMAP Phase 2 goal sentence from "without adding new columns" to "additive schema changes only; defaults preserve v0.1.0 behavior." Also check `typed_eav-enhancement-plan.md` for the same phrasing. This is a one-sentence change, low-risk, keeps the planning artifacts coherent. Decision is Lead's.

---

## Cross-cutting observations

### BC risk points

1. **`Field.sorted` and `Section.sorted`** — NOT renamed or aliased. The new ordering methods are additive instance methods. No BC risk for callers of `.sorted`. Confirmed: the scaffold controller does NOT use `.sorted` on fields (it uses `.order(...)` directly); the Section spec uses `described_class.sorted` which continues to work identically.

2. **`default_value=` callers** — `Field::Base#default_value=` (line 81) remains identical. The `UNSET_VALUE` change is in `Value#value=`, not in the field's `default_value=` method. All existing callers of `field.default_value=` are unaffected.

3. **`typed_values.create(field: f)` without `value:` kwarg** — behavior changes from "store nil" to "store default or nil." Existing callers in specs create fields without `default_value_meta`, so `field.default_value` → `nil`. Net result: no behavioral change for those specs. But any gem consumer who relies on `typed_values.create(field: f)` producing a nil value (not the field's default) will see a behavior change. This IS a behavioral change and should be documented in CHANGELOG under a "Behavior change" note.

4. **`has_many :values, dependent: :destroy` removal** — current `field.destroy!` destroys values via AR `dependent: :destroy`. After Phase 02, `field_dependent` defaults to `"destroy"` and the `before_destroy` hook calls `values.destroy_all`. Functional behavior is identical for default installs. The AC test (`spec/models/typed_eav/field_spec.rb` line 7: `it { is_expected.to have_many(:values) }` — shoulda-matchers) does NOT check the `dependent:` option, so the test still passes after removing `dependent: :destroy` from the association.

5. **`belongs_to :field` becoming optional** — currently AR validates presence of `field_id`. After adding `optional: true`, a Value row can be saved with `field_id: nil`. This is intentional for orphaned rows. The shoulda-matchers test (`spec/models/typed_eav/value_spec.rb` line 8: `it { is_expected.to belong_to(:field) }`) will still pass — `belong_to` without `.required` assertion does not check optionality by default in shoulda-matchers.

### Foundational-principle adherence

- **No hardcoded attribute references:** The ordering helpers take no attribute name parameter — they operate on the `sort_order` column of the record itself (the record IS the Field or Section). No risk.
- **`backfill_default!`:** Iterates entities and delegates value-writing through `field.default_value` (no hardcoded column names). The `value_column` for the skip check comes from `field.class.value_column` — already the correct accessor. No hardcoded attribute names.
- **`field_dependent` dispatch in `before_destroy`:** Reads `field_dependent` as a string and dispatches. The column name `field_dependent` is the field's own meta-attribute, not a reference to any user-defined entity attribute. No risk.

### Test-suite analogs

For each work area, the closest existing spec to place new tests alongside:

| Work area | New spec location | Closest analog |
|---|---|---|
| Ordering helpers (Field) | `spec/models/typed_eav/field_spec.rb` — new `RSpec.describe` block | Existing `RSpec.describe "Field default values"` block |
| Ordering helpers (Section) | `spec/models/typed_eav/section_and_option_spec.rb` — extend "scopes" describe | Existing `describe ".sorted scope"` block (lines 61–70) |
| UNSET_VALUE sentinel | `spec/models/typed_eav/value_spec.rb` — new describe block | Existing "cast invalid detection" block (lines 396–417) |
| `backfill_default!` | `spec/models/typed_eav/field_spec.rb` — new `RSpec.describe` block | Existing "Field default values" block (lines 253–277) |
| Cascade policies | `spec/lib/typed_eav/field_cascade_spec.rb` — new file | `spec/regressions/known_bugs_spec.rb` pattern (regression + coverage) |
| Migration | No spec needed for migration itself | Lifecycle spec in `spec/integration/typed_eav_lifecycle_spec.rb` may test cascade indirectly |

---

## File touch matrix (for Lead's plan)

| File | Areas | Operation |
|---|---|---|
| `app/models/typed_eav/field/base.rb` | 1, 2, 3 | Modify: add ordering methods; add `backfill_default!`; remove `dependent: :destroy`; add `field_dependent` column, validation, and `before_destroy` |
| `app/models/typed_eav/section.rb` | 1 | Modify: add ordering methods (symmetric inline duplication) |
| `app/models/typed_eav/value.rb` | 2, 3 | Modify: add `UNSET_VALUE` constant; modify `value=` and `apply_pending_value`; add `optional: true` to `belongs_to :field` |
| `db/migrate/YYYYMMDDHHMMSS_add_cascade_policy_to_typed_eav_fields.rb` | 3 | Create: `field_dependent` column; `field_id` nullable; FK drop-and-recreate |
| `spec/models/typed_eav/field_spec.rb` | 1, 2, 3 | Modify: add ordering specs; `backfill_default!` specs; `field_dependent` validation spec |
| `spec/models/typed_eav/section_and_option_spec.rb` | 1 | Modify: add section ordering helper specs |
| `spec/models/typed_eav/value_spec.rb` | 2, 3 | Modify: add `UNSET_VALUE` sentinel behavior specs; update `belongs_to :field` test if needed |
| `spec/lib/typed_eav/field_cascade_spec.rb` | 3 | Create: all three cascade policies × partition variations |
| `.vbw-planning/ROADMAP.md` | 4 | Modify: update Phase 2 goal language (chore task, one sentence) |
| `typed_eav-enhancement-plan.md` | 4 | Modify (optional): update "no new columns" phrasing if present (chore task) |
