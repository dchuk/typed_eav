# INDEX.md

Cross-referenced index of the codebase mapping. Each entry points to the document(s) where the topic is covered in depth.

## Quick orientation

| If you want to know… | Read |
|---|---|
| What the gem is and why it exists | `STACK.md` summary, `README.md` §"Why Typed Columns?" |
| How the engine wires into Rails | `ARCHITECTURE.md` §"Engine wiring" |
| How a query becomes SQL | `ARCHITECTURE.md` §"Layers" + `lib/typed_eav/query_builder.rb` |
| How multi-tenancy works (single-axis OR two-axis) | `ARCHITECTURE.md` §"Multi-tenant scoping" + `CONCERNS.md` §"Multi-tenant scoping" |
| What field types exist (22 as of v0.2.0) | `ARCHITECTURE.md` §"STI field hierarchy" + README §"Field Types" table |
| How to add a single-cell field type | `CONCERNS.md` §"Concerns specific to evolution" |
| How to add a multi-cell field type | `CONCERNS.md` §"Concerns specific to evolution" + `app/models/typed_eav/field/currency.rb` (canonical example) |
| The schema (5 tables) | `db/migrate/*` (4 migrations as of v0.2.0), `STRUCTURE.md` §"Top-level layout" |
| How event dispatch works (Phase 03) | `ARCHITECTURE.md` §"Event dispatch" + `lib/typed_eav/event_dispatcher.rb` |
| How versioning works (Phase 04) | `ARCHITECTURE.md` §"Versioning" + `lib/typed_eav/versioning/subscriber.rb` |
| How cascade policy works (Phase 02) | `ARCHITECTURE.md` §"Cascade policy on Field destroy" + `app/models/typed_eav/field/base.rb#dispatch_field_dependent` |
| How display ordering works (Phase 02) | `ARCHITECTURE.md` §"Display ordering" + `Field::Base` and `Section` `move_*`/`insert_at`/`reorder_within_partition` methods |
| How specs are organized | `TESTING.md` §"Spec layout" |
| What's planned vs. shipped | `CONCERNS.md` §"Technical debt" + `typed_eav-enhancement-plan.md` |

## Key files at a glance

