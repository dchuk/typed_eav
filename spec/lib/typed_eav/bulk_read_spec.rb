# frozen_string_literal: true

require "spec_helper"

# Unit specs for TypedEAV::BulkRead — the query object that backs
# `Entity.typed_eav_hash_for(records)`. Exercises the new class shape
# (constructor + `to_hash`) directly so future refactors can move the
# pipeline around without losing per-stage coverage. The high-level
# end-to-end behavior (query bounds, AR Relation input, real cascade
# scenarios) lives in spec/models/typed_eav/bulk_read_spec.rb.
RSpec.describe TypedEAV::BulkRead do
  describe "#to_hash input validation" do
    it "raises ArgumentError when records is nil" do
      expect { described_class.new(host_class: Contact, records: nil).to_hash }
        .to raise_error(ArgumentError, /requires an Enumerable.*got nil/)
    end

    it "returns {} when records is empty" do
      expect(described_class.new(host_class: Contact, records: []).to_hash).to eq({})
    end

    it "raises ArgumentError when records belong to a different class" do
      product = create(:product, title: "X")
      expect { described_class.new(host_class: Contact, records: [product]).to_hash }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end

    it "raises ArgumentError when records span multiple classes" do
      contact = create(:contact)
      product = create(:product, title: "X")
      expect { described_class.new(host_class: Contact, records: [contact, product]).to_hash }
        .to raise_error(ArgumentError, /mixed classes:.*Contact.*Product|Product.*Contact/)
    end
  end

  describe "#to_hash output shape" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "t1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
    let!(:alice)      { create(:contact, name: "Alice", tenant_id: "t1") }
    let!(:bob)        { create(:contact, name: "Bob",   tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: alice, field: name_field).tap do |v|
        v.value = "Alice"
        v.save!
      end
      TypedEAV::Value.create!(entity: alice, field: age_field).tap do |v|
        v.value = 30
        v.save!
      end
      TypedEAV::Value.create!(entity: bob, field: name_field).tap do |v|
        v.value = "Bob"
        v.save!
      end
      TypedEAV::Value.create!(entity: bob, field: age_field).tap do |v|
        v.value = 25
        v.save!
      end
    end

    it "returns { record_id => { field_name => value } } keyed by id" do
      result = TypedEAV.with_scope("t1") do
        described_class.new(host_class: Contact, records: [alice, bob]).to_hash
      end

      expect(result).to eq(
        alice.id => { "name" => "Alice", "age" => 30 },
        bob.id => { "name" => "Bob", "age" => 25 },
      )
    end

    it "returns an inner {} for records with no values" do
      empty = create(:contact, tenant_id: "t1")

      result = TypedEAV.with_scope("t1") do
        described_class.new(host_class: Contact, records: [empty]).to_hash
      end

      expect(result).to eq(empty.id => {})
    end
  end

  describe "per-tuple partition grouping" do
    let!(:field_t1) { create(:text_field, name: "label", entity_type: "Contact", scope: "t1") }
    let!(:field_t2) { create(:text_field, name: "label", entity_type: "Contact", scope: "t2") }
    let!(:c1)       { create(:contact, name: "C1", tenant_id: "t1") }
    let!(:c2)       { create(:contact, name: "C2", tenant_id: "t2") }

    before do
      TypedEAV::Value.create!(entity: c1, field: field_t1).tap do |v|
        v.value = "tenant_one_value"
        v.save!
      end
      TypedEAV::Value.create!(entity: c2, field: field_t2).tap do |v|
        v.value = "tenant_two_value"
        v.save!
      end
    end

    # BulkRead groups records by [typed_eav_scope, typed_eav_parent_scope]
    # and resolves field definitions ONCE per tuple via the host's
    # `typed_eav_definitions(scope:, parent_scope:)` — an explicit per-tuple
    # lookup, NOT an ambient resolution. The single per-tuple
    # `Partition.definitions_by_name(...)` call therefore picks the right
    # field for each tenant's record without leaking the other tenant's rows.
    it "resolves field definitions per tuple so each record sees its own tenant's field" do
      result = described_class.new(host_class: Contact, records: [c1, c2]).to_hash

      expect(result).to eq(
        c1.id => { "label" => "tenant_one_value" },
        c2.id => { "label" => "tenant_two_value" },
      )
    end
  end

  describe "collision precedence per tuple" do
    let!(:global_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }
    let!(:scoped_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
    let!(:contact)    { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: contact, field: scoped_age).tap do |v|
        v.value = 99
        v.save!
      end
      # Bypass uniqueness to attach a stale row to the shadowed global field.
      TypedEAV::Value.connection.execute(<<~SQL.squish)
        INSERT INTO typed_eav_values (entity_type, entity_id, field_id, integer_value, created_at, updated_at)
        VALUES ('Contact', #{contact.id}, #{global_age.id}, 11, NOW(), NOW())
      SQL
    end

    it "prefers the scoped (winning) value over the shadowed global value" do
      result = TypedEAV.with_scope("t1") do
        described_class.new(host_class: Contact, records: [contact]).to_hash
      end

      expect(result).to eq(contact.id => { "age" => 99 })
    end
  end

  describe "single-shot value preload" do
    let!(:name_field_t1) { create(:text_field, name: "name", entity_type: "Contact", scope: "t1") }
    let!(:name_field_t2) { create(:text_field, name: "name", entity_type: "Contact", scope: "t2") }
    let!(:t1_records) { Array.new(3) { |i| create(:contact, name: "T1-#{i}", tenant_id: "t1") } }
    let!(:t2_records) { Array.new(2) { |i| create(:contact, name: "T2-#{i}", tenant_id: "t2") } }

    before do
      t1_records.each_with_index do |c, i|
        TypedEAV::Value.create!(entity: c, field: name_field_t1).tap do |v|
          v.value = "T1-#{i}"
          v.save!
        end
      end
      t2_records.each_with_index do |c, i|
        TypedEAV::Value.create!(entity: c, field: name_field_t2).tap do |v|
          v.value = "T2-#{i}"
          v.save!
        end
      end
    end

    it "issues bounded queries (independent of record count)", :unscoped do
      records = t1_records + t2_records
      queries = []
      callback = lambda do |_, _, _, _, payload|
        next if payload[:name] == "SCHEMA"
        next if %w[TRANSACTION CACHE].include?(payload[:name])

        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.new(host_class: Contact, records: records).to_hash.each_value(&:keys)
      end

      # 1 value preload + 1 field preload + 1 definitions per unique tuple (= 2).
      expect(queries.size).to be <= 4
    end
  end
end
