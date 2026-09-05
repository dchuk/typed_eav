# frozen_string_literal: true

require "spec_helper"

# Behavioral coverage for the explicit `source: :preloaded` bulk-read mode.
# The source mode must consume only association targets already attached to
# each caller record; it must not turn a missing preload into an N+1 query.
RSpec.describe "Entity.typed_eav_hash_for source:", type: :model do
  def sql_payloads(&block)
    payloads = []
    callback = lambda do |_, _, _, _, payload|
      next if payload[:name] == "SCHEMA"
      next if %w[TRANSACTION CACHE].include?(payload[:name])

      payloads << payload
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    payloads
  end

  def preload_contacts(*records)
    Contact.includes(typed_values: :field).where(id: records.map(&:id)).order(:id).to_a
  end

  describe "equivalent fresh and preloaded snapshots" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "t1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
    let!(:alice)      { create(:contact, tenant_id: "t1") }
    let!(:bob)        { create(:contact, tenant_id: "t1") }

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
    end

    it "matches a fresh database read when the association graph is preloaded" do
      records = preload_contacts(alice, bob)

      expect(Contact.typed_eav_hash_for(records, fields: %i[name age], source: :preloaded)).to eq(
        alice.id => { "name" => "Alice", "age" => 31 },
        bob.id => { "name" => "Bob", "age" => 42 },
      )
      expect(Contact.typed_eav_hash_for(records, fields: %i[name age], source: :database)).to eq(
        alice.id => { "name" => "Alice", "age" => 31 },
        bob.id => { "name" => "Bob", "age" => 42 },
      )
    end

    it "does not issue Value or field-association SELECTs in preloaded mode" do
      records = preload_contacts(alice, bob)

      queries = sql_payloads do
        Contact.typed_eav_hash_for(records, fields: [:name], source: :preloaded)
      end

      expect(queries).not_to include(satisfy { |payload| payload[:sql].match?("typed_eav_values") })
      expect(queries.count { |payload| payload[:sql].match?("typed_eav_fields") }).to eq(1)
    end

    it "hydrates the Value graph again for the explicit fresh database source" do
      records = preload_contacts(alice, bob)

      queries = sql_payloads do
        Contact.typed_eav_hash_for(records, fields: [:name], source: :database)
      end

      expect(queries).to include(satisfy { |payload| payload[:sql].match?("typed_eav_values") })
    end

    it "does not instantiate Value rows while projecting preloaded records" do
      records = preload_contacts(alice, bob)
      events = []
      callback = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
        Contact.typed_eav_hash_for(records, fields: [:name], source: :preloaded)
      end

      expect(events.select { |payload| payload[:class_name] == "TypedEAV::Value" }).to be_empty
    end

    it "includes selected in-memory changes without saving or mutating the caller" do
      records = preload_contacts(alice, bob)
      alice_record = records.find { |record| record.id == alice.id }
      alice_value = alice_record.typed_values.find { |value| value.field.name == "name" }
      alice_value.value = "Alice (unsaved)"

      expect(Contact.typed_eav_hash_for(records, fields: [:name])).to eq(
        alice.id => { "name" => "Alice" },
        bob.id => { "name" => "Bob" },
      )
      result = Contact.typed_eav_hash_for(records, fields: [:name], source: :preloaded)

      expect(result[alice.id]).to eq("name" => "Alice (unsaved)")
      expect(alice_value.value).to eq("Alice (unsaved)")
      expect(TypedEAV::Value.where(entity_id: alice.id, field_id: name_field.id).pick(:string_value))
        .to eq("Alice")
    end

    it "includes a newly built unsaved Value in the preloaded snapshot" do
      new_field = create(:text_field, name: "nickname", entity_type: "Contact", scope: "t1")
      loaded = preload_contacts(alice).first
      new_value = loaded.typed_values.build(field: new_field)
      new_value.value = "Al"

      result = Contact.typed_eav_hash_for([loaded], fields: [:nickname], source: :preloaded)

      expect(result).to eq(loaded.id => { "nickname" => "Al" })
      expect(new_value).not_to be_persisted
      expect(TypedEAV::Value.where(entity_id: loaded.id, field_id: new_field.id)).to be_empty
    end
  end

  describe "selected-field projection" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "t1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
    let!(:record)     { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: record, field: name_field).tap do |value|
        value.value = "Alice"
        value.save!
      end
      TypedEAV::Value.create!(entity: record, field: age_field).tap do |value|
        value.value = 31
        value.save!
      end
    end

    it "does not evaluate an unrequested field's logical reader" do
      loaded = preload_contacts(record).first
      age_value = loaded.typed_values.find { |value| value.field.name == "age" }
      allow(age_value.field).to receive(:read_value).and_raise("unrequested field evaluated")

      expect(Contact.typed_eav_hash_for([loaded], fields: [:name], source: :preloaded))
        .to eq(record.id => { "name" => "Alice" })
    end

    it "requires field associations only for selected values" do
      loaded = Contact.includes(:typed_values).find(record.id)
      name_value = loaded.typed_values.find { |value| value.field_id == name_field.id }
      age_value = loaded.typed_values.find { |value| value.field_id == age_field.id }
      ActiveRecord::Associations::Preloader.new(records: [name_value], associations: :field).call
      expect(age_value.association(:field).loaded?).to be(false)

      queries = sql_payloads do
        expect(Contact.typed_eav_hash_for([loaded], fields: [:name], source: :preloaded))
          .to eq(record.id => { "name" => "Alice" })
      end

      expect(queries).not_to include(satisfy { |payload| payload[:sql].match?("typed_eav_values") })
      expect(age_value.association(:field).loaded?).to be(false)
    end

    it "applies field selection and duplicate normalization to preloaded rows" do
      loaded = preload_contacts(record).first

      expect(Contact.typed_eav_hash_for([loaded], fields: [:name, "name", :unknown], source: :preloaded))
        .to eq(record.id => { "name" => "Alice" })
    end

    it "preserves explicit false and NULL values" do
      enabled_field = create(:boolean_field, name: "enabled", entity_type: "Contact", scope: "t1")
      blank_field = create(:text_field, name: "blank", entity_type: "Contact", scope: "t1")
      TypedEAV::Value.create!(entity: record, field: enabled_field).tap do |value|
        value.value = false
        value.save!
      end
      TypedEAV::Value.create!(entity: record, field: blank_field)
      loaded = preload_contacts(record).first

      expect(Contact.typed_eav_hash_for([loaded], fields: %i[enabled blank], source: :preloaded))
        .to eq(record.id => { "enabled" => false, "blank" => nil })
    end
  end

  describe "partition and collision semantics" do
    let!(:global_status) { create(:text_field, name: "status", entity_type: "Contact", scope: nil) }
    let!(:scoped_status) { create(:text_field, name: "status", entity_type: "Contact", scope: "t1") }
    let!(:t1_record)     { create(:contact, tenant_id: "t1") }
    let!(:t2_record)     { create(:contact, tenant_id: "t2") }

    before do
      TypedEAV::Value.create!(entity: t1_record, field: scoped_status).tap do |value|
        value.value = "scoped"
        value.save!
      end
      TypedEAV::Value.create!(entity: t1_record, field: global_status).tap do |value|
        value.value = "global"
        value.save!
      end
      # A stale cross-partition row should remain invisible for t2 even though
      # the preload contains it and the selected field ID is valid for t1.
      TypedEAV::Value.connection.execute(<<~SQL.squish)
        INSERT INTO typed_eav_values (entity_type, entity_id, field_id, string_value, created_at, updated_at)
        VALUES ('Contact', #{t2_record.id}, #{scoped_status.id}, 'wrong tenant', NOW(), NOW())
      SQL
    end

    it "uses the per-tuple winner and does not leak a selected row across tuples" do
      records = Contact.includes(typed_values: :field).where(id: [t1_record.id, t2_record.id]).order(:id).to_a

      expect(Contact.typed_eav_hash_for(records, fields: [:status], source: :preloaded)).to eq(
        t1_record.id => { "status" => "scoped" },
        t2_record.id => {},
      )
    end

    it "keeps a NULL Value row while leaving a missing row absent" do
      null_field = create(:text_field, name: "nullable", entity_type: "Contact", scope: "t1")
      null_record = create(:contact, tenant_id: "t1")
      missing_record = create(:contact, tenant_id: "t1")
      TypedEAV::Value.create!(entity: null_record, field: null_field)
      records = Contact.includes(typed_values: :field)
                       .where(id: [null_record.id, missing_record.id])
                       .order(:id)
                       .to_a

      expect(Contact.typed_eav_hash_for(records, fields: [:nullable], source: :preloaded)).to eq(
        null_record.id => { "nullable" => nil },
        missing_record.id => {},
      )
    end
  end

  describe "preload requirements" do
    let!(:field)  { create(:text_field, name: "note", entity_type: "Contact", scope: "t1") }
    let!(:record) { create(:contact, tenant_id: "t1") }

    before do
      TypedEAV::Value.create!(entity: record, field: field).tap do |value|
        value.value = "hello"
        value.save!
      end
    end

    it "returns empty maps without preload requirements or queries" do
      queries = sql_payloads do
        expect(Contact.typed_eav_hash_for([record], fields: [], source: :preloaded))
          .to eq(record.id => {})
      end

      expect(queries).to be_empty
    end

    it "raises without loading typed_values and does not issue an N+1 query" do
      queries = sql_payloads do
        expect do
          Contact.typed_eav_hash_for([record], fields: [:note], source: :preloaded)
        end.to raise_error(ArgumentError, /source: :preloaded.*typed_values.*preloaded/i)
      end

      expect(queries).not_to include(satisfy { |payload| payload[:sql].match?("typed_eav_values") })
      expect(queries.count { |payload| payload[:sql].match?("typed_eav_fields") }).to eq(1)
    end

    it "raises when typed_values are loaded but field associations are not" do
      loaded = Contact.includes(:typed_values).find(record.id)

      queries = sql_payloads do
        expect do
          Contact.typed_eav_hash_for([loaded], fields: [:note], source: :preloaded)
        end.to raise_error(ArgumentError, /source: :preloaded.*field association.*preloaded/i)
      end

      expect(queries).not_to include(satisfy { |payload| payload[:sql].match?("typed_eav_values") })
      expect(queries.count { |payload| payload[:sql].match?("typed_eav_fields") }).to eq(1)
    end

    it "permits a loaded orphan field association and skips that row" do
      TypedEAV::Field::Base.connection.execute(
        "DELETE FROM typed_eav_fields WHERE id = #{field.id}",
      )
      loaded = Contact.includes(typed_values: :field).find(record.id)

      expect(loaded.typed_values).to all(satisfy { |value| value.association(:field).loaded? })
      expect(Contact.typed_eav_hash_for([loaded], fields: [:note], source: :preloaded))
        .to eq(record.id => {})
    end
  end

  describe "source validation" do
    let!(:record) { create(:contact, tenant_id: "t1") }

    it "accepts only :database and :preloaded" do
      expect do
        Contact.typed_eav_hash_for([record], source: :cache)
      end.to raise_error(ArgumentError, /source must be :database or :preloaded/)
    end
  end
end
