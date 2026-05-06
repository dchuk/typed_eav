# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Field::Base, type: :model do
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

    # Phase 1: uniqueness widened to (entity_type, scope, parent_scope) and
    # the orphan-parent invariant rejects (parent_scope set, scope blank).
    # The Field::Base validations contract:
    #   - same name allowed across different parent_scope partitions
    #   - duplicate within the same triple still rejected
    #   - parent_scope.present? && scope.blank? always invalid
    context "with parent_scope partitioning" do
      it "allows a same-name field with a different parent_scope under the same scope" do
        create(:integer_field, name: "x_pp1", entity_type: "Project", scope: "t1")
        f = build(:integer_field, name: "x_pp1", entity_type: "Project", scope: "t1", parent_scope: "w1")
        expect(f).to be_valid
      end

      it "rejects a duplicate within the same (entity_type, scope, parent_scope) tuple" do
        create(:integer_field, name: "y_pp1", entity_type: "Project", scope: "t1", parent_scope: "w1")
        dup = build(:integer_field, name: "y_pp1", entity_type: "Project", scope: "t1", parent_scope: "w1")
        expect(dup).not_to be_valid
        expect(dup.errors[:name]).to be_present
      end

      it "allows a same-name field across different parent_scope values" do
        create(:integer_field, name: "z_pp1", entity_type: "Project", scope: "t1", parent_scope: "w1")
        f = build(:integer_field, name: "z_pp1", entity_type: "Project", scope: "t1", parent_scope: "w2")
        expect(f).to be_valid
      end

      it "rejects an orphan-parent (parent_scope set, scope nil)" do
        f = build(:integer_field, name: "orphan_pp1", entity_type: "Project", scope: nil, parent_scope: "w1")
        expect(f).not_to be_valid
        expect(f.errors[:parent_scope]).to be_present
      end

      it "accepts (scope nil, parent_scope nil) — pure global" do
        f = build(:integer_field, name: "global_pp1", entity_type: "Project", scope: nil, parent_scope: nil)
        expect(f).to be_valid
      end

      it "accepts (scope set, parent_scope nil) — scope-only (existing shape)" do
        f = build(:integer_field, name: "scoped_pp1", entity_type: "Project", scope: "t1", parent_scope: nil)
        expect(f).to be_valid
      end
    end
  end

  describe "STI resolution" do
    it "loads as the correct subclass" do
      field = TypedEAV::Field::Integer.create!(name: "age", entity_type: "Contact")
      reloaded = described_class.find(field.id)
      expect(reloaded).to be_a(TypedEAV::Field::Integer)
    end
  end
end

RSpec.describe "Field type column mappings" do
  {
    TypedEAV::Field::Text => :string_value,
    TypedEAV::Field::LongText => :text_value,
    TypedEAV::Field::Integer => :integer_value,
    TypedEAV::Field::Decimal => :decimal_value,
    TypedEAV::Field::Boolean => :boolean_value,
    TypedEAV::Field::Date => :date_value,
    TypedEAV::Field::DateTime => :datetime_value,
    TypedEAV::Field::Select => :string_value,
    TypedEAV::Field::MultiSelect => :json_value,
    TypedEAV::Field::IntegerArray => :json_value,
    TypedEAV::Field::DecimalArray => :json_value,
    TypedEAV::Field::TextArray => :json_value,
    TypedEAV::Field::DateArray => :json_value,
    TypedEAV::Field::Email => :string_value,
    TypedEAV::Field::Url => :string_value,
    TypedEAV::Field::Color => :string_value,
    TypedEAV::Field::Json => :json_value,
    # Phase 5 additions. Currency's PRIMARY column is decimal_value (the
    # amount); the secondary string_value (currency code) is asserted via
    # the value_columns multi-cell block in column_mapping_value_columns_spec.
    # Percentage inherits decimal_value from Decimal (re-declared explicitly
    # for STI subclass-of-subclass class-instance-variable lookup).
    TypedEAV::Field::Currency => :decimal_value,
    TypedEAV::Field::Percentage => :decimal_value,
    # Phase 5 plan 03: Active Storage-backed types. Both store the
    # blob's signed_id (a String) in :string_value; the :attachment
    # has_one_attached association lives on TypedEAV::Value.
    TypedEAV::Field::Image => :string_value,
    TypedEAV::Field::File => :string_value,
  }.each do |klass, expected_column|
    it "#{klass.name.demodulize} maps to #{expected_column}" do
      expect(klass.value_column).to eq(expected_column)
    end
  end
end

