---
title: "Upgrading"
nav_group: Project
---

# Upgrading

[Documentation home](../index.md)

### Migrating from v0.1.x

The resolver-callable contract is a **breaking change**: any custom
`Config.scope_resolver` lambda must now return `[scope, parent_scope]` (a
2-element Array) instead of a bare scalar. A scalar return raises
`ArgumentError` at the next ambient query so the failure is loud, not silent.
If you don't use parent_scope, return `[scope, nil]`.

Run `bin/rails typed_eav:install:migrations` to copy the new
`AddParentScopeToTypedEavPartitions` migration into your app, then
`bin/rails db:migrate`. The migration is safe on production: it adds a
nullable `parent_scope` column (catalog-only, instantaneous) and uses
`CREATE INDEX CONCURRENTLY` for all index changes, so existing rows aren't
rewritten. Existing fields end up with `parent_scope = NULL` (the
global-parent shape) and continue to work for every single-scope caller.

See the [CHANGELOG](https://github.com/dchuk/typed_eav/blob/main/CHANGELOG.md) for the full upgrade checklist.
