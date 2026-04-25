# frozen_string_literal: true

require "spec_helper"

# Regression coverage for Codex review round 2.
#
# Bug A — required TextArray accepted whitespace-only elements because
#         `blank_typed_value?` and `TextArray#cast` both treated " " as
#         meaningful content.
# Bug B — MultiSelect rejected empty form submissions because Rails' hidden
#         "" sentinel for `select multiple: true` fell through cast and got
#         rejected by the option-inclusion validator.
RSpec.describe "Review round 2: blank handling in array-valued fields" do
  let(:contact) { create(:contact) }

  describe "required TextArray" do
    let(:field) { create(:text_array_field, required: true) }

    it "rejects a single whitespace-only element" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = [" "]
      expect(value).not_to be_valid
      expect(value.errors.details[:value]).to include(a_hash_including(error: :blank))
    end

    it "rejects a mix of empty, nil, and whitespace-only elements" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = ["", nil, "   "]
      expect(value).not_to be_valid
      expect(value.errors.details[:value]).to include(a_hash_including(error: :blank))
    end

    it "accepts an element with real content and preserves inner whitespace" do
      value = TypedFields::Value.new(entity: contact, field: field)
      value.value = [" actual "]
      expect(value).to be_valid
      # Only purely blank elements are dropped; leading/trailing spaces inside
      # real content are intentionally preserved (callers may rely on them).
      expect(value.value).to eq([" actual "])
    end
  end

  describe "MultiSelect with Rails' hidden \"\" sentinel" do
    context "when the field is optional" do
      let(:field) { create(:multi_select_field) }

      it "treats [\"\"] as an empty submission and stores nil" do
        value = TypedFields::Value.new(entity: contact, field: field)
        value.value = [""]
        expect(value).to be_valid
        expect(value.value).to be_nil
      end

      it "filters the sentinel out when combined with a real selection" do
        value = TypedFields::Value.new(entity: contact, field: field)
        value.value = ["", "vip"]
        expect(value).to be_valid
        expect(value.value).to eq(["vip"])
      end
    end

    context "when the field is required" do
      let(:field) { create(:multi_select_field, required: true) }

      it "rejects [\"\"] as blank rather than as an invalid option" do
        value = TypedFields::Value.new(entity: contact, field: field)
        value.value = [""]
        expect(value).not_to be_valid
        expect(value.errors.details[:value]).to include(a_hash_including(error: :blank))
      end
    end
  end
end
