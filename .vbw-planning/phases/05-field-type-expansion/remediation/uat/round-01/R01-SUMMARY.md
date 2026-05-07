---
phase: 5
round: 01
title: "UAT remediation R01: drop README Phase 5 references (D01 + P05-T1)"
type: remediation
status: complete
started: 2026-05-06
completed: 2026-05-06
tasks_completed: 1
tasks_total: 1
commit_hashes:
  - 41f07ffaa5a8e9686290e5cd7d09432acf86d9a8
files_modified:
  - README.md
deviations: []
pre_existing_issues: []
---

UAT R01 dropped all "Phase 5" plan-internal references from the consumer-facing README sections; ROADMAP wording was preserved per user clarification.

## Task 1: Drop "Phase 5" references from consumer-facing README sections

### What Was Built
- README.md cleaned of every consumer-facing "Phase 5" / "Phase-5" reference. Verification: `grep -nE 'Phase[ -]5' README.md` returns 0 matches.
- Two UAT-cited sites fixed:
  - **D01 (minor):** `### Multi-cell field types (Phase 5)` heading → `### Multi-cell field types`. Bullet body untouched.
  - **P05-T1 (minor):** Closing summary `**Phase 5 summary:** Five field types ship in Phase 5 — **Image, File, Reference, Currency, Percentage**. All five preserve the cast-tuple contract...` reworded to `**Summary:** The built-in field types **Image, File, Reference, Currency, Percentage** all preserve the cast-tuple contract (\`[casted, invalid?]\`), the operator-dispatch model (\`supported_operators\` + \`operator_column\` for multi-cell types), and the no-hardcoded-attribute-references foundational principle. The multi-cell extension surface (\`read_value\`, \`apply_default_to\`, \`operator_column\`, and \`write_value\`) is the canonical way to build any future external multi-cell field type.` Factual content (cast-tuple contract, operator-dispatch model, no-hardcoded-attribute-references principle, multi-cell extension surface) is fully preserved.
- Adjacent collateral cleanup the verification grep surfaced (the task instructions explicitly directed: "If there are still matches that aren't in any internal/changelog section, polish them too"):
  - `### Built-in Phase-5 field types` subheading → `### Built-in field types`.
  - Each bullet header that carried a `(Phase 5)` parenthetical had it stripped: `Currency`, `Percentage`, `Image`, `File`, `Active Storage dependency`, `on_image_attached` hook, `Reference`. Bullet bodies untouched.
  - Inline mention `The built-in \`Field::Currency\` (Phase 5) is the canonical multi-cell consumer...` → `The built-in \`Field::Currency\` is the canonical multi-cell consumer...`.
  - Versioning section line `Multi-cell field types (Phase 5 Currency, when it lands) produce two-key snapshots...` → `Multi-cell field types (e.g., \`Currency\`) produce two-key snapshots...`. Removes both the phase label and the stale "when it lands" wording (Currency has shipped).
- ROADMAP.md and all other planning artifacts intentionally untouched per user clarification: "ROADMAP referencing Phase 5 is fine (internal artifact). Only README must drop the phase references."

### Files Modified
- `README.md` -- edit: drop every `Phase 5` / `Phase-5` reference from consumer-facing headings, bullet labels, and prose; reword the closing summary to a phase-agnostic factual lead-in; reword the versioning-section multi-cell example to drop the stale "when it lands" wording. 16 insertions, 16 deletions; no factual content removed.

### Deviations
None
