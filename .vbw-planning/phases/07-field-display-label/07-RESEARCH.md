---
phase: 7
title: Field display label (issue #21)
created: 2026-06-01
source: GitHub issue #21 + codebase verification (2026-06-01)
scope: phase-wide
---

# Research — Field display label (issue #21)

Issue #21 is a complete, file-referenced implementation spec. This document records the
verification of those references against the current tree and the resulting work surface.

## Verified facts (2026-06-01, at v0.4.0)

- **Field STI base:** `app/models/typed_eav/field/base.rb` (Rails-engine layout; models in
  `app/models`, not `lib/`). `display_name` is **absent** — feature not yet implemented.
- **Symmetry precedent:** `app/models/typed_eav/option.rb:11` — `validates :label, presence: true`;
  `option.rb:14` — `scope :sorted, -> { order(sort_order: :asc, label: :asc, id: :asc) }`.
  Field will mirror the machine/human split but with `label` *optional* (no presence) and
  ordering staying slug-stable.
- **Fields table:** created in `db/migrate/20260330000000_create_typed_eav_tables.rb`; the
  `typed_eav_fields` table has **no `label` column** today.
- **Schema portability:** `lib/typed_eav/schema_portability.rb` anchors confirmed at the
  exact lines the issue cites — `export_field_entry` (109), `export_snapshot_field_entry`
  (144), `overwrite_field!` (248), `create_field!` (270), `field_export_row_equal?` (327).

## Work surface

1. **Migration** — `add_column :typed_eav_fields, :label, :string, null: true`. Additive,
   nullable, no index, no default, no backfill. Reversible. Safe/instant on PG 11+.

2. **Model (`field/base.rb`)** — add:
   ```ruby
   def display_name
     label.presence || name.humanize
   end
   ```
   Optional `validates :label, length: { maximum: 255 }, allow_nil: true`. AR auto-exposes
   `label`/`label=` from the column — no attribute plumbing needed. **Do not** touch the
   `:rename` dispatch (must stay keyed on `:name` only) or `sorted` (stays `sort_order, name`).

3. **Schema portability (`schema_portability.rb`)** —
   - `export_field_entry`: add `"label" => field.label`. Flows into `field_export_row_equal?`
     automatically (it compares `export_field_entry(existing) == incoming`).
   - `overwrite_field!`: add `label: entry["label"]` to the allow-listed `assign_attributes`.
   - `create_field!`: **no change** — does `create!(entry.except("options_data"))`, so a
     `"label"` key passes through.
   - `export_snapshot_field_entry`: add `"display_name" => field.display_name` (resolved;
     render-oriented per CONTEXT decision 3).
   - Back-compat: legacy export payloads lack `"label"` → `entry["label"]` is `nil` →
     imports as `NULL` → `display_name` falls back. No version gate.

## Test surface (issue's suggested tests + regression guard)

- `display_name` with label present / blank / nil.
- A reserved-adjacent `name` still validates when `label` is set (label bypasses `RESERVED_NAMES`).
- **Update only `label` → event is `:update`, never `:rename`** (rename-dispatch regression guard).
- `export_field_entry` includes `label`; full `export_schema`/`import_schema` round-trip preserves it.
- Import of a pre-feature payload (no `label` key) → `label` nil, `display_name` falls back.
- `overwrite` import changes `label` on an existing field; divergence detection sees a label diff.
- `sorted` ordering unaffected by `label`.

## Risks / notes

- **Lowest-risk change class:** one additive nullable column + one pure reader + serializer
  pass-through. No data migration, no index, no lock concern.
- The only behavioral change is opt-in (consumers must start writing `label` / reading
  `display_name`). Default NULL preserves byte-for-byte current rendering.
- Watch that no existing serializer/equality path treats the new `label` key as a breaking
  diff for already-exported schemas — covered by the legacy-payload import test.
