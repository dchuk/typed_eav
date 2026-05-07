# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::ValueVersion do
  describe "associations" do
    it { is_expected.to belong_to(:value).class_name("TypedEAV::Value").optional }
    it { is_expected.to belong_to(:field).class_name("TypedEAV::Field::Base").optional }
    it { is_expected.to belong_to(:entity) }
  end

  describe "validations" do
    subject(:version) { described_class.new }

    it {
      expect(version).to validate_inclusion_of(:change_type)
        .in_array(%w[create update destroy])
        .with_message("must be one of: create, update, destroy")
    }

    it { is_expected.to validate_presence_of(:entity_type) }
    it { is_expected.to validate_presence_of(:entity_id) }
    it { is_expected.to validate_presence_of(:changed_at) }
  end

  describe "schema defaults" do
    it "defaults before_value to {}" do
      version = described_class.new
      expect(version.before_value).to eq({})
    end

    it "defaults after_value to {}" do
      version = described_class.new
      expect(version.after_value).to eq({})
    end

    it "defaults context to {}" do
      version = described_class.new
      expect(version.context).to eq({})
    end

    it "allows changed_by to be nil (permissive actor contract)" do
      version = described_class.new(
        entity_type: "Contact", entity_id: 1, change_type: "create",
        changed_at: Time.current, changed_by: nil
      )
      version.valid?
      expect(version.errors[:changed_by]).to be_empty
    end
  end

  describe "jsonb round-trip", :real_commits do
    let(:contact) { Contact.create!(name: "test", tenant_id: "t1") }

    it "preserves typed-column-name keyed snapshots" do
      version = described_class.create!(
        entity: contact,
        change_type: "create",
        changed_at: Time.current,
        before_value: {},
        after_value: { "integer_value" => 42 },
      )
      reloaded = described_class.find(version.id)

      expect(reloaded.before_value).to eq({})
      expect(reloaded.after_value).to eq("integer_value" => 42)
    end

    it "preserves multi-column snapshots (Phase 05 Currency forward-compat)" do
      version = described_class.create!(
        entity: contact,
        change_type: "update",
        changed_at: Time.current,
        before_value: { "decimal_value" => "10.0", "string_value" => "USD" },
        after_value: { "decimal_value" => "20.0", "string_value" => "EUR" },
      )
      reloaded = described_class.find(version.id)

      expect(reloaded.before_value).to eq("decimal_value" => "10.0", "string_value" => "USD")
      expect(reloaded.after_value).to eq("decimal_value" => "20.0", "string_value" => "EUR")
    end

    it "distinguishes {} (no value) from {col: nil} (recorded nil)" do
      no_value = described_class.create!(
        entity: contact, change_type: "create", changed_at: Time.current,
        before_value: {}, after_value: { "integer_value" => 1 }
      )
      recorded_nil = described_class.create!(
        entity: contact, change_type: "update", changed_at: Time.current,
        before_value: { "integer_value" => 1 }, after_value: { "integer_value" => nil }
      )

      expect(described_class.find(no_value.id).before_value).to eq({})
      expect(described_class.find(recorded_nil.id).after_value).to eq("integer_value" => nil)
    end
  end

  describe "FK ON DELETE SET NULL behavior", :real_commits do
    let(:contact) { Contact.create!(name: "test", tenant_id: "t1") }
    let(:field) do
      TypedEAV.with_scope("t1") do
        TypedEAV::Field::Integer.create!(name: "age", entity_type: "Contact", scope: "t1")
      end
    end
    let(:value) { TypedEAV::Value.create!(entity: contact, field: field, value: 42) }

    it "nulls value_id when the source Value is destroyed (preserves audit log)" do
      version = described_class.create!(
        entity: contact, value: value, field: field,
        change_type: "create", changed_at: Time.current,
        after_value: { "integer_value" => 42 }
      )
      value.destroy!

      version.reload
      expect(version.value_id).to be_nil
      expect(version.entity_type).to eq("Contact")
      expect(version.entity_id).to eq(contact.id)
    end

    it "nulls field_id when the source Field is destroyed (preserves audit log)" do
      version = described_class.create!(
        entity: contact, value: value, field: field,
        change_type: "update", changed_at: Time.current,
        before_value: { "integer_value" => 41 },
        after_value: { "integer_value" => 42 }
      )
      # field_dependent default "destroy" → cascade destroys value first;
      # destroying field with ON DELETE SET NULL on the version's field_id
      # leaves value_id NULL (set by the value-destroy cascade above) and
      # field_id NULL (set by the field destroy here).
      field.destroy!

      version.reload
      expect(version.field_id).to be_nil
    end
  end

  describe "#version_group_id" do
    # Phase 06 correlation tag — additive uuid column landed in
    # `db/migrate/20260506000001_add_version_group_id_to_typed_eav_value_versions.rb`.
    # No AR-model change was needed; the column is auto-discovered from
    # the schema.
    it "responds to version_group_id (column auto-discovered from schema)" do
      expect(described_class.new).to respond_to(:version_group_id)
    end

    it "round-trips a uuid through reload", :real_commits do
      contact = Contact.create!(name: "test", tenant_id: "t1")
      uuid = SecureRandom.uuid
      version = described_class.create!(
        entity: contact,
        change_type: "create",
        changed_at: Time.current,
        version_group_id: uuid,
        after_value: { "integer_value" => 1 },
      )

      expect(described_class.find(version.id).version_group_id).to eq(uuid)
    end
  end
end
