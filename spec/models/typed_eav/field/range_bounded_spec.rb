# frozen_string_literal: true

require "spec_helper"

# Family-base spec for Field::RangeBounded. Covers the shared
# min/max-bound validation surface ONCE for Integer/Decimal/Date/DateTime
# instead of the previous per-leaf duplication. The Integer/Decimal axis
# and the Date/DateTime axis are both covered.
RSpec.describe TypedEAV::Field::RangeBounded, type: :model do
  describe "inheritance chain" do
    it "is a Field::Base subclass" do
      expect(described_class.superclass).to eq(TypedEAV::Field::Base)
    end

    it "is the parent of Field::Integer" do
      expect(TypedEAV::Field::Integer.superclass).to eq(described_class)
    end

    it "is the parent of Field::Decimal" do
      expect(TypedEAV::Field::Decimal.superclass).to eq(described_class)
    end

    it "is the parent of Field::Date" do
      expect(TypedEAV::Field::Date.superclass).to eq(described_class)
    end

    it "is the parent of Field::DateTime" do
      expect(TypedEAV::Field::DateTime.superclass).to eq(described_class)
    end

    it "leaves Field::Percentage's chain as Percentage < Decimal" do
      expect(TypedEAV::Field::Percentage.superclass).to eq(TypedEAV::Field::Decimal)
    end
  end

  describe "Field::Percentage.value_column survives the deeper chain" do
    # Percentage < Decimal < RangeBounded < Base — chain depth grows from
    # 2 to 3. Ruby class instance variables are not inherited; Percentage's
    # explicit `value_column :decimal_value` re-declaration is what makes
    # `Percentage.value_column` work. Constraint per task T005.
    it "still returns :decimal_value" do
      expect(TypedEAV::Field::Percentage.value_column).to eq(:decimal_value)
    end
  end

  describe "STI dispatch (unchanged by intermediate-class insertion)" do
    it "Integer rows load as Field::Integer" do
      i = TypedEAV::Field::Integer.create!(name: "rb_i1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(i.id)).to be_a(TypedEAV::Field::Integer)
    end

    it "Decimal rows load as Field::Decimal" do
      d = TypedEAV::Field::Decimal.create!(name: "rb_d1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(d.id)).to be_a(TypedEAV::Field::Decimal)
    end

    it "Date rows load as Field::Date" do
      dt = TypedEAV::Field::Date.create!(name: "rb_dt1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(dt.id)).to be_a(TypedEAV::Field::Date)
    end

    it "DateTime rows load as Field::DateTime" do
      dtt = TypedEAV::Field::DateTime.create!(name: "rb_dtt1", entity_type: "Contact")
      expect(TypedEAV::Field::Base.find(dtt.id)).to be_a(TypedEAV::Field::DateTime)
    end
  end

  describe "Integer / Decimal inverted-bounds guard (pre-existing)" do
    it "Integer rejects max < min" do
      field = build(:integer_field, options: { "min" => 100, "max" => 10 })
      expect(field).not_to be_valid
      expect(field.errors[:max]).to be_present
    end

    it "Decimal rejects max < min" do
      field = build(:decimal_field, options: { "min" => 100, "max" => 10 })
      expect(field).not_to be_valid
      expect(field.errors[:max]).to be_present
    end

    it "Integer accepts max == min" do
      field = build(:integer_field, options: { "min" => 5, "max" => 5 })
      expect(field).to be_valid
    end
  end

  describe "Date / DateTime inverted-bounds guard (latent-bug grooming per ADR-0004)" do
    it "Date rejects max_date < min_date (newly enforced)" do
      field = build(:date_field, options: { "min_date" => "2026-01-01", "max_date" => "2025-01-01" })
      expect(field).not_to be_valid
      expect(field.errors[:max_date]).to be_present
    end

    it "DateTime rejects max_datetime < min_datetime (newly enforced)" do
      field = build(:datetime_field,
                    options: { "min_datetime" => "2026-01-01 00:00:00",
                               "max_datetime" => "2025-01-01 00:00:00" })
      expect(field).not_to be_valid
      expect(field.errors[:max_datetime]).to be_present
    end

    it "Date accepts max_date >= min_date" do
      field = build(:date_field, options: { "min_date" => "2020-01-01", "max_date" => "2030-12-31" })
      expect(field).to be_valid
    end

    it "DateTime accepts max_datetime >= min_datetime" do
      field = build(:datetime_field,
                    options: { "min_datetime" => "2020-01-01 00:00:00",
                               "max_datetime" => "2030-12-31 23:59:59" })
      expect(field).to be_valid
    end

    it "Date accepts a config with only min_date set" do
      field = build(:date_field, options: { "min_date" => "2020-01-01" })
      expect(field).to be_valid
    end

    it "Date accepts a config with only max_date set" do
      field = build(:date_field, options: { "max_date" => "2030-12-31" })
      expect(field).to be_valid
    end
  end

  describe "shared validate_range helper (via Value validation)" do
    let(:contact) { create(:contact) }

    it "Integer rejects values below min" do
      field = create(:integer_field, options: { "min" => 10, "max" => 100 })
      v = TypedEAV::Value.new(entity: contact, field: field, value: 5)
      expect(v).not_to be_valid
    end

    it "Integer rejects values above max" do
      field = create(:integer_field, options: { "min" => 10, "max" => 100 })
      v = TypedEAV::Value.new(entity: contact, field: field, value: 500)
      expect(v).not_to be_valid
    end

    it "Decimal accepts values within bounds" do
      field = create(:decimal_field, options: { "min" => 0, "max" => 1 })
      v = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("0.5"))
      expect(v).to be_valid
    end
  end

  describe "shared validate_date_range helper (via Value validation)" do
    let(:contact) { create(:contact) }
    let(:field) { create(:date_field, options: { "min_date" => "2020-01-01", "max_date" => "2030-12-31" }) }

    it "rejects dates before min_date" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "2019-12-31")
      expect(v).not_to be_valid
    end

    it "rejects dates after max_date" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "2031-01-01")
      expect(v).not_to be_valid
    end

    it "accepts dates within range" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "2025-06-15")
      expect(v).to be_valid
    end
  end

  describe "shared validate_datetime_range helper (via Value validation)" do
    let(:contact) { create(:contact) }
    let(:field) do
      create(:datetime_field,
             options: { "min_datetime" => "2020-01-01 00:00:00", "max_datetime" => "2030-12-31 23:59:59" })
    end

    it "rejects datetimes before min_datetime" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "2019-12-31 23:59:59")
      expect(v).not_to be_valid
    end

    it "accepts datetimes within range" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "2025-06-15 12:00:00")
      expect(v).to be_valid
    end
  end
end
