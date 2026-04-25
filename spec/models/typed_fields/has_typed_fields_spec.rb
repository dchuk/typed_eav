# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedFields::HasTypedFields, type: :model do
  describe "has_typed_fields class method" do
    it "adds typed_values association" do
      expect(Contact.reflect_on_association(:typed_values)).to be_present
      expect(Contact.reflect_on_association(:typed_values).macro).to eq(:has_many)
    end

    it "registers in the global registry" do
      expect(TypedFields.registry.entity_types).to include("Contact")
    end

    it "stores scope_method" do
      expect(Contact.typed_fields_scope_method).to eq(:tenant_id)
    end

    it "stores type restrictions normalized to strings" do
      # Normalized to strings once at registration so hot paths (type-
      # restriction validation, `typed_fields_attributes=`) don't re-map.
      expect(Product.allowed_typed_field_types).to eq(%w[text integer decimal boolean])
    end
  end

  describe ".typed_field_definitions", :unscoped do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:product_weight) { create(:decimal_field, name: "weight", entity_type: "Product") }

    it "returns only fields for the model's entity type" do
      fields = Contact.typed_field_definitions
      expect(fields).to include(age_field)
      expect(fields).not_to include(product_weight)
    end

    it "includes scoped fields when scope provided" do
      scoped = create(:text_field, name: "dept_note", entity_type: "Contact", scope: "tenant_1")
      global = create(:text_field, name: "global_note", entity_type: "Contact", scope: nil)

      fields = Contact.typed_field_definitions(scope: "tenant_1")
      expect(fields).to include(scoped, global)
    end
  end

  describe ".where_typed_fields", :unscoped do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:city_field) { create(:text_field, name: "city", entity_type: "Contact") }

    let!(:alice) { create(:contact, name: "Alice") }
    let!(:bob) { create(:contact, name: "Bob") }
    let!(:charlie) { create(:contact, name: "Charlie") }

    before do
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
    end

    it "filters by a single field" do
      results = Contact.where_typed_fields([{ name: "age", op: :gt, value: 28 }])
      expect(results).to contain_exactly(alice, charlie)
    end

    it "filters by multiple fields (AND)" do
      results = Contact.where_typed_fields(
        { name: "age", op: :gt, value: 28 },
        { name: "city", op: :eq, value: "Portland" },
      )
      expect(results).to contain_exactly(alice, charlie)
    end

    it "supports compact keys (n, op, v)" do
      results = Contact.where_typed_fields([{ n: "city", op: :contains, v: "port" }])
      expect(results).to contain_exactly(alice, charlie)
    end

    it "defaults to :eq when operator is omitted" do
      results = Contact.where_typed_fields([{ name: "city", value: "Seattle" }])
      expect(results).to eq([bob])
    end

    it "raises ArgumentError for nonexistent field names" do
      expect do
        Contact.where_typed_fields(
          [{ name: "nonexistent", op: :eq, value: "x" }],
        )
      end.to raise_error(ArgumentError, /Unknown typed field/)
    end

    it "chains with standard ActiveRecord scopes" do
      results = Contact.where(name: "Alice").where_typed_fields([{ name: "age", op: :gt, value: 20 }])
      expect(results).to eq([alice])
    end
  end

  describe ".with_field", :unscoped do
    let!(:field) { create(:integer_field, name: "score", entity_type: "Contact") }
    let!(:alice) { create(:contact, name: "Alice") }

    before do
      TypedFields::Value.create!(entity: alice, field: field).tap do |v|
        v.value = 95
        v.save!
      end
    end

    it "short form: with_field(name, value) implies :eq" do
      expect(Contact.with_field("score", 95)).to eq([alice])
    end

    it "full form: with_field(name, :operator, value)" do
      expect(Contact.with_field("score", :gteq, 90)).to eq([alice])
    end
  end

  describe "#initialize_typed_values" do
    let!(:field_a) { create(:text_field, name: "bio", entity_type: "Contact") }
    let(:contact) { create(:contact) }

    before { create(:integer_field, name: "age", entity_type: "Contact") }

    it "builds missing values with defaults" do
      values = contact.initialize_typed_values
      expect(values.size).to eq(2)
      expect(values.map { |v| v.field.name }).to match_array(%w[bio age])
    end

    it "does not duplicate existing values" do
      TypedFields::Value.create!(entity: contact, field: field_a).tap do |v|
        v.value = "existing"
        v.save!
      end

      values = contact.initialize_typed_values
      expect(values.size).to eq(2)
    end
  end

  describe "#typed_fields_attributes=" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let(:contact) { create(:contact) }

    before { create(:text_field, name: "bio", entity_type: "Contact") }

    it "creates values from attribute hashes" do
      contact.typed_fields_attributes = [
        { name: "age", value: 30 },
        { name: "bio", value: "Hello" },
      ]
      contact.save!

      expect(contact.typed_field_value("age")).to eq(30)
      expect(contact.typed_field_value("bio")).to eq("Hello")
    end

    it "updates existing values" do
      TypedFields::Value.create!(entity: contact, field: age_field).tap do |v|
        v.value = 25
        v.save!
      end

      contact.typed_fields_attributes = [{ name: "age", value: 30 }]
      contact.save!

      expect(contact.typed_field_value("age")).to eq(30)
      expect(contact.typed_values.where(field: age_field).count).to eq(1)
    end

    it "ignores unknown field names" do
      contact.typed_fields_attributes = [{ name: "nonexistent", value: "nope" }]
      contact.save!

      expect(contact.typed_values.count).to eq(0)
    end
  end

  describe "#typed_field_value and #set_typed_field_value" do
    let(:contact) { create(:contact) }

    before { create(:text_field, name: "nickname", entity_type: "Contact") }

    it "sets and reads a value by field name" do
      contact.set_typed_field_value("nickname", "Ace")
      contact.save!

      expect(contact.typed_field_value("nickname")).to eq("Ace")
    end
  end

  describe "#typed_fields_hash" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:bio_field) { create(:text_field, name: "bio", entity_type: "Contact") }
    let(:contact) { create(:contact) }

    before do
      TypedFields::Value.create!(entity: contact, field: age_field).tap do |v|
        v.value = 30
        v.save!
      end
      TypedFields::Value.create!(entity: contact, field: bio_field).tap do |v|
        v.value = "Hello"
        v.save!
      end
    end

    it "returns all values as a hash" do
      expect(contact.typed_fields_hash).to eq({ "age" => 30, "bio" => "Hello" })
    end
  end

  describe "scoping" do
    let!(:global_field) { create(:text_field, name: "notes", entity_type: "Contact", scope: nil) }
    let!(:tenant_field) { create(:text_field, name: "dept", entity_type: "Contact", scope: "t1") }

    let(:contact) { create(:contact, tenant_id: "t1") }

    it "includes global and scoped fields for the contact's tenant" do
      definitions = contact.typed_field_definitions
      expect(definitions).to include(global_field, tenant_field)
    end

    it "excludes fields scoped to other tenants" do
      other_tenant_field = create(:text_field, name: "other", entity_type: "Contact", scope: "t2")
      definitions = contact.typed_field_definitions
      expect(definitions).not_to include(other_tenant_field)
    end
  end

  describe "#typed_fields_attributes= with _destroy" do
    let(:contact) { create(:contact) }

    before { create(:integer_field, name: "age", entity_type: "Contact") }

    it "destroys existing values when _destroy is truthy" do
      contact.typed_fields_attributes = [{ name: "age", value: 30 }]
      contact.save!
      expect(contact.typed_field_value("age")).to eq(30)

      contact.reload
      contact.typed_fields_attributes = [{ name: "age", _destroy: "1" }]
      contact.save!
      expect(contact.typed_values.reload.count).to eq(0)
    end

    it "handles _destroy for non-existent values gracefully" do
      contact.typed_fields_attributes = [{ name: "age", _destroy: true }]
      expect { contact.save! }.not_to raise_error
    end
  end

  describe "#typed_fields_attributes= type restrictions" do
    it "skips fields of disallowed types on restricted models" do
      json_field = create(:text_field, name: "notes", entity_type: "Product")
      # Change type to Json which is not in Product's allowed types
      json_field.update_column(:type, "TypedFields::Field::Json")
      product = create(:product)
      product.typed_fields_attributes = [{ name: "notes", value: { key: "val" } }]
      product.save!
      expect(product.typed_values.count).to eq(0)
    end

    it "allows fields of permitted types" do
      create(:text_field, name: "description", entity_type: "Product")
      product = create(:product)
      product.typed_fields_attributes = [{ name: "description", value: "hello" }]
      product.save!
      expect(product.typed_values.count).to eq(1)
    end
  end

  describe "#typed_fields_attributes= with Hash input" do
    let(:contact) { create(:contact) }

    before do
      create(:integer_field, name: "age", entity_type: "Contact")
      create(:text_field, name: "bio", entity_type: "Contact")
    end

    it "accepts hash-of-hashes (ActionController params format)" do
      contact.typed_fields_attributes = {
        "0" => { name: "age", value: 30 },
        "1" => { name: "bio", value: "Hello" },
      }
      contact.save!
      expect(contact.typed_field_value("age")).to eq(30)
      expect(contact.typed_field_value("bio")).to eq("Hello")
    end
  end

  describe "#set_typed_field_value edge cases" do
    let(:contact) { create(:contact) }

    before { create(:text_field, name: "nickname", entity_type: "Contact") }

    it "returns nil for non-existent field name" do
      result = contact.set_typed_field_value("nonexistent", "value")
      expect(result).to be_nil
    end

    it "updates an existing value" do
      contact.set_typed_field_value("nickname", "Ace")
      contact.save!
      contact.set_typed_field_value("nickname", "Updated")
      contact.save!
      expect(contact.typed_field_value("nickname")).to eq("Updated")
    end
  end

  describe "#initialize_typed_values with defaults" do
    let(:contact) { create(:contact) }

    it "populates built values with field defaults" do
      create(:integer_field, name: "score", entity_type: "Contact",
                             default_value_meta: { "v" => 100 })
      values = contact.initialize_typed_values
      score_value = values.detect { |v| v.field.name == "score" }
      expect(score_value).to be_present
      expect(score_value.value).to eq(100)
    end
  end

  describe "dependent: :destroy" do
    it "destroys typed_values when entity is destroyed" do
      create(:text_field, name: "note", entity_type: "Contact")
      contact = create(:contact)
      contact.set_typed_field_value("note", "test")
      contact.save!
      expect { contact.destroy! }.to change(TypedFields::Value, :count).by(-1)
    end
  end

  describe "field definition lifecycle" do
    it "destroying a field cascades to values" do
      field = create(:text_field, name: "temp", entity_type: "Contact")
      contact = create(:contact)
      TypedFields::Value.create!(entity: contact, field: field).tap do |v|
        v.value = "x"
        v.save!
      end
      expect { field.destroy! }.to change(TypedFields::Value, :count).by(-1)
    end

    it "destroying a select field cascades to options" do
      field = create(:select_field, name: "status", entity_type: "Contact")
      option_count = field.field_options.count
      expect(option_count).to be > 0
      expect { field.destroy! }.to change(TypedFields::Option, :count).by(-option_count)
    end
  end
end
