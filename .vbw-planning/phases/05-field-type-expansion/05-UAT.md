---
phase: 5
plan_count: 4
status: issues_found
started: 2026-05-06
completed: 2026-05-06
total_tests: 9
passed: 7
skipped: 0
issues: 2
---

Phase 5 UAT — contract clarity and ergonomic-judgment tests for the five new field types (Image, File, Reference, Currency, Percentage). The 820-example RSpec suite already covers behavioral correctness; this UAT focuses on what only you can judge.

## Tests

### P01-T1: Field::Base extension-point README clarity

- **Plan:** 05-01 -- Field::Base extension points (read_value, apply_default_to, operator_column) + dispatch wiring
- **Scenario:** Open `README.md` and find the "Multi-cell field types (Phase 5)" bullet (look near the §Field Types or §Validation Behavior section). Read the description of when an external field type should override `read_value`, `apply_default_to`, and `operator_column`.
- **Expected:** The wording clearly conveys (a) WHEN to override (multi-cell logical values composed across multiple typed columns), (b) the BC guarantee (single-cell types inherit defaults unchanged), and (c) Currency as the canonical example.
- **Result:** pass

### D01: README "Phase 5" framing leaks plan-internal terminology to consumers

- **Plan:** (discovered during P01-T1)
- **Scenario:** User observation during UAT
- **Expected:** (not applicable — discovered issue)
- **Result:** issue
- **Issue:**
  - Description: README's "Multi-cell field types (Phase 5)" bullet calls out "Phase 5" — that's a plan-internal phase label that doesn't matter to gem consumers. The bullet should describe the contract on its own terms (e.g., "Multi-cell field types") without referring to internal release phases.
  - Severity: minor

### P02-T1: Currency operator naming and Hash-only cast

- **Plan:** 05-02 -- Field::Currency (two-cell, operator_column override) + Field::Percentage (Decimal subclass)
- **Scenario:** Review the Currency bullet in README. The new operator is named `:currency_eq` (filters by currency code, e.g. `op: :currency_eq, value: "USD"`); amount filtering uses `:eq`/`:gt`/`:lt`/`:between`. Cast input is Hash-only (bare Numeric like `99.99` is rejected).
- **Expected:** The `:currency_eq` name reads as intuitive (vs alternatives like `:currency`, `:currency_code_eq`). The Hash-only cast contract feels right — explicit `{amount: 99.99, currency: "USD"}` over silent default-currency fallback when amount is bare.
- **Result:** pass

### P02-T2: Percentage 0..1 storage with display_as formatting

- **Plan:** 05-02 -- Field::Percentage (Decimal subclass with 0-1 range and display_as: :fraction|:percent)
- **Scenario:** Review the Percentage bullet in README. Storage is 0..1 (fraction); user-facing display is controlled by `display_as: :percent` formatting (e.g., 0.75 → "75.0%").
- **Expected:** The 0..1-storage-plus-display-formatting choice feels right vs alternatives (e.g., 0..100 native storage with formatter for fractions). The `display_as` option adequately covers the read-side concerns.
- **Result:** pass

### P03-T1: Active Storage lazy soft-detect ergonomics

- **Plan:** 05-03 -- Field::Image + Field::File via Active Storage soft-detect (engine initializer, has_one_attached, on_image_attached hook)
- **Scenario:** Review the Image/File bullet in README plus how the gem behaves when Active Storage isn't loaded: classes still load (Zeitwerk autoload), but `cast` raises NotImplementedError on first use with the message: `TypedEAV::Field::Image requires Active Storage. Add 'gem activestorage' to your Gemfile.`
- **Expected:** The lazy-detect approach feels right — apps that don't use Image/File don't have to pull in Active Storage. The error message at first-use is actionable.
- **Result:** pass

### P03-T2: Single :attachment association on Value (vs separate per-type)

- **Plan:** 05-03 -- has_one_attached :attachment on TypedEAV::Value
- **Scenario:** Phase 5 declares ONE shared `has_one_attached :attachment` on TypedEAV::Value (covers both Image and File). The discriminator at runtime is `value.field.is_a?(TypedEAV::Field::Image)`. Alternative was two separate associations (`:image_attachment`, `:file_attachment`).
- **Expected:** The single-association choice feels right (less AR overhead per Value row; field-class discrimination is the natural dispatch axis). The fact that every Value row carries the `:attachment` association even when its field isn't Image/File is acceptable.
- **Result:** pass

### P04-T1: Reference target_scope field-save validation strictness

- **Plan:** 05-04 -- Field::Reference (target-scope validation, :references operator)
- **Scenario:** When `target_scope` is set on a Reference field, the target_entity_type MUST be a scope-aware model (registered with `has_typed_eav scope_method:`). Otherwise, the field SAVE itself fails with an explicit error. When `target_scope` is nil, references to any entity type (scoped or unscoped) are accepted with no cross-scope check.
- **Expected:** Field-save-time rejection feels right (catches the misconfiguration early rather than at value-write time). The opt-in nature (target_scope nil = no check) preserves backwards compatibility.
- **Result:** pass

### P04-T2: :references operator accepting AR records or Integer IDs

- **Plan:** 05-04 -- :references operator dispatch (Integer + AR record both work)
- **Scenario:** The `:references` operator accepts BOTH Integer FKs and AR record instances. Example: `Contact.where_typed_eav(name: "manager", op: :references, value: alice)` works AND `..., op: :references, value: alice.id` works.
- **Expected:** The dual-input shape feels right (ergonomic parity with Rails AR's `Contact.where(manager: alice)`). Keeping the conventional `:eq` operator strict (Integer-only) avoids the cost of touching all 17 existing field types' `:eq` branches.
- **Result:** pass

### P05-T1: README Phase 5 closing summary

- **Plan:** 05-04 -- ROADMAP four-vs-five doc fix + Phase 5 closing summary
- **Scenario:** Read the closing line of the README's §Field Types section that summarizes Phase 5 ("Phase 5 ships five field types: Image, File, Reference, Currency, Percentage. All five preserve the cast-tuple contract..."). Also confirm the ROADMAP §Phase 5 Goal text now says "five new field types" (was "four").
- **Expected:** The closing summary is concise and reads naturally. ROADMAP discrepancy is fully resolved (no remaining "four" references).
- **Result:** issue
- **Issue:**
  - Description: README should not refer to internal development phases. The closing summary line "Phase 5 ships five field types: Image, File, Reference, Currency, Percentage..." leaks plan-internal "Phase 5" terminology to gem consumers, same theme as D01. The ROADMAP referencing Phase 5 is fine (internal artifact); the README is consumer-facing and should describe the contracts on their own terms without phase labels. Remediation: remove "Phase 5" references from README's closing summary AND the extension-points bullet (D01) while keeping the same factual content. ROADMAP wording is correct as-is.
  - Severity: minor

## Summary

- Passed: 7
- Skipped: 0
- Issues: 2
- Total: 9
