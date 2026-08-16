# Phase 1: Two-level scope partitioning — Context

Gathered: 2026-04-28
Calibration: architect

## Phase Boundary

Extend the canonical partition tuple from `(entity_type, scope)` to `(entity_type, scope, parent_scope)` for fields AND sections. Mirror the existing scope-NULL / scope-NOT-NULL paired partial unique indexes onto the new triple. Single-scope users (no `parent_scope_method:`) must see no API change. New `parent_scope` column is nullable; existing data migrates cleanly.

Out of scope for this phase: cascade behavior changes (Phase 2), default-value pipeline (Phase 2), event/context contract (Phase 3), versioning (Phase 4).

## Decisions Made

### Sentinel design
- **Reuse the existing `UNSET_SCOPE` / `ALL_SCOPES` pair for both `scope` and `parent_scope`.** Kwarg name (`scope:` vs `parent_scope:`) disambiguates which key the sentinel addresses.
- The thread-local stack stores tuples now; a sentinel passed via kwarg applies to whichever slot is being set.
- No new `UNSET_PARENT_SCOPE` / `ALL_PARENT_SCOPES` constants — keeps the sentinel pair count at 1, smaller surface area to teach.

### Resolver protocol shape
- **Tuple-returning resolver** is the contract: `Config.scope_resolver` returns `[scope, parent_scope]`.
- **This is a hard breaking change** — every consumer with a custom `Config.scope_resolver` must update on upgrade, even if they aren't using `parent_scope`.
- Major version bump on release. Explicit CHANGELOG entry required. Migration note must be in the README and in the Phase 1 SUMMARY.
- This decision **carves out an exception** to the milestone-level "Backwards compatibility is binding" decision. The BC commitment still applies to every other API surface in this phase (existing scope kwargs, `with_scope` block, `unscoped` block, `where_typed_eav`, `with_field`, `Field.sorted`).
- Auto-detection of `acts_as_tenant` (`Config::DEFAULT_SCOPE_RESOLVER`) must be updated to return a tuple — its parent_scope slot is `nil` when no parent-scope analog exists in the tenant gem.

### Section ↔ Field code sharing
- **Inline duplicate** the symmetric scope/parent_scope logic in `field/base.rb` and `section.rb`, the same way `for_entity` is mirrored today.
- **Do NOT extract a `Scopable` concern in this phase.** Defer until either (a) a third caller needs the partition-tuple logic, or (b) the two implementations start diverging.
- Why: matches the codebase's current style; avoids adding a layer that doesn't exist; honors YAGNI. Section vs Field already have small but real divergences (e.g., `validate_field_scope_matches_entity` is Field-only) that argue against premature extraction.

### `unscoped { }` semantics with both keys
- **Atomic bypass** — `unscoped { }` drops both `scope` AND `parent_scope` predicates entirely. Plan-canonical.
- Multimap stays at the `field_id` level: OR across all `field_id`s sharing a name. No `scope` or `parent_scope` filtering is added inside `unscoped`.
- Preserves today's audit-query semantic of "show me everything across tenants" — extending it to "across tenants AND parent scopes" is the natural generalization.
- `spec/regressions/review_round_2_scope_leak_spec.rb` and `review_round_3_collision_spec.rb` get parallel coverage for the parent_scope axis.

### Open (Claude's discretion)

- **Migration ordering and rollback strategy.** The migration adds a nullable `parent_scope` column to `typed_eav_fields` and `typed_eav_sections`, drops the existing paired partial unique indexes, and creates new paired partial unique indexes on the triple. Production deployments may have millions of rows. Default to `CREATE INDEX CONCURRENTLY` outside a transaction, with index names that fit Postgres' 63-byte limit (`idx_te_*` prefix) — to be detailed in the Phase 1 plan.
- **Composite resolution semantics edge cases.** When `scope=nil` (global), `parent_scope` must also be nil — no orphan-parent rows. The resolver chain enforces this, and `Value#validate_field_scope_matches_entity` rejects orphan-parent writes. Specific predicate construction in `where_typed_eav` (single-scope branch and multimap branch) belongs in the plan.
- **Spec naming convention** for the new parent-scope coverage — extend `spec/regressions/review_round_*_scope*` patterns or open a new round file. Lead/Dev to pick at plan time.

## Deferred Ideas

- **Extract `Scopable` concern.** Deferred until a third caller surfaces or Section/Field implementations diverge. Track via a project-level open question (not a phase deferral).
- **Auto-coerce non-array returns from custom resolvers as `[value, nil]`** — the BC-shim alternative explicitly rejected during this discussion. Documented here so future maintainers don't reintroduce it without a deliberate decision reversal.
