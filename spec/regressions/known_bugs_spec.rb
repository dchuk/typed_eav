# frozen_string_literal: true

require "spec_helper"

# Regression tests for bugs identified in ANALYSIS.md.
#
# Structure:
# - Tests marked `pending` describe DESIRED behavior that doesn't work yet.
#   They will auto-un-pend when the bug is fixed.
# - Tests WITHOUT pending verify the fix is in place (for already-fixed bugs).

RSpec.describe "Regressions from ANALYSIS.md" do
  describe "ANALYSIS 1.1: where_typed_fields single hash destructuring (FIXED)" do
    let!(:field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:contact) { create(:contact) }

    before do
      TypedFields::Value.create!(entity: contact, field: field).tap { |v| v.value = 30; v.save! }
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

    it "should mark garbage input as invalid" do
      expect(field.cast("banana")).to eq([nil, true])
    end
  end

  describe "ANALYSIS 2.6: DateTime should mark invalid input" do
    it "should mark unparseable datetime as invalid" do
      field = build(:datetime_field)
      expect(field.cast("hello")).to eq([nil, true])
    end
  end

  describe "ANALYSIS 2.7: Non-existent field names should raise" do
    let!(:field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:contact) { create(:contact) }

    before do
      TypedFields::Value.create!(entity: contact, field: field).tap { |v| v.value = 30; v.save! }
    end

    it "raises for unknown field names (FIXED)" do
      expect {
        Contact.where_typed_fields([{ name: "nonexistent_typo", op: :eq, value: "x" }])
      }.to raise_error(ArgumentError)
    end
  end

  describe "ANALYSIS 3.1: Integer should reject decimal input" do
    it "should mark decimal input as invalid" do
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
end
