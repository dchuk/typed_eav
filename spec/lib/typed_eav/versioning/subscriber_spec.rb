# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Versioning::Subscriber, :event_callbacks do
  # Use real Contact instances + a real Field/Value because the
  # subscriber writes a ValueVersion row that depends on the value's
  # entity reference, field, etc. :real_commits ensures after_commit
  # cleanup runs cleanly between examples.

  let(:contact) { Contact.create!(name: "test", tenant_id: "t1") }
  let(:field) do
    TypedEAV.with_scope("t1") do
      TypedEAV::Field::Integer.create!(name: "age", entity_type: "Contact", scope: "t1")
    end
  end

  describe "gate behavior", :real_commits do
    # CRITICAL spec setup (Discrepancy D4): the :event_callbacks around
    # hook in spec_helper.rb:87-104 CLEARS EventDispatcher.value_change_internals
    # at example entry. Phase 04's subscriber was registered at engine boot
    # via config.after_initialize, but the around hook wipes it for the
    # duration of the example. We re-register it here so writes during
    # the example trigger the subscriber. The hook's ensure block restores
    # the pre-example snapshot, so this re-registration does NOT leak.
    before do
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::EventDispatcher.register_internal_value_change(
        described_class.method(:call),
      )
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    it "writes a version row when both gates pass" do
      value = nil
      expect do
        value = TypedEAV.with_context(actor: "alice") do
          TypedEAV::Value.create!(entity: contact, field: field, value: 42)
        end
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      version = TypedEAV::ValueVersion.last
      expect(version.value_id).to eq(value.id)
      expect(version.entity_type).to eq("Contact")
      expect(version.entity_id).to eq(contact.id)
      expect(version.change_type).to eq("create")
      expect(version.before_value).to eq({})
      expect(version.after_value).to eq("integer_value" => 42)
      expect(version.context).to eq("actor" => "alice")
    end

    it "does NOT write a version row when entity is not opted in" do
      TypedEAV.registry.register("Contact", types: nil, versioned: false)

      expect do
        TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      end.not_to change(TypedEAV::ValueVersion, :count)
    end

    it "does NOT write a version row when field is nil (orphan Value)" do
      # Direct subscriber call path — bypasses the registered-subscriber
      # chain. Verifies the in-call orphan guard works even if some future
      # caller invokes Subscriber.call directly with a fieldless value.
      orphan = instance_double(TypedEAV::Value, field: nil, entity_type: "Contact")
      expect do
        described_class.call(orphan, :create, {})
      end.not_to change(TypedEAV::ValueVersion, :count)
    end
  end

  describe "engine-boot registration gating (Config.versioning = false)", :real_commits do
    # Verifies the locked CONTEXT contract: when Config.versioning is false
    # at engine boot (default), the subscriber is NOT in
    # EventDispatcher.value_change_internals. True zero overhead.
    #
    # The :event_callbacks around hook clears value_change_internals at
    # example entry, then we invoke the production registration helper
    # (`TypedEAV::Versioning.register_if_enabled`) against the cleared
    # state with versioning=false. The helper must return early — leaving
    # the array empty AND not adding the Subscriber callable.
    #
    # The integration spec value_versioning_integration_spec.rb (P05)
    # covers the "subscriber writes rows when registered" path end-to-end.
    it "subscriber is NOT auto-fired when re-registration is omitted" do
      # No before block re-registers the subscriber. The :event_callbacks
      # hook cleared it. So writes here must NOT trigger ValueVersion.
      TypedEAV.registry.register("Contact", types: nil, versioned: true)

      expect do
        TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      end.not_to change(TypedEAV::ValueVersion, :count)
    ensure
      TypedEAV.registry.register("Contact", types: nil, versioned: false)
    end

    it "register_if_enabled with Config.versioning=false leaves value_change_internals empty (true zero overhead)" do
      # Defense-in-depth zero-overhead contract: when the helper runs
      # against the default master switch, no callable lands in the
      # dispatcher chain. This is the locked CONTEXT line 17 invariant —
      # the spec uses two assertions (be_empty AND not_to include) so any
      # future regression that adds a callable via a side path is caught
      # even if the array technically isn't empty.
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = false

      TypedEAV::Versioning.register_if_enabled

      expect(TypedEAV::EventDispatcher.value_change_internals).to be_empty
      expect(TypedEAV::EventDispatcher.value_change_internals)
        .not_to include(described_class.method(:call))
    end

    it "registering twice when versioning=true results in exactly one entry" do
      # Idempotency contract: register_if_enabled uses Array#include? to
      # check whether Subscriber.method(:call) is already in the chain.
      # Method#== compares receiver+name (semantic equality), so two
      # fresh Subscriber.method(:call) instances compare equal. The N=2
      # call sequence here protects against future code paths that might
      # re-invoke the helper for any reason — production currently calls
      # it exactly once at engine boot, but the guard makes that count
      # bound rather than convention.
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = true

      TypedEAV::Versioning.register_if_enabled
      TypedEAV::Versioning.register_if_enabled

      matching = TypedEAV::EventDispatcher.value_change_internals.count do |m|
        m == described_class.method(:call)
      end
      expect(matching).to eq(1),
                          "Calling register_if_enabled twice with versioning=true must produce " \
                          "exactly ONE Subscriber.method(:call) entry, got #{matching}. The helper's " \
                          "Array#include? guard depends on Method#== semantic equality (receiver+name); " \
                          "if this fails, the guard was removed or Method#== semantics changed in the Ruby version."
    end
  end

  describe "snapshot logic", :real_commits do
    # Re-register subscriber per Discrepancy D4. See gate-behavior block above.
    before do
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::EventDispatcher.register_internal_value_change(
        described_class.method(:call),
      )
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    it ":create snapshot has empty before, populated after" do
      TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      v = TypedEAV::ValueVersion.last
      expect(v.before_value).to eq({})
      expect(v.after_value).to eq("integer_value" => 42)
    end

    it ":update snapshot has both populated (typed-column-name keyed)" do
      value = TypedEAV::Value.create!(entity: contact, field: field, value: 41)
      value.update!(value: 42)

      versions = TypedEAV::ValueVersion.where(value_id: value.id).order(:changed_at)
      update_version = versions.last
      expect(update_version.change_type).to eq("update")
      expect(update_version.before_value).to eq("integer_value" => 41)
      expect(update_version.after_value).to eq("integer_value" => 42)
    end

    it ":destroy snapshot has populated before, empty after, AND value_id: nil" do
      value = TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      value.destroy!

      destroy_version = TypedEAV::ValueVersion.where(entity_id: contact.id, change_type: "destroy").last
      expect(destroy_version.before_value).to eq("integer_value" => 42)
      expect(destroy_version.after_value).to eq({})
      # CRITICAL: value_id is nil (not value_id_before_destroy). With
      # FK ON DELETE SET NULL, the parent Value row is gone by the time
      # after_commit fires; writing the stale id would FK-fail. The
      # subscriber explicitly writes nil for :destroy events.
      expect(destroy_version.value_id).to be_nil
      # Field is NOT destroyed — field_id remains populated for audit.
      expect(destroy_version.field_id).to eq(field.id)
      # Entity reference remains the durable identity.
      expect(destroy_version.entity_type).to eq("Contact")
      expect(destroy_version.entity_id).to eq(contact.id)
    end

    it ":destroy event does NOT raise FK violation at INSERT" do
      # Regression guard for the bug that motivated the value_id: nil
      # fix. If the subscriber wrote `value_id: value.id` for destroy,
      # this would raise ActiveRecord::InvalidForeignKey at the
      # ValueVersion.create! call (because typed_eav_values no longer
      # has the parent row at after_commit time).
      value = TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      expect { value.destroy! }.not_to raise_error
    end

    it "iterates value_columns (plural) — multi-cell forward-compat" do # rubocop:disable RSpec/ExampleLength -- multi-cell forward-compat needs full setup: anonymous Field subclass, scoped create, instance_double, stubs, then assertion. Splitting hides the contract.
      # Stub a Field subclass that overrides value_columns to a two-element
      # Array. Verify the subscriber writes both columns in the snapshot.
      multi_cell_field_class = Class.new(TypedEAV::Field::Base) do
        value_column :decimal_value
        define_singleton_method(:value_columns) { %i[decimal_value string_value] }
      end
      stub_const("TypedEAV::Field::TestMulti04Plan02", multi_cell_field_class)

      multi_field = nil
      TypedEAV.with_scope("t1") do
        multi_field = TypedEAV::Field::TestMulti04Plan02.create!(
          name: "money", entity_type: "Contact", scope: "t1",
        )
      end

      # Direct subscriber call (bypassing real Value AR write — the
      # subscriber's contract is what matters; AR plumbing is exercised
      # in the gate spec above).
      value_double = instance_double(
        TypedEAV::Value,
        id: nil, # nil because we're not creating a real Value row here
        field_id: multi_field.id,
        entity_type: "Contact",
        entity_id: contact.id,
        field: multi_field,
      )
      allow(value_double).to receive(:[]).with(:decimal_value).and_return(BigDecimal("99.99"))
      allow(value_double).to receive(:[]).with(:string_value).and_return("USD")
      allow(value_double).to receive(:attribute_before_last_save).and_return(nil)

      # For :create the subscriber writes value_id: value.id; we stubbed id to nil
      # so the FK accepts (column is nullable).
      expect do
        described_class.call(value_double, :create, {})
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      v = TypedEAV::ValueVersion.last
      expect(v.after_value).to eq(
        "decimal_value" => "99.99",
        "string_value" => "USD",
      )
    end
  end

  describe "actor coercion", :real_commits do
    # Re-register subscriber per Discrepancy D4. See gate-behavior block above.
    before do
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::EventDispatcher.register_internal_value_change(
        described_class.method(:call),
      )
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    it "coerces an AR record actor to id.to_s" do
      actor_record = Contact.create!(name: "actor", tenant_id: "t-actor")
      TypedEAV::Config.actor_resolver = -> { actor_record }

      TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      expect(TypedEAV::ValueVersion.last.changed_by).to eq(actor_record.id.to_s)
    end

    it "coerces a scalar actor to to_s" do
      TypedEAV::Config.actor_resolver = -> { "alice" }

      TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      expect(TypedEAV::ValueVersion.last.changed_by).to eq("alice")
    end

    it "writes nil changed_by when actor_resolver returns nil (permissive contract)" do
      TypedEAV::Config.actor_resolver = -> { nil } # rubocop:disable Style/NilLambda -- explicit nil body documents permissive contract
      TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      expect(TypedEAV::ValueVersion.last.changed_by).to be_nil
    end

    it "writes nil changed_by when actor_resolver is nil (no resolver configured)" do
      TypedEAV::Config.actor_resolver = nil

      TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      expect(TypedEAV::ValueVersion.last.changed_by).to be_nil
    end
  end

  describe "raise propagation (locked internal-error policy)" do
    it "lets exceptions from ValueVersion.create! propagate up" do
      # Direct subscriber call — no re-registration needed for this path.
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      allow(TypedEAV::ValueVersion).to receive(:create!).and_raise(
        ActiveRecord::RecordInvalid.new(TypedEAV::ValueVersion.new),
      )

      field_class_double = class_double(TypedEAV::Field::Integer, value_columns: [:integer_value])
      field_double = instance_double(TypedEAV::Field::Integer, class: field_class_double)
      value_double = instance_double(
        TypedEAV::Value,
        id: 1, field_id: 1, entity_type: "Contact", entity_id: 1,
        field: field_double
      )
      allow(value_double).to receive_messages("[]": 42, attribute_before_last_save: nil)

      expect do
        described_class.call(value_double, :create, {})
      end.to raise_error(ActiveRecord::RecordInvalid)
    ensure
      TypedEAV.registry.register("Contact", types: nil, versioned: false)
    end
  end

  describe "context capture" do
    it "stores TypedEAV.with_context payload in the version row's context column", :real_commits do
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      # Re-register subscriber per Discrepancy D4.
      TypedEAV::EventDispatcher.register_internal_value_change(
        described_class.method(:call),
      )

      TypedEAV.with_context(request_id: "abc", source: :api) do
        TypedEAV::Value.create!(entity: contact, field: field, value: 42)
      end

      v = TypedEAV::ValueVersion.last
      # Symbol keys serialize to string keys in jsonb. Source value :api
      # likewise serializes to "api".
      expect(v.context).to eq("request_id" => "abc", "source" => "api")
    ensure
      TypedEAV.registry.register("Contact", types: nil, versioned: false)
    end
  end

  describe "engine boot registration" do
    it "subscriber identity is comparable via .method(:call)" do
      # Document the expected callable identity. The :event_callbacks hook
      # cleared the engine-boot registration, but we can re-register here
      # and assert the identity round-trip works (matters for plan 04-03's
      # slot-0 regression spec which asserts identity equality).
      TypedEAV::EventDispatcher.register_internal_value_change(
        described_class.method(:call),
      )
      expect(TypedEAV::EventDispatcher.value_change_internals).to include(
        described_class.method(:call),
      )
    end
  end
end
