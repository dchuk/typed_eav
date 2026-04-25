# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedFields::Section, type: :model do
  describe "validations" do
    it "requires name, code, and entity_type" do
      section = described_class.new
      expect(section).not_to be_valid
      expect(section.errors[:name]).to be_present
      expect(section.errors[:code]).to be_present
      expect(section.errors[:entity_type]).to be_present
    end

    it "enforces code uniqueness per entity_type and scope" do
      create(:typed_section, code: "general", entity_type: "Contact", scope: nil)

      duplicate = build(:typed_section, code: "general", entity_type: "Contact", scope: nil)
      expect(duplicate).not_to be_valid

      different_entity = build(:typed_section, code: "general", entity_type: "Product")
      expect(different_entity).to be_valid
    end
  end

  describe "associations" do
    it "has many fields" do
      section = create(:typed_section)
      field = create(:text_field, entity_type: section.entity_type, section: section)

      expect(section.fields).to include(field)
    end

    it "nullifies field section_id on destroy" do
      section = create(:typed_section)
      field = create(:text_field, entity_type: section.entity_type, section: section)

      section.destroy!
      expect(field.reload.section_id).to be_nil
    end
  end

  describe "scopes" do
    it ".active returns only active sections" do
      active = create(:typed_section, active: true)
      inactive = create(:typed_section, active: false)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(inactive)
    end

    it ".for_entity filters by entity_type" do
      contact_section = create(:typed_section, entity_type: "Contact")
      product_section = create(:typed_section, entity_type: "Product")

      expect(described_class.for_entity("Contact")).to include(contact_section)
      expect(described_class.for_entity("Contact")).not_to include(product_section)
    end
  end

  describe ".sorted scope" do
    it "orders by sort_order then name" do
      z = create(:typed_section, name: "Zebra", sort_order: 2)
      a = create(:typed_section, name: "Alpha", sort_order: 1)
      b = create(:typed_section, name: "Beta", sort_order: 1)
      sorted = described_class.sorted
      expect(sorted.first).to eq(a)
      expect(sorted.second).to eq(b)
      expect(sorted.third).to eq(z)
    end
  end

  describe "default active value" do
    it "defaults to true" do
      expect(described_class.new.active).to be true
    end
  end
end

RSpec.describe TypedFields::Option, type: :model do
  describe "validations" do
    it "requires label and value" do
      option = described_class.new
      expect(option).not_to be_valid
      expect(option.errors[:label]).to be_present
      expect(option.errors[:value]).to be_present
    end

    it "enforces value uniqueness per field" do
      field = create(:select_field)
      # factory already creates options, so check against those
      duplicate = field.field_options.build(label: "Dup", value: "active")
      expect(duplicate).not_to be_valid
    end
  end

  describe "scopes" do
    it ".sorted orders by sort_order then label" do
      field = create(:select_field)
      options = field.field_options.sorted
      expect(options.first.sort_order).to be <= options.last.sort_order
    end
  end

  describe "associations" do
    it "belongs_to field" do
      option = create(:typed_option)
      expect(option.field).to be_a(TypedFields::Field::Base)
    end
  end
end
