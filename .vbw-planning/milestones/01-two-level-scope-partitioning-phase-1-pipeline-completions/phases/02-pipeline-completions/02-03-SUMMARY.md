---
phase: 2
plan: 03
title: UNSET_VALUE sentinel + default-population on non-form Value creation
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - a4f5666
deviations:
  - "Spec coverage delivered 12 examples (vs the matrix's 8 cases) by splitting some cases into multiple `it` blocks for clarity (e.g., the form-path case has both 'stores form value' and 'stores explicit nil from form path'); no behavior changed, just finer-grained assertions. All material cases from the plan's coverage matrix are present."
  - "Fixed a transient blocker: file-guard hook initially picked plan 02-02 as 'active' because 02-02-SUMMARY.md hadn't landed yet, blocking writes to value.rb. Resolved when team-lead populated `.vbw-planning/.delegated-workflow.json` with execute team-mode marker. No code-deviation."
pre_existing_issues: []
ac_results:
  - criterion: "TypedEAV::Value::UNSET_VALUE is a public class-level frozen constant (Object.new.freeze, not private_constant)"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:21; spec 'is a frozen, identifiable, public class-level constant' (commit a4f5666)"
  - criterion: "Value#initialize override substitutes UNSET_VALUE for missing :value kwarg"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:107-122; spec 'populates default when create is called WITHOUT a value: kwarg'"
  - criterion: "Value#value=(val) sentinel branch populates field.default_value when field is present"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:65-78; spec 'populates default when create is called WITHOUT a value: kwarg' and 'populates default across non-Integer types'"
  - criterion: "Value#value=(val) with sentinel and no field stashes UNSET_VALUE in @pending_value"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:74-78; spec 'stashes the sentinel in @pending_value when field is unset at construct time'"
  - criterion: "apply_pending_value handles @pending_value.equal?(UNSET_VALUE) via apply_field_default (not via value=)"
    verdict: pass
    evidence: "app/models/typed_eav/value.rb:130-145; spec 'resolves to the field default when apply_pending_value runs after late field assignment'"
  - criterion: "typed_values.create(field: f) populates field.default_value when default present, nil otherwise"
    verdict: pass
    evidence: "specs 'populates default when create is called WITHOUT a value: kwarg' and 'stores nil when create is called without a value: kwarg'"
  - criterion: "typed_values.create(field: f, value: nil) stores nil; default NOT applied"
    verdict: pass
    evidence: "spec 'stores explicit nil and does NOT re-apply the default'"
  - criterion: "typed_values.create(field: f, value: 42) stores 42 (BC unchanged)"
    verdict: pass
    evidence: "spec 'stores explicit value (existing behavior unchanged)'"
  - criterion: "Form path (typed_eav_attributes=, typed_values_attributes=, set_typed_eav_value, initialize_typed_values) is UNAFFECTED"
    verdict: pass
    evidence: "specs 'stores the form-supplied value, not the field default' and 'stores explicit nil from the form path'; existing 65 value_spec examples + full suite (486 examples) pass with 0 failures"
  - criterion: "Read-path orphan guards (field nil) continue to short-circuit (unchanged)"
    verdict: pass
    evidence: "Existing spec '#value when field is nil returns nil without error' still green; value reader at app/models/typed_eav/value.rb:59-63 unchanged"
  - criterion: "Value#value reader unchanged"
    verdict: pass
    evidence: "git show HEAD app/models/typed_eav/value.rb:59-63 shows value reader untouched"
  - criterion: "Single atomic commit covering exactly two files"
    verdict: pass
    evidence: "Commit a4f5666 — 2 files changed, 204 insertions(+), 2 deletions(-)"
---

UNSET_VALUE sentinel wired through Value#initialize / value= / apply_pending_value so non-form `typed_values.create(field: f)` populates field.default_value while preserving explicit-value and explicit-nil semantics.

## What Was Built

- Public class-level constant `TypedEAV::Value::UNSET_VALUE = Object.new.freeze` (mirrors UNSET_SCOPE / ALL_SCOPES; not private_constant by design)
- `Value#initialize` override substituting UNSET_VALUE for a missing `:value` kwarg before `super` — handles plain Hash and ActionController::Parameters; unchanged for nil/scalar attribute shapes
- `Value#value=` sentinel branch: when field is assigned, calls private `apply_field_default`; when field is unset, stashes UNSET_VALUE in `@pending_value` (parallel to existing pending-value path)
- `apply_pending_value` parallel branch: dispatches sentinel-pending case to `apply_field_default` directly (does NOT route back through `value=`)
- New private helper `apply_field_default` writes `field.default_value` (already cast or nil) directly to the typed column
- 12 new specs covering: constant identity/freeze/visibility, default population on create-without-value, explicit nil stores nil, explicit value stores value, fields without configured defaults, String-type sentinel coverage, form-path bypass (typed_eav_attributes=), and the late-field-assignment caveat

## Files Modified

- `app/models/typed_eav/value.rb` -- modify: add UNSET_VALUE constant, initialize override, value= sentinel branch, apply_pending_value sentinel branch, apply_field_default helper
- `spec/models/typed_eav/value_spec.rb` -- modify: append `describe "UNSET_VALUE sentinel"` block with 12 examples covering all matrix cases
