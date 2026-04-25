# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedFields::Field::Base, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:values) }
    it { is_expected.to have_many(:field_options) }
    it { is_expected.to belong_to(:section).optional }
  end

  describe "validations" do
    subject { build(:text_field) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:type) }
    it { is_expected.to validate_presence_of(:entity_type) }

    it "enforces name uniqueness per entity_type and scope" do
      create(:text_field, name: "bio", entity_type: "Contact", scope: nil)

      duplicate = build(:text_field, name: "bio", entity_type: "Contact", scope: nil)
      expect(duplicate).not_to be_valid

      different_entity = build(:text_field, name: "bio", entity_type: "Product", scope: nil)
      expect(different_entity).to be_valid

      different_scope = build(:text_field, name: "bio", entity_type: "Contact", scope: "tenant_1")
      expect(different_scope).to be_valid
    end
  end

  describe "STI resolution" do
    it "loads as the correct subclass" do
      field = TypedFields::Field::Integer.create!(name: "age", entity_type: "Contact")
      reloaded = described_class.find(field.id)
      expect(reloaded).to be_a(TypedFields::Field::Integer)
    end
  end
end

RSpec.describe "Field type column mappings" do
  {
    TypedFields::Field::Text => :string_value,
    TypedFields::Field::LongText => :text_value,
    TypedFields::Field::Integer => :integer_value,
    TypedFields::Field::Decimal => :decimal_value,
    TypedFields::Field::Boolean => :boolean_value,
    TypedFields::Field::Date => :date_value,
    TypedFields::Field::DateTime => :datetime_value,
    TypedFields::Field::Select => :string_value,
    TypedFields::Field::MultiSelect => :json_value,
    TypedFields::Field::IntegerArray => :json_value,
    TypedFields::Field::DecimalArray => :json_value,
    TypedFields::Field::TextArray => :json_value,
    TypedFields::Field::DateArray => :json_value,
    TypedFields::Field::Email => :string_value,
    TypedFields::Field::Url => :string_value,
    TypedFields::Field::Color => :string_value,
    TypedFields::Field::Json => :json_value,
  }.each do |klass, expected_column|
    it "#{klass.name.demodulize} maps to #{expected_column}" do
      expect(klass.value_column).to eq(expected_column)
    end
  end
end

RSpec.describe "Field type supported operators" do
  it "Integer supports numeric operators" do
    ops = TypedFields::Field::Integer.supported_operators
    expect(ops).to include(:eq, :gt, :lt, :gteq, :lteq, :between)
  end

  it "Boolean supports only eq and null checks" do
    ops = TypedFields::Field::Boolean.supported_operators
    expect(ops).to eq(%i[eq is_null is_not_null])
  end

  it "Text supports string operators" do
    ops = TypedFields::Field::Text.supported_operators
    expect(ops).to include(:contains, :starts_with, :ends_with)
  end

  it "Select supports eq/not_eq and null" do
    ops = TypedFields::Field::Select.supported_operators
    expect(ops).to eq(%i[eq not_eq is_null is_not_null])
  end

  it "MultiSelect supports array operators" do
    ops = TypedFields::Field::MultiSelect.supported_operators
    expect(ops).to include(:any_eq, :all_eq)
  end
end

RSpec.describe "Field type casting" do
  describe TypedFields::Field::Integer do
    let(:field) { build(:integer_field) }

    it "casts strings to integers" do
      expect(field.cast("42").first).to eq(42)
    end

    it "returns nil for non-numeric strings" do
      expect(field.cast("abc").first).to be_nil
    end

    it "rejects decimal input" do
      expect(field.cast("3.7")).to eq([nil, true])
    end
  end

  describe TypedFields::Field::Decimal do
    let(:field) { build(:decimal_field) }

    it "casts strings to BigDecimal" do
      expect(field.cast("19.99").first).to eq(BigDecimal("19.99"))
    end
  end

  describe TypedFields::Field::Boolean do
    let(:field) { build(:boolean_field) }

    it "casts string 'true' to true" do
      expect(field.cast("true").first).to be(true)
    end

    it "casts string '0' to false" do
      expect(field.cast("0").first).to be(false)
    end

    it "casts nil to nil" do
      expect(field.cast(nil).first).to be_nil
    end
  end

  describe TypedFields::Field::Date do
    let(:field) { build(:date_field) }

    it "casts string to Date" do
      expect(field.cast("2025-06-15").first).to eq(Date.new(2025, 6, 15))
    end

    it "passes through Date objects" do
      date = Time.zone.today
      expect(field.cast(date).first).to eq(date)
    end

    it "returns nil for invalid dates" do
      expect(field.cast("not-a-date").first).to be_nil
    end
  end

  describe TypedFields::Field::Email do
    let(:field) { build(:email_typed_field) }

    it "downcases and strips" do
      expect(field.cast("  USER@Example.COM  ").first).to eq("user@example.com")
    end
  end

  describe TypedFields::Field::IntegerArray do
    let(:field) { build(:integer_array_field) }

    it "casts array elements to integers" do
      expect(field.cast(%w[1 2 3]).first).to eq([1, 2, 3])
    end

    it "marks cast invalid and stores nil when any element is non-numeric" do
      # Prior behavior was to silently drop bad elements. That hid bad input
      # from users on form re-renders; see review_round_2_array_cast_spec.rb.
      expect(field.cast(%w[1 abc 3])).to eq([nil, true])
    end
  end

  describe TypedFields::Field::Select do
    it "reports as optionable" do
      expect(build(:select_field)).to be_optionable
    end

    it "reports as not array" do
      expect(build(:select_field)).not_to be_array_field
    end
  end

  describe TypedFields::Field::MultiSelect do
    it "reports as optionable and array" do
      field = build(:multi_select_field)
      expect(field).to be_optionable
      expect(field).to be_array_field
    end
  end
