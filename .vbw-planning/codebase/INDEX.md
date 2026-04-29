# INDEX.md

Cross-referenced index of the codebase mapping. Each entry points to the document(s) where the topic is covered in depth.

## Quick orientation

| If you want to know… | Read |
|---|---|
| What the gem is and why it exists | `STACK.md` summary, `README.md` §"Why Typed Columns?" |
| How the engine wires into Rails | `ARCHITECTURE.md` §"Engine wiring" |
| How a query becomes SQL | `ARCHITECTURE.md` §"Layers" + `lib/typed_eav/query_builder.rb` |
| How multi-tenancy works | `ARCHITECTURE.md` §"Multi-tenant scoping" + `CONCERNS.md` §"Multi-tenant scoping" |
| What field types exist | `ARCHITECTURE.md` §"STI field hierarchy" + README §"Field Types" table |
| How to add a new field type | `CONCERNS.md` §"Concerns specific to evolution" |
| The schema | `db/migrate/20260330000000_create_typed_eav_tables.rb`, `STRUCTURE.md` §"Top-level layout" |
| How specs are organized | `TESTING.md` §"Spec layout" |
| What's planned vs. shipped | `CONCERNS.md` §"Technical debt" + `typed_eav-enhancement-plan.md` |

## Key files at a glance

| File | What it contains | Documented in |
|---|---|---|
| `lib/typed_eav.rb` | Module-level API: `configure`, `current_scope`, `with_scope`, `unscoped`, `normalize_scope`. Inflection registration. | ARCHITECTURE, STRUCTURE |
| `lib/typed_eav/engine.rb` | Rails::Engine. Two initializers: autoload + `on_load(:active_record)`. | ARCHITECTURE |
| `lib/typed_eav/has_typed_eav.rb` | The `has_typed_eav` macro, `ClassQueryMethods`, `InstanceMethods`. The most density-rich file in the gem. | ARCHITECTURE, CONCERNS |
| `lib/typed_eav/query_builder.rb` | Operator dispatch — one module, one big case statement. | ARCHITECTURE |
| `lib/typed_eav/column_mapping.rb` | The `value_column` macro + per-column-type default operator map. | ARCHITECTURE, STRUCTURE |
| `lib/typed_eav/config.rb` | Singleton config: `field_types`, `scope_resolver`, `require_scope`. Auto-detects `acts_as_tenant`. | ARCHITECTURE, DEPENDENCIES |
| `lib/typed_eav/registry.rb` | Singleton: registered entity types + per-entity type allow-lists. | ARCHITECTURE |
| `app/models/typed_eav/value.rb` | The Value model. Reads/writes the typed column based on the field's `value_column`. Three security-relevant validations. | ARCHITECTURE, CONCERNS |
| `app/models/typed_eav/field/base.rb` | STI parent. `cast` tuple contract. Validation helper library. | ARCHITECTURE, CONVENTIONS |
| `app/models/typed_eav/field/<type>.rb` (17 files) | STI subclasses. Each declares `value_column`, optionally narrows operators, implements `cast`, optionally implements `validate_typed_value`. | STRUCTURE, CONVENTIONS |
| `db/migrate/20260330000000_create_typed_eav_tables.rb` | Four tables, all indexes. Postgres-specific (partial unique, GIN, text_pattern_ops). | STRUCTURE, DEPENDENCIES, CONCERNS |
| `lib/generators/typed_eav/scaffold/scaffold_generator.rb` | Copies a controller + helper + Stimulus controllers + views into the host app. Fail-closed admin auth hook. | ARCHITECTURE, CONCERNS |

## Cross-references

- **The cast tuple `[casted, invalid?]` contract** is defined in `Field::Base#cast` (`app/models/typed_eav/field/base.rb` lines 77–79) and consumed in `Value#value=` (`app/models/typed_eav/value.rb` lines 38–49) and `Value#validate_value` (lines 69–93). Documented in CONVENTIONS §"Comments" (it was a refactor, commit `eef8e51`).
- **The `UNSET_SCOPE`/`ALL_SCOPES` sentinel pair** is declared in `has_typed_eav.rb` lines 99–104 and used in `where_typed_eav` (lines 120, 152), `typed_eav_definitions` (line 230), and `resolve_scope` (line 248). Documented in ARCHITECTURE §"Multi-tenant scoping" and CONCERNS §"Multi-tenant scoping".
- **The two write-paths** (`typed_eav_attributes=` by name, `typed_values_attributes=` by id) are documented inline (`has_typed_eav.rb` lines 319–387). Summarized in ARCHITECTURE §"Forms & nested attributes".
- **The "non-obvious contracts"** in README §"Validation Behavior" map to specific code:
  - Required+blank → `Value#blank_typed_value?`
  - Array all-or-nothing cast → `IntegerArray#cast` and friends
  - Integer rejects fractional → `Integer#cast` (`BigDecimal#frac != 0` check)
  - Json parses strings → `Json#cast`
  - TextArray ≠ contains → `TextArray` operators declaration + comment
  - Orphan skip → `InstanceMethods#typed_eav_value`/`typed_eav_hash` orphan guards
  - Cross-scope rejection → `Value#validate_field_scope_matches_entity`
  All listed in CONCERNS §"Validation surprises".

## Validation Notes (contradictions / nuance)

No contradictions found between source files and documentation. A few items worth flagging:

1. **`README.md` says "Requires PostgreSQL"** and the migration uses Postgres-only features. `Gemfile` declares `pg` (only). CI pins Postgres 16 explicitly. These three are consistent — there is no "we should also support MySQL someday" path in the code, despite the README §"Database Support" hedging that "MySQL/SQLite support would require…". Read that as "documenting why, not promising a future."

2. **`typed_eav-0.1.0.gem` is committed to the repo** but is also generated by `gem build`. Worth removing from git on a future cleanup pass.

3. **`TEST_PLAN.md`** was generated 2026-04-08 against an earlier point in the suite — it lists "Existing spec files (6)" but the suite now has 22 spec files. The plan document is still useful as a target/checklist, but its "Current State" section is outdated relative to the present suite.

4. **The gem version bumped through a rename**: commits show `chore(rename)!: rename gem from typed_fields to typed_eav`. There is no v0.0.x history under the old name in `CHANGELOG.md` — the changelog starts cleanly at `[0.1.0] - 2026-04-25`. If anyone asks "what changed from typed_fields", the answer is "everything was renamed; semantics unchanged."

5. **`Naming/PredicateMethod` is disabled in rubocop config**. This is what allows methods like `array_field?`/`optionable?`/`unscoped?` to coexist with predicates like `cast` that return tuples (`cast` is *not* a predicate despite being asked-of-the-field — the rubocop cop would have complained about the convention split).

## What's not in this map

- **Generated ERB templates** (41 files under `lib/generators/typed_eav/scaffold/templates/views/`) are documented in `STRUCTURE.md` as a category, not enumerated individually. Each is a small input partial for one field type. They are template files, not runtime code.
- **`spec/dummy/`** is a minimal Rails app for testing, documented in `TESTING.md` §"Test harness". It is not part of the gem's public surface.
- **The Stimulus controllers in `lib/generators/.../templates/javascript/`** are template files copied into consumers. They have no tests and are not exercised by the gem's spec suite (see TESTING.md §"Coverage gaps").
