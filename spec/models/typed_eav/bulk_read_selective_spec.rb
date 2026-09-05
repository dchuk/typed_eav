# frozen_string_literal: true

require "spec_helper"

# Regression coverage for the `fields:` projection on
# `Entity.typed_eav_hash_for`. The production query must narrow the Value
# relation before Active Record hydrates rows; filtering the final Ruby hash is
# not sufficient because field-specific readers may perform expensive work.
RSpec.describe "Entity.typed_eav_hash_for fields:", type: :model do
  def count_sql_queries(&block)
    queries = []
    callback = lambda do |_, _, _, _, payload|
      next if payload[:name] == "SCHEMA"
      next if %w[TRANSACTION CACHE].include?(payload[:name])

      queries << payload
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  describe "selected values" do
    let!(:name_field)    { create(:text_field, name: "name", entity_type: "Contact", scope: "t1") }
    let!(:age_field)     { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
    let!(:enabled_field) { create(:boolean_field, name: "enabled", entity_type: "Contact", scope: "t1") }
    let!(:blank_field)   { create(:text_field, name: "blank", entity_type: "Contact", scope: "t1") }
    let!(:alice)         { create(:contact, tenant_id: "t1") }
    let!(:bob)           { create(:contact, tenant_id: "t1") }

    before do
      [[alice, "Alice", 31], [bob, "Bob", 42]].each do |record, name, age|
        TypedEAV::Value.create!(entity: record, field: name_field).tap do |value|
          value.value = name
          value.save!
        end
        TypedEAV::Value.create!(entity: record, field: age_field).tap do |value|
          value.value = age
          value.save!
        end
      end
      TypedEAV::Value.create!(entity: alice, field: enabled_field).tap do |value|
        value.value = false
        value.save!
      end
      TypedEAV::Value.create!(entity: bob, field: enabled_field).tap do |value|
        value.value = true
        value.save!
      end
      TypedEAV::Value.create!(entity: alice, field: blank_field)
    end

    it "returns only requested names and filters Value rows before hydration" do
      queries = count_sql_queries do
        result = Contact.typed_eav_hash_for([alice, bob], fields: [:name])

        expect(result).to eq(
          alice.id => { "name" => "Alice" },
          bob.id => { "name" => "Bob" },
        )
      end

      value_query = queries.find { |payload| payload[:sql].match?(/typed_eav_values/) }
      expect(value_query[:sql]).to include("field_id")
      bind_values = value_query[:binds].map(&:value)
      expect(bind_values).to include(name_field.id)
      expect(bind_values).not_to include(age_field.id)
    end

    it "does not instantiate unrequested Value rows" do
      events = []
      callback = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
        Contact.typed_eav_hash_for([alice, bob], fields: [:name])
      end

      value_events = events.select { |payload| payload[:class_name] == "TypedEAV::Value" }
      expect(value_events.sum { |payload| payload[:record_count] }).to eq(2)
    end

    it "normalizes symbols and removes duplicate names while ignoring unknown names" do
      result = Contact.typed_eav_hash_for([alice], fields: [:name, "name", :unknown])

      expect(result).to eq(alice.id => { "name" => "Alice" })
    end

    it "preserves explicit false and NULL values in the selected projection" do
      expect(Contact.typed_eav_hash_for([alice, bob], fields: [:enabled])).to eq(
        alice.id => { "enabled" => false },
        bob.id => { "enabled" => true },
      )
      expect(Contact.typed_eav_hash_for([alice], fields: [:blank])).to eq(
        alice.id => { "blank" => nil },
      )
    end

    it "does not issue a Value SELECT when every selected name is unknown" do
      queries = count_sql_queries do
        expect(Contact.typed_eav_hash_for([alice], fields: [:unknown])).to eq(alice.id => {})
      end

      expect(queries).to all(satisfy { |payload| payload[:sql].exclude?("typed_eav_values") })
    end

    it "accepts one String or Symbol as a convenience selection" do
      expect(Contact.typed_eav_hash_for([alice], fields: "name"))
        .to eq(alice.id => { "name" => "Alice" })
      expect(Contact.typed_eav_hash_for([alice], fields: :name))
        .to eq(alice.id => { "name" => "Alice" })
    end
  end

  describe "names absent from a requested partition" do
    let!(:label_t1) { create(:text_field, name: "label", entity_type: "Contact", scope: "t1") }
    let!(:t1_record) { create(:contact, tenant_id: "t1") }
    let!(:t2_record) { create(:contact, tenant_id: "t2") }

    before do
      TypedEAV::Value.create!(entity: t1_record, field: label_t1).tap do |value|
        value.value = "Tenant one"
        value.save!
      end
      # A stale cross-partition row must not leak merely because the same
      # field ID is selected for another record's tuple.
      TypedEAV::Value.connection.execute(<<~SQL.squish)
        INSERT INTO typed_eav_values (entity_type, entity_id, field_id, string_value, created_at, updated_at)
        VALUES ('Contact', #{t2_record.id}, #{label_t1.id}, 'wrong tenant', NOW(), NOW())
      SQL
    end

    it "omits the name for records whose tuple has no definition" do
      result = Contact.typed_eav_hash_for([t1_record, t2_record], fields: [:label])

      expect(result).to eq(
        t1_record.id => { "label" => "Tenant one" },
        t2_record.id => {},
      )
    end

    it "keeps the definition, value, and field preloads bounded across tuples" do
      queries = count_sql_queries do
        Contact.typed_eav_hash_for([t1_record, t2_record], fields: [:label])
      end

      expect(queries.size).to eq(3)
    end
  end

  describe "empty selection" do
    let!(:field)  { create(:text_field, name: "note", entity_type: "Contact", scope: "t1") }
    let!(:record) { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: record, field: field).tap do |value|
        value.value = "memo"
        value.save!
      end
    end

    it "returns one empty hash per record without querying definitions or values" do
      queries = count_sql_queries do
        expect(Contact.typed_eav_hash_for([record], fields: [])).to eq(record.id => {})
      end

      expect(queries).to be_empty
    end

    it "still validates the single-class invariant" do
      product = create(:product, title: "Wrong class")

      expect { Contact.typed_eav_hash_for([product], fields: []) }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end
  end

  describe "collision and missing-value semantics" do
    let!(:global_status) { create(:text_field, name: "status", entity_type: "Contact", scope: nil) }
    let!(:scoped_status) { create(:text_field, name: "status", entity_type: "Contact", scope: "t1") }
    let!(:record)        { create(:contact, tenant_id: "t1") }
    let!(:empty_record)  { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: record, field: scoped_status).tap do |value|
        value.value = "scoped"
        value.save!
      end
      # Simulate a stale row attached to the shadowed global definition.
      TypedEAV::Value.connection.execute(<<~SQL.squish)
        INSERT INTO typed_eav_values (entity_type, entity_id, field_id, string_value, created_at, updated_at)
        VALUES ('Contact', #{record.id}, #{global_status.id}, 'global', NOW(), NOW())
      SQL
    end

    it "preserves most-specific-wins precedence for selected names" do
      expect(Contact.typed_eav_hash_for([record], fields: [:status]))
        .to eq(record.id => { "status" => "scoped" })
    end

    it "keeps missing rows absent from the selected projection" do
      expect(Contact.typed_eav_hash_for([empty_record], fields: [:status]))
        .to eq(empty_record.id => {})
    end
  end

  describe "orphan values" do
    let!(:field)  { create(:text_field, name: "note", entity_type: "Contact", scope: "t1") }
    let!(:record) { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: record, field: field).tap do |value|
        value.value = "stale"
        value.save!
      end
      TypedEAV::Field::Base.connection.execute(
        "DELETE FROM typed_eav_fields WHERE id = #{field.id}",
      )
    end

    it "skips an orphan row when its name is selected" do
      expect(Contact.typed_eav_hash_for([record], fields: [:note]))
        .to eq(record.id => {})
    end
  end

  describe "invalid field selections" do
    let!(:record) { create(:contact, tenant_id: "t1") }

    it "raises a clear error when the selection is not enumerable" do
      expect { Contact.typed_eav_hash_for([record], fields: 7) }
        .to raise_error(ArgumentError, /fields must be an Enumerable/)
    end

    it "raises a clear error when an element is not a name" do
      expect { Contact.typed_eav_hash_for([record], fields: [:name, 7]) }
        .to raise_error(ArgumentError, /fields must contain only String or Symbol names/)
    end
  end
end
