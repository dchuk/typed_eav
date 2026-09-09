---
title: "Getting started"
nav_group: Start here
---

# Getting started

## Compatibility

The canonical support contract lives in
[`.github/compatibility.json`](https://github.com/dchuk/typed_eav/blob/main/.github/compatibility.json). Typed EAV supports:

| Runtime | Supported versions |
|---|---|
| Ruby | 3.3 through 4.0 (`>= 3.3`, `< 4.1`) |
| Rails | 7.2 through 8.1 (`>= 7.2`, `< 8.2`) |
| PostgreSQL | 15 through 18 |

CI proves representative floor, middle, and ceiling combinations rather than
every Cartesian product. Versions outside these ranges and prerelease versions
are outside the support guarantee. PostgreSQL compatibility claims assume the
current minor release for each supported major version.

## Installation

Add to your Gemfile:

```ruby
gem "typed_eav"
```

Run the install migration:

```bash
bin/rails typed_eav:install:migrations
bin/rails db:migrate
```

PostgreSQL is required; MySQL and SQLite are not supported. For existing
installations, see [Upgrading](guides/upgrading.md) and the
[Changelog](https://github.com/dchuk/typed_eav/blob/main/CHANGELOG.md).

## Quick Start

Assuming your application already has a `Contact` model and table:

```ruby
class Contact < ApplicationRecord
  has_typed_eav
end

TypedEAV::Field::Integer.create!(
  name: "age",
  entity_type: Contact.polymorphic_name,
  options: { min: 0, max: 150 }
)

contact = Contact.new
contact.set_typed_eav_value("age", "40")
contact.save! # Supply any other attributes your Contact model requires.

contact.typed_eav_value("age") # => 40 (Integer)
contact.typed_eav_hash         # => { "age" => 40 }

Contact.with_field("age", :gteq, 21)
       .order_typed_eav("age", direction: :desc)
       .limit(25)
```

Fields cast and validate both assigned values and query operands. Queries
return Active Record relations, so you can combine them with ordinary host
filters. Use `Contact.polymorphic_name` when creating definitions to respect
Rails' STI and namespaced-polymorphism settings.

See [Reading, writing, and forms](guides/usage.md) for bulk assignment,
nested attributes, form helpers, and the admin scaffold, or
[Querying typed fields](guides/queries.md) for operators, multi-field
filters, sorting, distinct values, counts, and numeric aggregates.

