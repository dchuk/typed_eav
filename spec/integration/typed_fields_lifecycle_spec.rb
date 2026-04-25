# frozen_string_literal: true

require "spec_helper"

RSpec.describe "TypedFields full lifecycle", type: :model do
  describe "entity lifecycle", :unscoped do
    it "creates, assigns, queries, updates, and deletes" do
      # 1. Create field definitions
      create(:integer_field, name: "age", entity_type: "Contact")
      create(:text_field, name: "city", entity_type: "Contact")

      # 2. Create entity and assign values
      contact = create(:contact, name: "Alice")
      contact.typed_fields_attributes = [
        { name: "age", value: 30 },
        { name: "city", value: "Portland" },
      ]
      contact.save!

      # 3. Read back values
      expect(contact.typed_field_value("age")).to eq(30)
      expect(contact.typed_field_value("city")).to eq("Portland")
      expect(contact.typed_fields_hash).to eq({ "age" => 30, "city" => "Portland" })

      # 4. Query
      expect(Contact.with_field("age", :gt, 25)).to include(contact)
      expect(Contact.with_field("city", "Portland")).to include(contact)
      expect(Contact.with_field("age", :lt, 25)).not_to include(contact)

      # 5. Update
      contact.set_typed_field_value("age", 31)
      contact.save!
      contact.reload
      expect(contact.typed_field_value("age")).to eq(31)

      # 6. Delete entity cascades to values
      value_count = contact.typed_values.count
      expect(value_count).to eq(2)
      expect { contact.destroy! }.to change(TypedFields::Value, :count).by(-2)
    end
  end

  describe "multi-field AND query", :unscoped do
    it "filters by multiple fields simultaneously" do
      age_field = create(:integer_field, name: "age", entity_type: "Contact")
      city_field = create(:text_field, name: "city", entity_type: "Contact")

      alice = create(:contact, name: "Alice")
      bob = create(:contact, name: "Bob")
      charlie = create(:contact, name: "Charlie")

      { alice => [30, "Portland"], bob => [25, "Seattle"], charlie => [40, "Portland"] }.each do |c, (age, city)|
        TypedFields::Value.create!(entity: c, field: age_field).tap do |v|
          v.value = age
          v.save!
        end
        TypedFields::Value.create!(entity: c, field: city_field).tap do |v|
          v.value = city
          v.save!
        end
      end

      # Age > 28 AND city = Portland
      results = Contact.where_typed_fields(
        [{ name: "age", op: :gt, value: 28 },
         { name: "city", op: :eq, value: "Portland" }],
      )
      expect(results).to contain_exactly(alice, charlie)
    end
  end

  describe "field definition lifecycle" do
    it "field destroy cascades to values and options" do
      field = create(:select_field, name: "status", entity_type: "Contact")
      contact = create(:contact)
      TypedFields::Value.create!(entity: contact, field: field).tap do |v|
        v.value = "active"
        v.save!
      end

      option_count = field.field_options.count
      expect(option_count).to be > 0

      expect { field.destroy! }
        .to change(TypedFields::Value, :count).by(-1)
        .and change(TypedFields::Option, :count).by(-option_count)
    end
  end

  describe "section lifecycle" do
    it "section destroy nullifies field section_id" do
      section = create(:typed_section, entity_type: "Contact")
      field = create(:text_field, entity_type: "Contact", section: section)
      expect(field.section).to eq(section)

      section.destroy!
      expect(field.reload.section_id).to be_nil
    end
  end

  describe "multi-tenant scoping" do
    it "isolates fields by scope" do
      global = create(:text_field, name: "notes", entity_type: "Contact", scope: nil)
      tenant1 = create(:text_field, name: "dept", entity_type: "Contact", scope: "t1")
      tenant2 = create(:text_field, name: "team", entity_type: "Contact", scope: "t2")

      contact_t1 = create(:contact, tenant_id: "t1")
      defs = contact_t1.typed_field_definitions

      expect(defs).to include(global, tenant1)
      expect(defs).not_to include(tenant2)
    end
  end

  describe "Product with type restrictions" do
    it "only allows specified field types" do
      create(:text_field, name: "desc", entity_type: "Product")
      create(:integer_field, name: "qty", entity_type: "Product")

      product = create(:product)
      product.typed_fields_attributes = [
        { name: "desc", value: "Widget" },
        { name: "qty", value: 10 },
      ]
      product.save!

      expect(product.typed_field_value("desc")).to eq("Widget")
      expect(product.typed_field_value("qty")).to eq(10)
    end
  end

  describe "chaining with ActiveRecord scopes", :unscoped do
    it "works with standard where clauses" do
      field = create(:integer_field, name: "age", entity_type: "Contact")
      alice = create(:contact, name: "Alice")
      bob = create(:contact, name: "Bob")

      TypedFields::Value.create!(entity: alice, field: field).tap do |v|
        v.value = 30
        v.save!
      end
      TypedFields::Value.create!(entity: bob, field: field).tap do |v|
        v.value = 30
        v.save!
      end

      results = Contact.where(name: "Alice").where_typed_fields([{ name: "age", op: :eq, value: 30 }])
      expect(results).to eq([alice])
    end
  end
end
