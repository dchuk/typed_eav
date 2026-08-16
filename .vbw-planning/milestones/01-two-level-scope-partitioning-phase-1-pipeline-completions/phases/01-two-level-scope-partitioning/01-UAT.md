---
phase: "01"
title: "Phase 01 UAT — Two-level scope partitioning"
status: complete
generated: 2026-04-29
completed_date: 2026-04-29
total_tests: 3
completed: 3
passed: 3
failed: 0
skipped: 0
---

# Phase 01 UAT: Two-level scope partitioning

The bulk of phase 01 is internal infrastructure (migration, resolver chain, validators, query construction, specs) — automated QA verified those at 440/440 green. UAT focuses on the **user-facing surface**: the docs and migration guide that consumers will actually read when upgrading.

## Test Scenarios

### P07-T01 — README "Two-level scoping" section clarity (plan 01-07)

**Scenario:** Open `README.md` and read the new "Two-level scoping (parent_scope)" subsection (search for "Two-level scoping" or "parent_scope_method").

**Expected:** A consumer reading this for the first time understands (a) what `parent_scope_method:` is for, (b) when they would want to use it (e.g., tenant + workspace setup), (c) the orphan-parent invariant. The example code is concrete and copy-paste friendly.

**Result:** pass

### P07-T02 — CHANGELOG v0.2.0 migration guide (plan 01-07)

**Scenario:** Open `CHANGELOG.md` and read the `[0.2.0]` entry, especially the "Migration from v0.1.x" or migration steps section.

**Expected:** A consumer with a custom `Config.scope_resolver` that returns a bare scalar in v0.1.x can read the migration steps and know exactly how to update their resolver to return `[scope, parent_scope]`. The breaking-change marker is prominent. There's a minimal example showing before/after.

**Result:** pass

### P07-T03 — Validation behavior section (plans 01-03/04/05/06)

**Scenario:** Open `README.md` and find the "Orphan-parent invariant" subsection (search for "Orphan-parent" or "orphan_parent"). Then check the "Validation Behavior" bullet for parent_scope.

**Expected:** The orphan-parent invariant (parent_scope set, scope blank → rejected) is documented as a validation behavior, not buried. A consumer encountering an unexpected validation error knows where to look.

**Result:** pass
