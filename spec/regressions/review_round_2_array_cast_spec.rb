# frozen_string_literal: true

require "spec_helper"

# When any element in an array field fails to parse, the cast must mark the
# whole value invalid and store nil — not silently drop bad elements. A
# "partial cast" would make failed form re-renders confusing: the user sees
# only the good elements, not the ones that actually failed, and has no hook
# to correct them.
RSpec.describe "Array field cast preserves invalid state" do
  let(:contact) { create(:contact) }

  describe TypedFields::Field::IntegerArray do
    let(:field) { create(:integer_array_field) }

    it "returns [nil, true] when any element is fractional" do
      expect(field.cast(["1", "2.5", "3"])).to eq([nil, true])
    end

    it "returns [nil, true] when any element is non-numeric" do
      expect(field.cast(%w[1 abc 3])).to eq([nil, true])
    end

    it "casts cleanly when every element is a valid integer" do
      expect(field.cast(%w[1 2 3])).to eq([[1, 2, 3], false])
    end

    it "preserves nil input" do
      expect(field.cast(nil)).to eq([nil, false])
    end

    it "surfaces :invalid on the value record, not silent truncation" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = ["1", "2.9", "3"]
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/invalid/))
      # The stored column should be nil — not [1, 3] — so a form re-render
      # shows the original submission instead of a silently pruned subset.
      expect(value.json_value).to be_nil
    end
  end

  describe TypedFields::Field::DecimalArray do
    let(:field) { create(:decimal_array_field) }

    it "returns [nil, true] when any element is unparseable" do
      expect(field.cast(["1.5", "banana", "2.0"])).to eq([nil, true])
    end

    it "casts cleanly when every element is a valid decimal" do
      result, invalid = field.cast(["1.5", "2.0"])
      expect(invalid).to be(false)
      expect(result).to eq([BigDecimal("1.5"), BigDecimal("2.0")])
    end
  end

  describe TypedFields::Field::DateArray do
    let(:field) { create(:date_array_field) }

    it "returns [nil, true] when any element is not a valid date" do
      expect(field.cast(["2025-01-01", "not-a-date"])).to eq([nil, true])
    end

    it "casts cleanly when every element is a valid date" do
      result, invalid = field.cast(%w[2025-01-01 2025-06-15])
      expect(invalid).to be(false)
      expect(result).to eq([Date.new(2025, 1, 1), Date.new(2025, 6, 15)])
    end
  end
end
