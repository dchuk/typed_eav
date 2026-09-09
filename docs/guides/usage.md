---
title: "Reading, writing, and forms"
---

# Reading, writing, and forms

[Documentation home](../index.md)

## Model setup

```ruby
class Contact < ApplicationRecord
  has_typed_eav
end

# With multi-tenant scoping:
class Contact < ApplicationRecord
  has_typed_eav scope_method: :tenant_id
end

# With restricted field types:
class Contact < ApplicationRecord
  has_typed_eav types: [:text, :integer, :boolean, :select]
end
```

## Field definitions

```ruby
# Simple fields
TypedEAV::Field::Text.create!(
  name: "nickname",
  entity_type: "Contact"
)

TypedEAV::Field::Integer.create!(
  name: "age",
  entity_type: "Contact",
  required: true,
  options: { min: 0, max: 150 }
)

TypedEAV::Field::Date.create!(
  name: "birthday",
  entity_type: "Contact",
  options: { max_date: Date.today.to_s }
)

# Select field with options
status = TypedEAV::Field::Select.create!(
  name: "status",
  entity_type: "Contact",
  required: true
)
status.field_options.create!([
  { label: "Active",   value: "active",   sort_order: 1 },
  { label: "Inactive", value: "inactive", sort_order: 2 },
  { label: "Lead",     value: "lead",     sort_order: 3 },
])

# Multi-select (stored as json array)
tags = TypedEAV::Field::MultiSelect.create!(
  name: "tags",
  entity_type: "Contact"
)
tags.field_options.create!([
  { label: "VIP",      value: "vip" },
  { label: "Partner",  value: "partner" },
  { label: "Prospect", value: "prospect" },
])
```

When deriving `entity_type` from a model class, use
`Contact.polymorphic_name`. Rails stores polymorphic associations under that
canonical name, which is the base-class type for STI hosts and respects the
application's namespaced-polymorphism setting.

## Reading and writing

```ruby
contact = Contact.new(name: "Darrin")

# Individual assignment
contact.set_typed_eav_value("age", 40)
contact.set_typed_eav_value("status", "active")

# Bulk assignment by field NAME (ergonomic for scripting / seeds)
contact.typed_eav_attributes = [
  { name: "age", value: 40 },
  { name: "status", value: "active" },
  { name: "tags", value: ["vip", "partner"] },
]

# Bulk assignment by field ID (standard Rails form contract).
# Your form templates emit this shape when you use fields_for :typed_values.
contact.typed_values_attributes = [
  { id: 12, field_id: 4, value: "40" },
  { field_id: 7, value: "active" },
]

contact.save!

# Reading
contact.typed_eav_value("age")    # => 40 (Ruby Integer)
contact.typed_eav_value("status") # => "active"
contact.typed_eav_hash              # => { "age" => 40, "status" => "active", ... }
```

## Defaults for new and existing records

```ruby
field = TypedEAV::Field::Integer.create!(
  name: "score", entity_type: Contact.polymorphic_name,
  default_value: 10, options: { min: 0 }
)
contact = Contact.new(name: "Ada")
contact.initialize_typed_values
contact.typed_eav_value("score") # => 10
contact.save!

# Apply this field's default to an existing population:
field.backfill_default!(relation: Contact.where(active: true))
```

Set the record's tenant/workspace before initializing values.
`initialize_typed_values` builds one unsaved Value for each effective definition
that has no row yet, using that field's default (possibly `nil`). It returns
the `typed_values` association, leaves existing values alone, and saves nothing
until the host is saved. The form helper uses this initialization behavior.
Creating a field or reading a missing value does not populate existing hosts.

When building a Value directly, omitting `value:` applies the field default;
passing `value: nil` explicitly stores NULL instead:

```ruby
contact.typed_values.build(field: field)             # default of 10
contact.typed_values.build(field: field, value: nil) # explicit NULL
# These illustrate alternatives; do not create both for the same host/field.
```

Defaults are cast and validated when the field is saved. Backfill is synchronous
and idempotent: it creates missing rows or replaces fully NULL typed values,
while preserving existing non-NULL values, including `false` and zero. Multi-cell
fields count as present if any declared typed cell is non-NULL. A `nil` default
performs no writes.

