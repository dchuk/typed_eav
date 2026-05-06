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

  # Two-level partitioned host: declares both `scope_method:` and
  # `parent_scope_method:` (see spec/dummy/app/models/test_models.rb).
  # `tenant_id` and `workspace_id` default to nil so a bare `create(:project)`
  # produces a host with no scope axis active — tests opt in by passing the
  # values explicitly. Mirrors the `:contact` factory's nil-default pattern.
  factory :project do
    sequence(:name) { |n| "Project #{n}" }
    tenant_id { nil }
    workspace_id { nil }
  end

  # ── Field Definitions ──

  factory :text_field, class: "TypedEAV::Field::Text" do
    sequence(:name) { |n| "text_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :long_text_field, class: "TypedEAV::Field::LongText" do
    sequence(:name) { |n| "long_text_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :integer_field, class: "TypedEAV::Field::Integer" do
    sequence(:name) { |n| "integer_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :decimal_field, class: "TypedEAV::Field::Decimal" do
    sequence(:name) { |n| "decimal_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :boolean_field, class: "TypedEAV::Field::Boolean" do
    sequence(:name) { |n| "boolean_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :date_field, class: "TypedEAV::Field::Date" do
    sequence(:name) { |n| "date_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :datetime_field, class: "TypedEAV::Field::DateTime" do
    sequence(:name) { |n| "datetime_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :select_field, class: "TypedEAV::Field::Select" do
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

  factory :multi_select_field, class: "TypedEAV::Field::MultiSelect" do
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

  factory :integer_array_field, class: "TypedEAV::Field::IntegerArray" do
    sequence(:name) { |n| "int_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :text_array_field, class: "TypedEAV::Field::TextArray" do
    sequence(:name) { |n| "text_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :email_typed_eav, class: "TypedEAV::Field::Email" do
    sequence(:name) { |n| "email_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :decimal_array_field, class: "TypedEAV::Field::DecimalArray" do
    sequence(:name) { |n| "decimal_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :date_array_field, class: "TypedEAV::Field::DateArray" do
    sequence(:name) { |n| "date_array_field_#{n}" }
    entity_type { "Contact" }
    options { {} }
  end

  factory :url_field, class: "TypedEAV::Field::Url" do
    sequence(:name) { |n| "url_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :color_field, class: "TypedEAV::Field::Color" do
    sequence(:name) { |n| "color_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :json_field, class: "TypedEAV::Field::Json" do
    sequence(:name) { |n| "json_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :currency_field, class: "TypedEAV::Field::Currency" do
    sequence(:name) { |n| "currency_field_#{n}" }
    entity_type { "Contact" }
    options { { default_currency: "USD" } }
  end

  factory :percentage_field, class: "TypedEAV::Field::Percentage" do
    sequence(:name) { |n| "percentage_field_#{n}" }
    entity_type { "Contact" }
    options { { decimal_places: 2, display_as: :fraction } }
  end

  # Phase 5 Active Storage-backed field types. Both store the attached
  # blob's signed_id in string_value; the :attachment has_one_attached
  # association on TypedEAV::Value is registered at engine boot (when
  # ActiveStorage::Blob is defined; soft-detect per Gating Decision 1).
  # Factories don't override value_column — the field class declares it.
  factory :image_field, class: "TypedEAV::Field::Image" do
    sequence(:name) { |n| "image_field_#{n}" }
    entity_type { "Contact" }
  end

  factory :file_field, class: "TypedEAV::Field::File" do
    sequence(:name) { |n| "file_field_#{n}" }
    entity_type { "Contact" }
  end

  # Phase 5 plan 04: Reference field type. FK stored in integer_value;
  # default target_entity_type points at "Contact" (the dummy app's
  # primary scoped model). target_scope is unset by default — tests
  # configure it when exercising Gating Decision 2 paths.
  factory :reference_field, class: "TypedEAV::Field::Reference" do
    sequence(:name) { |n| "reference_field_#{n}" }
    entity_type { "Contact" }
    options { { target_entity_type: "Contact" } }
  end

  # ── Values ──

  factory :typed_value, class: "TypedEAV::Value" do
    association :entity, factory: :contact
    association :field, factory: :text_field
  end

  # ── Sections ──

  factory :typed_section, class: "TypedEAV::Section" do
    sequence(:name) { |n| "Section #{n}" }
    sequence(:code) { |n| "section_#{n}" }
    entity_type { "Contact" }
  end

  # ── Options ──

  factory :typed_option, class: "TypedEAV::Option" do
    association :field, factory: :select_field
    sequence(:label) { |n| "Option #{n}" }
    sequence(:value) { |n| "option_#{n}" }
  end
end