| File | What it contains | Documented in |
|---|---|---|
| `lib/typed_eav.rb` | Module-level API: `configure`, `current_scope`, `with_scope`, `unscoped`, `normalize_scope`, `with_context`, `current_context`. Inflection registration. Phase 1 strict resolver contract. | ARCHITECTURE, STRUCTURE |
| `lib/typed_eav/engine.rb` | Rails::Engine. Two `initializer` blocks (autoload + `on_load(:active_record)`) PLUS two `config.after_initialize` blocks (Phase 04 versioning subscriber registration + Phase 05 Active Storage soft-detect). | ARCHITECTURE |
| `lib/typed_eav/has_typed_eav.rb` | The `has_typed_eav` macro (now with `parent_scope_method:` + `versioned:` kwargs), `ClassQueryMethods` (two-axis `scope:`/`parent_scope:` kwargs), `InstanceMethods`. The most density-rich file in the gem. Includes the macro-time guard for `parent_scope_method:` without `scope_method:`. | ARCHITECTURE, CONCERNS |
| `lib/typed_eav/query_builder.rb` | Operator dispatch — one module, one big case statement. Now routes to physical column via `field.class.operator_column(operator)`. Handles `:references` (FK normalization) and `:currency_eq` (currency-code equality on routed column). | ARCHITECTURE |
| `lib/typed_eav/column_mapping.rb` | The `value_column` macro + `value_columns` plural + `operator_column(op)` dispatch + per-column-type default operator map. | ARCHITECTURE, STRUCTURE |
| `lib/typed_eav/config.rb` | Singleton config: `field_types`, `scope_resolver` (strict), `require_scope`, `versioning` (Phase 04 master switch), `actor_resolver`, `on_value_change`, `on_field_change`, `on_image_attached`. Hand-rolled `defined?(@var)` accessors (Configurable was deprecated in Rails 8.1). Auto-detects `acts_as_tenant`. | ARCHITECTURE, DEPENDENCIES |
| `lib/typed_eav/registry.rb` | Singleton: registered entity types + per-entity `types:` allow-lists + `versioned?` per-entity opt-in flag. | ARCHITECTURE |
| `lib/typed_eav/event_dispatcher.rb` | Phase 03 in-process pub/sub hub. Two channels (value, field) with internal-subscribers arrays + user-proc slots. Locked internal-vs-user error policy split. | ARCHITECTURE, CONCERNS |
| `lib/typed_eav/versioning.rb` | Phase 04 namespace + `register_if_enabled` helper (called from engine `config.after_initialize`). Includes explicit nested `autoload :Subscriber` because top-level autoload doesn't recurse. | ARCHITECTURE |
| `lib/typed_eav/versioning/subscriber.rb` | Phase 04 internal subscriber. Two runtime gates (orphan + per-entity opt-in). Snapshot logic iterates `value_columns` plural. Critical: writes `value_id: nil` for `:destroy` events. | ARCHITECTURE, CONCERNS |
| `lib/typed_eav/versioned.rb` | Phase 04 mixin (post-`has_typed_eav` opt-in). `included` hook re-registers entity with `versioned: true`, preserving existing `types:` restriction. | ARCHITECTURE |
| `app/models/typed_eav/value.rb` | The Value model. Reads/writes via `field.read_value`/`write_value` (multi-cell dispatch). `UNSET_VALUE` sentinel for distinguishing "no value kwarg" from "explicit nil". `versions`/`history`/`revert_to`. Three explicit `after_commit on:` for Rails 8.1 alias-collision workaround. Phase 05 `_dispatch_image_attached`. | ARCHITECTURE, CONCERNS |
| `app/models/typed_eav/value_version.rb` | Phase 04 audit log row. `value_id`/`field_id` nullable + ON DELETE SET NULL (preserves history when live row destroyed). `entity` polymorphic NOT NULL (durable identity). `change_type` validated to closed set. | ARCHITECTURE, CONCERNS |
| `app/models/typed_eav/field/base.rb` | STI parent. `cast` tuple contract. Validation helper library. Cascade dispatch (`field_dependent`). Partition-aware ordering helpers. Default-value handling + `backfill_default!`. Multi-cell extension points (`read_value`/`write_value`/`apply_default_to`). Phase 03 `_dispatch_field_change` branch dispatch. | ARCHITECTURE, CONVENTIONS |
| `app/models/typed_eav/field/<type>.rb` (22 files) | STI subclasses. Each declares `value_column`, optionally narrows operators, implements `cast`, optionally implements `validate_typed_value`. Phase 05 multi-cell types (Currency) override the read/write/default trio. Phase 05 Active Storage types (Image, File) soft-detect AS. | STRUCTURE, CONVENTIONS |
| `app/models/typed_eav/section.rb` | Section model. Phase 01 added `parent_scope` axis to uniqueness key + `for_entity` scope + orphan-parent invariant. Phase 02 added partition-aware ordering helpers (mirrors Field::Base byte-for-byte). | ARCHITECTURE, STRUCTURE |
| `db/migrate/20260330000000_create_typed_eav_tables.rb` | Base four tables + indexes. Postgres-specific (partial unique, GIN, text_pattern_ops). | STRUCTURE, DEPENDENCIES, CONCERNS |
| `db/migrate/20260430000000_add_parent_scope_to_typed_eav_partitions.rb` | Phase 01. Adds `parent_scope` column on fields/sections; replaces two paired partials with three (Option B split: `*_uniq_scoped_full`, `*_uniq_scoped_only`, `*_uniq_global`). Uses `disable_ddl_transaction!` + `algorithm: :concurrently`. | STRUCTURE, DEPENDENCIES, CONCERNS |
| `db/migrate/20260501000000_add_cascade_policy_to_typed_eav_fields.rb` | Phase 02. Adds `field_dependent` column + flips `typed_eav_values.field_id` FK from ON DELETE CASCADE to ON DELETE SET NULL. | STRUCTURE, CONCERNS |
| `db/migrate/20260505000000_create_typed_eav_value_versions.rb` | Phase 04. Audit log table + three `idx_te_vvs_*` indexes (DESC on `changed_at`). | STRUCTURE, CONCERNS |
| `lib/generators/typed_eav/scaffold/scaffold_generator.rb` | Copies a controller + helper + Stimulus controllers + views into the host app. Fail-closed admin auth hook. | ARCHITECTURE, CONCERNS |

