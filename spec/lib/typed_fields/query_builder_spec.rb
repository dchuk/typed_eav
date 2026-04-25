# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedFields::QueryBuilder do
  let!(:contact_a) { create(:contact, name: "Alice") }
  let!(:contact_b) { create(:contact, name: "Bob") }
  let!(:contact_c) { create(:contact, name: "Charlie") }

  describe ".filter with integer fields" do
    let!(:field) { create(:integer_field, name: "age") }

    before do
      [
        [contact_a, 25],
        [contact_b, 35],
        [contact_c, 45],
      ].each do |contact, age|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = age
          v.save!
        end
      end
    end

    it ":eq finds exact match" do
      results = described_class.filter(field, :eq, 35)
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":gt finds greater than" do
      results = described_class.filter(field, :gt, 30)
      expect(results.pluck(:entity_id)).to contain_exactly(contact_b.id, contact_c.id)
    end

    it ":lt finds less than" do
      results = described_class.filter(field, :lt, 30)
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":gteq finds greater than or equal" do
      results = described_class.filter(field, :gteq, 35)
      expect(results.pluck(:entity_id)).to contain_exactly(contact_b.id, contact_c.id)
    end

    it ":lteq finds less than or equal" do
      results = described_class.filter(field, :lteq, 35)
      expect(results.pluck(:entity_id)).to contain_exactly(contact_a.id, contact_b.id)
    end

    it ":between finds within range" do
      results = described_class.filter(field, :between, 30..40)
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":not_eq excludes match and includes NULLs" do
      # contact without any age value
      create(:contact, name: "Diana")

      results = described_class.filter(field, :not_eq, 35)
      entity_ids = results.pluck(:entity_id)

      expect(entity_ids).to include(contact_a.id, contact_c.id)
      expect(entity_ids).not_to include(contact_b.id)
      # Diana has no value record so won't appear (she's not in the values table)
    end

    it "casts string values via Rails column type" do
      results = described_class.filter(field, :eq, "35")
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end
  end

  describe ".filter with text fields" do
    let!(:field) { create(:text_field, name: "city") }

    before do
      [
        [contact_a, "Portland"],
        [contact_b, "San Francisco"],
        [contact_c, "Portland Heights"],
      ].each do |contact, city|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = city
          v.save!
        end
      end
    end

    it ":eq finds exact match" do
      results = described_class.filter(field, :eq, "Portland")
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":contains finds substring match (ILIKE)" do
      results = described_class.filter(field, :contains, "portland")
      expect(results.pluck(:entity_id)).to contain_exactly(contact_a.id, contact_c.id)
    end

    it ":starts_with finds prefix match" do
      results = described_class.filter(field, :starts_with, "San")
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":ends_with finds suffix match" do
      results = described_class.filter(field, :ends_with, "Heights")
      expect(results.pluck(:entity_id)).to eq([contact_c.id])
    end

    it ":not_contains excludes substring" do
      results = described_class.filter(field, :not_contains, "Portland")
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it "escapes LIKE wildcards in search values" do
      TypedFields::Value.create!(entity: contact_a, field: create(:text_field, name: "note")).tap do |v|
        v.value = "100% complete"
        v.save!
      end

      note_field = TypedFields::Field::Text.find_by(name: "note")
      results = described_class.filter(note_field, :contains, "100%")
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".filter with boolean fields" do
    let!(:field) { create(:boolean_field, name: "active") }

    before do
      [[contact_a, true], [contact_b, false]].each do |contact, val|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = val
          v.save!
        end
      end
    end

    it ":eq true finds truthy records" do
      results = described_class.filter(field, :eq, true)
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":eq false finds falsy records" do
      results = described_class.filter(field, :eq, false)
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end
  end

  describe ".filter with date fields" do
    let!(:field) { create(:date_field, name: "birthday") }

    before do
      [
        [contact_a, Date.new(1990, 1, 15)],
        [contact_b, Date.new(2000, 6, 20)],
        [contact_c, Date.new(1985, 12, 1)],
      ].each do |contact, date|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = date
          v.save!
        end
      end
    end

    it ":gt finds dates after" do
      results = described_class.filter(field, :gt, Date.new(1995, 1, 1))
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":between finds dates in range" do
      results = described_class.filter(field, :between, Date.new(1989, 1, 1)..Date.new(1999, 12, 31))
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".filter with json array fields" do
    let!(:field) { create(:integer_array_field, name: "scores") }

    before do
      [
        [contact_a, [10, 20, 30]],
        [contact_b, [20, 40, 60]],
        [contact_c, [5, 10, 15]],
      ].each do |contact, scores|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = scores
          v.save!
        end
      end
    end

    it ":any_eq finds arrays containing element" do
      results = described_class.filter(field, :any_eq, 20)
      expect(results.pluck(:entity_id)).to contain_exactly(contact_a.id, contact_b.id)
    end

    it ":all_eq finds arrays containing all elements" do
      results = described_class.filter(field, :all_eq, [10, 20])
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".filter null checks" do
    let!(:field) { create(:text_field, name: "notes") }

    before do
      TypedFields::Value.create!(entity: contact_a, field: field).tap do |v|
        v.value = "has notes"
        v.save!
      end
      TypedFields::Value.create!(entity: contact_b, field: field) # nil value
    end

    it ":is_null finds NULL values" do
      results = described_class.filter(field, :is_null, nil)
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":is_not_null finds non-NULL values" do
      results = described_class.filter(field, :is_not_null, nil)
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".entity_ids" do
    let!(:field) { create(:integer_field, name: "score") }

    before do
      TypedFields::Value.create!(entity: contact_a, field: field).tap do |v|
        v.value = 100
        v.save!
      end
    end

    it "returns a relation suitable for subqueries" do
      ids = described_class.entity_ids(field, :eq, 100)
      expect(ids).to be_a(ActiveRecord::Relation)
      expect(Contact.where(id: ids).pluck(:name)).to eq(["Alice"])
    end
  end

  describe "unknown operator" do
    let!(:field) { create(:text_field) }

    it "raises ArgumentError" do
      expect { described_class.filter(field, :bogus, "x") }.to raise_error(ArgumentError, /not supported/)
    end
  end

  describe ".filter with decimal fields" do
    let!(:field) { create(:decimal_field, name: "price") }

    before do
      [
        [contact_a, BigDecimal("19.99")],
        [contact_b, BigDecimal("29.99")],
        [contact_c, BigDecimal("9.99")],
      ].each do |contact, price|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = price
          v.save!
        end
      end
    end

    it ":eq finds exact BigDecimal match" do
      results = described_class.filter(field, :eq, BigDecimal("29.99"))
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":gt finds greater than" do
      results = described_class.filter(field, :gt, BigDecimal("15"))
      expect(results.pluck(:entity_id)).to contain_exactly(contact_a.id, contact_b.id)
    end

    it ":between finds within range" do
      results = described_class.filter(field, :between, BigDecimal("10")..BigDecimal("25"))
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".filter with datetime fields" do
    let!(:field) { create(:datetime_field, name: "last_login") }

    before do
      [
        [contact_a, Time.zone.parse("2025-01-15 10:00:00")],
        [contact_b, Time.zone.parse("2025-06-20 14:30:00")],
        [contact_c, Time.zone.parse("2025-12-01 08:00:00")],
      ].each do |contact, time|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = time
          v.save!
        end
      end
    end

    it ":gt finds datetimes after" do
      results = described_class.filter(field, :gt, Time.zone.parse("2025-06-01"))
      expect(results.pluck(:entity_id)).to contain_exactly(contact_b.id, contact_c.id)
    end

    it ":between finds datetimes in range" do
      results = described_class.filter(field, :between,
                                       Time.zone.parse("2025-01-01")..Time.zone.parse("2025-03-01"))
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":eq finds exact datetime" do
      results = described_class.filter(field, :eq, Time.zone.parse("2025-06-20 14:30:00"))
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end
  end

  describe ".filter with select fields" do
    let!(:field) { create(:select_field, name: "status") }

    before do
      [
        [contact_a, "active"],
        [contact_b, "inactive"],
        [contact_c, "lead"],
      ].each do |contact, status|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = status
          v.save!
        end
      end
    end

    it ":eq finds matching option" do
      results = described_class.filter(field, :eq, "active")
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":not_eq excludes matching" do
      results = described_class.filter(field, :not_eq, "active")
      expect(results.pluck(:entity_id)).to contain_exactly(contact_b.id, contact_c.id)
    end
  end

  describe ".filter with multi_select fields" do
    let!(:field) { create(:multi_select_field, name: "tags") }

    before do
      [
        [contact_a, %w[vip partner]],
        [contact_b, ["prospect"]],
        [contact_c, %w[vip prospect]],
      ].each do |contact, tags|
        TypedFields::Value.create!(entity: contact, field: field).tap do |v|
          v.value = tags
          v.save!
        end
      end
    end

    it ":any_eq finds arrays containing element" do
      results = described_class.filter(field, :any_eq, "vip")
      expect(results.pluck(:entity_id)).to contain_exactly(contact_a.id, contact_c.id)
    end

    it ":all_eq finds arrays containing all elements" do
      results = described_class.filter(field, :all_eq, %w[vip partner])
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ".filter with color fields" do
    let!(:field) { create(:color_field, name: "brand_color") }

    before do
      TypedFields::Value.create!(entity: contact_a, field: field).tap do |v|
        v.value = "#ff0000"
        v.save!
      end
      TypedFields::Value.create!(entity: contact_b, field: field).tap do |v|
        v.value = "#00ff00"
        v.save!
      end
    end

    it ":eq finds exact color" do
      results = described_class.filter(field, :eq, "#ff0000")
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end

    it ":not_eq excludes color" do
      results = described_class.filter(field, :not_eq, "#ff0000")
      entity_ids = results.pluck(:entity_id)
      expect(entity_ids).to include(contact_b.id)
      expect(entity_ids).not_to include(contact_a.id)
    end
  end

  describe "null value edge cases" do
    let!(:field) { create(:integer_field, name: "score") }

    before do
      TypedFields::Value.create!(entity: contact_a, field: field).tap do |v|
        v.value = 100
        v.save!
      end
      TypedFields::Value.create!(entity: contact_b, field: field) # nil value
    end

    it ":eq with nil acts as IS NULL" do
      results = described_class.filter(field, :eq, nil)
      expect(results.pluck(:entity_id)).to eq([contact_b.id])
    end

    it ":not_eq with nil acts as IS NOT NULL" do
      results = described_class.filter(field, :not_eq, nil)
      expect(results.pluck(:entity_id)).to eq([contact_a.id])
    end
  end

  describe ":between input validation" do
    let!(:field) { create(:integer_field, name: "val") }

    it "raises ArgumentError for non-range values" do
      expect { described_class.filter(field, :between, 42) }.to raise_error(ArgumentError, /between/)
    end

    it "accepts Range input" do
      expect { described_class.filter(field, :between, 1..10) }.not_to raise_error
    end

    it "accepts Array with first/last" do
      expect { described_class.filter(field, :between, [1, 10]) }.not_to raise_error
    end
  end

  describe "operator validation per field type" do
    it "rejects :gt on Boolean field" do
      field = create(:boolean_field, name: "flag")
      expect { described_class.filter(field, :gt, true) }.to raise_error(ArgumentError, /not supported/)
    end

    it "rejects :contains on Integer field" do
      field = create(:integer_field, name: "num")
      expect { described_class.filter(field, :contains, "5") }.to raise_error(ArgumentError, /not supported/)
    end

    it "rejects :between on Select field" do
      field = create(:select_field, name: "sel")
      expect { described_class.filter(field, :between, "a".."z") }.to raise_error(ArgumentError, /not supported/)
    end
  end
end
