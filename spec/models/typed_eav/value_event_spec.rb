# frozen_string_literal: true

require "spec_helper"

# Integration specs for TypedEAV::Value `after_commit` dispatch wired in
# plan 03-02 P01. All examples opt into BOTH `:event_callbacks` (snapshot/
# restore Config user procs + EventDispatcher internal-subscriber lists)
# AND `:real_commits` (disable transactional fixtures so after_commit fires
# durably; manual cleanup in FK order after).
#
# Unit-side coverage of EventDispatcher (ordering, error policy, etc.) lives
# in spec/lib/typed_eav/event_dispatcher_spec.rb. This file proves the
# Value-model wiring forwards correctly to the dispatcher — including the
# orphan-skip filter, the value-column-changed update filter, and the
# locked post-destroy `value.id` readability contract.
# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
# Spec path uses value_event_spec.rb to group with field_event_spec.rb under
# Phase 03 event-dispatch naming. The string second argument "event dispatch"
# is a topical descriptor, not a method name — the integration specs cover
# the after_commit chain wired into Value, not a single method.
RSpec.describe TypedEAV::Value, "event dispatch", :event_callbacks, :real_commits do
  # rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
  let(:contact) { create(:contact) }

  describe ":create event" do
    it "fires once on the first commit" do
      events = []
      TypedEAV::Config.on_value_change = ->(v, t, c) { events << [v.id, t, c] }
      field = create(:text_field, name: "create_evt")

      value = described_class.create!(entity: contact, field: field, value: "hello")

      expect(events).to eq([[value.id, :create, {}]])
    end
  end

  describe ":update event" do
    it "fires when the typed value column changes" do
      events = []
      field = create(:text_field, name: "update_evt")
      value = described_class.create!(entity: contact, field: field, value: "first")

      TypedEAV::Config.on_value_change = ->(v, t, _c) { events << [v.id, t] }
      value.update!(value: "second")

      expect(events).to eq([[value.id, :update]])
    end

    # Amendment 3 spec rigor: do NOT use save! on a clean record (Rails
    # short-circuits before any after_commit when changes.empty?, making
    # the assertion a tautology). Use touch — it persists (writes
    # updated_at) and fires the full callback chain, but does NOT change
    # the typed value column. The filter on
    # `saved_change_to_attribute?(field.class.value_column)` must reject it.
    it "does NOT fire when only updated_at changes (touch path)" do
      events = []
      field = create(:text_field, name: "touch_evt")
      value = described_class.create!(entity: contact, field: field, value: "stable")

      TypedEAV::Config.on_value_change = ->(v, t, _c) { events << [v.id, t] }

      expect { value.touch }.not_to(change { events.size })
    end
  end

  describe ":destroy event" do
    it "fires on destroy commit and value.id is readable inside the proc" do
      # Live validation of Scout §G #5: value.id must be readable inside
      # `after_commit on: :destroy`. If this assertion fails, the
      # EventDispatcher dispatch_value_change error-log line that reads
      # `value.id` would need a fallback (capture id pre-destroy at the
      # model layer); plan 03-01 ships on the assumption it IS readable.
      captured_id = nil
      events = []
      field = create(:text_field, name: "destroy_evt")
      value = described_class.create!(entity: contact, field: field, value: "bye")
      pre_destroy_id = value.id

      TypedEAV::Config.on_value_change = lambda { |v, t, _c|
        captured_id = v.id
        events << t
      }

      value.destroy!

      expect(events).to eq([:destroy])
      expect(captured_id).to eq(pre_destroy_id)
    end
  end

  describe "orphan Value (field.nil?) skip" do
    it "fires no event after the FK NULLs field_id (cascade) AND on subsequent saves" do
      events = []
      field = create(:text_field, name: "orphan_evt", field_dependent: "nullify")
      value = described_class.create!(entity: contact, field: field, value: "v")

      # Now wire the user proc — we want only POST-cascade events captured.
      TypedEAV::Config.on_value_change = ->(v, t, _c) { events << [v.id, t] }

      # `field_dependent: :nullify` runs at the DB level (FK ON DELETE SET
      # NULL). AR callbacks are bypassed entirely — no Value :destroy or
      # :update events fire during the cascade itself. Documented in
      # 03-RESEARCH.md §B and re-stated in EventDispatcher docs.
      field.destroy!
      expect(events).to be_empty

      # Amendment 3 spec rigor: MUST call value.reload — without it the
      # in-memory `value.field` association cache returns the stale Field
      # record, so `field.nil?` would be false and the orphan-guard test
      # would pass for the wrong reason. With reload, AR re-fetches and
      # observes field_id IS NULL.
      value.reload
      expect(value.field).to be_nil

      # Now exercise the orphan guard for real: a save that would
      # otherwise fire :update must short-circuit at the model layer.
      value.touch
      expect(events).to be_empty
    end
  end

  describe "field_dependent: :destroy cascade" do
    it "fires per-Value :destroy events for every Value when the Field is destroyed" do
      events = []
      field = create(:text_field, name: "cascade_evt", field_dependent: "destroy")
      contact_a = create(:contact, name: "A")
      contact_b = create(:contact, name: "B")
      contact_c = create(:contact, name: "C")
      value_ids = [contact_a, contact_b, contact_c].map do |c|
        described_class.create!(entity: c, field: field, value: "x").id
      end

      TypedEAV::Config.on_value_change = ->(v, t, _c) { events << [v.id, t] }

      field.destroy!

      expect(events.map { |id, _t| id }).to match_array(value_ids)
      expect(events.map { |_id, t| t }).to all(eq(:destroy))
    end
  end

  describe "internal-vs-user ordering" do
    it "internal subscriber fires before user proc with identical (value, change_type, context)" do
      sequence = []
      TypedEAV::EventDispatcher.register_internal_value_change(
        ->(v, t, c) { sequence << [:internal, v.id, t, c] },
      )
      TypedEAV::Config.on_value_change = ->(v, t, c) { sequence << [:user, v.id, t, c] }

      field = create(:text_field, name: "order_evt")
      TypedEAV.with_context(actor_id: 7) do
        described_class.create!(entity: contact, field: field, value: "v")
      end

      expect(sequence.map(&:first)).to eq(%i[internal user])
      # Both saw the same args
      expect(sequence[0][1..]).to eq(sequence[1][1..])
      expect(sequence[0][3]).to eq(actor_id: 7)
    end
  end

  describe "user-proc error policy" do
    it "user-proc raise is rescued + logged; save still succeeds" do
      allow(Rails.logger).to receive(:error)
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { raise "boom" }
      field = create(:text_field, name: "rescue_evt")

      value = nil
      expect do
        value = described_class.create!(entity: contact, field: field, value: "x")
      end.not_to raise_error

      expect(value).to be_persisted
      expect(Rails.logger).to have_received(:error).with(/on_value_change raised/)
    end
  end

  describe "internal-subscriber error policy" do
    # Rails 8 default for after_commit is `raise_in_transactional_callbacks=true`.
    # Internal-subscriber raises propagate up through dispatch_value_change
    # (no rescue at that layer) and out of the AR save call. Contract from
    # 03-CONTEXT.md §"User-callback error policy": versioning failure must
    # be loud, never silent.
    it "internal-subscriber raise propagates out of the save call" do
      TypedEAV::EventDispatcher.register_internal_value_change(
        ->(_v, _t, _c) { raise "internal-must-be-loud" },
      )
      field = create(:text_field, name: "internal_raise_evt")

      expect do
        described_class.create!(entity: contact, field: field, value: "x")
      end.to raise_error(RuntimeError, "internal-must-be-loud")
    end
  end
end