## Cross-references

- **The cast tuple `[casted, invalid?]` contract** is defined in `Field::Base#cast` and consumed in `Value#value=` (`app/models/typed_eav/value.rb` lines 92–123) and `Value#validate_value` (lines 363–387). Documented in CONVENTIONS §"Comments" (it was a refactor, commit `eef8e51`).
- **The `UNSET_SCOPE`/`ALL_SCOPES` sentinel pair** is declared in `has_typed_eav.rb` lines 152–160 and used in `where_typed_eav` (lines 217, 218), `typed_eav_definitions` (line 312), and `resolve_scope` (line 343). Documented in ARCHITECTURE §"Multi-tenant scoping" and CONCERNS §"Multi-tenant scoping".
- **The `Value::UNSET_VALUE` sentinel** is declared in `app/models/typed_eav/value.rb` lines 8–21. Lets `Value.create(field: f)` (no `value:` kwarg) trigger `field.apply_default_to(self)`; `Value.create(field: f, value: nil)` stores nil explicitly. Mirrors the `UNSET_SCOPE`/`ALL_SCOPES` public-sentinel pattern.
- **The two-axis (scope, parent_scope) tuple contract** is the Phase 1 deliverable. Strict resolver contract lives in `TypedEAV.current_scope` (lines 84–114); BC-permissive `with_scope` block lives at lines 138–144. Two surfaces, two contracts. The macro-time guard for `parent_scope_method:` without `scope_method:` lives at `has_typed_eav.rb` lines 111–117.
- **The three-way name-collision precedence** (global / scope-only / full-triple) is centralized in `HasTypedEAV.definitions_by_name` (lines 57–61). Used by both `where_typed_eav` (single-winner) and `typed_eav_defs_by_name` (instance) so the two paths can't drift. The unscoped multimap branch uses `definitions_multimap_by_name` (lines 68–70) instead.
- **The Phase 03 dispatch chain** for Value: three explicit `after_commit ..., on: :X` declarations (Rails 8.1 alias-collision workaround) → `_dispatch_value_change_*` → `EventDispatcher.dispatch_value_change(value, change_type)` → internals first (Phase 04 versioning at slot 0; raises propagate) → user proc last (rescued+logged). For Field: single `after_commit :_dispatch_field_change` → branch by `previously_new_record?` / `destroyed?` / `saved_change_to_attribute?(:name)` / else → `EventDispatcher.dispatch_field_change(field, change_type)`.
- **The Phase 04 versioning gates**: master switch at engine boot (`Versioning.register_if_enabled` only registers when `Config.versioning = true`) AND per-entity opt-in at call time (`Subscriber.call` checks `Registry.versioned?(value.entity_type)`). Default off everywhere — apps that don't opt in pay zero overhead.
- **The Phase 05 multi-cell extension trio**: `read_value` / `write_value` / `apply_default_to` are paired. Currency overrides ALL THREE — overriding only one creates an asymmetry. Documented in `field/base.rb` lines 247–309.
- **The Phase 05 Active Storage soft-detect**: `Engine.register_attachment_associations!` registers `has_one_attached :attachment` on TypedEAV::Value when `::ActiveStorage::Blob` is defined. Image/File field-type `cast` raises `NotImplementedError` (with install instructions) when AS is absent; `validate_typed_value` no-ops. Mirrors the `acts_as_tenant` precedent.
- **The "non-obvious contracts"** in README §"Validation Behavior" map to specific code:
  - Required+blank → `Value#blank_typed_value?`
  - Array all-or-nothing cast → `IntegerArray#cast` and friends
  - Integer rejects fractional → `Integer#cast` and `Reference#cast` (`BigDecimal#frac != 0` check)
  - Json parses strings → `Json#cast`
  - TextArray ≠ contains → `TextArray` operators declaration + comment
  - Orphan skip → `InstanceMethods#typed_eav_value`/`typed_eav_hash` orphan guards (now load-bearing for Phase 02 `:nullify` cascade)
  - Cross-scope rejection → `Value#validate_field_scope_matches_entity` (two-axis since Phase 01)
  - Currency Hash-only cast → `Currency#cast` rejection of bare numerics
  - Reference accepts records-or-ids → `Reference#cast` polymorphic raw input
  All listed in CONCERNS §"Validation surprises".

