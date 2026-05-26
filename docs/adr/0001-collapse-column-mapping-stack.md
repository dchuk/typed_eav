# Collapse column-mapping stack; break `FieldStorageContract` extension API pre-1.0

**Status:** accepted

The Phase-5 storage stack had five participants for one concept ("where does a typed value live in the row?"): `ColumnMapping`, `FieldStorageContract`, `CurrencyStorageContract`, Field instance methods (`read_value` / `write_value` / `apply_default_to`), and the `storage_contract_class` macro. `FieldStorageContract` was a pass-through wrapper for 19 of 20 field types — one real adapter (Currency) on a seam designed for many. Currency carried double-declarations across the Field class and its dedicated contract subclass, where the same column list lived in three places.

We collapsed the stack into a single `Field::TypedStorage` concern that lives on `Field::Base`. The contract classes, the `storage_contract_class` macro, and `field.storage_contract` are removed. Multi-cell field types override three instance methods on their Field subclass (`read_value`, `write_value`, `apply_default`); snapshot/change-detection methods become concrete (derived from `value_columns`). Currency becomes a normal Field subclass with overrides — the same shape external custom multi-cell types now use.

## Considered alternatives

- **α (strict BC):** keep `FieldStorageContract` and `storage_contract_class` as the public extension surface; rewire internal callers to use Field methods directly; delete only `CurrencyStorageContract`. Achieves the internal cleanup without breaking external authors. Rejected because the wrapper class would survive as legacy plumbing with no internal justification, leaving the documented extension API and the actual internal pattern divergent forever.
- **β (deprecate with warnings):** same as α, plus deprecation warnings on `storage_contract_class` / `field.storage_contract`. Rejected because CONTEXT.md's "BC is binding" rule provides no on-ramp to removal — the deprecation would point at nothing and become permanent noise.
- **γ (chosen):** break BC. Remove `FieldStorageContract` entirely. Re-ship as 0.3.0.

## BC reconciliation

CONTEXT.md (`.vbw-planning/CONTEXT.md`) lists "Backwards compatibility is binding" as a key decision. That rule was scoped to the Phase 1–7 enhancement arc — every *phase* preserves current API surface. This refactor is not a phase; it's an out-of-band architectural cleanup happening pre-1.0 where SemVer allows breaking changes at the minor version. Future architectural refactors with the same character should follow the same pattern: an explicit ADR + a minor-version bump, not a silent break.

## Consequences

- External authors who subclass `FieldStorageContract` must migrate to override-on-Field (subclass `Field::Base`, override `value_columns` / `operator_column` / `read_value` / `write_value` / `apply_default`). The Currency source serves as the canonical example.
- The README's §"Multi-cell field types" is rewritten around the new pattern.
- Three spec files (`field_storage_contract_spec`, `column_mapping_spec`, `column_mapping_value_columns_spec`) consolidate into one `field/typed_storage_spec`.
- Override surface shrinks from 7 methods to 3. Snapshot shape becomes a versioning-coupled invariant locked in by `value_columns` rather than an extension point external authors could silently break.
