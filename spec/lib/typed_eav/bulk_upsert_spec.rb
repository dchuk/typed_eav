# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/DescribeClass -- class-method API has no single concrete class.
RSpec.describe "Entity.bulk_upsert_typed_eav_values", :aggregate_failures do
  def definition_selects(&block)
    queries = []
    subscriber = lambda do |_, _, _, _, payload|
      sql = payload[:sql]
      queries << sql if payload[:name] != "SCHEMA" && sql.match?(/\ASELECT .*FROM "typed_eav_fields"/im)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    queries
  end

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

  it "uses one definition SELECT for one or twenty requested partitions" do
    records = Array.new(20) do |index|
      scope = "batch_tenant_#{index}"
      create(:integer_field, name: "batch_score", entity_type: "Contact", scope: scope)
      create(:contact, name: "Batch #{index}", tenant_id: scope)
    end

    one_partition = definition_selects do
      Contact.bulk_upsert_typed_eav_values(
        [records.first], { batch_score: 1 }, acknowledge_reduced_semantics: true
      )
    end
    twenty_partitions = definition_selects do
      Contact.bulk_upsert_typed_eav_values(
        records, { batch_score: 2 }, acknowledge_reduced_semantics: true
      )
    end

    expect(one_partition.size).to eq(1)
    expect(twenty_partitions.size).to eq(1)
  end

  it "uses one batched definition SELECT per transaction chunk" do
    records = Array.new(6) do |index|
      scope = "chunk_tenant_#{index}"
      create(:integer_field, name: "chunk_score", entity_type: "Contact", scope: scope)
      create(:contact, name: "Chunk #{index}", tenant_id: scope)
    end

    queries = definition_selects do
      Contact.bulk_upsert_typed_eav_values(
        records,
        { chunk_score: 3 },
        acknowledge_reduced_semantics: true,
        transaction: :chunks,
        chunk_size: 2,
      )
    end

    expect(queries.size).to eq(3)
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

  it "resolves global, scope, and parent-scope precedence independently per tuple" do
    global = create(:integer_field, name: "priority", entity_type: "Project")
    tenant_one = create(:integer_field, name: "priority", entity_type: "Project", scope: "t1")
    tenant_one_w1 = create(
      :integer_field, name: "priority", entity_type: "Project", scope: "t1", parent_scope: "w1"
    )
    tenant_one_w2 = create(
      :integer_field, name: "priority", entity_type: "Project", scope: "t1", parent_scope: "w2"
    )
    tenant_two = create(:integer_field, name: "priority", entity_type: "Project", scope: "t2")
    records = [
      create(:project, tenant_id: "t1", workspace_id: "w1"),
      create(:project, tenant_id: "t1", workspace_id: "w2"),
      create(:project, tenant_id: "t1", workspace_id: "w3"),
      create(:project, tenant_id: "t2", workspace_id: "w1"),
      create(:project, tenant_id: "t3", workspace_id: "w1"),
    ]

    expect(
      Project.bulk_upsert_typed_eav_values(
        records, { priority: 5 }, acknowledge_reduced_semantics: true
      ),
    ).to eq(5)

    field_ids = TypedEAV::Value.where(entity_type: "Project").order(:entity_id).pluck(:field_id)
    expect(field_ids).to eq([tenant_one_w1.id, tenant_one_w2.id, tenant_one.id, tenant_two.id, global.id])
  end

  it "prevalidates the unit before writing" do
    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice], { age: "not-an-integer" }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /validation failed/)

    expect(TypedEAV::Value.where(entity_id: alice.id).count).to eq(0)
  end

  it "retains orphan-parent tuple validation before writes" do
    create(:integer_field, name: "project_score", entity_type: "Project")
    project = create(:project, tenant_id: nil, workspace_id: "orphan")

    expect do
      Project.bulk_upsert_typed_eav_values(
        [project], { project_score: 1 }, acknowledge_reduced_semantics: true
      )
    end.to raise_error(ArgumentError, /parent_scope cannot be set when scope is blank/)

    expect(TypedEAV::Value.where(entity_type: "Project", entity_id: project.id)).to be_empty
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

  it "keeps a committed chunk when a later chunk fails field visibility validation" do
    field = create(:integer_field, name: "only_t1_chunked", entity_type: "Contact", scope: "tenant_1")

    expect do
      Contact.bulk_upsert_typed_eav_values(
        [alice, bob],
        { only_t1_chunked: 2 },
        acknowledge_reduced_semantics: true,
        transaction: :chunks,
        chunk_size: 1,
      )
    end.to raise_error(ArgumentError, /field is not visible/)

    expect(TypedEAV::Value.find_by(entity_id: alice.id)).to have_attributes(field_id: field.id, integer_value: 2)
    expect(TypedEAV::Value.where(entity_id: bob.id)).to be_empty
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
