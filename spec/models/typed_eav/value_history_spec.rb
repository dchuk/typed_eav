# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Value, "#history", :event_callbacks, :real_commits do
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

  describe "empty history" do
    # Strategy (a) from plan amendment R2: undo the outer `before` block's
    # subscriber registration for this example. The :event_callbacks around
    # hook clears value_change_internals at example entry, then the outer
    # `before` re-registers the subscriber. Here we clear it again so the
    # subscriber never fires and no version row is written — the cleanest
    # representation of "Value exists without an audit trail" for the empty-
    # history assertion. Setting Config.versioning = false at call time
    # would NOT suppress the subscriber under the amended design (the
    # master switch is enforced at registration time, not per call).
    it "returns an empty relation when no versions exist" do
      TypedEAV::EventDispatcher.value_change_internals.clear
      value = described_class.create!(entity: contact, field: field, value: 42)

      expect(value.history).to be_empty
      expect(value.history).to be_a(ActiveRecord::Relation)
    end
  end

  describe "ordering" do
    it "returns versions most-recent-first" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      value.update!(value: 3)

      changed_ats = value.history.pluck(:changed_at)
      expect(changed_ats).to eq(changed_ats.sort.reverse)
    end

    it "tie-breaks on id (descending) when changed_at ties" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      # Force two version rows with identical changed_at via direct
      # ValueVersion.create! (bypasses the subscriber's Time.current).
      pinned = Time.current
      v1 = TypedEAV::ValueVersion.create!(
        value: value, entity: contact, field: field,
        change_type: "update", changed_at: pinned,
        before_value: { "integer_value" => 10 }, after_value: { "integer_value" => 20 }
      )
      v2 = TypedEAV::ValueVersion.create!(
        value: value, entity: contact, field: field,
        change_type: "update", changed_at: pinned,
        before_value: { "integer_value" => 20 }, after_value: { "integer_value" => 30 }
      )

      ids_in_order = value.history.pluck(:id)
      # v2 has higher id (created second) — appears first in DESC ordering.
      expect(ids_in_order).to start_with([v2.id, v1.id])
    end
  end

  describe "return type" do
    it "returns ValueVersion records" do
      value = described_class.create!(entity: contact, field: field, value: 42)
      expect(value.history.first).to be_a(TypedEAV::ValueVersion)
    end

    it "returns a chainable relation" do
      value = described_class.create!(entity: contact, field: field, value: 1)
      value.update!(value: 2)
      value.update!(value: 3)

      # Chain .where to filter
      updates_only = value.history.where(change_type: "update")
      expect(updates_only.count).to eq(2)

      # Chain .limit to paginate
      latest_one = value.history.limit(1)
      expect(latest_one.count).to eq(1)
    end
  end

  describe "post-destruction (orphaned destroy versions)" do
    # Documents the locked semantic from plan 04-02 amendment: :destroy
    # versions are written with `value_id: nil` (FK ON DELETE SET NULL +
    # post-after_commit-DELETE timing — the parent row is gone by INSERT
    # time and writing the in-memory value.id would FK-fail). Because
    # `Value#history` is `versions.order(...)` — an association keyed on
    # value_id — destroy versions never appear there. The canonical path
    # for "full lifecycle audit including destroy" is the entity-scoped
    # query on TypedEAV::ValueVersion directly. README §"Querying full
    # audit history" documents this for end users.

    it "excludes :destroy pre-destroy; entity-scoped query exposes full lifecycle post-destroy" do
      value = described_class.create!(entity: contact, field: field, value: 42)
      value.update!(value: 43)

      # PRE-destroy assertion: value.history is `versions.order(...)`,
      # keyed on value_id. The destroy version hasn't been written yet,
      # so this naturally excludes destroy. The `Value#history` excludes
      # `:destroy` semantic is what we want to lock in: even when (in a
      # future code path) destroy versions exist, the value_id-keyed
      # association cannot surface them because plan 04-02's subscriber
      # writes `value_id: nil` for destroys (the parent typed_eav_values
      # row is gone by INSERT time, so writing a non-nil value_id would
      # FK-fail).
      pre_destroy_types = value.history.pluck(:change_type)
      expect(pre_destroy_types).to contain_exactly("create", "update")
      expect(pre_destroy_types).not_to include("destroy")

      # Capture identifiers before destroy — the AR object is gone after
      # destroy! and we can't call instance methods on it.
      contact_id = contact.id
      field_id = field.id
      value.destroy! # writes a destroy version with value_id: nil

      # Schema reality (locked at db/migrate/20260505000000_create_typed_eav_value_versions.rb):
      # the value_id FK is `ON DELETE SET NULL`, so destroying the parent
      # Value also nullifies value_id on every pre-existing :create / :update
      # version row. Combined with the subscriber writing `value_id: nil`
      # for the new :destroy version, ALL version rows for this Value
      # end up with `value_id: nil` after destruction. The entity-scoped
      # query is the canonical lookup for the full audit lifecycle —
      # `entity_type + entity_id + field_id` are durable identifiers that
      # survive Value destruction (destroying a Value does not destroy
      # its Field).

      full_history = TypedEAV::ValueVersion
                     .where(entity_type: "Contact", entity_id: contact_id, field_id: field_id)
                     .order(changed_at: :desc, id: :desc)
      change_types_full = full_history.pluck(:change_type)
      expect(change_types_full).to include("create", "update", "destroy")

      # The destroy version IS present in the entity-scoped query with
      # the documented row shape (value_id: nil, before populated, after empty).
      destroy_version = full_history.find_by(change_type: "destroy")
      expect(destroy_version).not_to be_nil
      expect(destroy_version.value_id).to be_nil
      expect(destroy_version.before_value).to eq("integer_value" => 43)
      expect(destroy_version.after_value).to eq({})
      # field_id remains populated because destroying a Value doesn't
      # destroy its Field.
      expect(destroy_version.field_id).to eq(field_id)
    end
  end

  describe "scoping (does not see other Values' versions)" do
    it "scopes versions to the calling Value's id" do
      value_a = described_class.create!(entity: contact, field: field, value: 1)

      contact_b = Contact.create!(name: "other", tenant_id: "t1")
      field_b = TypedEAV.with_scope("t1") do
        TypedEAV::Field::Integer.create!(name: "score", entity_type: "Contact", scope: "t1")
      end
      value_b = described_class.create!(entity: contact_b, field: field_b, value: 99)
      value_b.update!(value: 100)

      expect(value_a.history.count).to eq(1) # just the create
      expect(value_b.history.count).to eq(2) # create + update
      # Cross-check: value_a's history doesn't include value_b's versions
      expect(value_a.history.pluck(:value_id).uniq).to eq([value_a.id])
    end
  end
end