# Phase 05 BC regression: Field::Base ships `operator_column(operator)` as
# a class method that defaults to `value_column`. Every built-in field
# type as of Phase 04 must return the same column from
# `operator_column(op)` as `value_column` for every operator the type
# explicitly supports. This is the regression guard that future external
# field types (registered via Config.register_field_type) inherit safely.
# Mirrors the precedent set by spec/lib/typed_eav/column_mapping_value_columns_spec.rb
# (Phase 04's exhaustive value_columns regression).
RSpec.describe "Field type operator_column BC across all built-in types" do
  phase05_operator_column_bc_types = {
    TypedEAV::Field::Text => :string_value,
    TypedEAV::Field::LongText => :text_value,
    TypedEAV::Field::Integer => :integer_value,
    TypedEAV::Field::Decimal => :decimal_value,
    TypedEAV::Field::Boolean => :boolean_value,
    TypedEAV::Field::Date => :date_value,
    TypedEAV::Field::DateTime => :datetime_value,
    TypedEAV::Field::Select => :string_value,
    TypedEAV::Field::MultiSelect => :json_value,
    TypedEAV::Field::IntegerArray => :json_value,
    TypedEAV::Field::DecimalArray => :json_value,
    TypedEAV::Field::TextArray => :json_value,
    TypedEAV::Field::DateArray => :json_value,
    TypedEAV::Field::Email => :string_value,
    TypedEAV::Field::Url => :string_value,
    TypedEAV::Field::Color => :string_value,
    TypedEAV::Field::Json => :json_value,
    # Percentage is a Decimal subclass (Phase 5) that inherits Decimal's
    # operator set without overriding operator_column — every supported
    # operator routes to decimal_value.
    TypedEAV::Field::Percentage => :decimal_value,
    # Phase 5 plan 03: Image and File inherit the default operator_column
    # (delegates to value_column → :string_value). Their explicit
    # operator narrowing is to [:eq, :is_null, :is_not_null]; all three
    # route to :string_value via the inherited delegation.
    TypedEAV::Field::Image => :string_value,
    TypedEAV::Field::File => :string_value,
  }.freeze

  phase05_operator_column_bc_types.each do |klass, expected_col|
    context klass.name do
      it "operator_column delegates to value_column for every supported operator" do
        klass.supported_operators.each do |op|
          expect(klass.operator_column(op)).to eq(expected_col),
                                               "#{klass.name}.operator_column(#{op.inspect}) " \
                                               "returned #{klass.operator_column(op).inspect}, " \
                                               "expected #{expected_col.inspect}"
        end
      end
    end
  end

  # Phase 5 explicit non-default case: Currency overrides operator_column
  # so that :currency_eq routes to :string_value while every other
  # supported operator routes to :decimal_value. This block is the
  # canonical assertion of that override.
  context "with TypedEAV::Field::Currency (non-default operator_column override)" do
    it ":currency_eq routes to :string_value (NOT value_column)" do
      expect(TypedEAV::Field::Currency.operator_column(:currency_eq)).to eq(:string_value)
      expect(TypedEAV::Field::Currency.value_column).to eq(:decimal_value)
    end

    it "every other supported operator routes to :decimal_value (the value_column)" do
      non_currency_eq_ops = TypedEAV::Field::Currency.supported_operators - [:currency_eq]
      non_currency_eq_ops.each do |op|
        actual = TypedEAV::Field::Currency.operator_column(op)
        expect(actual).to eq(:decimal_value),
                          "Currency.operator_column(#{op.inspect}) returned #{actual.inspect}, " \
                          "expected :decimal_value"
      end
    end
  end
end

RSpec.describe "Field type supported operators" do
  it "Integer supports numeric operators" do
    ops = TypedEAV::Field::Integer.supported_operators
    expect(ops).to include(:eq, :gt, :lt, :gteq, :lteq, :between)
  end

  it "Boolean supports only eq and null checks" do
    ops = TypedEAV::Field::Boolean.supported_operators
    expect(ops).to eq(%i[eq is_null is_not_null])
  end

  it "Text supports string operators" do
    ops = TypedEAV::Field::Text.supported_operators
    expect(ops).to include(:contains, :starts_with, :ends_with)
  end

  it "Select supports eq/not_eq and null" do
    ops = TypedEAV::Field::Select.supported_operators
    expect(ops).to eq(%i[eq not_eq is_null is_not_null])
  end

  it "MultiSelect supports array operators" do
    ops = TypedEAV::Field::MultiSelect.supported_operators
    expect(ops).to include(:any_eq, :all_eq)
  end

  it "Currency has the explicit operator set (Phase 5)" do
    # Explicit narrowing — does NOT inherit string-search operators
    # (:contains/:starts_with/:ends_with) from decimal_value's default
    # since those don't apply to amount-numeric or currency-code searches.
    # :currency_eq is registered ONLY on this class.
    expect(TypedEAV::Field::Currency.supported_operators).to match_array(
      %i[eq gt lt gteq lteq between currency_eq is_null is_not_null],
    )
  end

  it "Percentage inherits Decimal's operator set (Phase 5)" do
    expect(TypedEAV::Field::Percentage.supported_operators).to eq(
      TypedEAV::Field::Decimal.supported_operators,
    )
  end

  it "Image has the explicit operator set [:eq, :is_null, :is_not_null] (Phase 5 plan 03)" do
    # Explicit narrowing — signed_id strings don't support :contains,
    # :starts_with, :ends_with, or numeric/range operators. Presence
    # checks via :is_null / :is_not_null are the canonical
    # "does this entity have an attachment?" query.
    expect(TypedEAV::Field::Image.supported_operators).to eq(%i[eq is_null is_not_null])
  end

  it "File has the same explicit operator set as Image (Phase 5 plan 03)" do
    expect(TypedEAV::Field::File.supported_operators).to eq(%i[eq is_null is_not_null])
  end
end

