# Keep Phase-6 modules independent; do not introduce an import-pipeline orchestrator

**Status:** accepted

An architecture review surfaced `BulkWrite`, `CSVMapper`, and `SchemaPortability` as a possible missing-orchestrator situation: three Phase-6 modules that *could* form a 4-step import pipeline (export schema → import schema → parse CSV → bulk-write) but don't share an interface, return three different result shapes, and force users assembling the full flow to write per-module glue. On closer inspection the three are correctly scoped as independent toolbox utilities, not a fragmented pipeline.

We're keeping them as-is. Each module owns a focused responsibility and is independently useful:

- `SchemaPortability` moves Field+Section definitions between environments. Used standalone for environment-to-environment schema sync — no CSV or bulk-write involved.
- `CSVMapper.row_to_attributes` is a pure stateless transform with no record context. Used standalone for preview UIs, custom validation flows, anything that needs "header → field name" mapping without committing to a write.
- `BulkWrite.execute` runs batch typed-value writes with savepoint isolation and version-group stamping. Used standalone for bulk imports from non-CSV sources (JSON APIs, admin forms, migrations).

The "import pipeline" is a usage pattern when users compose all three — not an architectural concept the gem needs to name.

## Why the asymmetric return shapes are correct

The three return shapes match each module's natural axis:

- `BulkWrite` returns `{ successes: [...], errors_by_record: {...} }` because per-record error attribution is what a bulk-write caller needs.
- `SchemaPortability.import_schema` returns aggregate counts (`created`, `updated`, `skipped`, `unchanged`, `errors`) because schema import is a category-of-action operation, not per-row.
- `CSVMapper` returns a `Result` value object (`attributes`, `errors`, `success?`) because it transforms one row at a time.

Forcing a unified `Result` shape across all three would either lose the per-record axis (BulkWrite) or shoehorn aggregate counts into a `success?`/`failure?` boolean that doesn't fit (SchemaPortability). The shapes diverge because the use cases diverge.

## Why an orchestrator class would hurt

An `ImportPipeline` class taking a schema Hash + CSV source + host class would either:
- Hardcode a single pipeline shape (export-then-import-then-CSV-then-bulk), inflexible for users with custom flows, OR
- Become a fluent builder that duplicates each module's existing API in a wrapper, growing surface area without addressing the original modules.

Users assembling the full flow today write straightforward composition code. That's correct — the composition is theirs, not the gem's.

## Considered alternatives

- **(b) Unify result shapes only.** Rejected because each return shape's axis is correct for its module's domain.
- **(c) Add `ImportPipeline` orchestrator.** Rejected because it imposes a pipeline shape on users who compose modules differently.
- **(d) b + c.** Rejected for the union of both objections.
- **(e) Minor error-message standardization.** No concrete inconsistencies worth a separate change — each module's error vocabulary fits its domain.

## Where the friction came from

The original review identified cognitive friction (three modules with similar names; no obvious "pipeline" home) and proposed an orchestrator. The friction doesn't survive contact with the implementations: CSVMapper's docstring explicitly documents its scope as "a pure stateless transform with no record context," BulkWrite's docstring states its purpose as "internal executor for host-class bulk typed-value writes," and SchemaPortability's docstring states its purpose as "export and import field + section definitions for an exact partition tuple." Each module is doing one thing well and saying so out loud.

Future contributors who hit the same "shouldn't these compose under one orchestrator?" reaction should land here first.
