# Pre-1.0 architecture cleanup — ship typed_eav 0.3.0

## Objective

Land the four-part pre-1.0 architectural refactor described in GitHub issue #8 and ship it as version 0.3.0. Each refactor lives as a fully-specced child issue (#9, #10, #11, #12); the release issue (#13) writes the CHANGELOG and bumps the version.

## Original Request

User invoked `/goalbuddy issues 8-13` against a project where:
- `gh issue #8` is the parent PRD ("Pre-1.0 architecture cleanup arc")
- `gh issue #9` — Collapse column-mapping stack into `Field::TypedStorage` concern (ADR-0001)
- `gh issue #10` — Extract `ScopeTuple` module
- `gh issue #11` — Split `HasTypedEav` into `EntityQuery` + `FilterQuery` + `BulkRead` (ADR-0002)
- `gh issue #12` — Field family intermediate bases: `ValidatedString`, `RangeBounded`, `Optionable` (ADR-0004)
- `gh issue #13` — Release 0.3.0 (CHANGELOG + version bump) — blocked by #9–#12

Each child issue carries a `## Technical Spec` section with file paths, line numbers, behavior slices, tracer-bullet, acceptance-criteria mapping, posture, and risks (added via `/issues-to-specs`).

## Intake Summary

- Input shape: `existing_plan`
- Audience: gem maintainer (`dchuk`) and future external authors of custom field types
- Authority: `approved` — issues are published, ADRs 0001–0005 are accepted in `docs/adr/`, PRD has been refined through grills
- Proof type: `test` (full RSpec suite green) + `artifact` (CHANGELOG entry + `VERSION = "0.3.0"`)
- Completion proof: All four refactor PRs merged to `main`; `bundle exec rspec` and `bundle exec rubocop` green at HEAD; `lib/typed_eav/version.rb` shows `VERSION = "0.3.0"`; CHANGELOG.md has a `## [0.3.0]` entry referencing ADRs 0001–0005; final commit subject is `chore(release): bump version to 0.3.0`.
- Goal oracle: `bundle exec rspec && bundle exec rubocop` from repo root, plus `cat lib/typed_eav/version.rb | grep '"0.3.0"'`, plus `grep -E '^## \[0\.3\.0\]' CHANGELOG.md`. Final Judge audit must map every acceptance-criterion checkbox from issues #9–#13 to a verification receipt before declaring `full_outcome_complete: true`.
- Likely misfire: marking the goal done after #9 alone lands ("the hardest one is done — ship it"). Each child issue is a vertical slice; the goal is not complete until #13's release commit exists and the version is bumped. Second misfire: skipping the README updates (per #9 §"Multi-cell field types" and #12 §"Custom field types"), since they're easy to overlook when the test suite goes green.
- Blind spots considered:
  - `scripts/bump-version.sh` is referenced in CLAUDE.md but does NOT exist — fall back to direct edit of `lib/typed_eav/version.rb` (called out in #13's spec).
  - `Field::Percentage`'s class-ivar workaround (`value_column :decimal_value` re-declaration) deepens one level under #12 — verify it still resolves after the family-base refactor.
  - Spec stubs that mock `TypedEAV::FieldStorageContract.new(field_double)` (e.g. `spec/lib/typed_eav/versioning/subscriber_spec.rb:329`) need rewriting in #9.
  - Per-leaf field specs may have fixtures with inverted `min/max` bounds that worked silently before #12 — grep before each PR.
- Existing plan facts:
  - Sequencing per PRD: #9 → #10 → #11 → #12 → #13. #9 and #12 both touch `Field::Base` (sequential), so the dependency-ordered sequence is the safe path.
  - Each issue has full Technical Spec with codebase reads, behavior slices, tracer bullet, acceptance criteria mapping, posture constraints, and risks.
  - ADRs 0001–0005 are accepted and live in `docs/adr/`.
  - Commit format: `{type}({scope}): {description}` per CLAUDE.md.
  - Do NOT bump version or push until #13's slice — explicit CLAUDE.md rule.
  - VBW plugin isolation: this work uses GoalBuddy under `docs/goals/`; do not touch `.vbw-planning/` or `.planning/`.
  - Do NOT touch `EventDispatcher` (ADR-0003) or Phase-6 modules (`BulkWrite`, `CSVMapper`, `SchemaPortability`) per ADR-0005.
  - No DB schema changes for any of the four refactors.
  - No public API change on host AR models (`where_typed_eav`, `with_field`, `typed_eav_value`, `typed_eav_hash`, etc. preserved).

## Goal Oracle

The oracle for this goal is:

`bundle exec rspec && bundle exec rubocop` from repo root, **AND** `grep -E '^## \[0\.3\.0\]' CHANGELOG.md` returns the new entry, **AND** `ruby -e "require './lib/typed_eav/version'; puts TypedEAV::VERSION"` prints `0.3.0`, **AND** the last commit's subject is `chore(release): bump version to 0.3.0`, **AND** every acceptance-criterion checkbox in issues #9, #10, #11, #12, #13 maps to a receipted slice in this board.

The PM must keep comparing task receipts to this oracle. Each Worker package leaves a verification command output in its receipt; T999 reads all five issues, maps each `- [ ]` checkbox to a receipted slice, and only then records `full_outcome_complete: true`.

## Goal Kind

`existing_plan`

## Current Tranche

Continuous execution: implement #9 → #10 → #11 → #12 → #13 in dependency order. Each refactor is a coherent vertical slice (its own PR per PRD). After each Worker package lands and verifies, immediately activate the next. Final audit task (T999) confirms the full owner outcome — 0.3.0 shipped with all four refactors, docs updated, ADRs referenced, suite + rubocop green.

## Non-Negotiable Constraints

- **No version bump or push before T006**. CLAUDE.md is explicit; the release commit is the only place where `lib/typed_eav/version.rb` changes.
- **No public API change on host AR models**. `where_typed_eav`, `with_field`, `typed_eav_value`, `typed_eav_hash`, etc. preserve signatures verbatim.
- **No DB schema changes**. No migrations in any of the four refactors.
- **No touching `EventDispatcher`** (ADR-0003) or `BulkWrite` / `CSVMapper` / `SchemaPortability` (ADR-0005).
- **Commit format**: `{type}({scope}): {description}` per CLAUDE.md — `refactor`, `test`, `fix`, `docs`, `chore` are the relevant types.
- **One commit per slice (PRD recommends one PR per Grill).** Worker tasks should aim for one cohesive commit per task that touches lib + tests + docs together; do not split across many micro-commits.
- **Plugin isolation**: do NOT read, write, glob, grep, or reference any files in `.vbw-planning/` or `.planning/` (per CLAUDE.md).
- **No skipping hooks or signing.** No `--no-verify`, no `--no-gpg-sign`.
- **Do not push.** No `git push` at any point unless the user explicitly asks.
- **Do not re-add rubocop blanket disables** that #11 is supposed to remove (`Metrics/CyclomaticComplexity` on `where_typed_eav`, `typed_eav_hash_for`).

## Stop Rule

Stop only when T999 (final Judge audit) records `full_outcome_complete: true` after mapping every acceptance-criterion checkbox in issues #9–#13 to a receipted slice and verifying the oracle.

Do not stop after #9 lands. Do not stop after #11 lands. Do not stop after #12 lands. Do not stop with the CHANGELOG written but the version unbumped. Do not stop with verification stale or red.

## Slice Sizing

Each child issue (#9, #10, #11, #12) is a single Worker package per PRD ("one PR per Grill"). These are LARGE slices that each touch multiple files (lib + tests + docs/README + spec consolidation) — that's correct. Do NOT split #11 into "extract InstanceMethods" + "extract EntityQuery" + "extract FilterQuery" + "extract BulkRead" — the PRD treats them as one coherent refactor commit.

The release task (#13) is smaller — primarily a CHANGELOG entry + version constant edit + commit. It is one Worker package.

Tiny tasks are allowed if Judge T001 surfaces a precursor (e.g., "fix a stale spec fixture before #9 can run cleanly"). They should not become the default rhythm.

## Canonical Board

Machine truth lives at:

`docs/goals/refactor-0-3-0/state.yaml`

If this charter and `state.yaml` disagree, `state.yaml` wins.

## Run Command

```text
/goal Follow docs/goals/refactor-0-3-0/goal.md.
```

## PM Loop

On every `/goal` continuation:

1. Read this charter.
2. Read `state.yaml`.
3. Run the bundled GoalBuddy update checker when available and mention a newer version without blocking.
4. Re-check intake: original request, input shape, authority, proof, blind spots, existing plan facts, likely misfire.
5. Work only on the active board task.
6. Assign Scout, Judge, Worker, or PM according to the task.
7. Write a compact task receipt (or `notes/<task-id>-<slug>.md` for long receipts).
8. Update the board.
9. After T001 (Judge validation), activate T002 (Worker #9). After each Worker receipt verifies, immediately activate the next Worker. Use Judge only at T999 (final audit) unless a slice's verification fails or a risk boundary appears.
10. If a slice's verification fails twice or files outside `allowed_files` are needed, mark it blocked with a receipt and queue a Scout/Judge task to resolve.
11. Issue/PR handoffs: each Worker should reference the corresponding GitHub issue number in its commit subject when possible (`refactor(field): collapse storage stack into TypedStorage concern (#9)`).
12. Finish only with T999's Judge audit recording `full_outcome_complete: true`.
