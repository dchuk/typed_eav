---
title: "Documentation"
nav_group: Start here
---

# TypedEAV documentation

Add runtime-defined custom fields to Active Record models using native PostgreSQL
columns for scalar values and JSONB for collections. Define fields globally or
per tenant, validate input, and query values through Active Record relations.

## Start here

1. [Install and try TypedEAV](getting-started.md).
2. [Define fields, assign values, and build forms](guides/usage.md).
3. [Configure tenant scoping](guides/scoping.md) if your application has tenants.
4. [Filter, sort, and summarize values](guides/queries.md).

## Guides

| Task | Guide |
|---|---|
| Choose field types and create custom types | [Fields and validation](guides/fields.md) |
| Build forms, manage fields, and inspect pending changes | [Reading, writing, and forms](guides/usage.md) |
| Configure tenants and inspect effective definitions | [Scoping and partitions](guides/scoping.md) |
| Search and summarize custom values | [Queries](guides/queries.md) |
| Read and update many records | [Bulk operations](guides/bulk-operations.md) |
| Map CSV rows to custom fields | [CSV mapping](guides/csv-import.md) |
| Move field definitions between environments | [Schema portability](guides/schema.md) |
| React to changes and keep audit history | [Events and versioning](guides/events-and-versioning.md) |
| Evaluate indexes and performance tradeoffs | [Storage and performance](guides/performance.md) |
| Upgrade an existing installation | [Upgrading](guides/upgrading.md) |

## Reference and development

- [Public API and configuration](reference/index.md)
- [Architecture](guides/architecture.md) and [design decisions](adr/index.md)
- [Development and test isolation](guides/development.md)
- [Maintaining and publishing these docs](maintaining.md)
- [Changelog](changelog.md)
- [Source and issues](https://github.com/dchuk/typed_eav)

These pages describe the code on the default branch. Check the changelog and
release tag when using an older gem version.
