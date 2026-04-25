# frozen_string_literal: true

require "spec_helper"

# Round-3 review: two correctness bugs around field-name collisions across
# scope partitions and the global/scoped overlap.
#
# Bug 1 — `TypedFields.unscoped { Contact.where_typed_fields(...) }` collapsed
#   per-tenant field rows that share a name to a single definition via
#   `index_by(&:name)`. Result: a query that should match across N tenants
#   silently dropped N-1 of them. Fix: under ALL_SCOPES, OR-across all
#   matching field_ids per filter while preserving AND between filters.
#
# Bug 2 — On a scoped record where both a global (scope=NULL) and a same-name
#   scoped field exist, `initialize_typed_values` iterated raw definitions
#   (two rows) and built TWO value rows, while every other read/write path
#   collapsed via `definitions_by_name` (scoped wins). Forms rendered duplicate
#   inputs but only one round-tripped on save. Fix: route through the
#   collapsed view so exactly one value row is built, and harden read paths
#   to prefer the row tied to the winning field_id.
RSpec.describe "Round-3 review: field-name collisions across scopes", :scoping do
  before do
    TypedFields.config.scope_resolver = nil
    TypedFields.config.require_scope = true
  end

  after do
    TypedFields.config.reset!
  end

  describe "Bug 1: TypedFields.unscoped + where_typed_fields across tenants" do
    # Three tenants, each with their own per-tenant `status` field of type
    # text. Each tenant has one contact with status="active".
    let!(:status_a) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_a") }
    let!(:status_b) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_b") }
    let!(:status_c) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_c") }

    let!(:contact_a) do
      create(:contact, tenant_id: "tenant_a").tap do |c|
        TypedFields::Value.create!(entity: c, field: status_a, value: "active")
      end
    end
    let!(:contact_b) do
      create(:contact, tenant_id: "tenant_b").tap do |c|
        TypedFields::Value.create!(entity: c, field: status_b, value: "active")
      end
    end
    let!(:contact_c) do
      create(:contact, tenant_id: "tenant_c").tap do |c|
        TypedFields::Value.create!(entity: c, field: status_c, value: "active")
      end
    end

    # Negative-control: another tenant_a contact whose status is NOT "active";
    # must NOT be returned by the eq filter.
    let!(:contact_a_inactive) do
      create(:contact, tenant_id: "tenant_a").tap do |c|
        TypedFields::Value.create!(entity: c, field: status_a, value: "inactive")
      end
    end

    it "returns matches across ALL tenants under TypedFields.unscoped { }" do
      results = TypedFields.unscoped do
        Contact.where_typed_fields({ name: "status", op: :eq, value: "active" })
      end

      expect(results).to include(contact_a, contact_b, contact_c)
      expect(results).not_to include(contact_a_inactive)
    end

    it "ANDs across multiple filters under unscoped (per-filter OR over name, AND across filters)" do
      # Add an `age` integer field per tenant + values.
      age_a = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_a")
      age_b = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_b")
      age_c = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_c")

      TypedFields::Value.create!(entity: contact_a, field: age_a, value: 30) # match
      TypedFields::Value.create!(entity: contact_b, field: age_b, value: 18) # status match, age fails
      TypedFields::Value.create!(entity: contact_c, field: age_c, value: 40) # match
      TypedFields::Value.create!(entity: contact_a_inactive, field: age_a, value: 50) # age match, status fails

      results = TypedFields.unscoped do
        Contact.where_typed_fields(
          { name: "age", op: :gt, value: 21 },
          { name: "status", op: :eq, value: "active" },
        )
      end

      expect(results).to include(contact_a, contact_c)
      expect(results).not_to include(contact_b)            # age fails
      expect(results).not_to include(contact_a_inactive)   # status fails
    end

    it "still raises ArgumentError for unknown field names under unscoped" do
      expect do
        TypedFields.unscoped do
          Contact.where_typed_fields({ name: "nonexistent_typo", op: :eq, value: "x" })
        end
      end.to raise_error(ArgumentError, /Unknown typed field 'nonexistent_typo'/)
    end
  end

  describe "Bug 2: global+scoped name collision on a scoped record" do
    let!(:status_global) do
      create(:text_field, name: "status", entity_type: "Contact", scope: nil)
    end
    let!(:status_scoped) do
      create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_a")
    end
    let(:contact) { create(:contact, tenant_id: "tenant_a") }

    it "initialize_typed_values builds exactly ONE value row (scoped wins)" do
      TypedFields.with_scope("tenant_a") do
        contact.initialize_typed_values
      end

      status_rows = contact.typed_values.select { |tv| tv.field.name == "status" }
      expect(status_rows.size).to eq(1)
      expect(status_rows.first.field_id).to eq(status_scoped.id)
    end

    it "typed_field_value('status') returns the scoped value when both definitions exist" do
      # Even if a stray value row attached to the global field somehow exists
      # on this record, the scoped winner's value must be the one returned.
      #
      # Create the stray global row FIRST (smaller id, appears first under the
      # default id-asc ordering) so this test has discriminative power: a buggy
      # `candidates.first` implementation would return "global-stray", while the
      # winner-preference branch returns "scoped-wins".
      stray = TypedFields::Value.new
      stray.entity = contact
      stray.field = status_global
      stray.value = "global-stray"
      stray.save(validate: false)
      TypedFields::Value.create!(entity: contact, field: status_scoped, value: "scoped-wins")

      contact.reload
      expect(contact.typed_field_value("status")).to eq("scoped-wins")
    end

    it "typed_fields_hash prefers the scoped row when both exist on the same record" do
      TypedFields::Value.create!(entity: contact, field: status_scoped, value: "scoped-wins")
      stray = TypedFields::Value.new
      stray.entity = contact
      stray.field = status_global
      stray.value = "global-stray"
      stray.save(validate: false)

      contact.reload
      expect(contact.typed_fields_hash["status"]).to eq("scoped-wins")
    end

    it "read paths skip orphaned value rows (field deleted out from under value)" do
      # Build a fresh field + value, then delete the field row directly to
      # simulate an FK cascade that didn't fire (or a raw-SQL delete).
      # `delete_all` bypasses `dependent: :destroy` on the field, leaving the
      # value row dangling with `field_id` pointing at a now-missing row.
      orphan_field = create(:text_field, name: "orphaned_name", entity_type: "Contact", scope: "tenant_a")
      TypedFields::Value.create!(entity: contact, field: orphan_field, value: "stale")
      TypedFields::Field::Base.where(id: orphan_field.id).delete_all

      contact.reload

      TypedFields.with_scope("tenant_a") do
        expect { contact.typed_field_value("orphaned_name") }.not_to raise_error
        expect(contact.typed_field_value("orphaned_name")).to be_nil
        expect { contact.typed_fields_hash }.not_to raise_error
        expect(contact.typed_fields_hash).not_to have_key("orphaned_name")
      end
    end
  end
end
