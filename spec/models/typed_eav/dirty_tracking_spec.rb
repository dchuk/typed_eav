# frozen_string_literal: true

require "spec_helper"

RSpec.describe "typed EAV pending dirty tracking", type: :model do
  let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
  let!(:price_field) { create(:currency_field, name: "price", entity_type: "Contact") }
  let!(:contact) { create(:contact, name: "Dirty") }

  def save_value(field, value)
    TypedEAV::Value.create!(entity: contact, field: field, value: value)
  end

  def field_queries(&block)
    queries = []
    callback = lambda do |_, _, _, _, payload|
      next if payload[:name] == "SCHEMA"

      queries << payload[:sql] if payload[:sql].match?(/SELECT.*typed_eav_fields/i)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  describe "#typed_eav_changes" do
    it "reports a named assignment without loading unrelated rows" do
      contact.set_typed_eav_value("age", 21)

      expect(contact.typed_eav_changes).to eq("age" => [nil, 21])
    end

    it "reports nested typed-value assignments by field name" do
      contact.typed_values_attributes = [{ field_id: age_field.id, value: "22" }]

      expect(contact.typed_eav_changes).to eq("age" => [nil, 22])
    end

    it "reports the name-based typed_eav_attributes= path" do
      contact.typed_eav_attributes = [{ name: "age", value: "22" }]

      expect(contact.typed_eav_changes).to eq("age" => [nil, 22])
    end

    it "reports direct association builds" do
      contact.typed_values.build(field: age_field, value: "23")

      expect(contact.typed_eav_changes).to eq("age" => [nil, 23])
    end

    it "does not load fields for an unchanged loaded association target" do
      save_value(age_field, 23)
      reloaded = contact.reload
      reloaded.typed_values.load

      queries = field_queries { expect(reloaded.typed_eav_changes).to eq({}) }

      expect(queries).to eq([])
    end

    it "reports direct association value mutations" do
      save_value(age_field, 24)
      contact.reload.typed_values.load

      value = contact.typed_values.target.first
      value.value = "25"

      expect(contact.typed_eav_changes).to eq("age" => [24, 25])
    end

    it "uses one logical pair for a multi-cell value" do
      save_value(price_field, { amount: "10.00", currency: "USD" })
      contact.reload.typed_values.load

      value = contact.typed_values.target.first
      value.value = { amount: "11.50", currency: "EUR" }

      expect(contact.typed_eav_changes).to eq(
        "price" => [
          { amount: BigDecimal("10.0"), currency: "USD" },
          { amount: BigDecimal("11.5"), currency: "EUR" },
        ],
      )
    end

    it "tracks in-place mutation of a JSON-backed array" do
      field = create(:integer_array_field, name: "scores", entity_type: "Contact")
      save_value(field, [1])
      contact.reload.typed_values.load

      value = contact.typed_values.target.first
      value.value << 2

      expect(contact.typed_eav_changes).to eq("scores" => [[1], [1, 2]])
    end

    it "reports removal through nested attributes" do
      value = save_value(age_field, 26)
      contact.reload
      contact.typed_values_attributes = [{ id: value.id, _destroy: true }]

      expect(contact.typed_eav_changes).to eq("age" => [26, nil])
    end

    it "reports removal marked on a direct association value" do
      save_value(age_field, 27)
      contact.reload.typed_values.load
      value = contact.typed_values.target.first
      value.mark_for_destruction

      expect(contact.typed_eav_changes).to eq("age" => [27, nil])
    end

    it "omits same-value assignments and reverts to the persisted value" do
      save_value(age_field, 28)
      contact.reload

      contact.set_typed_eav_value("age", 28)
      expect(contact.typed_eav_changes).to eq({})

      contact.set_typed_eav_value("age", 29)
      expect(contact.typed_eav_changes).to eq("age" => [28, 29])

      contact.set_typed_eav_value("age", 28)
      expect(contact.typed_eav_changes).to eq({})
    end

    it "uses the effective scoped definition when names collide" do
      global = create(:text_field, name: "status", entity_type: "Contact", scope: nil)
      scoped = create(:text_field, name: "status", entity_type: "Contact", scope: "t1")
      scoped_contact = create(:contact, tenant_id: "t1")

      scoped_contact.typed_eav_attributes = [{ name: "status", value: "active" }]

      expect(scoped_contact.typed_eav_changes).to eq("status" => [nil, "active"])
      expect(scoped_contact.typed_values.target.map(&:field_id)).to eq([scoped.id])
      expect(scoped_contact.typed_values.target.map(&:field_id)).not_to include(global.id)
    end

    it "keeps invalid casts out of the reported after value while retaining errors" do
      save_value(age_field, 30)
      contact.reload
      contact.set_typed_eav_value("age", "not-an-integer")
      value = contact.typed_values.target.first

      expect(contact.typed_eav_changes).to eq("age" => [30, nil])
      expect(contact.save).to be(false)
      expect(value.errors[:value]).to include("is invalid")
      expect(contact.typed_eav_changes).to eq("age" => [30, nil])
    end

    it "does not report an invalid nil-to-nil new value" do
      contact.set_typed_eav_value("age", "not-an-integer")

      expect(contact.typed_eav_changes).to eq({})
      expect(contact.save).to be(false)
      expect(contact.typed_values.target.first.errors[:value]).to include("is invalid")
    end

    it "treats nil-to-nil creation and removal as no-op changes" do
      contact.set_typed_eav_value("age", nil)
      expect(contact.typed_eav_changes).to eq({})
      contact.save!

      value = contact.typed_values.target.first
      contact.typed_values_attributes = [{ id: value.id, _destroy: true }]

      expect(contact.typed_eav_changes).to eq({})
    end

    it "returns mutable copies that cannot alter the Value or the next result" do
      contact.set_typed_eav_value("price", { amount: "10.00", currency: "USD" })
      original = contact.typed_eav_changes

      original["price"][1][:amount] = BigDecimal("99.0")
      original["price"][1][:currency] = "EUR"

      expect(contact.typed_eav_changes).to eq(
        "price" => [
          nil,
          { amount: BigDecimal("10.0"), currency: "USD" },
        ],
      )
    end

    it "returns an empty hash after a successful save" do
      contact.set_typed_eav_value("age", 31)
      expect(contact.save).to be(true)

      expect(contact.typed_eav_changes).to eq({})
    end

    it "preserves pending changes after a failed host save" do
      age_field.update!(options: { min: 18 })
      contact.set_typed_eav_value("age", 17)

      expect(contact.save).to be(false)
      expect(contact.typed_eav_changes).to eq("age" => [nil, 17])
    end

    it "restores pending changes when an outer transaction rolls back" do
      save_value(age_field, 33)
      contact.reload
      contact.set_typed_eav_value("age", 34)

      Contact.transaction do
        contact.save!
        expect(contact.typed_eav_changes).to eq({})
        raise ActiveRecord::Rollback
      end

      expect(contact.typed_eav_changes).to eq("age" => [33, 34])
      expect(TypedEAV::Value.find_by(entity: contact, field: age_field).value).to eq(33)
    end

    it "clears pending changes on reload" do
      contact.set_typed_eav_value("age", 35)

      expect(contact.reload.typed_eav_changes).to eq({})
    end

    it "exposes pending changes to a host before_save callback" do
      observed = nil
      callback = proc { observed = typed_eav_changes }
      Contact.set_callback(:save, :before, callback, prepend: true)

      begin
        contact.set_typed_eav_value("age", 36)
        contact.save!
      ensure
        Contact.skip_callback(:save, :before, callback, prepend: true)
      end

      expect(observed).to eq("age" => [nil, 36])
    end
  end
end
