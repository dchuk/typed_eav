# Introduce family intermediate bases on `Field` (ValidatedString, RangeBounded, Optionable)

**Status:** accepted

The Field STI hierarchy was nearly flat — 20+ leaf subclasses all directly under `Field::Base` (the only exception being Percentage < Decimal). Three real duplication families had grown across the leaves: Text/Email/Url duplicated min/max_length + pattern validation (~30 lines × 3); Integer/Decimal/Date/DateTime duplicated min/max range patterns with inconsistencies (Integer/Decimal had a macro-level `validates :max, comparison:` check; Date/DateTime didn't); Select/MultiSelect duplicated `optionable?` + `allowed_values` + option-inclusion validators. Each family had three or more leaves — well above the "two adapters = real seam" threshold.

We introduced three intermediate types — one inheritance-vs-mixin choice per family — and documented them as public extension API. ValidatedString and RangeBounded are intermediate classes (`< Field::Base`); Optionable is a concern. Leaf subclasses move to the appropriate family. The protected validation helpers move from Field::Base down to the family that owns them (validate_length/validate_pattern → ValidatedString; validate_range/_date_range/_datetime_range → RangeBounded; validate_option_inclusion/validate_multi_option_inclusion → Optionable). `validate_array_size` stays on Field::Base because its callers (MultiSelect via Optionable and IntegerArray directly) don't share a family.

True stubs (Color, Boolean, Json) stay as direct children of Field::Base — no family fits them; the stub form is the correct shape when there's nothing to absorb.

## The inheritance-vs-concern rule

The choice per family was driven by storage shape:

- **Inheritance class when children share storage.** ValidatedString's leaves (Text, Email, Url) all use `string_value`. RangeBounded's leaves use different columns, but the family is identified by "has min/max bounds" — no storage declaration on the parent; each leaf still declares its own value_column.
- **Concern (mixin) when children don't share storage.** Optionable's leaves (Select, MultiSelect) use different columns and one is array-typed. Inheritance can't fix storage for both; a concern adds the shared behavior without claiming a parent slot.

This rule should govern future family extractions in the same codebase. Mixing the two patterns is intentional, not accidental.

## Grooming fixes folded in

Extracting the families surfaced inconsistencies that were latent bugs:

- ValidatedString's `max_gte_min_length` validator (previously only on Text) now covers Email and Url. Email configured with `max_length: 5, min_length: 10` now raises at field-save time instead of saving silently.
- RangeBounded's `validates :max, comparison: { greater_than_or_equal_to: :min }`-style macros now cover Date and DateTime (previously only Integer and Decimal). Inverted date bounds raise at field-save time.

CHANGELOG entry notes the behavior change for users who may have invalid configurations they never noticed.

## Public extension API

ValidatedString, RangeBounded, and Optionable are documented in README §"Custom field types" as recommended extension bases. External authors building (e.g.) a Phone or Slug field type subclass ValidatedString instead of duplicating min/max_length plumbing.

## Considered alternatives

- **(a) Status quo + ADR.** Rejected because three subclasses per family is real duplication, and the inconsistencies (max_gte_min_length only on Text; comparison macro only on Integer/Decimal) prove the duplication was already drifting.
- **(d) Registry-driven declarations for true stubs.** Rejected because it breaks STI for affected types — Field would need two parallel type-identification schemes (class names vs registry keys). Cost outweighs the gain of removing three small files.
- **(a3) All families as concerns** (no intermediate classes). Rejected because it abandons the existing Percentage < Decimal precedent and forces an unnatural "include for these but inherit for those" rule with no clear principle.
- **(b2) Internal-only family bases.** Rejected because external authors face the same duplication; keeping the bases gem-private solves the gem maintainer's problem and leaves external authors with the original friction.

## Consequences

- Test surface shrinks: per-leaf specs cover only leaf-specific behavior. Shared family behavior tested once on the family's spec.
- Future custom-field-type authors get the family's validation surface for free by picking the right parent.
- The "inheritance when children share storage; concern otherwise" rule is now an established pattern. Future families (e.g., if "array-typed" grows beyond MultiSelect + IntegerArray + others) should apply the same test.
- One outlier remains: `validate_array_size` lives on Field::Base because its callers span unrelated families. This is acknowledged technical debt; if a third array-family caller emerges, extract to an ArraySupport concern.
