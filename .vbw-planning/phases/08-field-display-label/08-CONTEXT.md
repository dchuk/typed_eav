---
phase: 8
gathered: 2026-06-01
calibration: architect
source: GitHub issue #21
pre_seeded: false
---

# Phase 8 Context — Field display label (issue #21)

## Problem

`TypedEAV::Field` (STI base at `app/models/typed_eav/field/base.rb`) exposes a single
`name` column that serves double duty: the **machine slug** (used in uniqueness indexes,
partition lookups, rename-event dispatch, and as the API/CSV/JSON key) *and* the
human-facing display string. A host app that slugifies user input (e.g. "Sub-Category"
→ `sub_category`) loses the original text. Rendering then reconstructs it inconsistently
(`name.humanize` → "Sub category"; raw `name` → "sub_category"). `Option` already has a
`label` distinct from its machine `value`; `Field` lacks the symmetric concept.

## Goal

Give `Field` an optional, free-text **display label** independent of its slug `name`,
with one canonical accessor (`display_name`) for all human-facing rendering. `name` stays
the immutable machine key; `label` is purely cosmetic and never participates in
uniqueness, lookup, or partitioning. Fully additive and backwards-compatible.

## Binding decisions

These resolve the issue's two open questions and lock the foundational-principle and
backwards-compat constraints for this phase.

1. **Column name = `label`; computed accessor = `display_name`.** Mirrors `Option#label`
   (machine `value` + human `label`). `display_name` is the fallback-aware reader:
   `label.presence || name.humanize`. Consumers read `display_name` for all rendering;
   `name` remains the key.

2. **Schema portability carries the raw `label` (round-trip fidelity).** Regular
   `export_field_entry` adds `"label" => field.label`; import reproduces it verbatim. This
   flows into `field_export_row_equal?` divergence detection automatically.

3. **Snapshot entries carry the resolved `display_name`.** `export_snapshot_field_entry`
   adds `"display_name" => field.display_name` — snapshots are render-oriented read views,
   so the resolved string is the convenient shape. (Adjustable in plan review if raw-label
   round-trips are preferred for snapshots too; default chosen for the render use case.)

4. **No constraints on `label`.** Free text. No uniqueness, no format. `RESERVED_NAMES`
   and slug-uniqueness apply to `name` only. Optional `length: { maximum: 255 }, allow_nil: true`.

5. **Rename detection must NOT widen to `label`.** `_dispatch_field_change` keys `:rename`
   off `saved_change_to_attribute?(:name)`. Editing only `label` must dispatch `:update`,
   never `:rename` (a label change does not affect the matview column map). Add a
   regression test pinning this so a future refactor cannot widen detection.

6. **Ordering unchanged.** `sorted` orders by `sort_order, name`; `label` is cosmetic and
   must not affect ordering.

7. **Migration safety.** Single additive nullable column on `typed_eav_fields`, no index,
   no default, no backfill. Existing rows keep `label = NULL` and render identically to
   today via the `display_name` fallback. Reversible via `remove_column`.

## Acceptance criteria (from issue #21)

- `typed_eav_fields.label` exists, nullable, no index.
- `Field#display_name` returns `label` when present, else `name.humanize`.
- No uniqueness/format constraint on `label`; `name` constraints unchanged.
- Setting/changing only `label` dispatches `:update`, never `:rename`.
- `sorted` ordering unaffected by `label`.
- `export_schema` round-trips `label`; legacy payloads (no `label` key) import as `NULL`.
- `overwrite` conflict path updates `label`; divergence detection treats a differing
  `label` as a difference.
- Existing rows (label NULL) render unchanged.

## Code anchors (verified 2026-06-01)

- Model: `app/models/typed_eav/field/base.rb` — `display_name` absent; add accessor +
  optional length validation; do NOT touch rename dispatch or `sorted`.
- Schema portability: `lib/typed_eav/schema_portability.rb` — `export_field_entry` (:109),
  `export_snapshot_field_entry` (:144), `overwrite_field!` (:248), `create_field!` (:270),
  `field_export_row_equal?` (:327). `create_field!` needs no change (passes keys through).
- Migration: new `db/migrate/<ts>_add_label_to_typed_eav_fields.rb` (table created in
  `db/migrate/20260330000000_create_typed_eav_tables.rb`).

## Cross-cutting (binding for every phase)

- No hardcoded attribute references — `display_name` derives from the row, no per-attribute logic.
- Backwards compatibility — every existing `name`-based caller untouched; NULL-label rows render unchanged.
- Postgres-only is fine (additive column, no PG-specific feature needed).
- Testing discipline — add tests per the issue's suggested-tests list; pin the rename-dispatch guard.
- Documentation discipline — add a README bullet (the existing model for non-obvious contracts).
