# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Value, "#revert_to", :event_callbacks, :real_commits do
  before do
    TypedEAV.registry.register("Contact", types: nil, versioned: true)
    TypedEAV::Config.versioning = true
    # CRITICAL (Discrepancy D4 from plan 04-02 amendment): the
    # :event_callbacks hook clears EventDispatcher.value_change_internals
    # at example entry. Phase 04's subscriber was registered at engine
    # boot via config.after_initialize but is gone for the duration of
    # this example. Re-register explicitly. The hook's ensure block
    # restores the snapshot, so this re-registration does NOT leak
    # across examples.
    TypedEAV::EventDispatcher.register_internal_value_change(
      TypedEAV::Versioning::Subscriber.method(:call),
    )
  end

  after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

  let(:contact) { Contact.create!(name: "test", tenant_id: "t1") }
  let(:field) do
    TypedEAV.with_scope("t1") do
      TypedEAV::Field::Integer.create!(name: "age", entity_type: "Contact", scope: "t1")
    end
  end

  describe "happy path: revert to an :update version" do
    it "writes the targeted version's before_value back to the typed column" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      value.update!(value: 3)

      target_version = value.history.find_by(after_value: { "integer_value" => 2 })
      expect(target_version).not_to be_nil
      expect(target_version.before_value).to eq("integer_value" => 1)

      value.revert_to(target_version)

      expect(value.reload.value).to eq(1)
    end

    it "writes a NEW version row capturing the revert (append-only audit trail)" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      target = value.history.find_by(change_type: "update") # before: 1, after: 2

      expect do
        value.revert_to(target)
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      newest = value.history.first
      expect(newest.change_type).to eq("update")
      expect(newest.before_value).to eq("integer_value" => 2) # state at revert time
      expect(newest.after_value).to eq("integer_value" => 1)  # reverted-to value
    end

    it "fires Config.on_value_change user proc (revert is a normal :update)" do
      captured = []
      TypedEAV::Config.on_value_change = lambda { |v, t, ctx|
        captured << [v.value, t, ctx[:source]]
      }

      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      target = value.history.find_by(change_type: "update")

      TypedEAV.with_context(source: :revert_test) do
        value.revert_to(target)
      end

      # The revert fires after_commit on :update → user proc fires LAST
      # (slot 0 versioning subscriber runs first). Captured event has
      # the reverted-to value (1) and the test context.
      expect(captured.last).to eq([1, :update, :revert_test])
    end
  end

  describe "context capture (caller controls revert intent)" do
    it "stores caller's with_context payload in the new version row" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      target = value.history.find_by(change_type: "update")

      TypedEAV.with_context(reverted_from_version_id: target.id, actor: "alice") do
        value.revert_to(target)
      end

      newest_version = value.history.first
      expect(newest_version.context).to eq(
        "reverted_from_version_id" => target.id,
        "actor" => "alice",
      )
    end

    it "does NOT inject reverted_from_version_id automatically (caller's choice)" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      target = value.history.find_by(change_type: "update")

      # Revert without with_context — verifies the gem doesn't auto-inject
      # reverted_from_version_id (CONTEXT §revert_to semantics §3 lock).
      value.revert_to(target)

      newest_version = value.history.first
      expect(newest_version.context).to eq({})
      expect(newest_version.context).not_to have_key("reverted_from_version_id")
    end
  end

  describe "error cases (three raise conditions in order)" do
    it "raises ArgumentError when version.value_id is nil (source Value destroyed)" do
      # Plan 04-02's subscriber writes value_id: nil for :destroy events.
      # revert_to's check 1 catches this — can't save! a destroyed AR
      # record back into existence.
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.destroy!
      destroy_version = TypedEAV::ValueVersion.where(entity: contact, change_type: "destroy").last
      expect(destroy_version.value_id).to be_nil

      # Re-create a Value with the same id won't work post-destroy in
      # general, but we can construct a stand-in to call revert_to on.
      # Actually we just need any Value to call revert_to on; the check
      # short-circuits before touching `self`.
      stand_in = described_class.create!(entity: contact, field: field, value: 99)
      expect do
        stand_in.revert_to(destroy_version)
      end.to raise_error(ArgumentError, /source Value was destroyed/)
    end

    it "raises ArgumentError when version is a :create (empty before_value) — check 2" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      create_version = value.history.find_by(change_type: "create")
      expect(create_version.before_value).to eq({})
      expect(create_version.value_id).to eq(value.id) # check 1 passes

      expect do
        value.revert_to(create_version)
      end.to raise_error(ArgumentError, /before_value is empty/)
    end

    it "raises ArgumentError when version belongs to a different Value — check 3" do
      value_a = described_class.create!(entity: contact, field: field, value: 1)
      contact_b = Contact.create!(name: "other", tenant_id: "t1")
      field_b = TypedEAV.with_scope("t1") do
        TypedEAV::Field::Integer.create!(name: "score", entity_type: "Contact", scope: "t1")
      end
      value_b = described_class.create!(entity: contact_b, field: field_b, value: 99)
      value_b.update!(value: 100) # produce an :update version
      update_version_for_b = value_b.history.find_by(change_type: "update")

      # value_id is set (check 1 passes), before_value populated (check 2
      # passes), but value_id doesn't match value_a.id → check 3 fails.
      expect do
        value_a.revert_to(update_version_for_b)
      end.to raise_error(ArgumentError, /value_id mismatch/)
    end

    it "names both ids in the value_id mismatch error (check 3)" do
      value_a = described_class.create!(entity: contact, field: field, value: 1)
      contact_b = Contact.create!(name: "other", tenant_id: "t1")
      field_b = TypedEAV.with_scope("t1") do
        TypedEAV::Field::Integer.create!(name: "score", entity_type: "Contact", scope: "t1")
      end
      value_b = described_class.create!(entity: contact_b, field: field_b, value: 99)
      value_b.update!(value: 100)
      update_version_for_b = value_b.history.find_by(change_type: "update")

      expect do
        value_a.revert_to(update_version_for_b)
      end.to raise_error(ArgumentError, /Value##{value_a.id}.*Value##{value_b.id}/)
    end

    it "check ordering: nil-value_id beats empty-before_value when both apply" do
      # Synthetic version that fails BOTH check 1 (value_id: nil) and
      # check 2 (before_value: {}). The ordered checks should raise
      # the value_id-nil error, not the before_value-empty error.
      stand_in = described_class.create!(entity: contact, field: field, value: 1)
      synthetic = TypedEAV::ValueVersion.new(
        value_id: nil,
        before_value: {},
        change_type: "destroy",
      )
      expect do
        stand_in.revert_to(synthetic)
      end.to raise_error(ArgumentError, /source Value was destroyed/)
    end
  end

  describe "save failure" do
    it "raises and does NOT write a version row when save! fails" do
      value = described_class.create!(entity: contact, field: field, value: 10)
      value.update!(value: 20)
      target = value.history.find_by(change_type: "update") # before: 10

      # Sabotage the save by stubbing validate on the specific instance.
      # Avoids allow_any_instance_of (RSpec/AnyInstance) — `value` is the
      # only instance we need to fail, and it is the same in-memory record
      # revert_to operates on.
      allow(value).to receive(:validate_value) do
        value.errors.add(:value, "sabotaged")
      end

      versions_before = TypedEAV::ValueVersion.count
      expect { value.revert_to(target) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(TypedEAV::ValueVersion.count).to eq(versions_before)
      # The Value's persisted state is unchanged (save! rolled back any
      # in-memory column writes by raising before commit).
      expect(value.reload.value).to eq(20)
    end
  end

  describe "multi-cell forward-compat" do
    it "iterates value_columns when reverting (Phase 05 Currency forward-compat)" do
      # Stub a multi-cell field type: value_columns returns 2 columns.
      multi_cell_class = Class.new(TypedEAV::Field::Base) do
        value_column :decimal_value
        define_singleton_method(:value_columns) { %i[decimal_value string_value] }
      end
      stub_const("TypedEAV::Field::Money04Plan03", multi_cell_class)

      money_field = TypedEAV.with_scope("t1") do
        TypedEAV::Field::Money04Plan03.create!(
          name: "price", entity_type: "Contact", scope: "t1",
        )
      end

      value = described_class.create!(entity: contact, field: money_field)
      value[:decimal_value] = BigDecimal("10.00")
      value[:string_value] = "USD"
      value.save! # produces a :create version

      # Update both cells.
      value[:decimal_value] = BigDecimal("20.00")
      value[:string_value] = "EUR"
      value.save! # produces an :update version with before: {dec: 10, str: USD}

      target = value.history.find_by(change_type: "update")
      expect(target.before_value).to eq("decimal_value" => "10.0", "string_value" => "USD")

      value.revert_to(target)
      value.reload

      expect(value[:decimal_value]).to eq(BigDecimal("10.00"))
      expect(value[:string_value]).to eq("USD")
    end
  end
end