RSpec.describe "Field type casting" do
  describe TypedEAV::Field::Integer do
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

  describe TypedEAV::Field::Decimal do
    let(:field) { build(:decimal_field) }

    it "casts strings to BigDecimal" do
      expect(field.cast("19.99").first).to eq(BigDecimal("19.99"))
    end
  end

  describe TypedEAV::Field::Boolean do
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

  describe TypedEAV::Field::Date do
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

  describe TypedEAV::Field::Email do
    let(:field) { build(:email_typed_eav) }

    it "downcases and strips" do
      expect(field.cast("  USER@Example.COM  ").first).to eq("user@example.com")
    end
  end

  describe TypedEAV::Field::IntegerArray do
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

  describe TypedEAV::Field::Select do
    it "reports as optionable" do
      expect(build(:select_field)).to be_optionable
    end

    it "reports as not array" do
      expect(build(:select_field)).not_to be_array_field
    end
  end

  describe TypedEAV::Field::MultiSelect do
    it "reports as optionable and array" do
      field = build(:multi_select_field)
      expect(field).to be_optionable
      expect(field).to be_array_field
    end
  end

  describe TypedEAV::Field::Currency do
    let(:field) { build(:currency_field) }

    it "casts a full hash to {amount: BigDecimal, currency: String}" do
      casted, invalid = field.cast({ amount: "99.99", currency: "USD" })
      expect(casted).to eq(amount: BigDecimal("99.99"), currency: "USD")
      expect(invalid).to be(false)
    end

    it "applies default_currency when amount given without currency" do
      casted, invalid = field.cast({ amount: "10" })
      expect(casted).to eq(amount: BigDecimal("10"), currency: "USD")
      expect(invalid).to be(false)
    end

    it "casts nil to [nil, false]" do
      expect(field.cast(nil)).to eq([nil, false])
    end

    it "casts empty hash to [nil, false]" do
      expect(field.cast({})).to eq([nil, false])
    end

    it "marks bare Numeric input as invalid" do
      expect(field.cast(99.99)).to eq([nil, true])
    end

    it "marks bare String input as invalid" do
      expect(field.cast("99.99")).to eq([nil, true])
    end

    it "marks unparseable amount as invalid" do
      expect(field.cast({ amount: "abc", currency: "USD" })).to eq([nil, true])
    end

    it "rejects non-3-letter currency code" do
      expect(field.cast({ amount: "10", currency: "DOLLARS" })).to eq([nil, true])
    end

    it "uppercases currency code" do
      casted, = field.cast({ amount: "10", currency: "usd" })
      expect(casted[:currency]).to eq("USD")
    end

    it "accepts string-keyed hash" do
      casted, invalid = field.cast({ "amount" => "5.00", "currency" => "EUR" })
      expect(casted).to eq(amount: BigDecimal("5.00"), currency: "EUR")
      expect(invalid).to be(false)
    end
  end

  describe TypedEAV::Field::Percentage do
    let(:field) { build(:percentage_field) }

    it "round-trips 0.75 as BigDecimal via Decimal#cast" do
      casted, invalid = field.cast("0.75")
      expect(casted).to eq(BigDecimal("0.75"))
      expect(invalid).to be(false)
    end

    it "casts nil to [nil, false]" do
      expect(field.cast(nil)).to eq([nil, false])
    end
  end

  # Phase 5 plan 03: Image and File share the same cast contract — nil/
  # blank returns [nil, false]; String passthrough returns [raw, false]
  # (treated as a signed_id); ActiveStorage::Blob returns [signed_id,
  # false]; everything else (IO, File, Tempfile, Hash) returns [nil, true].
  # The dummy app loads Active Storage via `require "rails/all"`, so
  # cast does NOT raise here — the unloaded-path raise is covered in
  # active_storage_soft_detect_spec.rb.
  describe TypedEAV::Field::Image do
    let(:field) { build(:image_field) }

    it "casts nil to [nil, false]" do
      expect(field.cast(nil)).to eq([nil, false])
    end

    it "casts blank String to [nil, false]" do
      expect(field.cast("")).to eq([nil, false])
    end

    it "passes a String through as a signed_id" do
      expect(field.cast("some_signed_id_str")).to eq(["some_signed_id_str", false])
    end

    it "extracts signed_id from an ActiveStorage::Blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("img"),
        filename: "img.png",
        content_type: "image/png",
      )
      expect(field.cast(blob)).to eq([blob.signed_id, false])
    end

    it "marks a StringIO as invalid" do
      expect(field.cast(StringIO.new("x"))).to eq([nil, true])
    end

    it "marks a Hash as invalid" do
      expect(field.cast({ raw: "data" })).to eq([nil, true])
    end
  end

  describe TypedEAV::Field::File do
    let(:field) { build(:file_field) }

    it "casts nil to [nil, false]" do
      expect(field.cast(nil)).to eq([nil, false])
    end

    it "passes a String through as a signed_id" do
      expect(field.cast("some_signed_id_str")).to eq(["some_signed_id_str", false])
    end

    it "extracts signed_id from an ActiveStorage::Blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("doc"),
        filename: "doc.pdf",
        content_type: "application/pdf",
      )
      expect(field.cast(blob)).to eq([blob.signed_id, false])
    end

    it "marks a StringIO as invalid" do
      expect(field.cast(StringIO.new("x"))).to eq([nil, true])
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
    expect(TypedEAV::Field::MultiSelect.new.field_type_name).to eq("multi_select")
  end

  it "returns underscore name for IntegerArray" do
    expect(TypedEAV::Field::IntegerArray.new.field_type_name).to eq("integer_array")
  end

  it "returns underscore name for LongText" do
    expect(TypedEAV::Field::LongText.new.field_type_name).to eq("long_text")
  end

  it "returns underscore name for DateTime" do
    expect(TypedEAV::Field::DateTime.new.field_type_name).to eq("date_time")
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
     email_typed_eav url_field color_field json_field
     currency_field percentage_field
     image_field file_field].each do |factory_name|
    it "#{factory_name} returns nil" do
      field = build(factory_name)
      expect(field.cast(nil).first).to be_nil
    end
  end
end

RSpec.describe "Supported operators for all field types" do
  it "Decimal supports numeric operators" do
    expect(TypedEAV::Field::Decimal.supported_operators).to include(:eq, :gt, :between)
  end

  it "Date supports comparison operators" do
    expect(TypedEAV::Field::Date.supported_operators).to include(:eq, :gt, :between)
  end

  it "DateTime supports comparison operators" do
    expect(TypedEAV::Field::DateTime.supported_operators).to include(:eq, :gt, :between)
  end

  it "LongText supports string operators" do
    expect(TypedEAV::Field::LongText.supported_operators).to include(:contains, :starts_with)
  end

  it "Color supports only eq/not_eq/null" do
    expect(TypedEAV::Field::Color.supported_operators).to eq(%i[eq not_eq is_null is_not_null])
  end

  it "Json supports only null operators" do
    expect(TypedEAV::Field::Json.supported_operators).to eq(%i[is_null is_not_null])
  end

  it "IntegerArray supports array operators" do
    expect(TypedEAV::Field::IntegerArray.supported_operators).to include(:any_eq, :all_eq)
  end

  it "DecimalArray supports array operators" do
    expect(TypedEAV::Field::DecimalArray.supported_operators).to include(:any_eq, :all_eq)
  end

  it "TextArray supports JSONB array containment operators but not :contains" do
    # :contains previously mapped to Arel `matches` (SQL LIKE), which is
    # invalid against jsonb. Element containment is expressed via :any_eq /
    # :all_eq, which map to the JSONB `@>` operator.
    ops = TypedEAV::Field::TextArray.supported_operators
    expect(ops).to include(:any_eq, :all_eq)
    expect(ops).not_to include(:contains)
  end

  it "DateArray supports array operators" do
    expect(TypedEAV::Field::DateArray.supported_operators).to include(:any_eq)
  end

  it "Currency supports the explicit Phase-5 set including :currency_eq" do
    ops = TypedEAV::Field::Currency.supported_operators
    expect(ops).to include(:eq, :gt, :lt, :gteq, :lteq, :between, :currency_eq, :is_null, :is_not_null)
    # :currency_eq is registered ONLY on Currency.
    expect(TypedEAV::Field::Decimal.supported_operators).not_to include(:currency_eq)
    expect(TypedEAV::Field::Text.supported_operators).not_to include(:currency_eq)
  end

  it "Percentage inherits the Decimal operator set unchanged" do
    expect(TypedEAV::Field::Percentage.supported_operators).to eq(TypedEAV::Field::Decimal.supported_operators)
  end

  it "Image supports only :eq, :is_null, :is_not_null (Phase 5 plan 03)" do
    expect(TypedEAV::Field::Image.supported_operators).to eq(%i[eq is_null is_not_null])
  end

  it "File supports only :eq, :is_null, :is_not_null (Phase 5 plan 03)" do
    expect(TypedEAV::Field::File.supported_operators).to eq(%i[eq is_null is_not_null])
  end