Without `relation:`, backfill scans the field's host class. A supplied relation
must belong to that exact host class (an Array or a subclass relation raises
`ArgumentError`); it narrows the population before batches of 1,000. Partition
checks still apply. Each batch uses a transaction and normal Value validations,
callbacks, and enabled versioning. Failures propagate and roll back the current
batch; previous batches remain committed unless enclosed in a caller transaction.
The method has no documented count/result report. For background processing,
call it from an application-owned job. See [bulk operations](bulk-operations.md)
for related write guarantees.

## Forms

Wire typed fields into Rails forms via nested attributes:

```erb
<%= form_with model: @contact do |f| %>
  <%= f.text_field :name %>

  <%= render_typed_value_inputs(form: f, record: @contact) %>

  <%= f.submit %>
<% end %>
```

The helper emits one input per available field, including the hidden `id` / `field_id` markers required by `accepts_nested_attributes_for`. Permit the nested shape in your controller — the `value: []` form is required for array/multi-select types:

```ruby
def contact_params
  params.require(:contact).permit(
    :name,
    typed_values_attributes: [
      :id, :field_id, :_destroy, :value, { value: [] }
    ]
  )
end
```

For list pages, preload the field association to avoid N+1:

```ruby
@contacts = Contact.includes(typed_values: :field).all
```

## Admin Scaffold

To manage field definitions through a UI, run the scaffold generator:

```bash
bin/rails g typed_eav:scaffold
bin/rails db:migrate
```

This copies a controller, views, helper, Stimulus controllers, and an initializer into your app, and adds routes mounted at `/typed_eav_fields`.

**Security**: the generated controller ships with `authorize_typed_eav_admin!` returning `head :not_found` by default — fail-closed. Edit the method directly in `app/controllers/typed_eav_controller.rb` to wire it to your auth system:

```ruby
def authorize_typed_eav_admin!
  return if current_user&.admin?
  head :not_found
end
```

Defining `authorize_typed_eav_admin!` in `ApplicationController` does **not** override it — the scaffold sets it on its own controller.

## In-memory typed-value changes

```ruby
contact.set_typed_eav_value("age", 41)
contact.typed_eav_changes # => {"age" => [40, 41]}
contact.save!
contact.typed_eav_changes # => {}
```

`typed_eav_changes` reports logical `[before, after]` pairs for pending changes
on this host's in-memory `typed_values` target. It covers named setters,
`typed_eav_attributes=`, nested `typed_values_attributes=`, association builds,
edits to target Values, and `mark_for_destruction`/nested `_destroy`. Multi-cell
fields such as Currency retain their logical shape; returned hashes, pairs,
and mutable values are copies. Same-value assignments, reversions, and logical
`nil`-to-`nil` changes are omitted, including creating/removing a NULL value row.
Invalid input reports the cast logical result without discarding validation errors.

Failed saves retain pending state; successful saves and reload clear it. An
outer rollback follows Active Record's restored child dirty state. The API
resolves effective field names using this record's partition precedence, and
does not load all persisted Values merely to inspect an untouched host.

After saving, `saved_typed_eav_changes` exposes the most recent successful
host save's logical pairs:

```ruby
contact.set_typed_eav_value("age", 42)
contact.save!
contact.saved_typed_eav_changes # => {"age" => [41, 42]}
contact.typed_eav_changes       # => {}
```

Saved changes are available in normal host `after_save` callbacks, including
values assigned by `before_save`. Each successful save replaces the snapshot;
a no-op save replaces it with `{}`. Failed validation or a save-callback
exception preserves the previous successful snapshot. Reload and an outer
transaction rollback clear saved changes. These are successful-save semantics,
not proof of a durable commit: use `after_commit` when external effects must
wait for commit. Exceptions after a transaction has already committed cannot
undo persisted data. Neither dirty API requires versioning or adds audit rows.

This is in-memory editing state, not audit history. Independently loaded/saved
Values, reassignment of an existing Value's field identity, SQL/`delete_all`,
and collection operations that immediately remove rows from the host target
are not tracked. Use nested destruction or `mark_for_destruction` for tracked
removal. Reduced `BulkUpsert` does not update unrelated in-memory host objects;
reload them after external writes. Bulk reads do not create dirty state.
