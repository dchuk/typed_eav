# frozen_string_literal: true

require "spec_helper"

RSpec.describe "inherited host polymorphic entity types" do
  around do |example|
    registered_entities = TypedEAV.registry.entities.deep_dup
    example.run
  ensure
    TypedEAV.registry.entities.replace(registered_entities)
  end

  it "bulk-reads a subclass record whose value is stored under the base polymorphic type" do
    field = create(:integer_field, name: "score", entity_type: Contact.polymorphic_name, scope: "tenant_1")
    record = PremiumContact.create!(name: "Premium", tenant_id: "tenant_1")
    TypedEAV::Value.create!(entity: record, field: field).tap do |value|
      value.value = 91
      value.save!
    end

    expect(TypedEAV::Value.find_by!(entity_id: record.id).entity_type).to eq(Contact.polymorphic_name)
    expect(PremiumContact.typed_eav_hash_for([record])).to eq(record.id => { "score" => 91 })
  end

  it "resolves definitions for a namespaced STI subclass through its polymorphic base" do
    field = create(
      :integer_field,
      name: "score",
      entity_type: Support::Contact.polymorphic_name,
      scope: "tenant_1",
    )
    unrelated = create(:integer_field, name: "score", entity_type: Contact.polymorphic_name, scope: "tenant_1")

    definitions = Support::PriorityContact.typed_eav_definitions(scope: "tenant_1")

    expect(definitions).to include(field)
    expect(definitions).not_to include(unrelated)
  end

  it "filters a namespaced STI subclass using definitions stored for its polymorphic base" do
    field = create(
      :integer_field,
      name: "score",
      entity_type: Support::Contact.polymorphic_name,
      scope: "tenant_1",
    )
    record = Support::PriorityContact.create!(name: "Priority", tenant_id: "tenant_1")
    TypedEAV::Value.create!(entity: record, field: field).tap do |value|
      value.value = 73
      value.save!
    end

    result = Support::PriorityContact.with_field("score", 73, scope: "tenant_1")

    expect(result).to contain_exactly(record)
  end

  it "keeps canonical writes on the scope-winning definition for an STI subclass" do
    entity_type = Support::Contact.polymorphic_name
    global = create(:integer_field, name: "score", entity_type: entity_type)
    field = create(:integer_field, name: "score", entity_type: entity_type, scope: "tenant_1")
    other_tenant = create(:integer_field, name: "score", entity_type: entity_type, scope: "tenant_2")
    record = Support::PriorityContact.create!(name: "Priority", tenant_id: "tenant_1")

    semantic_result = Support::PriorityContact.bulk_set_typed_eav_values([record], { score: 40 })
    expect(semantic_result[:successes]).to contain_exactly(record)

    expect(
      Support::PriorityContact.bulk_upsert_typed_eav_values(
        [record],
        { score: 41 },
        acknowledge_reduced_semantics: true,
      ),
    ).to eq(1)

    value = TypedEAV::Value.find_by!(entity_id: record.id)
    expect(value).to have_attributes(entity_type: entity_type, field_id: field.id, integer_value: 41)
    expect(value.field_id).not_to eq(global.id)
    expect(value.field_id).not_to eq(other_tenant.id)
  end

  it "registers an inherited has_typed_eav declaration under the polymorphic base type" do
    host = stub_const("RestrictedPremiumContact", Class.new(Contact))

    host.has_typed_eav(types: %i[integer], versioned: true)

    expect(TypedEAV.registry.entities["Contact"]).to eq(types: %i[integer], versioned: true)
    expect(TypedEAV.registry.entities).not_to have_key("RestrictedPremiumContact")
  end

  it "opts an inherited Versioned concern into the polymorphic base registration" do
    TypedEAV.registry.register("Contact", types: %i[integer], versioned: false)
    host = stub_const("VersionedPremiumContact", Class.new(Contact))

    host.include(TypedEAV::Versioned)

    expect(TypedEAV.registry.entities["Contact"]).to eq(types: %i[integer], versioned: true)
    expect(TypedEAV.registry.entities).not_to have_key("VersionedPremiumContact")
  end
end