end

RSpec.describe TypedEAV::ColumnMapping do
  it "raises NotImplementedError for undeclared value_column" do
    klass = Class.new(TypedEAV::Field::Base) do
      self.table_name = "typed_eav_fields"
    end
    expect { klass.value_column }.to raise_error(NotImplementedError)
  end
end

# Phase 02: cascade-policy validator. Inclusion narrows `field_dependent` to
# the closed set the dispatch hook understands; default "destroy" matches
# v0.1.0 behavior so omitting the kwarg never surprises a v0.1.0 caller.
# Cascade *behavior* (the dispatch itself) is covered in
# spec/lib/typed_eav/field_cascade_spec.rb — this block only asserts the
# validation contract.
#
# String description on the describe is intentional: the file already has
# an earlier `RSpec.describe TypedEAV::Field::Base` block (line 5). The
# string disambiguates them per RSpec/RepeatedExampleGroupDescription
# without forcing a wholesale restructure of the existing 540 lines.
RSpec.describe TypedEAV::Field::Base, "#field_dependent", type: :model do
  describe "field_dependent validation" do
    it "is valid for each of the three allowed values" do
      %w[destroy nullify restrict_with_error].each do |policy|
        f = build(:text_field, field_dependent: policy)
        expect(f).to be_valid, "expected #{policy} to be valid (errors: #{f.errors.full_messages})"
      end
    end

    it "is invalid for an unknown string" do
      f = build(:text_field, field_dependent: "bogus")
      expect(f).not_to be_valid
      expect(f.errors[:field_dependent].join).to match(/destroy.*nullify.*restrict_with_error/)
    end

    it "defaults to 'destroy' from the DB when omitted" do
      f = create(:text_field, name: "default_fd")
      expect(f.field_dependent).to eq("destroy")
    end
  end
end

