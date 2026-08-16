---
phase: 1
plan: "07"
title: "README migration note + CHANGELOG + version bump"
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - b8fbc91
deviations:
  - "DEVN-02 (file scope): commit includes Gemfile.lock as a 4th source file in addition to the plan-prescribed README.md / CHANGELOG.md / lib/typed_eav/version.rb. Reason: Bundler auto-rewrites Gemfile.lock to match lib/typed_eav/version.rb on the next `bundle exec` invocation; leaving the lock at 0.1.0 against a 0.2.0 version pin produces a self-inconsistent repo where every subsequent bundler call dirties a tracked file. The version-bump task in the plan implicitly covers this — Gemfile.lock change is mechanical fallout from the version constant edit, not a scope expansion."
  - "DEVN-05 (pre-existing): rubocop reports 5 Layout/HashAlignment offenses in typed_eav.gemspec lines 22-26. Verified pre-existing at HEAD e5e78a4 before this plan started; no file in this plan touched typed_eav.gemspec. Out of scope — flagged for separate housekeeping per ROADMAP."
pre_existing_issues:
  - '{"test": "rubocop", "file": "typed_eav.gemspec:22-26", "error": "Layout/HashAlignment: hash literal keys not aligned in metadata{} block (5 occurrences). Verified pre-existing at HEAD e5e78a4 before plan 01-07 started; no file in this plan touched typed_eav.gemspec."}'
