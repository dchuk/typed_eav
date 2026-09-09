---
title: "Development and test isolation"
nav_group: Project
---

# Development and test isolation

[Documentation home](../index.md)

These examples use metadata and hooks defined in this gem’s `spec/spec_helper.rb`. Host applications need equivalent test setup.

## Event-hook tests

Test files that exercise event hooks should opt in to the `:event_callbacks`
metadata:

```ruby
RSpec.describe "my feature", :event_callbacks do
  it "fires the hook" do
    captured = []
    TypedEAV::Config.on_value_change = ->(v, t, _ctx) { captured << [v.id, t] }
    contact.update!(typed_eav: { phone: "555-1234" })
    expect(captured).to include([be_a(Integer), :update])
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshots and
restores Config user procs and the internal-subscriber lists around each
example, so test mutations don't leak across examples and engine-load
registrations from later phases stay intact.

Integration specs that create real AR records and need `after_commit` to
fire durably should additionally opt in to `:real_commits`:

```ruby
RSpec.describe "my model", :event_callbacks, :real_commits do
  # ...
end
```

`:real_commits` disables transactional fixtures for the example and
manually deletes typed_eav rows in FK order after.

## Versioning tests

Specs that exercise versioning should opt into the `:event_callbacks`
and `:real_commits` metadata flags (see [Event hooks](events-and-versioning.md#event-hooks) — same pattern):

```ruby
RSpec.describe "my versioning behavior", :event_callbacks, :real_commits do
  before do
    TypedEAV.registry.register("Contact", versioned: true)
    TypedEAV::Config.versioning = true
    # Transactional Value callbacks are boot-latched and remain installed;
    # the hook isolates only public and generic EventDispatcher observers.
  end
  after { TypedEAV.registry.register("Contact", versioned: false) }

  it "writes a version row" do
    # ...
  end
end
```

The `:event_callbacks` around hook in `spec/spec_helper.rb` snapshots and
restores `Config.versioning`, `Config.actor_resolver`, and generic
EventDispatcher observer lists around each example. Transactional Value
callback installation is tested independently through callback-chain and
boot-latch specs. The
`:real_commits` hook disables transactional fixtures (so `after_commit`
fires durably) and cleans up `TypedEAV::ValueVersion` rows in
FK-respecting order between examples.