# Phase 02: partition-aware ordering helpers (move_higher / move_lower /
# move_to_top / move_to_bottom / insert_at). These tests are the
# authoritative algorithm spec — Section's mirror spec is lighter because
# the implementations are byte-equivalent (inline-duplicated per Phase 01
# precedent).
#
# Describe-by-string (rather than `RSpec.describe TypedEAV::Field::Base, …`)
# avoids RSpec/RepeatedExampleGroupDescription against the earlier
# class-level describe blocks at the top of this file, and it sidesteps
# RSpec/DescribeMethod which expects a `#instance_method` or
# `.class_method` second argument when a class is passed.
RSpec.describe "TypedEAV::Field::Base ordering helpers", type: :model do
  # Helper to build a stable partition of N text fields with explicit
  # sort_order 1..N under a unique entity_type so each example sees an
  # isolated partition (Contact entity_type is shared with many other
  # specs in this file, and registry-based validations would otherwise
  # interfere).
  def make_partition(entity_type:, scope: nil, parent_scope: nil, count: 3, prefix: "ord")
    Array.new(count) do |i|
      create(
        :text_field,
        name: "#{prefix}_#{i + 1}",
        entity_type: entity_type,
        scope: scope,
        parent_scope: parent_scope,
        sort_order: i + 1,
      )
    end
  end

  def partition_orders(entity_type:, scope: nil, parent_scope: nil)
    TypedEAV::Field::Base
      .for_entity(entity_type, scope: scope, parent_scope: parent_scope)
      .order(:sort_order, :name)
      .pluck(:name, :sort_order)
  end

  describe "#move_higher" do
    it "swaps the middle item with the one above" do
      f1, f2, f3 = make_partition(entity_type: "OrdHigher1", count: 3)

      f2.move_higher

      expect(partition_orders(entity_type: "OrdHigher1")).to eq(
        [["ord_2", 1], ["ord_1", 2], ["ord_3", 3]],
      )
      expect([f1, f2, f3].map { |r| r.reload.sort_order }).to eq([2, 1, 3])
    end

    it "is a no-op at the top boundary" do
      f1, _f2, _f3 = make_partition(entity_type: "OrdHigher2", count: 3)
      original = partition_orders(entity_type: "OrdHigher2")

      f1.move_higher

      expect(partition_orders(entity_type: "OrdHigher2")).to eq(original)
    end
  end

  describe "#move_lower" do
    it "swaps the middle item with the one below" do
      _f1, f2, _f3 = make_partition(entity_type: "OrdLower1", count: 3)

      f2.move_lower

      expect(partition_orders(entity_type: "OrdLower1")).to eq(
        [["ord_1", 1], ["ord_3", 2], ["ord_2", 3]],
      )
    end

    it "is a no-op at the bottom boundary" do
      _f1, _f2, f3 = make_partition(entity_type: "OrdLower2", count: 3)
      original = partition_orders(entity_type: "OrdLower2")

      f3.move_lower

      expect(partition_orders(entity_type: "OrdLower2")).to eq(original)
    end
  end

  describe "#move_to_top" do
    it "moves the bottom item to position 1 and normalizes the rest" do
      _f1, _f2, f3 = make_partition(entity_type: "OrdTop1", count: 3)

      f3.move_to_top

      expect(partition_orders(entity_type: "OrdTop1")).to eq(
        [["ord_3", 1], ["ord_1", 2], ["ord_2", 3]],
      )
    end
  end

  describe "#move_to_bottom" do
    it "moves the top item to the last position and normalizes the rest" do
      f1, _f2, _f3 = make_partition(entity_type: "OrdBottom1", count: 3)

      f1.move_to_bottom

      expect(partition_orders(entity_type: "OrdBottom1")).to eq(
        [["ord_2", 1], ["ord_3", 2], ["ord_1", 3]],
      )
    end
  end

  describe "#insert_at" do
    it "clamps n=0 (and any non-positive value) to position 1" do
      _f1, _f2, f3 = make_partition(entity_type: "OrdInsert1", count: 3)

      f3.insert_at(0)

      expect(partition_orders(entity_type: "OrdInsert1").first).to eq(["ord_3", 1])
    end

    it "clamps n above the partition size to the last position" do
      f1, _f2, _f3 = make_partition(entity_type: "OrdInsert2", count: 3)

      f1.insert_at(999)

      expect(partition_orders(entity_type: "OrdInsert2").last).to eq(["ord_1", 3])
    end

    it "places the record at the requested 1-based position" do
      _f1, _f2, _f3, _f4, f5 = make_partition(entity_type: "OrdInsert3", count: 5)

      f5.insert_at(2)

      expect(partition_orders(entity_type: "OrdInsert3")).to eq(
        [["ord_1", 1], ["ord_5", 2], ["ord_2", 3], ["ord_3", 4], ["ord_4", 5]],
      )
    end
  end

  describe "partition isolation" do
    it "does not affect a different scope partition" do
      t1_fields = make_partition(entity_type: "OrdIsoScope", scope: "t1", count: 3, prefix: "t1")
      t2_fields = make_partition(entity_type: "OrdIsoScope", scope: "t2", count: 3, prefix: "t2")
      t2_before = t2_fields.map { |f| [f.name, f.sort_order] }

      t1_fields.first.move_to_bottom

      expect(partition_orders(entity_type: "OrdIsoScope", scope: "t2")).to eq(t2_before)
    end

    it "does not affect a different parent_scope partition" do
      w1_fields = make_partition(
        entity_type: "OrdIsoParent",
        scope: "t1",
        parent_scope: "w1",
        count: 3,
        prefix: "w1",
      )
      w2_fields = make_partition(
        entity_type: "OrdIsoParent",
        scope: "t1",
        parent_scope: "w2",
        count: 3,
        prefix: "w2",
      )
      w2_before = w2_fields.map { |f| [f.name, f.sort_order] }

      w1_fields.first.move_to_bottom

      expect(partition_orders(entity_type: "OrdIsoParent", scope: "t1", parent_scope: "w2")).to eq(w2_before)
    end
  end

  describe "nil sort_order normalization" do
    it "places nil-sort_order rows after positioned rows and assigns 1..N" do
      f1 = create(:text_field, name: "nil_a", entity_type: "OrdNilNorm", sort_order: nil)
      f2 = create(:text_field, name: "nil_b", entity_type: "OrdNilNorm", sort_order: nil)
      f3 = create(:text_field, name: "nil_c", entity_type: "OrdNilNorm", sort_order: nil)

      # Any move helper triggers normalization of the partition.
      f1.move_higher

      orders = TypedEAV::Field::Base
               .for_entity("OrdNilNorm")
               .pluck(:sort_order)
               .sort
      expect(orders).to eq([1, 2, 3])
      [f1, f2, f3].each { |f| expect(f.reload.sort_order).to be_between(1, 3) }
    end
  end

  describe "SQL emission" do
    it "issues a partition-level SELECT ... FOR UPDATE on typed_eav_fields" do
      f1, _f2, _f3 = make_partition(entity_type: "OrdSqlEmit", count: 3)

      queries = []
      callback = ->(_, _, _, _, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        f1.move_to_bottom
      end

      lock_query = queries.find { |q| q.include?("typed_eav_fields") && q.match?(/FOR UPDATE/i) }
      expect(lock_query).not_to be_nil,
                                "expected a SELECT ... FOR UPDATE on typed_eav_fields, got: #{queries.inspect}"
    end
  end

  # Partition-level concurrency: load-bearing race-safety test. With the
  # canonical partition-level FOR UPDATE lock acquired in :id order, two
  # threads moving DIFFERENT records in the SAME partition serialize on
  # the lock acquisition and produce a consistent, normalized result.
  # If the implementation regressed to per-record `with_lock`, both threads
  # would pass their per-row locks and race on normalization — this test
  # would then fail with duplicated or missing sort_order values.
  #
  # `use_transactional_tests = false` is required: each thread checks out
  # its own AR connection from the pool, and connections cannot see a
  # parent connection's open transaction. Without this, the threads would
  # see an empty `typed_eav_fields` table and the moves would be no-ops.
  context "with concurrent moves on the same partition", :concurrency do
    self.use_transactional_tests = false

    after do
      TypedEAV::Field::Base.where(entity_type: "OrdConcur").delete_all
    end

    it "two threads moving different records yield a normalized partition with no lost or duplicated rows" do
      fields = Array.new(5) do |i|
        create(
          :text_field,
          name: "concur_#{i + 1}",
          entity_type: "OrdConcur",
          scope: "t1",
          sort_order: i + 1,
        )
      end
      original_ids = fields.map(&:id).sort

      threads = []
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          fields.first.move_to_bottom
        end
      end
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          fields.last.move_to_top
        end
      end
      threads.each(&:join)

      final = TypedEAV::Field::Base.for_entity("OrdConcur", scope: "t1").pluck(:id, :sort_order)

      # All rows still present (no row lost during the race)
      expect(final.map(&:first).sort).to eq(original_ids)

      # Sort orders are exactly 1..5, no duplicates, no nils
      expect(final.map(&:last).sort).to eq([1, 2, 3, 4, 5])
    end
  end
end

# Phase 02: partition-aware default-value backfill. Forms the backward half
# of the default-value pipeline (the forward half — UNSET_VALUE-driven
# population on non-form Value creation — landed in plan 02-03). The two
# halves are intentionally adjacent in scope (forward + backward of the
# same pipeline) but are sequenced into different waves because they touch
# different files and the backfill block depends on partition and ordering
# infrastructure that lands in waves 1-2.
#
# Describe-by-string avoids RSpec/RepeatedExampleGroupDescription against
# the earlier `RSpec.describe TypedEAV::Field::Base` blocks at the top of
# this file.
RSpec.describe "TypedEAV::Field::Base#backfill_default!", type: :model do
  describe "no-op safety" do
    it "is a no-op when no default is configured" do
      field = create(:integer_field, name: "no_default", entity_type: "Contact")
      create(:contact)
      expect(field.default_value).to be_nil

      expect { field.backfill_default! }.not_to change(TypedEAV::Value, :count)
    end
  end

  describe "fill missing rows" do
    it "creates a Value row with the default for each entity in the partition" do
      field = create(:integer_field, name: "bf_fill", entity_type: "Contact",
                                     default_value_meta: { "v" => 42 })
      contacts = Array.new(3) { create(:contact) }

      expect { field.backfill_default! }.to change { TypedEAV::Value.where(field_id: field.id).count }.from(0).to(3)

      contacts.each do |contact|
        value = TypedEAV::Value.find_by!(entity: contact, field_id: field.id)
        expect(value.integer_value).to eq(42)
      end
    end
  end

  describe "skip rule for non-nil typed values" do
    it "does not overwrite entities that already have a non-nil typed value" do
      field = create(:integer_field, name: "bf_skip", entity_type: "Contact",
                                     default_value_meta: { "v" => 42 })
      contact_a, contact_b, contact_c = Array.new(3) { create(:contact) }

      # Pre-existing non-nil row for contact_a — must NOT be overwritten.
      TypedEAV::Value.create!(entity: contact_a, field: field, value: 99)

      field.backfill_default!

      expect(TypedEAV::Value.find_by!(entity: contact_a, field_id: field.id).integer_value).to eq(99)
      expect(TypedEAV::Value.find_by!(entity: contact_b, field_id: field.id).integer_value).to eq(42)
      expect(TypedEAV::Value.find_by!(entity: contact_c, field_id: field.id).integer_value).to eq(42)
    end
  end

  describe "update existing nil typed values" do
    it "updates Value rows whose typed column is nil to the default" do
      field = create(:integer_field, name: "bf_nilupd", entity_type: "Contact",
                                     default_value_meta: { "v" => 42 })
      contact = create(:contact)

      # Plan 02-03's UNSET_VALUE sentinel lets explicit `value: nil` create a
      # row whose typed column is nil — exactly the candidate the skip rule
      # deliberately allows backfill to fix.
      TypedEAV::Value.create!(entity: contact, field: field, value: nil)
      pre = TypedEAV::Value.find_by!(entity: contact, field_id: field.id)
      expect(pre.integer_value).to be_nil

      field.backfill_default!

      expect(pre.reload.integer_value).to eq(42)
    end
  end

  describe "idempotent re-run" do
    it "produces no new Value rows and no changes to existing rows" do
      field = create(:integer_field, name: "bf_idemp", entity_type: "Contact",
                                     default_value_meta: { "v" => 42 })
      Array.new(3) { create(:contact) }
      field.backfill_default!

      pre_snapshot = TypedEAV::Value.where(field_id: field.id).pluck(:id, :integer_value, :updated_at)

      expect { field.backfill_default! }.not_to(change { TypedEAV::Value.where(field_id: field.id).count })

      post_snapshot = TypedEAV::Value.where(field_id: field.id).pluck(:id, :integer_value, :updated_at)
      expect(post_snapshot).to match_array(pre_snapshot)
    end
  end

  describe "partition isolation by scope", :scoping do
    it "creates Values only for entities in the matching scope" do
      field = create(:integer_field, name: "bf_scope", entity_type: "Contact", scope: "t1",
                                     default_value_meta: { "v" => 42 })
      t1_contact = create(:contact, tenant_id: "t1")
      t2_contact = create(:contact, tenant_id: "t2")

      field.backfill_default!

      expect(TypedEAV::Value.where(entity: t1_contact, field_id: field.id).pluck(:integer_value)).to eq([42])
      expect(TypedEAV::Value.where(entity: t2_contact, field_id: field.id)).to be_empty
    end
  end

  describe "partition isolation by parent_scope", :scoping do
    it "creates Values only for entities matching both scope and parent_scope" do
      field = create(:integer_field, name: "bf_pscope", entity_type: "Project", scope: "t1",
                                     parent_scope: "p1", default_value_meta: { "v" => 42 })
      match    = create(:project, tenant_id: "t1", workspace_id: "p1")
      wrong_p  = create(:project, tenant_id: "t1", workspace_id: "p2")
      no_p     = create(:project, tenant_id: "t1", workspace_id: nil)

      field.backfill_default!

      expect(TypedEAV::Value.where(entity: match, field_id: field.id).pluck(:integer_value)).to eq([42])
      expect(TypedEAV::Value.where(entity: wrong_p, field_id: field.id)).to be_empty
      expect(TypedEAV::Value.where(entity: no_p, field_id: field.id)).to be_empty
    end
  end

  describe "global field iterates all entities", :scoping do
    it "creates Values for every entity of entity_type when field.scope is nil" do
      field = create(:integer_field, name: "bf_global", entity_type: "Contact", scope: nil,
                                     default_value_meta: { "v" => 42 })
      a = create(:contact, tenant_id: nil)
      b = create(:contact, tenant_id: "t1")
      c = create(:contact, tenant_id: "t2")

      field.backfill_default!

      [a, b, c].each do |contact|
        expect(TypedEAV::Value.find_by!(entity: contact, field_id: field.id).integer_value).to eq(42)
      end
    end
  end

  describe "value_column lookup works for non-integer types" do
    it "fills string_value for a Text field" do
      field = create(:text_field, name: "bf_text", entity_type: "Contact",
                                  default_value_meta: { "v" => "hello" })
      contacts = Array.new(2) { create(:contact) }

      field.backfill_default!

      contacts.each do |contact|
        value = TypedEAV::Value.find_by!(entity: contact, field_id: field.id)
        expect(value.string_value).to eq("hello")
      end
    end
  end

  describe "per-batch transaction atomicity" do
    # When a batch raises mid-iteration, the WHOLE batch rolls back atomically.
    # All 5 entities fit in one batch (default batch_size 1000), so a raise on
    # the 3rd entity must roll back ALL FIVE — proving the transaction wraps
    # the batch, not the record. Re-running the un-stubbed backfill then
    # commits all 5 — proving recoverability.
    it "rolls back the whole batch on failure and recovers cleanly on re-run" do
      field = create(:integer_field, name: "bf_atomic", entity_type: "Contact",
                                     default_value_meta: { "v" => 42 })
      Array.new(5) { create(:contact) }

      call_count = 0
      original_method = field.method(:backfill_one)
      allow(field).to receive(:backfill_one) do |entity, column|
        call_count += 1
        raise "boom on third entity" if call_count == 3

        original_method.call(entity, column)
      end

      expect { field.backfill_default! }.to raise_error(StandardError, /boom/)

      # Whole batch rolled back: zero Value rows, even though two records had
      # already been backfilled inside the same transaction before the raise.
      expect(TypedEAV::Value.where(field_id: field.id).count).to eq(0)

      # Recovery: un-stub and re-run — all five now backfilled.
      RSpec::Mocks.space.proxy_for(field).reset
      field.backfill_default!
      expect(TypedEAV::Value.where(field_id: field.id).count).to eq(5)
    end
  end
end

# Phase 5: Currency operator_column override is asserted in the BC block
# above; this block is the focused assertion site for the dispatch logic
# in isolation.
RSpec.describe TypedEAV::Field::Currency, ".operator_column" do
  it ":currency_eq routes to :string_value" do
    expect(described_class.operator_column(:currency_eq)).to eq(:string_value)
  end

  it ":eq, :gt, :lt, :gteq, :lteq, :between, :is_null, :is_not_null all route to :decimal_value" do
    %i[eq gt lt gteq lteq between is_null is_not_null].each do |op|
      actual = described_class.operator_column(op)
      expect(actual).to eq(:decimal_value),
                        "Expected Currency.operator_column(#{op.inspect}) -> :decimal_value, got #{actual.inspect}"
    end
  end
end

RSpec.describe TypedEAV::Field::Currency, "#validate_typed_value co-population", type: :model do
  let(:contact) { Contact.create!(name: "Currency Co-pop", tenant_id: nil) }
  # Use a field WITHOUT default_currency so the amount-only case doesn't
  # silently fall back. The default_currency-fallback path is documented
  # as "applies ONLY when the hash has an amount but no currency" — when
  # set, an amount-only hash IS the documented fallback case (and is
  # therefore co-populated after cast). We test the unhappy path here.
  let(:field) { create(:currency_field, name: "co_pop_price", options: {}) }

  it "rejects an amount-only hash when default_currency is not set" do
    value = TypedEAV::Value.new(entity: contact, field: field)
    value.value = { amount: BigDecimal("10"), currency: nil }
    value.valid?
    expect(value.errors[:value]).to include("must have both amount and currency")
  end

  it "rejects a currency-only hash" do
    value = TypedEAV::Value.new(entity: contact, field: field)
    value.value = { amount: nil, currency: "USD" }
    value.valid?
    expect(value.errors[:value]).to include("must have both amount and currency")
  end

  it "accepts a co-populated hash" do
    value = TypedEAV::Value.new(entity: contact, field: field)
    value.value = { amount: BigDecimal("10"), currency: "USD" }
    expect(value).to be_valid
  end

  it "default_currency fallback path: amount-only with default set is co-populated after cast" do
    field_with_default = create(:currency_field, name: "co_pop_with_default") # factory provides default_currency: "USD"
    value = TypedEAV::Value.new(entity: contact, field: field_with_default)
    value.value = { amount: BigDecimal("10") } # no currency key
    expect(value).to be_valid
    expect(value.string_value).to eq("USD")
  end

  it "rejects a currency outside allowed_currencies when set" do
    field.update!(options: field.options.merge(allowed_currencies: %w[USD EUR]))
    value = TypedEAV::Value.new(entity: contact, field: field)
    value.value = { amount: BigDecimal("10"), currency: "GBP" }
    value.valid?
    expect(value.errors[:value]).to include(I18n.t("errors.messages.inclusion"))
  end
end

RSpec.describe TypedEAV::Field::Currency, ".validations (field-level options)", type: :model do
  it "rejects default_currency that is not 3 uppercase letters" do
    field = build(:currency_field, options: { default_currency: "us" })
    expect(field).not_to be_valid
    expect(field.errors[:default_currency]).to be_present
  end

  it "rejects allowed_currencies that is not an Array of 3-letter uppercase codes" do
    field = build(:currency_field, options: { default_currency: "USD", allowed_currencies: %w[USD eur] })
    expect(field).not_to be_valid
    expect(field.errors[:allowed_currencies]).to be_present
  end

  it "accepts well-formed options" do
    field = build(:currency_field, options: { default_currency: "USD", allowed_currencies: %w[USD EUR] })
    expect(field).to be_valid
  end
end

RSpec.describe TypedEAV::Field::Percentage, "#validate_typed_value (0-1 range)", type: :model do
  let(:contact) { Contact.create!(name: "Pct Range", tenant_id: nil) }

  it "accepts 0.5" do
    field = create(:percentage_field, name: "pct_mid")
    value = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("0.5"))
    expect(value).to be_valid
  end

  it "accepts boundary 0" do
    field = create(:percentage_field, name: "pct_low")
    value = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("0"))
    expect(value).to be_valid
  end

  it "accepts boundary 1" do
    field = create(:percentage_field, name: "pct_hi")
    value = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("1"))
    expect(value).to be_valid
  end

  it "rejects 1.5" do
    field = create(:percentage_field, name: "pct_over")
    value = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("1.5"))
    value.valid?
    expect(value.errors[:value]).to include("must be between 0.0 and 1.0")
  end

  it "rejects -0.1" do
    field = create(:percentage_field, name: "pct_under")
    value = TypedEAV::Value.new(entity: contact, field: field, value: BigDecimal("-0.1"))
    value.valid?
    expect(value.errors[:value]).to include("must be between 0.0 and 1.0")
  end