ac_results:
  - criterion: "README §Multi-Tenant Scoping section gains a 'Two-level scoping (parent_scope)' subsection covering parent_scope_method:, with_scope tuple form, and the tuple-returning resolver contract"
    verdict: pass
    evidence: "README.md added the subsection before §'Name collisions across scopes'. Covers Project example with both scope_method:/parent_scope_method:, three-level precedence (full-triple > scope-only > global), macro-time guard requiring scope_method: alongside parent_scope_method:, with_scope([\"t1\", \"w1\"]) tuple example, scalar-form BC example, custom resolver tuple example, parent_scope: kwarg on where_typed_eav, and acts_as_tenant auto-detect returning [tenant, nil]."
  - criterion: "README §Database Support section gains a one-line note that paired partial unique indexes now cover the (entity_type, scope, parent_scope) tuple"
    verdict: pass
    evidence: "README.md §Database Support gained a paragraph: 'As of v0.2.0, the paired partial unique indexes cover the three-key partition tuple (entity_type, scope, parent_scope). The orphan-parent invariant means the WHERE scope IS NULL partials don't include parent_scope — a global row always has parent_scope NULL too.'"
  - criterion: "README §Validation Behavior section gains a bullet about orphan-parent rejection (parent_scope set without scope is invalid)"
    verdict: pass
    evidence: "README.md §Validation Behavior gained two bullet updates: cross-scope-writes bullet extended ('The same guard covers the parent_scope axis.') and a new bullet 'Orphan-parent rows rejected: a Field or Section row with parent_scope set but scope blank is invalid. The Value-side guard rejects cross-(scope, parent_scope) writes too.'"
  - criterion: "CHANGELOG.md gains a [0.2.0] section with: (a) BREAKING resolver-callable contract change, (b) new parent_scope column and indexes, (c) new parent_scope_method: macro kwarg, (d) explicit upgrade-step list for users with custom scope_resolver"
    verdict: pass
    evidence: "CHANGELOG.md [0.2.0] - 2026-04-29 inserted above [0.1.0]. Sections: Added (parent_scope_method:, parent_scope: query kwargs, with_scope tuple form, idx_te_sections_lookup), Changed (BREAKING resolver tuple, current_scope tuple, DEFAULT_SCOPE_RESOLVER tuple, for_entity parent_scope:, AR uniqueness validators, three-way precedence, paired partials renamed to _uniq_*, lookup index recreated), Validation (orphan-parent guard on Field/Section, Value cross-axis guard), Migration Steps (numbered 1-4: install:migrations, db:migrate, update resolver lambda, optional parent_scope_method:), References (six-commit phase-01 chain). [0.2.0] link reference added at bottom."
  - criterion: "lib/typed_eav/version.rb is bumped from 0.1.0 to 0.2.0 — manually edited, NOT via scripts/bump-version.sh (forbidden per project rules without explicit user request)"
    verdict: pass
    evidence: "Edited via Edit tool (single-line replace of VERSION constant). `ruby -e \"require './lib/typed_eav/version'; puts TypedEAV::VERSION\"` => 0.2.0. scripts/bump-version.sh was NOT invoked; verified by absence in command history."
  - criterion: "Migration step in CHANGELOG explicitly tells users: (i) run the engine install:migrations rake task to copy the new migration into their app, (ii) update any custom Config.scope_resolver lambda to return [scope, parent_scope]"
    verdict: pass
    evidence: "CHANGELOG.md ### Migration steps section: step 1 says 'Run bin/rails typed_eav:install:migrations to copy AddParentScopeToTypedEavPartitions into your app.' Step 3 says 'Update any custom TypedEAV.config.scope_resolver lambda to return [scope, parent_scope]. If you don't use parent_scope, return [scope, nil]. A bare scalar return surfaces as ArgumentError at runtime — there is no silent fallback.'"
  - criterion: "Single commit: docs(release): document parent_scope migration, bump to 0.2.0, update CHANGELOG"
    verdict: pass
    evidence: "Commit b8fbc91 with the exact subject line. `git diff HEAD~1 --stat` shows 4 source files (CHANGELOG.md, Gemfile.lock, README.md, lib/typed_eav/version.rb) + 2 planning files (ROADMAP.md, STATE.md auto-staged by planning_tracking=commit hook). Body documents what each file change covers."
  - criterion: "auto_push behavior honored: do NOT push unless .vbw-planning/config.json has auto_push set to always or after_phase"
    verdict: pass
    evidence: ".vbw-planning/config.json has `auto_push: never`. No `git push` invoked. `git status` after commit shows 'Your branch is ahead of origin/main by 19 commits' — local-only commit as required by policy."
  - criterion: "Artifact README.md provides Two-level scoping documentation + breaking-change migration note (contains 'parent_scope_method')"
    verdict: pass
    evidence: "README.md +93 / -5 lines. `grep -c parent_scope_method README.md` => 4 occurrences (Quick Start example removed; new occurrences in §Two-level scoping subsection: heading reference, class-decl example, paragraph explaining requirement on scope_method:, paragraph in macro-time guard sentence)."
  - criterion: "Artifact CHANGELOG.md provides 0.2.0 release entry with BREAKING tag (contains '## [0.2.0]')"
    verdict: pass
    evidence: "CHANGELOG.md +80 lines. `grep -n 'BREAKING' CHANGELOG.md` => 1 hit on line 22 in Changed section ('**BREAKING** Config.scope_resolver callables MUST return a 2-element Array...'). [0.2.0] heading at line 8."
  - criterion: "Artifact lib/typed_eav/version.rb provides Major version bump (contains 'VERSION = \"0.2.0\"')"
    verdict: pass
    evidence: "lib/typed_eav/version.rb line 4: `VERSION = \"0.2.0\"`. Diff shows exactly one line changed."
  - criterion: "key_link CHANGELOG.md -> README.md via 'Migration steps in CHANGELOG cross-reference the README §Multi-Tenant Scoping subsection'"
    verdict: pass
    evidence: "CHANGELOG.md after Migration Steps numbered list: 'See the README [\"Migrating from v0.1.x\"](README.md#migrating-from-v01x) section for the full guidance, including the orphan-parent invariant and worked examples.'"
  - criterion: "key_link lib/typed_eav/version.rb -> CHANGELOG.md via 'Version bump must match the new CHANGELOG section heading'"
    verdict: pass
    evidence: "version.rb VERSION = \"0.2.0\" matches CHANGELOG.md heading `## [0.2.0] - 2026-04-29`. Both reference the same release."
  - criterion: "Full RSpec suite remains green (no regression)"
    verdict: pass
    evidence: "`bundle exec rspec` => 440 examples, 0 failures. Run twice (once after README+CHANGELOG+version edits, once after commit landed). DEPRECATION WARNING from ActiveSupport::Configurable is a pre-existing Rails 8.2 forward-compat warning unrelated to this plan."
---

