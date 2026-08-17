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

  it "casts and upserts values on each record's partition" do
    result = Contact.bulk_upsert_typed_eav_values(
      [alice, bob], { age: "7" }, acknowledge_reduced_semantics: true
    )

    expect(result).to eq(2)
    expect(alice.reload.typed_eav_hash).to eq("age" => 7)
    expect(bob.reload.typed_eav_hash).to eq("age" => 7)
    expect(TypedEAV::Value.where(entity_type: "Contact").count).to eq(2)
  end

  it "prevalidates the unit before writing" do
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice], { age: "not-an-integer" }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /validation failed/)

    expect(TypedEAV::Value.where(entity_id: alice.id).count).to eq(0)
  end

  it "updates an existing conflict row" do
    Contact.bulk_upsert_typed_eav_values([alice], { age: 3 }, acknowledge_reduced_semantics: true)
    Contact.bulk_upsert_typed_eav_values([alice], { age: 8 }, acknowledge_reduced_semantics: true)

    expect(alice.reload.typed_eav_hash).to eq("age" => 8)
    expect(TypedEAV::Value.where(entity_id: alice.id).count).to eq(1)
  end

  it "fails closed for a field absent from a record partition" do
    expect do
      Contact.bulk_upsert_typed_eav_values([alice], { missing: 1 }, acknowledge_reduced_semantics: true)
    end.to raise_error(ArgumentError, /field is not visible/)
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
