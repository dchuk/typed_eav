# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/DescribeClass -- class-method API has no single concrete class.
RSpec.describe "Entity.bulk_upsert_typed_eav_values", :aggregate_failures do
  before do
    create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1")
    create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_2")
  end

  let!(:alice) { create(:contact, tenant_id: "tenant_1") }
  let!(:bob) { create(:contact, tenant_id: "tenant_2") }

  it "requires explicit reduced-semantics acknowledgement" do
    expect { Contact.bulk_upsert_typed_eav_values([alice], { age: 1 }) }
      .to raise_error(ArgumentError, /acknowledge_reduced_semantics/)
  end

  it "rejects field-key collisions before lookup or upsert" do
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice], { age: 1, "age" => 2 }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /keys collide/)

    expect(TypedEAV::Value.where(entity_id: alice.id)).to be_empty
  end

  it "fails closed before writes when connections use different pools" do
    allow(Contact).to receive(:connection_pool).and_return(
      instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool),
    )

    expect do
      Contact.bulk_upsert_typed_eav_values([alice], { age: 1 }, acknowledge_reduced_semantics: true)
    end.to raise_error(ArgumentError, /share a pool/)
    expect(TypedEAV::Value.where(entity_id: alice.id)).to be_empty
  end

  it "casts and upserts values on each record's partition" do
    result = Contact.bulk_upsert_typed_eav_values(
      [alice, bob], { age: "7" }, acknowledge_reduced_semantics: true
    )

    expect(result).to eq(2)
    expect(alice.reload.typed_eav_hash).to eq("age" => 7)
    expect(bob.reload.typed_eav_hash).to eq("age" => 7)
    expect(TypedEAV::Value.where(entity_type: "Contact").count).to eq(2)
  end

  it "keeps same-name tenant fields isolated inside an unscoped block" do
    TypedEAV.unscoped do
      expect(
        Contact.bulk_upsert_typed_eav_values(
          [alice, bob], { age: 17 }, acknowledge_reduced_semantics: true
        ),
      ).to eq(2)
    end

    expect(TypedEAV::Value.where(entity_id: alice.id).pick(:field_id)).to eq(
      TypedEAV::Field::Integer.find_by!(name: "age", scope: "tenant_1").id,
    )
    expect(TypedEAV::Value.where(entity_id: bob.id).pick(:field_id)).to eq(
      TypedEAV::Field::Integer.find_by!(name: "age", scope: "tenant_2").id,
    )
  end

  it "preserves global fallback for an exact tenant tuple" do
    create(:integer_field, name: "fallback", entity_type: "Contact", scope: nil)

    TypedEAV.unscoped do
      Contact.bulk_upsert_typed_eav_values(
        [bob], { fallback: 23 }, acknowledge_reduced_semantics: true
      )
    end

    expect(bob.reload.typed_eav_hash).to include("fallback" => 23)
  end

  it "prevalidates the unit before writing" do
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice], { age: "not-an-integer" }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /validation failed/)

    expect(TypedEAV::Value.where(entity_id: alice.id).count).to eq(0)
  end

  it "keeps non-uniqueness validators active in the bulk context" do
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice], { age: "not-an-integer" }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /validation failed/)

    value = TypedEAV::Value.new(
      entity: bob,
      field: TypedEAV::Field::Integer.find_by!(name: "age", scope: "tenant_1"),
    )
    value.value = 1
    value.valid?(:bulk_upsert)
    expect(value.errors).to be_present
  end

  it "does not write an earlier record when a later record fails unit validation" do
    create(:integer_field, name: "only_t1", entity_type: "Contact", scope: "tenant_1")

    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice, bob], { only_t1: 2 }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /field is not visible/)

    expect(TypedEAV::Value.where(entity_id: [alice.id, bob.id]).count).to eq(0)
  end

  it "updates an existing conflict row" do
    Contact.bulk_upsert_typed_eav_values([alice], { age: 3 }, acknowledge_reduced_semantics: true)
    created_at = TypedEAV::Value.find_by(entity_id: alice.id).created_at
    Contact.bulk_upsert_typed_eav_values([alice], { age: 8 }, acknowledge_reduced_semantics: true)

    expect(alice.reload.typed_eav_hash).to eq("age" => 8)
    value = TypedEAV::Value.find_by(entity_id: alice.id)
    expect(value).to have_attributes(integer_value: 8, created_at: created_at)
    expect(value.updated_at).to be > created_at
  end

  it "fails closed for a field absent from a record partition" do
    expect do
      Contact.bulk_upsert_typed_eav_values([alice], { missing: 1 }, acknowledge_reduced_semantics: true)
    end.to raise_error(ArgumentError, /field is not visible/)
  end

  it "rejects duplicate or unpersisted records before SQL" do
    expect do
      Contact.bulk_upsert_typed_eav_values([alice, alice], { age: 1 }, acknowledge_reduced_semantics: true)
    end.to raise_error(ArgumentError, /duplicate entity/)
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [Contact.new(tenant_id: "tenant_1")], { age: 1 }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /persisted records/)
  end

  it "does not create version rows or invoke host saves" do
    TypedEAV.config.versioning = true
    TypedEAV.registry.register("Contact", types: nil, versioned: true)
    allow(alice).to receive(:save)

    Contact.bulk_upsert_typed_eav_values([alice], { age: 4 }, acknowledge_reduced_semantics: true)

    expect(alice).not_to have_received(:save)
    expect(TypedEAV::ValueVersion.where(entity_id: alice.id).count).to eq(0)
  ensure
    TypedEAV.config.versioning = false
  end

  it "supports explicit chunk transaction boundaries" do
    result = Contact.bulk_upsert_typed_eav_values(
      [alice, bob], { age: 9 },
      acknowledge_reduced_semantics: true,
      transaction: :chunks,
      chunk_size: 1
    )

    expect(result).to eq(2)
    expect(alice.reload.typed_eav_hash).to eq("age" => 9)
    expect(bob.reload.typed_eav_hash).to eq("age" => 9)
  end

  it "keeps semantic bulk-write transaction all as the default" do
    result = Contact.bulk_set_typed_eav_values([alice, bob], { age: 11 })

    expect(result[:successes]).to contain_exactly(alice, bob)
    expect(result[:errors_by_record]).to eq({})
  end
end
# rubocop:enable RSpec/DescribeClass