end

RSpec.describe TypedEAV::Field::Percentage, "#format" do
  it "renders display_as: :percent as '75.5%' for 0.755 with decimal_places: 1" do
    field = described_class.new(options: { decimal_places: 1, display_as: :percent })
    expect(field.format(BigDecimal("0.755"))).to eq("75.5%")
  end

  it "renders display_as: :percent default decimal_places: 2 as '75.5%' for 0.755" do
    field = described_class.new(options: { display_as: :percent })
    # 0.755 * 100 = 75.5 → rounded to 2 decimal places = 75.5 (no trailing
    # zeros in BigDecimal#round#to_s).
    expect(field.format(BigDecimal("0.755"))).to eq("75.5%")
  end

  it "renders display_as: :fraction as '0.75'" do
    field = described_class.new(options: { display_as: :fraction })
    expect(field.format(BigDecimal("0.75"))).to eq("0.75")
  end

  it "defaults to :fraction when display_as is unset" do
    field = described_class.new
    expect(field.format(BigDecimal("0.75"))).to eq("0.75")
  end

  it "returns nil for nil input" do
    expect(described_class.new.format(nil)).to be_nil
  end
end

RSpec.describe TypedEAV::Field::Percentage, ".validations (field-level options)", type: :model do
  it "rejects negative decimal_places" do
    field = build(:percentage_field, options: { decimal_places: -1 })
    expect(field).not_to be_valid
    expect(field.errors[:decimal_places]).to be_present
  end

  it "rejects display_as outside :fraction / :percent" do
    field = build(:percentage_field, options: { display_as: :weird })
    expect(field).not_to be_valid
    expect(field.errors[:display_as]).to be_present
  end

  it "accepts display_as: :percent" do
    field = build(:percentage_field, options: { display_as: :percent, decimal_places: 1 })
    expect(field).to be_valid
  end
