---
phase: 3
status: complete
started: 2026-05-01
completed: 2026-05-01
plans_covered:
  - 03-01
  - 03-02
total_tests: 2
completed_tests: 2
issues_found: 0
---

# Phase 03 UAT — Event System

Phase 03 ships the event-dispatch infrastructure that Phase 04 versioning and Phase 07 materialized index will plug into. The phase is **purely internal** — no UI, no user-facing screens. Per the VBW UAT protocol, internal-refactor phases get a small number of lightweight checkpoints requiring human judgment about whether the as-built API and documentation match expectations.

QA already verified the contract (full suite 547/547, rubocop clean, behavior probed live). UAT here is about **subjective acceptance**: does the public surface read clearly, and is the API shape what you actually want to live with?

## P03-T01 — README §"Event hooks" review

**Scenario:** Open `README.md` and read the new §"Event hooks" section (between §"Validation Behavior" and §"Database Support"). It documents `Config.on_value_change`, `Config.on_field_change`, `with_context`, the error-policy split (internals raise / user proc rescues), the firing-order guarantee, and the reset! split.

**Expected:** The section reads clearly — it explains the public callback shape, when callbacks fire, what arguments they receive, and how to roll back state in tests. A first-time reader could wire up an on_value_change subscriber from this section alone.

| Result | Notes |
|--------|-------|
| Pass   |       |

## P03-T02 — Live API sanity check (optional)

**Scenario:** Drop into `bin/rails console` (in `spec/dummy/`) or run a one-liner like:

```bash
bundle exec ruby -e '
  require "./spec/dummy/config/environment"
  TypedEAV::Config.on_value_change = ->(v, c, ctx) { puts "fired: #{c} value_id=#{v.id} ctx=#{ctx.inspect}" }
  TypedEAV.with_context(request_id: "uat-smoke") do
    section = TypedEAV::Section.create!(name: "uat", scope_id: "uat-scope")
    field = TypedEAV::Field::Text.create!(name: "title", section: section)
    contact = Contact.create!(scope_id: "uat-scope")
    contact.fields[:title] = "hello"
    contact.save!
  end
  TypedEAV::Config.reset!
'
```

(or paste the equivalent into the rails console)

**Expected:** You see `fired: create value_id=… ctx={request_id: "uat-smoke"}` for the value creation. The context Hash is frozen and has the `:request_id` key. If you want to skip this — no test fixture set up, etc. — choose Skip; QA already verified the equivalent live probe and the integration specs cover this contract.

| Result | Notes |
|--------|-------|
| Pass   |       |
