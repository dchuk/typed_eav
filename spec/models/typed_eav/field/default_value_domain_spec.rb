# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Field default value domain validation", type: :model do
  def invalid_default(field, value)
    field.default_value = value
    field
  end

  it "applies numeric bounds and Percentage's 0..1 domain" do
    expect(invalid_default(build(:integer_field, options: { min: 2, max: 5 }), 6)).not_to be_valid
    expect(invalid_default(build(:percentage_field), 1.5)).not_to be_valid
  end

  it "remaps domain errors to default_value without leaking value errors" do
    field = invalid_default(build(:integer_field, options: { min: 2 }), 1)

    expect(field).not_to be_valid
    expect(field.errors[:default_value]).to be_present
    expect(field.errors[:value]).to be_empty
  end

  it "accepts representative valid scalar and array defaults" do
    expect(invalid_default(build(:integer_field, options: { min: 2, max: 5 }), 3)).to be_valid
    expect(invalid_default(build(:text_field, options: { pattern: "\\Aok\\z" }), "ok")).to be_valid
    integer_array = build(:integer_array_field, options: { min_size: 1, max_size: 2, min: 1, max: 5 })
    expect(invalid_default(integer_array, [2])).to be_valid
    currency = build(:currency_field, options: { allowed_currencies: ["USD"] })
    expect(invalid_default(currency, { amount: "12.50", currency: "USD" })).to be_valid
  end

  it "applies text length and pattern rules to Text and LongText" do
    expect(invalid_default(build(:text_field, options: { max_length: 3 }), "abcd")).not_to be_valid
    expect(invalid_default(build(:text_field, options: { pattern: "\\Aok\\z" }), "nope")).not_to be_valid
    expect(invalid_default(build(:long_text_field, options: { max_length: 3 }), "abcd")).not_to be_valid
  end

  it "applies the shared and custom Email and URL validators" do
    expect(invalid_default(build(:email_typed_eav), "not-an-email")).not_to be_valid
    expect(invalid_default(build(:url_field), "ftp://example.test")).not_to be_valid
  end

  it "validates Select and MultiSelect against built option domains" do
    select = build(:select_field)
    select.field_options.build(label: "One", value: "one")
    expect(invalid_default(select, "two")).not_to be_valid

    multi = build(:multi_select_field, options: { min_size: 1, max_size: 2 })
    multi.field_options.build(label: "One", value: "one")
    multi.field_options.build(label: "Two", value: "two")
    expect(invalid_default(multi, %w[one three])).not_to be_valid
  end

  it "does not reject an unresolved unsaved optionable domain" do
    field = build(:select_field)
    field.default_value = "provided-later"

    expect(field).to be_valid
  end

  it "accepts built and persisted option domains" do
    built = build(:select_field)
    built.field_options.build(label: "One", value: "one")
    built.default_value = "one"
    expect(built).to be_valid

    persisted = create(:select_field)
    create(:typed_option, field: persisted, label: "One", value: "one")
    persisted.default_value = "one"
    expect(persisted).to be_valid
    persisted.default_value = "two"
    expect(persisted).not_to be_valid
    expect(persisted.errors[:default_value]).to be_present
  end

  it "validates array size and integer element bounds" do
    integer_array = build(:integer_array_field, options: { min_size: 2, max_size: 3, min: 1, max: 5 })
    expect(invalid_default(integer_array, [0, 2])).not_to be_valid
    decimal_array = build(:decimal_array_field, options: { max_size: 1 })
    expect(invalid_default(decimal_array, [BigDecimal("1"), BigDecimal("2")])).not_to be_valid
    expect(invalid_default(build(:date_array_field, options: { min_size: 2 }), [Date.new(2026, 1, 1)])).not_to be_valid
    expect(invalid_default(build(:text_array_field, options: { max_size: 1 }), %w[a b])).not_to be_valid
  end

  it "requires complete Currency defaults and enforces allowed currencies" do
    field = build(:currency_field, options: { allowed_currencies: ["USD"] })
    expect(invalid_default(field, { amount: "12.50" })).not_to be_valid

    field = build(:currency_field, options: { allowed_currencies: ["USD"] })
    expect(invalid_default(field, { amount: "12.50", currency: "EUR" })).not_to be_valid
  end

  it "preserves cast-invalid errors before domain validation" do
    field = build(:integer_field)
    field.default_value = "not-an-integer"

    expect(field).not_to be_valid
    expect(field.errors[:default_value]).to include("is not valid for this field type")
  end
end