## Validation Notes (contradictions / nuance)

No contradictions found between source files and documentation. A few items worth flagging:

1. **`README.md` says "Requires PostgreSQL"** and the migrations use Postgres-only features. `Gemfile` declares `pg` (only). CI pins Postgres 16 explicitly. Phase 01 migration uses `disable_ddl_transaction!` + `algorithm: :concurrently` which is PG-specific. These are consistent — there is no "we should also support MySQL someday" path in the code, despite the README §"Database Support" hedging that "MySQL/SQLite support would require…". Read that as "documenting why, not promising a future."

2. **`typed_eav-0.1.0.gem` is committed to the repo** but is also generated by `gem build`. As of v0.2.0 the artifact in the repo is still v0.1.0, not v0.2.0 — release workflow will rebuild on tag. Worth removing from git on a future cleanup pass.

3. **`TEST_PLAN.md`** was generated 2026-04-08 against an earlier point in the suite — it lists "Existing spec files (6)" but the suite now has 41 spec files. The plan document is still useful as a target/checklist, but its "Current State" section is well behind the present suite.

4. **The gem version bumped through a rename**: commits show `chore(rename)!: rename gem from typed_fields to typed_eav`. There is no v0.0.x history under the old name in `CHANGELOG.md` — the changelog starts cleanly at `[0.1.0] - 2026-04-25` and now records `[0.2.0]` for the Phase 01–05 rollout. If anyone asks "what changed from typed_fields", the answer is "everything was renamed; semantics unchanged."

5. **`Naming/PredicateMethod` is disabled in rubocop config**. This is what allows methods like `array_field?`/`optionable?`/`unscoped?`/`versioned?`/`previously_new_record?` to coexist with predicates like `cast` that return tuples (`cast` is *not* a predicate despite being asked-of-the-field — the rubocop cop would have complained about the convention split).

6. **Rails 8.1 alias-collision bug** for `after_commit` — see DEPENDENCIES.md note. `Value` works around with three explicit `after_commit ..., on: :X` declarations. `Field::Base` uses ONE `after_commit :_dispatch_field_change` (no `on:` filter, no aliasing) and branches by lifecycle predicate inside the method — a different pattern, intentional, documented inline (lines 73–94).

7. **`ActiveSupport::Configurable` was deprecated in Rails 8.1** without replacement (will be removed in Rails 8.2). `Config` and `Registry` switched to hand-rolled `defined?(@var)` accessors to keep the public API stable across the migration. Documented inline in both files.

## What's not in this map

- **Generated ERB templates** (41 files under `lib/generators/typed_eav/scaffold/templates/views/`) are documented in `STRUCTURE.md` as a category, not enumerated individually. Each is a small input partial for one field type. They are template files, not runtime code.
- **`spec/dummy/`** is a minimal Rails app for testing, documented in `TESTING.md` §"Test harness". It is not part of the gem's public surface.
- **The Stimulus controllers in `lib/generators/.../templates/javascript/`** are template files copied into consumers. They have no tests and are not exercised by the gem's spec suite (see TESTING.md §"Coverage gaps").
- **`.vbw-planning/`** holds the VBW phase-by-phase planning artifacts (CONTEXT.md, RESEARCH.md, PLAN/SUMMARY/VERIFICATION per task, etc.). The hooks block this directory from `.planning/` (the GSD plugin's directory) and vice versa — both plugins maintain isolation at the file-tool level.