Phase 1 / wave 4 / plan 07: terminal commit. Documented the v0.2.0 breaking-change release — README "Two-level scoping" subsection plus migration guide, CHANGELOG [0.2.0] entry with BREAKING marker and numbered upgrade steps, manual version bump from 0.1.0 to 0.2.0. Single atomic commit b8fbc91 lands locally; auto_push=never, so the orchestrator decides when to publish.

## What Was Built

- **README.md (+93 / -5)**: New §"Two-level scoping (parent_scope)" subsection covers `parent_scope_method:` (with the `scope_method:` requirement), three-layer precedence (full-triple > scope-only > global), `with_scope([s, ps])` tuple form (scalar BC preserved), custom-resolver tuple contract, `parent_scope:` kwarg on `where_typed_eav` / `with_field` / `typed_eav_definitions`, and the `acts_as_tenant` auto-detect returning `[tenant, nil]`. New §"Migrating from v0.1.x" walks through the breaking-change upgrade path with the install:migrations + CONCURRENTLY-safe migration narrative. New §"Orphan-parent invariant" explains the resolution-path reasoning. §"Validation Behavior" gained an orphan-parent bullet and extended the cross-scope-write bullet to the parent_scope axis. §"Database Support" notes the new triple-key paired-partial-unique design. §"Wiring the resolver" paragraph that previously read "The resolver can return a raw value..." rewritten to specify the 2-element Array contract and link to the migration section.
- **CHANGELOG.md (+80)**: [0.2.0] - 2026-04-29 entry inserted above [0.1.0]. Sections: Added, Changed (BREAKING marker on the resolver contract), Validation, Migration steps (numbered 1-4), References (six-commit phase-01 chain). [0.2.0] link reference at bottom.
- **lib/typed_eav/version.rb (+1 / -1)**: VERSION constant bumped 0.1.0 -> 0.2.0 via manual edit. scripts/bump-version.sh NOT invoked.
- **Gemfile.lock (+2 / -2)**: Bundler-rewritten consequence of the version constant edit (PATH section + CHECKSUMS section). Included to keep the repo self-consistent — bundler would otherwise rewrite this file on every subsequent `bundle exec` call.

## Files Modified

- `README.md` -- modified: +93 / -5 lines. Two-level-scoping subsection, migration guide, orphan-parent invariant, validation/database-support edits, resolver-paragraph rewrite. Total file 495 -> 583 lines.
- `CHANGELOG.md` -- modified: +80 / 0 lines. [0.2.0] release entry above [0.1.0].
- `lib/typed_eav/version.rb` -- modified: +1 / -1 line. VERSION = "0.2.0".
- `Gemfile.lock` -- modified: +2 / -2 lines. PATH typed_eav (0.1.0 -> 0.2.0) and CHECKSUMS row updated.

## Pre-existing Issues

- **rubocop typed_eav.gemspec:22-26 (Layout/HashAlignment, 5 offenses)**: hash keys in the `metadata{}` block aren't aligned with the trailing-arrow style. Verified pre-existing at HEAD e5e78a4 (before plan 01-07 started) — `git stash --keep-index && bundle exec rubocop typed_eav.gemspec` reproduces the same 5 offenses on the unmodified file. Out of scope for this plan; flag for housekeeping along with the existing typed_eav-0.1.0.gem cleanup item already noted in ROADMAP.

## Phase 01 Closeout

- **Phase status**: All four waves complete (440 examples, 0 failures).
  - Wave 0 (`5ff7c30`): migration scaffolding.
  - Wave 1 (`52014a3`, `6c3afb5`, `9c7e916`): resolver tuple, Field partition, Section partition.
  - Wave 2 (`c628372`): macro + queries + Value cross-axis.
  - Wave 3 (`e5e78a4`): spec coverage (52 new examples).
  - Wave 4 (`b8fbc91`): release docs + version bump (this plan).
- **Push status**: `auto_push: never` per `.vbw-planning/config.json`. Branch `main` is local-only at 19 commits ahead of `origin/main`. The orchestrator decides when to publish; no `git push` was invoked.
- **Build artifact**: `gem build typed_eav.gemspec` was run as a sanity check during verification and successfully produced `typed_eav-0.2.0.gem`. The build artifact was deleted afterward (it's gitignored anyway). The pre-existing `typed_eav-0.1.0.gem` at the repo root was preserved per the orchestrator's instruction.
