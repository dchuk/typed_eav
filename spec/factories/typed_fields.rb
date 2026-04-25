# frozen_string_literal: true

FactoryBot.define do
  factory :contact do
    sequence(:name) { |n| "Contact #{n}" }
    email { "#{name.parameterize}@example.com" }
    tenant_id { nil }
  end

  factory :product do
    sequence(:title) { |n| "Product #{n}" }
    price { 19.99 }
  end

  # ── Field Definitions ──

  factory :text_field, class: "TypedFields::Field::Text" do
    sequence(:name) { |n| "text_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :long_text_field, class: "TypedFields::Field::LongText" do
    sequence(:name) { |n| "long_text_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :integer_field, class: "TypedFields::Field::Integer" do
    sequence(:name) { |n| "integer_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :decimal_field, class: "TypedFields::Field::Decimal" do
    sequence(:name) { |n| "decimal_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :boolean_field, class: "TypedFields::Field::Boolean" do
    sequence(:name) { |n| "boolean_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :date_field, class: "TypedFields::Field::Date" do
    sequence(:name) { |n| "date_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :datetime_field, class: "TypedFields::Field::DateTime" do
    sequence(:name) { |n| "datetime_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :select_field, class: "TypedFields::Field::Select" do
    sequence(:name) { |n| "select_field_#{n}" }
    entity_type { "Contact" }

    after(:create) do |field|
      field.field_options.create!([
                                    { label: "Active",   value: "active",   sort_order: 1 },
                                    { label: "Inactive", value: "inactive", sort_order: 2 },
                                    { label: "Lead",     value: "lead",     sort_order: 3 },
                                  ])
    end
  end

  factory :multi_select_field, class: "TypedFields::Field::MultiSelect" do
    sequence(:name) { |n| "multi_select_field_#{n}" }
    entity_type { "Contact" }

    after(:create) do |field|
      field.field_options.create!([
                                    { label: "VIP",      value: "vip",      sort_order: 1 },
                                    { label: "Partner",  value: "partner",   sort_order: 2 },
                                    { label: "Prospect", value: "prospect",  sort_order: 3 },
                                  ])
    end
  end

  factory :integer_array_field, class: "TypedFields::Field::IntegerArray" do
    sequence(:name) { |n| "int_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :text_array_field, class: "TypedFields::Field::TextArray" do
    sequence(:name) { |n| "text_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :email_typed_field, class: "TypedFields::Field::Email" do
    sequence(:name) { |n| "email_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :decimal_array_field, class: "TypedFields::Field::DecimalArray" do
    sequence(:name) { |n| "decimal_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :date_array_field, class: "TypedFields::Field::DateArray" do
    sequence(:name) { |n| "date_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :url_field, class: "TypedFields::Field::Url" do
    sequence(:name) { |n| "url_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :color_field, class: "TypedFields::Field::Color" do
    sequence(:name) { |n| "color_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :json_field, class: "TypedFields::Field::Json" do
    sequence(:name) { |n| "json_field_#{n}" }
    entity_type { "Contact" }
  end

  # ── Values ──

  factory :typed_value, class: "TypedFields::Value" do
    association :entity, factory: :contact
    association :field, factory: :text_field
  end

  # ── Sections ──

  factory :typed_section, class: "TypedFields::Section" do
    sequence(:name) { |n| "Section #{n}" }
    sequence(:code) { |n| "section_#{n}" }
    entity_type { "Contact" }
  end

  # ── Options ──

  factory :typed_option, class: "TypedFields::Option" do
    association :field, factory: :select_field
    sequence(:label) { |n| "Option #{n}" }
    sequence(:value) { |n| "option_#{n}" }
  end
end
