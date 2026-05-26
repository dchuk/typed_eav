# frozen_string_literal: true

require "spec_helper"

# Family-base spec for Field::ValidatedString. Covers the shared
# string-validation surface ONCE for Text/Email/Url instead of the
# previous per-leaf duplication. Leaf-specific behavior (Email's
# EMAIL_FORMAT, Url's URL_FORMAT) stays in the per-leaf spec sections
# inside field_spec.rb.
RSpec.describe TypedEAV::Field::ValidatedString, type: :model do
  describe "inheritance chain" do
    it "is a Field::Base subclass" do
      expect(described_class.superclass).to eq(TypedEAV::Field::Base)
    end

    it "is the parent of Field::Text" do
      expect(TypedEAV::Field::Text.superclass).to eq(described_class)
    end

    it "is the parent of Field::Email" do
      expect(TypedEAV::Field::Email.superclass).to eq(described_class)
    end

    it "is the parent of Field::Url" do
      expect(TypedEAV::Field::Url.superclass).to eq(described_class)
    end
  end

  describe "STI dispatch (unchanged by intermediate-class insertion)" do
    it "Text rows load as Field::Text" do
      text = TypedEAV::Field::Text.create!(name: "vs_t1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(text.id)).to be_a(TypedEAV::Field::Text)
    end

    it "Email rows load as Field::Email" do
      email = TypedEAV::Field::Email.create!(name: "vs_e1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(email.id)).to be_a(TypedEAV::Field::Email)
    end

    it "Url rows load as Field::Url" do
      url = TypedEAV::Field::Url.create!(name: "vs_u1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(url.id)).to be_a(TypedEAV::Field::Url)
    end
  end

  describe ".value_column on every leaf is :string_value" do
    it "Text" do
      expect(TypedEAV::Field::Text.value_column).to eq(:string_value)
    end

    it "Email" do
      expect(TypedEAV::Field::Email.value_column).to eq(:string_value)
    end

    it "Url" do
      expect(TypedEAV::Field::Url.value_column).to eq(:string_value)
    end
  end

  describe "shared `max_gte_min_length` guard (latent-bug grooming per ADR-0004)" do
    it "Text rejects max_length < min_length at field-save" do
      field = build(:text_field, options: { "min_length" => 10, "max_length" => 5 })
      expect(field).not_to be_valid
      expect(field.errors[:max_length]).to be_present
    end

    it "Email rejects max_length < min_length at field-save (newly enforced)" do
      field = build(:email_typed_eav, options: { "min_length" => 10, "max_length" => 5 })
      expect(field).not_to be_valid
      expect(field.errors[:max_length]).to be_present
    end

    it "Url rejects max_length < min_length at field-save (newly enforced)" do
      field = build(:url_field, options: { "min_length" => 10, "max_length" => 5 })
      expect(field).not_to be_valid
      expect(field.errors[:max_length]).to be_present
    end

    it "accepts max_length == min_length" do
      field = build(:text_field, options: { "min_length" => 5, "max_length" => 5 })
      expect(field).to be_valid
    end

    it "accepts max_length > min_length" do
      field = build(:email_typed_eav, options: { "min_length" => 3, "max_length" => 50 })
      expect(field).to be_valid
    end
  end

  describe "shared `validate_pattern_syntax` guard" do
    it "rejects an invalid regex on Text" do
      field = build(:text_field, options: { "pattern" => "[invalid" })
      expect(field).not_to be_valid
      expect(field.errors[:pattern]).to be_present
    end

    it "rejects an invalid regex on Email" do
      field = build(:email_typed_eav, options: { "pattern" => "[invalid" })
      expect(field).not_to be_valid
      expect(field.errors[:pattern]).to be_present
    end

    it "rejects an invalid regex on Url" do
      field = build(:url_field, options: { "pattern" => "[invalid" })
      expect(field).not_to be_valid
      expect(field.errors[:pattern]).to be_present
    end

    it "accepts a valid regex on Text" do
      field = build(:text_field, options: { "pattern" => '\A[a-z]+\z' })
      expect(field).to be_valid
    end
  end

  describe "numericality of min_length / max_length" do
    it "rejects negative min_length" do
      field = build(:text_field, options: { "min_length" => -1 })
      expect(field).not_to be_valid
      expect(field.errors[:min_length]).to be_present
    end

    it "rejects zero max_length" do
      field = build(:text_field, options: { "max_length" => 0 })
      expect(field).not_to be_valid
      expect(field.errors[:max_length]).to be_present
    end
  end

  describe "shared validate_length helper (via Value validation)" do
    let(:field) { create(:text_field, options: { "min_length" => 3, "max_length" => 8 }) }
    let(:contact) { create(:contact) }

    it "rejects values shorter than min_length" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "ab")
      expect(v).not_to be_valid
      expect(v.errors[:value]).to be_present
    end

    it "rejects values longer than max_length" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "abcdefghi")
      expect(v).not_to be_valid
      expect(v.errors[:value]).to be_present
    end

    it "accepts values within bounds" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "abcd")
      expect(v).to be_valid
    end
  end

  describe "shared validate_pattern helper (via Value validation)" do
    let(:field) { create(:text_field, options: { "pattern" => '\A[a-z]+\z' }) }
    let(:contact) { create(:contact) }

    it "rejects values that don't match the pattern" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "ABC123")
      expect(v).not_to be_valid
    end

    it "accepts values that match the pattern" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "abcdef")
      expect(v).to be_valid
    end
  end
end