end

RSpec.describe "Reserved field names" do
  it "rejects reserved name 'id'" do
    field = build(:text_field, name: "id")
    expect(field).not_to be_valid
    expect(field.errors[:name]).to include("is reserved")
  end

  it "rejects reserved name 'type'" do
    expect(build(:text_field, name: "type")).not_to be_valid
  end

  it "rejects reserved name 'created_at'" do
    expect(build(:text_field, name: "created_at")).not_to be_valid
  end
end

RSpec.describe "Field default values" do
  it "stores and retrieves a default value cast through field type" do
    field = create(:integer_field)
    field.default_value_meta = { "v" => "42" }
    field.save!
    expect(field.reload.default_value).to eq(42)
  end

  it "returns nil when no default is set" do
    expect(build(:text_field).default_value).to be_nil
  end

  it "validates invalid default values" do
    field = build(:integer_field)
    field.default_value_meta = { "v" => "not_a_number" }
    expect(field).not_to be_valid
    expect(field.errors[:default_value]).to be_present
  end

  it "accepts valid default for text field" do
    field = build(:text_field)
    field.default_value_meta = { "v" => "hello" }
    expect(field).to be_valid
  end
end

RSpec.describe "Field#field_type_name" do
  it "returns underscore name for MultiSelect" do
    expect(TypedFields::Field::MultiSelect.new.field_type_name).to eq("multi_select")
  end

  it "returns underscore name for IntegerArray" do
    expect(TypedFields::Field::IntegerArray.new.field_type_name).to eq("integer_array")
  end

  it "returns underscore name for LongText" do
    expect(TypedFields::Field::LongText.new.field_type_name).to eq("long_text")
  end

  it "returns underscore name for DateTime" do
    expect(TypedFields::Field::DateTime.new.field_type_name).to eq("date_time")
  end
end

RSpec.describe "Field#allowed_option_values" do
  it "returns option values" do
    field = create(:select_field)
    expect(field.allowed_option_values).to match_array(%w[active inactive lead])
  end

  it "reflects newly added options immediately" do
    field = create(:select_field)
    field.field_options.create!(label: "New", value: "new", sort_order: 4)
    expect(field.allowed_option_values).to include("new")
  end
end

RSpec.describe "Text field option validations" do
  it "validates max_length >= min_length" do
    field = build(:text_field, options: { "min_length" => 10, "max_length" => 5 })
    expect(field).not_to be_valid
  end

  it "rejects invalid regex pattern" do
    field = build(:text_field, options: { "pattern" => "[invalid" })
    expect(field).not_to be_valid
    expect(field.errors[:pattern]).to be_present
  end

  it "accepts valid regex pattern" do
    field = build(:text_field, options: { "pattern" => "\\A[a-z]+\\z" })
    expect(field).to be_valid
  end
end

RSpec.describe "Integer field option validations" do
  it "validates max >= min" do
    field = build(:integer_field, options: { "min" => 100, "max" => 10 })
    expect(field).not_to be_valid
  end
end

RSpec.describe "Decimal field precision_scale" do
  let(:field) { build(:decimal_field, options: { "precision_scale" => "2" }) }

  it "applies rounding" do
    expect(field.cast("19.999").first).to eq(BigDecimal("20.00"))
  end

  it "ignores invalid precision_scale" do
    field = build(:decimal_field, options: { "precision_scale" => "abc" })
    expect(field.cast("19.99").first).to eq(BigDecimal("19.99"))
  end
end

RSpec.describe "LongText casting" do
  let(:field) { build(:long_text_field) }

  it "casts to string" do
    expect(field.cast(123).first).to eq("123")
  end

  it "returns nil for nil" do
    expect(field.cast(nil).first).to be_nil
  end
end

RSpec.describe "DateTime casting" do
  let(:field) { build(:datetime_field) }

  it "casts valid datetime string" do
    result = field.cast("2025-06-15 14:30:00").first
    expect(result).to be_a(Time)
  end

  it "passes through Time objects" do
    time = Time.current
    expect(field.cast(time).first).to eq(time)
  end

  it "returns nil and marks invalid for unparseable strings" do
    expect(field.cast("not-a-datetime")).to eq([nil, true])
  end
end

