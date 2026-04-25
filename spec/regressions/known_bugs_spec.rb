# frozen_string_literal: true

require "spec_helper"

# Regression tests for bugs identified in ANALYSIS.md.
#
# Structure:
# - Tests marked `pending` describe DESIRED behavior that doesn't work yet.
#   They will auto-un-pend when the bug is fixed.
# - Tests WITHOUT pending verify the fix is in place (for already-fixed bugs).

RSpec.describe "Regressions from ANALYSIS.md" do
  describe "ANALYSIS 1.1: where_typed_fields single hash destructuring (FIXED)", :unscoped do
    let!(:field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:contact) { create(:contact) }

    before do
      TypedFields::Value.create!(entity: contact, field: field).tap do |v|
        v.value = 30
        v.save!
      end
    end

    it "handles array-wrapped filter" do
      results = Contact.where_typed_fields([{ name: "age", op: :eq, value: 30 }])
      expect(results).to include(contact)
    end

    it "handles single hash filter" do
      results = Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
      expect(results).to include(contact)
    end

    it "handles hash-of-hashes (form params)" do
      results = Contact.where_typed_fields({ "0" => { name: "age", op: :eq, value: 30 } })
      expect(results).to include(contact)
    end
  end

  describe "ANALYSIS 1.2: Boolean should reject garbage strings" do
    let(:field) { build(:boolean_field) }

    it "marks garbage input as invalid" do
      expect(field.cast("banana")).to eq([nil, true])
    end
  end

  describe "ANALYSIS 2.6: DateTime should mark invalid input" do
    it "marks unparseable datetime as invalid" do
      field = build(:datetime_field)
      expect(field.cast("hello")).to eq([nil, true])
    end
  end

  describe "ANALYSIS 2.7: Non-existent field names should raise", :unscoped do
    let!(:field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:contact) { create(:contact) }

    before do
      TypedFields::Value.create!(entity: contact, field: field).tap do |v|
        v.value = 30
        v.save!
      end
    end

    it "raises for unknown field names (FIXED)" do
      expect do
        Contact.where_typed_fields([{ name: "nonexistent_typo", op: :eq, value: "x" }])
      end.to raise_error(ArgumentError)
    end
  end

  describe "ANALYSIS 3.1: Integer should reject decimal input" do
    it "marks decimal input as invalid" do
      field = build(:integer_field)
      expect(field.cast("3.7")).to eq([nil, true])
    end
  end

  describe "ANALYSIS 3.3: Option cache should auto-invalidate" do
    it "reflects new options without manual cache clear (FIXED)" do
      field = create(:select_field)
      field.allowed_option_values # prime cache
      field.field_options.create!(label: "New", value: "new_opt", sort_order: 10)
      expect(field.allowed_option_values).to include("new_opt")
    end
  end

  describe "ANALYSIS 2.4: Registry type restrictions should be enforced" do
    it "prevents creating disallowed field types (FIXED)" do
      field = TypedFields::Field::Json.new(name: "data", entity_type: "Product")
      expect(field).not_to be_valid
    end
  end

  describe "REVIEW: nested typed-value must not attach across scope", :unscoped do
    let(:scoped_field) do
      create(:text_field, name: "tenant_note", entity_type: "Contact", scope: "tenant_a")
    end
    let(:tenant_b_contact) { create(:contact, tenant_id: "tenant_b") }

    it "rejects a value for a field belonging to another scope" do
      value = TypedFields::Value.new(entity: tenant_b_contact, field: scoped_field)
      value.value = "leak"
      expect(value).not_to be_valid
      expect(value.errors[:field]).to be_present
    end

    it "accepts a value for a field whose scope matches the entity" do
      tenant_a_contact = create(:contact, tenant_id: "tenant_a")
      value = TypedFields::Value.new(entity: tenant_a_contact, field: scoped_field)
      value.value = "ok"
      expect(value).to be_valid
    end

    it "accepts values for global (scope=nil) fields regardless of entity scope" do
      global_field = create(:text_field, name: "global_note", entity_type: "Contact", scope: nil)
      value = TypedFields::Value.new(entity: tenant_b_contact, field: global_field)
      value.value = "ok"
      expect(value).to be_valid
    end
  end

  describe "REVIEW: required field rejects blank string/array" do
    let(:contact) { create(:contact) }

    it "rejects blank string for required text field" do
      field = create(:text_field, required: true)
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = "   "
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/blank/))
    end

    it "rejects array of blanks for required text_array field" do
      field = create(:text_array_field, required: true)
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = ["", nil, ""]
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/blank/))
    end
  end

  describe "REVIEW: Json field parses strings" do
    let(:contact) { create(:contact) }
    let(:field) { create(:json_field) }

    it "parses JSON object strings into hashes" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = '{"key":"val"}'
      expect(value).to be_valid
      value.save!
      value.reload
      expect(value.value).to eq({ "key" => "val" })
    end

    it "marks invalid JSON strings as invalid" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = "{not valid"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/invalid/))
    end

    it "passes through already-parsed hashes" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = { "a" => 1 }
      expect(value).to be_valid
    end
  end

  describe "REVIEW: IntegerArray rejects fractional elements" do
    let(:contact) { create(:contact) }
    let(:field) { create(:integer_array_field) }

    it "marks fractional input as invalid rather than truncating" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = ["1.9", "2"]
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/invalid/))
    end

    it "enforces per-element min/max" do
      field = create(:integer_array_field, options: { "min" => 10, "max" => 20 })
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = [15, 25]
      expect(value).not_to be_valid
    end
  end
end
