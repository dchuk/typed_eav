# frozen_string_literal: true

require "spec_helper"

# Phase 0A: smallest behavioral probes for the seven correctness classes in
# the improvement program. Pending examples are expected failures: they keep
# the baseline green while making an accidental production fix fail loudly.
RSpec.describe "Improvement program Phase 0 correctness probes", type: :model do
  describe "pending value presence" do
    let(:contact) { create(:contact) }
    let(:field) { create(:boolean_field, name: "phase0_active") }

    it "persists and reads back false when field precedes value in the constructor" do
      value = TypedEAV::Value.new(field: field, value: false, entity: contact)

      expect(value).to be_valid
      value.save!
      expect(value.reload.value).to be(false)
    end

    it "preserves false when value precedes field in the constructor" do
      value = TypedEAV::Value.new(value: false, field: field, entity: contact)

      value.save!
      expect(value.value).to be(false)
    end
  end

  describe "default versus explicit nil during late field resolution" do
    let(:contact) { create(:contact) }
    let(:field) { create(:integer_field, name: "phase0_default", default_value_meta: { "v" => 42 }) }

    it "applies the default for an omitted value after persistence and read-back" do
      value = TypedEAV::Value.new(field: field, entity: contact)
      value.save!

      expect(value.reload.value).to eq(42)
    end

    it "persists explicit nil and suppresses the default during late field resolution" do
      value = TypedEAV::Value.new(entity: contact)
      value.value = nil
      value.field = field
      value.save!

      expect(value.reload.value).to be_nil
    end
  end

  describe "invalid cast state" do
    it "remains invalid across repeated validation calls" do
      value = TypedEAV::Value.new(entity: create(:contact), field: create(:integer_field))
      value.value = 3.7

      expect(value).not_to be_valid
      expect(value).not_to be_valid
    end

    it "rejects save after an invalid cast" do
      value = TypedEAV::Value.new(entity: create(:contact), field: create(:integer_field))
      value.value = 3.7

      expect(value).not_to be_valid
      expect { value.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "accepts a corrected value after an invalid cast" do
      value = TypedEAV::Value.new(entity: create(:contact), field: create(:integer_field))
      value.value = 3.7
      value.value = 4

      expect(value).to be_valid
      expect { value.save! }.not_to raise_error
      expect(value.reload.value).to eq(4)
    end
  end

  describe "exact-partition field ordering" do
    it "does not reorder a global sibling while moving a scoped field" do
      global = create(:text_field, name: "phase0_global", sort_order: 1, scope: nil)
      scoped = create(:text_field, name: "phase0_scoped", sort_order: 2, scope: "tenant_a")

      scoped.move_higher

      expect(scoped.reload.sort_order).to eq(1)
      expect(global.reload.sort_order).to eq(1)
    end
  end

  describe "transient version-group state", :event_callbacks, :real_commits do
    before do
      TypedEAV.config.versioning = true
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::Versioning.register_if_enabled
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    it "does not reuse a bulk correlation group on a later mutation of the same Value" do
      contact = create(:contact, tenant_id: "phase0_tenant")
      field = create(:integer_field, name: "phase0_grouped", scope: "phase0_tenant")

      TypedEAV.with_scope("phase0_tenant") do
        Contact.bulk_set_typed_eav_values([contact], { "phase0_grouped" => 1 })
      end
      # BulkWrite stamps the in-memory Value object while iterating the
      # loaded association. Keep that exact object for the reuse probe.
      value = contact.typed_values.to_a.find { |candidate| candidate.field_id == field.id }
      first_group = value.versions.order(:id).last.version_group_id

      value.value = 2
      value.save!
      second_group = value.versions.order(:id).last.version_group_id

      expect(first_group).to be_present
      expect(second_group).not_to eq(first_group)
    end
  end

  describe "field-owned query casting" do
    it "rejects a fractional integer operand instead of silently narrowing it" do
      field = create(:integer_field, name: "phase0_integer")

      expect { TypedEAV::QueryBuilder.filter(field, :eq, 3.7) }
        .to raise_error(ArgumentError, /invalid|integer|cast/i)
    end
  end

  describe "strict between shape" do
    it "rejects arrays that do not contain exactly two bounds" do
      field = create(:integer_field, name: "phase0_between")

      expect { TypedEAV::QueryBuilder.filter(field, :between, [1, 2, 3]) }
        .to raise_error(ArgumentError, /between/i)
    end
  end

  describe "default-value domain validation" do
    it "applies the field domain validator to defaults" do
      field = build(:percentage_field, name: "phase0_percentage", default_value_meta: { "v" => 1.5 })

      expect(field).not_to be_valid
      expect(field.errors[:default_value]).to be_present
    end
  end
end