RSpec.describe "DecimalArray casting" do
  let(:field) { build(:decimal_array_field) }

  it "casts elements to BigDecimal" do
    expect(field.cast(["1.5", "2.5"]).first).to eq([BigDecimal("1.5"), BigDecimal("2.5")])
  end

  it "marks cast invalid and stores nil when any element is unparseable" do
    expect(field.cast(["1.5", "abc", "3.0"])).to eq([nil, true])
  end

  it "returns nil for nil" do
    expect(field.cast(nil).first).to be_nil
  end

  it "returns nil for empty array via .presence" do
    expect(field.cast([]).first).to be_nil
  end
end

RSpec.describe "DateArray casting" do
  let(:field) { build(:date_array_field) }

  it "casts date strings" do
    result = field.cast(%w[2025-01-01 2025-06-15]).first
    expect(result).to eq([Date.new(2025, 1, 1), Date.new(2025, 6, 15)])
  end

  it "marks cast invalid and stores nil when any element is not a valid date" do
    expect(field.cast(["2025-01-01", "not-a-date"])).to eq([nil, true])
  end

  it "returns nil for nil" do
    expect(field.cast(nil).first).to be_nil
  end
end

RSpec.describe "Url casting and validation" do
  let(:field) { build(:url_field) }

  it "strips whitespace" do
    expect(field.cast("  https://example.com  ").first).to eq("https://example.com")
  end

  it "does not downcase" do
    expect(field.cast("https://Example.COM/Path").first).to eq("https://Example.COM/Path")
  end

  it "validates URL format" do
    expect(field.url_format_valid?("https://example.com")).to be true
    expect(field.url_format_valid?("not-a-url")).to be false
  end
end

RSpec.describe "Color casting" do
  let(:field) { build(:color_field) }

  it "downcases and strips" do
    expect(field.cast("  #FF0000  ").first).to eq("#ff0000")
  end

  it "returns nil for nil" do
    expect(field.cast(nil).first).to be_nil
  end
end

RSpec.describe "Json casting" do
  let(:field) { build(:json_field) }

  it "passes through hash" do
    expect(field.cast({ "key" => "val" }).first).to eq({ "key" => "val" })
  end

  it "passes through array" do
    expect(field.cast([1, 2, 3]).first).to eq([1, 2, 3])
  end

  it "passes through nil" do
    expect(field.cast(nil).first).to be_nil
  end
end

RSpec.describe "Boolean casting edge cases" do
  let(:field) { build(:boolean_field) }

  it "casts standard truthy strings" do
    expect(field.cast("true").first).to be(true)
    expect(field.cast("1").first).to be(true)
  end

  it "casts standard falsy strings" do
    expect(field.cast("false").first).to be(false)
    expect(field.cast("0").first).to be(false)
  end
end

RSpec.describe "cast_value(nil) returns nil for all field types" do
  %i[text_field long_text_field integer_field decimal_field boolean_field
     date_field datetime_field select_field multi_select_field
     integer_array_field decimal_array_field text_array_field date_array_field
     email_typed_field url_field color_field json_field].each do |factory_name|
    it "#{factory_name} returns nil" do
      field = build(factory_name)
      expect(field.cast(nil).first).to be_nil
    end
  end
end

RSpec.describe "Supported operators for all field types" do
  it "Decimal supports numeric operators" do
    expect(TypedFields::Field::Decimal.supported_operators).to include(:eq, :gt, :between)
  end

  it "Date supports comparison operators" do
    expect(TypedFields::Field::Date.supported_operators).to include(:eq, :gt, :between)
  end

  it "DateTime supports comparison operators" do
    expect(TypedFields::Field::DateTime.supported_operators).to include(:eq, :gt, :between)
  end

  it "LongText supports string operators" do
    expect(TypedFields::Field::LongText.supported_operators).to include(:contains, :starts_with)
  end

  it "Color supports only eq/not_eq/null" do
    expect(TypedFields::Field::Color.supported_operators).to eq(%i[eq not_eq is_null is_not_null])
  end

  it "Json supports only null operators" do
    expect(TypedFields::Field::Json.supported_operators).to eq(%i[is_null is_not_null])
  end

  it "IntegerArray supports array operators" do
    expect(TypedFields::Field::IntegerArray.supported_operators).to include(:any_eq, :all_eq)
  end

  it "DecimalArray supports array operators" do
    expect(TypedFields::Field::DecimalArray.supported_operators).to include(:any_eq, :all_eq)
  end

  it "TextArray supports JSONB array containment operators but not :contains" do
    # :contains previously mapped to Arel `matches` (SQL LIKE), which is
    # invalid against jsonb. Element containment is expressed via :any_eq /
    # :all_eq, which map to the JSONB `@>` operator.
    ops = TypedFields::Field::TextArray.supported_operators
    expect(ops).to include(:any_eq, :all_eq)
    expect(ops).not_to include(:contains)
  end

  it "DateArray supports array operators" do
    expect(TypedFields::Field::DateArray.supported_operators).to include(:any_eq)
  end
end

RSpec.describe TypedFields::ColumnMapping do
  it "raises NotImplementedError for undeclared value_column" do
    klass = Class.new(TypedFields::Field::Base) do
      self.table_name = "typed_fields"
    end
    expect { klass.value_column }.to raise_error(NotImplementedError)
  end
end
