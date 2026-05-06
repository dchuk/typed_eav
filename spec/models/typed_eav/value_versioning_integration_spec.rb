# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/DescribeMethod
# Spec path uses value_versioning_integration_spec.rb to group with the other
# value_*_spec.rb files. The string second argument is a topical descriptor,
# not a method name — the file covers the end-to-end Phase 04 versioning
# pipeline (Config + Subscriber + Registry + Value lifecycle).
RSpec.describe TypedEAV::Value, "versioning integration", :event_callbacks, :real_commits do
  # rubocop:enable RSpec/DescribeMethod
  # End-to-end: Phase 04 subscriber + opted-in Contact + Config.versioning
  # = true. Verifies the full pipeline from Value.create!/update!/destroy!
  # through to ValueVersion rows being persisted with the correct shape.
  #
  # CRITICAL spec setup (Discrepancy D4): the :event_callbacks hook clears
  # value_change_internals at example entry, so the engine-boot-registered
  # subscriber is gone. We re-register it explicitly here.

  before do
    TypedEAV.registry.register("Contact", types: nil, versioned: true)
    TypedEAV::Config.versioning = true
    TypedEAV::Config.actor_resolver = -> { "test-actor" }
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

  describe ":create lifecycle" do
    it "writes one version row with change_type 'create'" do
      expect do
        TypedEAV.with_context(source: :test) do
          described_class.create!(entity: contact, field: field, value: 42)
        end
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      v = TypedEAV::ValueVersion.last
      expect(v.change_type).to eq("create")
      expect(v.before_value).to eq({})
      expect(v.after_value).to eq("integer_value" => 42)
      expect(v.changed_by).to eq("test-actor")
      expect(v.context).to eq("source" => "test")
      expect(v.changed_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe ":update lifecycle (the singular→plural fix matters here)" do
    it "writes a version row when the typed column changes" do
      value = described_class.create!(entity: contact, field: field, value: 41)

      expect do
        value.update!(value: 42)
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      update_v = TypedEAV::ValueVersion.where(change_type: "update").last
      expect(update_v.before_value).to eq("integer_value" => 41)
      expect(update_v.after_value).to eq("integer_value" => 42)
    end

    it "does NOT write a version row on touch (no typed-column change)" do
      value = described_class.create!(entity: contact, field: field, value: 42)
      initial_count = TypedEAV::ValueVersion.count

      value.touch # Updates updated_at only — no typed-column change

      # Phase 03 :update dispatch gate (now using value_columns.any?)
      # short-circuits because no value_column changed. Subscriber is
      # never called. No new ValueVersion row.
      expect(TypedEAV::ValueVersion.count).to eq(initial_count)
    end
  end

  describe ":destroy lifecycle" do
    it "writes a version row with change_type 'destroy' and value_id: nil" do
      value = described_class.create!(entity: contact, field: field, value: 42)

      expect do
        value.destroy!
      end.to change(TypedEAV::ValueVersion, :count).by(1)

      destroy_v = TypedEAV::ValueVersion.where(change_type: "destroy").last
      expect(destroy_v.before_value).to eq("integer_value" => 42)
      expect(destroy_v.after_value).to eq({})
      # value_id is nil — by after_commit time the parent typed_eav_values
      # row is already gone (Postgres commits DELETE before invoking
      # after_commit callbacks). Subscriber writes nil explicitly to
      # avoid FK-violating INSERT. Audit identity preserved via entity_*
      # and field_id.
      expect(destroy_v.value_id).to be_nil
      expect(destroy_v.field_id).to eq(field.id)
      expect(destroy_v.entity_type).to eq("Contact")
      expect(destroy_v.entity_id).to eq(contact.id)
    end

    it "destroy does NOT raise FK violation" do
      # Regression guard for the bug that motivated value_id: nil.
      value = described_class.create!(entity: contact, field: field, value: 42)
      expect { value.destroy! }.not_to raise_error
    end
  end

  describe "opt-out paths" do
    it "writes no version rows when entity is not opted in (Registry gate)" do
      TypedEAV.registry.register("Contact", types: nil, versioned: false)

      expect do
        v = described_class.create!(entity: contact, field: field, value: 42)
        v.update!(value: 43)
        v.destroy!
      end.not_to change(TypedEAV::ValueVersion, :count)
    end

    it "writes no version rows when subscriber is not registered (engine-boot gate)" do
      # Simulate the production "Config.versioning = false" path by
      # deliberately NOT having the subscriber in the chain — clear it after
      # the before block ran. This mimics the engine-boot decision to
      # skip registration when versioning is off.
      TypedEAV::EventDispatcher.value_change_internals.clear

      expect do
        v = described_class.create!(entity: contact, field: field, value: 42)
        v.update!(value: 43)
        v.destroy!
      end.not_to change(TypedEAV::ValueVersion, :count)
    end
  end

  describe "audit chain across multiple mutations" do
    # Four-mutation audit chain across with_context blocks. Each mutation
    # writes one ValueVersion row; the spec asserts the full timeline
    # (count, change_types, context.actor_ids, snapshot shapes).
    it "captures a full audit history for one Value across create/update/update/destroy" do
      value = nil
      TypedEAV.with_context(actor_id: 1) do
        value = described_class.create!(entity: contact, field: field, value: 1)
      end
      TypedEAV.with_context(actor_id: 2) { value.update!(value: 2) }
      TypedEAV.with_context(actor_id: 3) { value.update!(value: 3) }
      TypedEAV.with_context(actor_id: 4) { value.destroy! }

      versions = TypedEAV::ValueVersion.where(entity_id: contact.id).order(:changed_at)
      expect(versions.size).to eq(4)
      expect(versions.map(&:change_type)).to eq(%w[create update update destroy])
      expect(versions.map { |v| v.context["actor_id"] }).to eq([1, 2, 3, 4])
      expect(versions.first.after_value).to eq("integer_value" => 1)
      expect(versions.last.before_value).to eq("integer_value" => 3)
      expect(versions.last.after_value).to eq({})
    end
  end

  describe "registration is conditional on engine-boot Config.versioning" do
    # Documents the locked trade-off (Plan-time decision §6): runtime
    # toggles after config.after_initialize have NO effect. Apps must
    # restart the process to pick up a Config.versioning flip. This is
    # the cost of true zero-overhead-when-off.
    it "runtime toggle of Config.versioning does NOT affect already-registered subscriber" do
      # Subscriber was re-registered in `before`. Toggling Config.versioning
      # to false at example time does not unregister it — the subscriber
      # no longer reads Config.versioning at call time (the gate moved to
      # registration time). Writes still produce version rows.
      TypedEAV::Config.versioning = false

      expect do
        described_class.create!(entity: contact, field: field, value: 1)
      end.to change(TypedEAV::ValueVersion, :count).by(1)
    end
  end
end
