# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Value, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:entity) }
    # `:field` is optional as of Phase 02 cascade work — orphaned Value rows
    # (`field_id IS NULL`) are expected when `field_dependent: :nullify` is
    # used. Read-path guards silently skip orphans; write-path validators
    # `return unless field` so optional does not weaken integrity.
    it { is_expected.to belong_to(:field).optional }
  end

  describe "value storage in typed columns" do
    let(:contact) { create(:contact) }

    context "with an integer field" do
      let(:field) { create(:integer_field) }

      it "stores value in integer_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = 42
        value.save!
        value.reload

        expect(value.value).to eq(42)
        expect(value.integer_value).to eq(42)
        expect(value.string_value).to be_nil
      end

      it "casts string to integer via field type" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "123"
        value.save!
        value.reload

        expect(value.value).to eq(123)
        expect(value.value).to be_a(Integer)
      end

      it "handles nil values" do
        value = described_class.create!(entity: contact, field: field)
        value.value = nil
        value.save!
        value.reload

        expect(value.value).to be_nil
      end
    end

    context "with a text field" do
      let(:field) { create(:text_field) }

      it "stores value in string_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "hello world"
        value.save!
        value.reload

        expect(value.value).to eq("hello world")
        expect(value.string_value).to eq("hello world")
      end
    end

    context "with a boolean field" do
      let(:field) { create(:boolean_field) }

      it "stores true/false in boolean_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = true
        value.save!
        value.reload

        expect(value.value).to be(true)
        expect(value.boolean_value).to be(true)
      end

      it "casts string 'true' to boolean" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "true"
        value.save!
        value.reload

        expect(value.value).to be(true)
      end
    end

    context "with a decimal field" do
      let(:field) { create(:decimal_field) }

      it "stores value in decimal_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "19.99"
        value.save!
        value.reload

        expect(value.value).to eq(BigDecimal("19.99"))
        expect(value.decimal_value).to eq(BigDecimal("19.99"))
      end
    end

    context "with a date field" do
      let(:field) { create(:date_field) }

      it "stores value in date_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "2025-06-15"
        value.save!
        value.reload

        expect(value.value).to eq(Date.new(2025, 6, 15))
        expect(value.date_value).to eq(Date.new(2025, 6, 15))
      end
    end

    context "with a select field" do
      let(:field) { create(:select_field) }

      it "stores the option value in string_value" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "active"
        value.save!
        value.reload

        expect(value.value).to eq("active")
        expect(value.string_value).to eq("active")
      end
    end

    context "with a multi_select field" do
      let(:field) { create(:multi_select_field) }

      it "stores array in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = %w[vip partner]
        value.save!
        value.reload

        expect(value.value).to match_array(%w[vip partner])
        expect(value.json_value).to match_array(%w[vip partner])
      end
    end

    context "with an integer_array field" do
      let(:field) { create(:integer_array_field) }

      it "stores integer array in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = [1, 2, 3]
        value.save!
        value.reload

        expect(value.value).to eq([1, 2, 3])
      end

      it "casts string elements to integers" do
        value = described_class.create!(entity: contact, field: field)
        value.value = %w[10 20 30]
        value.save!
        value.reload

        expect(value.value).to eq([10, 20, 30])
      end
    end

    context "with an email field" do
      let(:field) { create(:email_typed_eav) }

      it "downcases and strips whitespace" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "  Test@Example.COM  "
        value.save!
        value.reload

        expect(value.value).to eq("test@example.com")
      end
    end
  end

  describe "uniqueness validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:text_field) }

    it "prevents duplicate values for the same entity and field" do
      described_class.create!(entity: contact, field: field, string_value: "first")

      duplicate = described_class.new(entity: contact, field: field, string_value: "second")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:field]).to be_present
    end
  end

  describe "entity type validation" do
    let(:contact) { create(:contact) }
    let(:product_field) { create(:integer_field, entity_type: "Product") }

    it "rejects values where entity type does not match field entity_type" do
      value = described_class.new(entity: contact, field: product_field)
      value.value = 42
      expect(value).not_to be_valid
      expect(value.errors[:entity]).to be_present
    end
  end

  describe "required field validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:integer_field, required: true) }

    it "requires a non-nil value when field is required" do
      value = described_class.new(entity: contact, field: field)
      value.value = nil
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/blank/))
    end

    it "passes when value is present" do
      value = described_class.new(entity: contact, field: field)
      value.value = 42
      expect(value).to be_valid
    end
  end

  describe "range validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:integer_field, options: { "min" => 1, "max" => 100 }) }

    it "rejects values below min" do
      value = described_class.new(entity: contact, field: field)
      value.value = 0
      expect(value).not_to be_valid
    end

    it "rejects values above max" do
      value = described_class.new(entity: contact, field: field)
      value.value = 101
      expect(value).not_to be_valid
    end

    it "accepts values within range" do
      value = described_class.new(entity: contact, field: field)
      value.value = 50
      expect(value).to be_valid
    end
  end

  describe "select option validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:select_field) }

    it "rejects values not in the options list" do
      value = described_class.new(entity: contact, field: field)
      value.value = "nonexistent"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/included in the list/))
    end

    it "accepts valid option values" do
      value = described_class.new(entity: contact, field: field)
      value.value = "active"
      expect(value).to be_valid
    end
  end

  describe "length validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:text_field, options: { "min_length" => 3, "max_length" => 10 }) }

    it "rejects values shorter than min_length" do
      value = described_class.new(entity: contact, field: field)
      value.value = "ab"
      expect(value).not_to be_valid
    end

    it "rejects values longer than max_length" do
      value = described_class.new(entity: contact, field: field)
      value.value = "a" * 11
      expect(value).not_to be_valid
    end

    it "accepts values within length range" do
      value = described_class.new(entity: contact, field: field)
      value.value = "hello"
      expect(value).to be_valid
    end
  end

  describe "value storage for additional types" do
    let(:contact) { create(:contact) }

    context "with a long_text field" do
      let(:field) { create(:long_text_field) }

      it "stores value in text_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "A very long text"
        value.save!
        value.reload
        expect(value.value).to eq("A very long text")
        expect(value.text_value).to eq("A very long text")
      end
    end

    context "with a datetime field" do
      let(:field) { create(:datetime_field) }

      it "stores value in datetime_value column" do
        value = described_class.create!(entity: contact, field: field)
        time = Time.zone.parse("2025-06-15 14:30:00")
        value.value = time
        value.save!
        value.reload
        expect(value.datetime_value).to be_within(1.second).of(time)
      end
    end

    context "with a decimal_array field" do
      let(:field) { create(:decimal_array_field) }

      it "stores array in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = ["1.5", "2.5"]
        value.save!
        value.reload
        expect(value.json_value).to be_an(Array)
        expect(value.json_value.size).to eq(2)
      end
    end

    context "with a date_array field" do
      let(:field) { create(:date_array_field) }

      it "stores dates in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = %w[2025-01-01 2025-06-15]
        value.save!
        value.reload
        expect(value.json_value).to be_an(Array)
        expect(value.json_value.size).to eq(2)
      end
    end

    context "with a text_array field" do
      let(:field) { create(:text_array_field) }

      it "stores string array in json_value" do
        value = described_class.create!(entity: contact, field: field)
        value.value = %w[hello world]
        value.save!
        value.reload
        expect(value.value).to eq(%w[hello world])
      end
    end

    context "with a url field" do
      let(:field) { create(:url_field) }

      it "stores in string_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "https://example.com"
        value.save!
        value.reload
        expect(value.string_value).to eq("https://example.com")
      end
    end

    context "with a color field" do
      let(:field) { create(:color_field) }

      it "stores in string_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = "#ff0000"
        value.save!
        value.reload
        expect(value.string_value).to eq("#ff0000")
      end
    end

    context "with a json field" do
      let(:field) { create(:json_field) }

      it "stores hash in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = { "key" => "val", "nested" => { "a" => 1 } }
        value.save!
        value.reload
        expect(value.json_value).to eq({ "key" => "val", "nested" => { "a" => 1 } })
      end

      it "stores array in json_value column" do
        value = described_class.create!(entity: contact, field: field)
        value.value = [1, "two", { "three" => 3 }]
        value.save!
        value.reload
        expect(value.json_value).to eq([1, "two", { "three" => 3 }])
      end
    end
  end

  describe "cast invalid detection" do
    let(:contact) { create(:contact) }

    it "adds :invalid error when field marks cast as invalid" do
      field = create(:integer_field, required: true)
      value = described_class.new(entity: contact, field: field)
      value.value = "not_a_number"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/invalid/))
    end

    it "does not leak cast-invalid flag across value instances sharing a field" do
      field = create(:integer_field)
      bad = described_class.new(entity: contact, field: field)
      bad.value = "abc"
      bad.valid? # surfaces :invalid on this record only

      good = described_class.new(entity: contact, field: field)
      good.value = "42"
      expect(good).to be_valid
    end
  end

  describe "pattern validation" do
    let(:contact) { create(:contact) }

    it "rejects text not matching pattern" do
      field = create(:text_field, options: { "pattern" => "\\A[A-Z]" })
      value = described_class.new(entity: contact, field: field)
      value.value = "hello"
      expect(value).not_to be_valid
    end

    it "accepts text matching pattern" do
      field = create(:text_field, options: { "pattern" => "\\A[A-Z]" })
      value = described_class.new(entity: contact, field: field)
      value.value = "Hello"
      expect(value).to be_valid
    end

    it "handles invalid regex pattern gracefully" do
      field = create(:text_field)
      field.update_column(:options, { "pattern" => "[invalid" })
      value = described_class.new(entity: contact, field: field)
      value.value = "test"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to be_present
    end
  end

  describe "email format validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:email_typed_eav) }

    it "rejects invalid email format" do
      value = described_class.new(entity: contact, field: field)
      value.value = "not-an-email"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/email/))
    end

    it "accepts valid email" do
      value = described_class.new(entity: contact, field: field)
      value.value = "user@example.com"
      expect(value).to be_valid
    end

    it "rejects email without domain" do
      value = described_class.new(entity: contact, field: field)
      value.value = "user@"
      expect(value).not_to be_valid
    end
  end

  describe "url format validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:url_field) }

    it "rejects invalid URL" do
      value = described_class.new(entity: contact, field: field)
      value.value = "not-a-url"
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/URL/))
    end

    it "accepts valid https URL" do
      value = described_class.new(entity: contact, field: field)
      value.value = "https://example.com"
      expect(value).to be_valid
    end

    it "accepts valid http URL" do
      value = described_class.new(entity: contact, field: field)
      value.value = "http://example.com/path?q=1"
      expect(value).to be_valid
    end
  end

  describe "date range validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:date_field, options: { "min_date" => "2020-01-01", "max_date" => "2030-12-31" }) }

    it "rejects date before min_date" do
      value = described_class.new(entity: contact, field: field)
      value.value = "2019-12-31"
      expect(value).not_to be_valid
    end

    it "rejects date after max_date" do
      value = described_class.new(entity: contact, field: field)
      value.value = "2031-01-01"
      expect(value).not_to be_valid
    end

    it "accepts date within range" do
      value = described_class.new(entity: contact, field: field)
      value.value = "2025-06-15"
      expect(value).to be_valid
    end
  end

  describe "datetime range validation" do
    let(:contact) { create(:contact) }
    let(:field) do
      create(:datetime_field,
             options: { "min_datetime" => "2020-01-01 00:00:00", "max_datetime" => "2030-12-31 23:59:59" })
    end

    it "rejects datetime before min" do
      value = described_class.new(entity: contact, field: field)
      value.value = "2019-12-31 23:59:59"
      expect(value).not_to be_valid
    end

    it "accepts datetime within range" do
      value = described_class.new(entity: contact, field: field)
      value.value = "2025-06-15 12:00:00"
      expect(value).to be_valid
    end
  end

  describe "multi-select option validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:multi_select_field) }

    it "rejects when any value not in options" do
      value = described_class.new(entity: contact, field: field)
      value.value = %w[vip nonexistent]
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/included in the list/))
    end

    it "accepts all valid options" do
      value = described_class.new(entity: contact, field: field)
      value.value = %w[vip partner]
      expect(value).to be_valid
    end
  end

  describe "array size validation" do
    let(:contact) { create(:contact) }

    it "rejects arrays smaller than min_size" do
      field = create(:integer_array_field, options: { "min_size" => 2 })
      value = described_class.new(entity: contact, field: field)
      value.value = [1]
      expect(value).not_to be_valid
    end

    it "rejects arrays larger than max_size" do
      field = create(:integer_array_field, options: { "max_size" => 3 })
      value = described_class.new(entity: contact, field: field)
      value.value = [1, 2, 3, 4]
      expect(value).not_to be_valid
    end

    it "accepts arrays within size range" do
      field = create(:integer_array_field, options: { "min_size" => 1, "max_size" => 5 })
      value = described_class.new(entity: contact, field: field)
      value.value = [1, 2, 3]
      expect(value).to be_valid
    end
  end

  describe "json size validation" do
    let(:contact) { create(:contact) }

    it "rejects JSON values exceeding 1MB" do
      field = create(:json_field)
      value = described_class.new(entity: contact, field: field)
      value.value = { "data" => "x" * 1_100_000 }
      expect(value).not_to be_valid
      expect(value.errors[:value]).to include(match(/too large/))
    end

    it "accepts JSON values under 1MB" do
      field = create(:json_field)
      value = described_class.new(entity: contact, field: field)
      value.value = { "key" => "small value" }
      expect(value).to be_valid
    end
  end

  describe "decimal range validation" do
    let(:contact) { create(:contact) }
    let(:field) { create(:decimal_field, options: { "min" => "0", "max" => "999.99" }) }

    it "rejects decimal below min" do
      value = described_class.new(entity: contact, field: field)
      value.value = "-1"
      expect(value).not_to be_valid
    end

    it "rejects decimal above max" do
      value = described_class.new(entity: contact, field: field)
      value.value = "1000"
      expect(value).not_to be_valid
    end

    it "accepts decimal within range" do
      value = described_class.new(entity: contact, field: field)
      value.value = "500.50"
      expect(value).to be_valid
    end
  end

  describe "#value when field is nil" do
    it "returns nil without error" do
      expect(described_class.new.value).to be_nil
    end
  end

  # Phase 1: two-axis cross-scope guard. The Value-level
  # `validate_field_scope_matches_entity` already rejects scope-axis
  # mismatches; Phase 1 extended it to also reject parent_scope-axis
  # mismatches. Mirrors the existing scope-axis "REVIEW: nested
  # typed-value must not attach across scope" block in
  # spec/regressions/known_bugs_spec.rb.
  describe "REVIEW: nested typed-value must not attach across parent_scope", :unscoped do
    let!(:full_triple_field) do
      create(:integer_field, entity_type: "Project", scope: "t1", parent_scope: "w1")
    end

    it "rejects when entity is in a different parent_scope" do
      project = Project.create!(name: "p", tenant_id: "t1", workspace_id: "w2")
      value = described_class.new(entity: project, field: full_triple_field, value: 1)
      expect(value).not_to be_valid
      expect(value.errors.added?(:field, :invalid)).to be true
    end

    it "rejects when entity host has no parent_scope_method (Contact -> full-triple field)" do
      contact = Contact.create!(name: "c", tenant_id: "t1")
      value = described_class.new(entity: contact, field: full_triple_field, value: 1)
      expect(value).not_to be_valid
      expect(value.errors.added?(:field, :invalid)).to be true
    end

    it "accepts when both scope and parent_scope match" do
      project = Project.create!(name: "p", tenant_id: "t1", workspace_id: "w1")
      value = described_class.new(entity: project, field: full_triple_field, value: 1)
      expect(value).to be_valid
    end
  end
end