end

# Phase 5 plan 03: on_image_attached hook firing.
# Asserts the after_commit dispatcher on TypedEAV::Value:
#   1. fires for Field::Image-typed Values when an attachment is added,
#   2. does NOT fire for Field::File-typed Values (image-specific by
#      ROADMAP design),
#   3. does NOT fire for Text/Integer/etc. (non-image fields),
#   4. does NOT fire when on_image_attached is nil (zero overhead).
#
# :event_callbacks snapshots Config.on_image_attached so per-example
# state is restored cleanly. The hook signature is `(value, blob)` — the
# tests record both into a captures array.
RSpec.describe "Config.on_image_attached hook dispatch", :event_callbacks, type: :model do
  let(:contact) { Contact.create!(name: "Hook Test", tenant_id: nil) }
  let(:hook_calls) { [] }

  before do
    TypedEAV.config.on_image_attached = lambda { |value, blob|
      hook_calls << [value.id, blob.filename.to_s, blob.content_type]
    }
  end

  it "fires when an attachment is added to a Field::Image-typed Value" do
    field = create(:image_field, name: "avatar")
    value = TypedEAV::Value.create!(entity: contact, field: field)
    value.attachment.attach(io: StringIO.new("img-data"), filename: "a.png", content_type: "image/png")
    value.update!(string_value: value.attachment.blob.signed_id)

    expect(hook_calls.size).to eq(1)
    expect(hook_calls.last).to eq([value.id, "a.png", "image/png"])
  end

  it "does NOT fire for Field::File attachments" do
    field = create(:file_field, name: "doc")
    value = TypedEAV::Value.create!(entity: contact, field: field)
    value.attachment.attach(io: StringIO.new("doc-data"), filename: "a.pdf", content_type: "application/pdf")
    value.update!(string_value: value.attachment.blob.signed_id)

    expect(hook_calls).to be_empty
  end

  it "does NOT fire for Field::Text-typed Values (regression: every Value gets the macro association)" do
    text_field = create(:text_field, name: "label")
    value = TypedEAV::Value.create!(entity: contact, field: text_field, value: "hello")
    # The :attachment association exists on every Value (declared at
    # engine boot), but for non-Image fields the dispatcher's
    # is_a?(Field::Image) guard short-circuits BEFORE probing
    # attached?. Even attaching directly should not fire the hook.
    value.attachment.attach(io: StringIO.new("img"), filename: "a.png", content_type: "image/png")
    value.update!(string_value: "hello again") # bumps string_value to satisfy saved_change

    expect(hook_calls).to be_empty
  end

  it "does NOT fire when Config.on_image_attached is nil" do
    TypedEAV.config.on_image_attached = nil
    field = create(:image_field, name: "avatar_unset_hook")
    value = TypedEAV::Value.create!(entity: contact, field: field)
    value.attachment.attach(io: StringIO.new("img"), filename: "a.png", content_type: "image/png")
    expect { value.update!(string_value: value.attachment.blob.signed_id) }.not_to raise_error
    expect(hook_calls).to be_empty
  end

  it "isolates hook errors so the after_commit chain does not crash the user save" do
    TypedEAV.config.on_image_attached = ->(_v, _b) { raise "boom" }
    field = create(:image_field, name: "avatar_raise")
    value = TypedEAV::Value.create!(entity: contact, field: field)
    value.attachment.attach(io: StringIO.new("img"), filename: "a.png", content_type: "image/png")
    # The save! call must succeed despite the hook raising — the row is
    # already committed by the time after_commit fires; crashing the
    # caller would corrupt the user's view of the save outcome.
    expect { value.update!(string_value: value.attachment.blob.signed_id) }.not_to raise_error
  end
end
