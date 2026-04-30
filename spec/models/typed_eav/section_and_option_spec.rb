# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Section, type: :model do
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

  # Phase 02: partition-aware ordering helpers, mirrors Field::Base. The
  # implementation is byte-equivalent to Field's (per Phase 01 inline-
  # duplication precedent), so this block confirms symmetry — the
  # authoritative algorithm spec lives in field_spec.rb.
  describe "ordering helpers" do
    def make_section_partition(entity_type:, scope: nil, parent_scope: nil, count: 3, prefix: "ord")
      Array.new(count) do |i|
        create(
          :typed_section,
          name: "#{prefix.capitalize} #{i + 1}",
          code: "#{prefix}_#{i + 1}",
          entity_type: entity_type,
          scope: scope,
          parent_scope: parent_scope,
          sort_order: i + 1,
        )
      end
    end

    def section_partition_orders(entity_type:, scope: nil, parent_scope: nil)
      TypedEAV::Section
        .for_entity(entity_type, scope: scope, parent_scope: parent_scope)
        .order(:sort_order, :name)
        .pluck(:code, :sort_order)
    end

    it "#move_higher swaps with the section above" do
      _s1, s2, _s3 = make_section_partition(entity_type: "SecHigher")

      s2.move_higher

      expect(section_partition_orders(entity_type: "SecHigher")).to eq(
        [["ord_2", 1], ["ord_1", 2], ["ord_3", 3]],
      )
    end

    it "#move_higher is a no-op at the top boundary" do
      s1, _s2, _s3 = make_section_partition(entity_type: "SecHigherBoundary")
      original = section_partition_orders(entity_type: "SecHigherBoundary")

      s1.move_higher

      expect(section_partition_orders(entity_type: "SecHigherBoundary")).to eq(original)
    end

    it "#move_lower swaps with the section below" do
      _s1, s2, _s3 = make_section_partition(entity_type: "SecLower")

      s2.move_lower

      expect(section_partition_orders(entity_type: "SecLower")).to eq(
        [["ord_1", 1], ["ord_3", 2], ["ord_2", 3]],
      )
    end

    it "#move_lower is a no-op at the bottom boundary" do
      _s1, _s2, s3 = make_section_partition(entity_type: "SecLowerBoundary")
      original = section_partition_orders(entity_type: "SecLowerBoundary")

      s3.move_lower

      expect(section_partition_orders(entity_type: "SecLowerBoundary")).to eq(original)
    end

    it "#move_to_top relocates a bottom item to position 1" do
      _s1, _s2, s3 = make_section_partition(entity_type: "SecTop")

      s3.move_to_top

      expect(section_partition_orders(entity_type: "SecTop")).to eq(
        [["ord_3", 1], ["ord_1", 2], ["ord_2", 3]],
      )
    end

    it "#move_to_bottom relocates a top item to the last position" do
      s1, _s2, _s3 = make_section_partition(entity_type: "SecBottom")

      s1.move_to_bottom

      expect(section_partition_orders(entity_type: "SecBottom")).to eq(
        [["ord_2", 1], ["ord_3", 2], ["ord_1", 3]],
      )
    end

    it "#insert_at clamps n to [1, partition_count]" do
      _s1, _s2, s3 = make_section_partition(entity_type: "SecInsertClampLow")

      s3.insert_at(0)

      expect(section_partition_orders(entity_type: "SecInsertClampLow").first).to eq(["ord_3", 1])

      s1, _s2, _s3 = make_section_partition(entity_type: "SecInsertClampHigh", prefix: "high")
      s1.insert_at(999)

      expect(section_partition_orders(entity_type: "SecInsertClampHigh").last).to eq(["high_1", 3])
    end

    it "isolates partitions across (entity_type, scope, parent_scope)" do
      t1_sections = make_section_partition(entity_type: "SecIso", scope: "t1", prefix: "t1")
      t2_sections = make_section_partition(entity_type: "SecIso", scope: "t2", prefix: "t2")
      t2_before = t2_sections.map { |s| [s.code, s.sort_order] }

      t1_sections.first.move_to_bottom

      expect(section_partition_orders(entity_type: "SecIso", scope: "t2")).to eq(t2_before)
    end

    it "places nil sort_order rows after positioned rows during normalization" do
      s1 = create(:typed_section, name: "Nil A", code: "nil_a", entity_type: "SecNilNorm", sort_order: nil)
      s2 = create(:typed_section, name: "Nil B", code: "nil_b", entity_type: "SecNilNorm", sort_order: nil)
      s3 = create(:typed_section, name: "Nil C", code: "nil_c", entity_type: "SecNilNorm", sort_order: nil)

      s1.move_higher

      orders = described_class.for_entity("SecNilNorm").pluck(:sort_order).sort
      expect(orders).to eq([1, 2, 3])
      [s1, s2, s3].each { |s| expect(s.reload.sort_order).to be_between(1, 3) }
    end
  end
end

RSpec.describe TypedEAV::Option, type: :model do
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
      expect(option.field).to be_a(TypedEAV::Field::Base)
    end
  end
end
