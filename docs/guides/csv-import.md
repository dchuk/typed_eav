---
title: "Mapping and importing CSV rows"
---

# Mapping and importing CSV rows

[Documentation home](../index.md)

`TypedEAV::CSVMapper` transforms one CSV row into field-name attributes. It does
not read files, create records, resolve tenants, or save values. Your application
owns those steps and can use the normal bulk writer for persistence.

## Map headers and validate casts

```ruby
require "csv"

mapping = { "Nickname" => :nickname, "Age" => :age }
fields = TypedEAV::Partition.effective_fields_by_name(
  entity_type: Contact.polymorphic_name, scope: "t1", parent_scope: nil
)
unknown = mapping.values.map(&:to_s) - fields.keys
raise ArgumentError, "Unknown mapped fields: #{unknown.join(', ')}" if unknown.any?

row = CSV::Row.new(["Nickname", "Age"], ["Ada", "37"])
result = TypedEAV::CSVMapper.row_to_attributes(row, mapping, fields_by_name: fields)
result.attributes # => {"nickname" => "Ada", "age" => 37}
result.errors     # => {}
result.success?   # => true

# Once your application has selected an authorized destination record:
if result.success?
  saved = Contact.bulk_set_typed_eav_values_per_record({ contact => result.attributes })
  saved[:errors_by_record] # Check full model/value validation failures here too.
end
```

Resolve definitions for the destination record's partition. If a file spans
partitions, resolve the appropriate map for each destination. Use the effective
map so inherited same-name fields follow normal precedence.

Typed mode calls each field's `cast`; it does not run the complete persistence
validation pipeline. For example, an integer may cast successfully but violate
its field's minimum or the host's validations when saved. A successful mapping
therefore does not guarantee a successful save.

## Headerless files and raw previews

```ruby
TypedEAV::CSVMapper.row_to_attributes(
  ["Ada", "37"], { 0 => :nickname, 1 => :age }, fields_by_name: fields
).attributes
# => {"nickname" => "Ada", "age" => 37}

# Omit fields_by_name for a raw mapping preview without casts:
TypedEAV::CSVMapper.row_to_attributes(row, mapping).attributes
# => {"nickname" => "Ada", "age" => "37"}
```

Mapping keys must be all String header names (for `CSV::Row`) or all Integer
column indexes (for Arrays). Mixed or unsupported key types raise `ArgumentError`
before processing. An empty mapping is valid. Field-name values may be Strings
or Symbols; result keys are Strings. Match the key style to the row shape.

## Errors and empty cells

```ruby
bad_row = CSV::Row.new(["Nickname", "Age"], ["Ada", "not-a-number"])
result = TypedEAV::CSVMapper.row_to_attributes(bad_row, mapping, fields_by_name: fields)
result.attributes # => {"nickname" => "Ada"}
result.errors     # => {"age" => ["is invalid"]}
result.failure?   # => true
```

Cast failures are collected per field and the invalid cell is omitted from
`attributes`. Do not persist the partial attributes unless your import policy
explicitly allows partial rows. Empty cells (`nil` or an empty String) cast to
`nil` without a cast error; required-field checks still happen when saving.
Missing headers/indexes that return `nil` follow that same path, so validate the
file's expected columns before importing if omission must be an error.

In typed mode, unknown field names are silently skipped without an error; the
upfront mapping check above prevents accidental omissions. In raw mode, every
mapped cell passes through unchanged. `attributes` and `errors` are frozen
Hashes; `success?` means only that `errors` is empty. Row numbering, logging,
file parsing errors, transactions, and retry policy remain application concerns.
See [bulk operations](bulk-operations.md#writing-a-batch-and-handling-results)
for save results and transaction options.
