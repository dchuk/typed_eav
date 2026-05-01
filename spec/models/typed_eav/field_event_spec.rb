# frozen_string_literal: true

require "spec_helper"

# Integration specs for TypedEAV::Field::Base `after_commit` dispatch wired
# in plan 03-02 P02. Same metadata combination as value_event_spec.rb:
# `:event_callbacks` (callback-state isolation) AND `:real_commits`
# (durable after_commit firing + manual cleanup).
#
# Verifies the locked branch order from 03-CONTEXT.md §"`on_field_change`
# change_type set" → "Mechanism":
#   previously_new_record? → :create
#   destroyed?             → :destroy
#   saved_change_to_attribute?(:name) → :rename
#   else                   → :update
#
# Plus: STI subclass dispatch from the Field::Base parent declaration,
# 2-arg `(field, change_type)` signature (no context — locked asymmetry
# vs. value-change), and the field_dependent: :nullify cascade interaction
# (Field :destroy fires; Value :destroy events do NOT — the FK SET NULL
# bypasses AR callbacks).
# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
# Spec path uses field_event_spec.rb (under spec/models/typed_eav/) to group
# with value_event_spec.rb under Phase 03 event-dispatch naming. The string
# second argument "event dispatch" is a topical descriptor, not a method
# name — the integration specs cover the after_commit chain wired into
# Field::Base, not a single method.
RSpec.describe TypedEAV::Field::Base, "event dispatch", :event_callbacks, :real_commits do
  # rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
  describe ":create" do
    it "fires once with (field, :create) — TWO args, no context" do
      events = []
      TypedEAV::Config.on_field_change = ->(*args) { events << args }

      field = create(:text_field, name: "create_evt")

      expect(events.size).to eq(1)
      seen_field, seen_type = events.first
      expect(seen_field).to eq(field)
      expect(seen_type).to eq(:create)
      # Locked 2-arg contract from 03-CONTEXT.md.
      expect(events.first.size).to eq(2)
    end
  end

  describe ":update" do
    it "fires when a non-name attribute changes" do
      field = create(:text_field, name: "update_evt")
      events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

      field.update!(field_dependent: "nullify")

      expect(events).to eq([:update])
    end
  end

  describe ":destroy" do
    it "fires once on destroy commit" do
      field = create(:text_field, name: "destroy_evt")
      events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

      field.destroy!

      expect(events).to eq([:destroy])
    end
  end

  describe ":rename" do
    it "fires when only the name column changes" do
      field = create(:text_field, name: "before_rename")
      events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

      field.update!(name: "after_rename")

      expect(events).to eq([:rename])
    end

    # Locked false-positive bias from 03-CONTEXT.md §`on_field_change`
    # change_type set: `:rename` fires whenever name is among
    # saved_changes, even if combined with other attr changes. Phase 07
    # matview must regenerate column DDL on rename; missing a rename
    # bundled with other edits would corrupt the matview's column-name
    # → field-name map.
    it "fires :rename (NOT :update) when name changes alongside other attrs" do
      field = create(:text_field, name: "before_combo", sort_order: 1)
      events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

      field.update!(name: "after_combo", sort_order: 99)

      expect(events).to eq([:rename])
    end

    it ":create takes precedence when name is set on insert" do
      events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

      create(:text_field, name: "fresh_create")

      expect(events).to eq([:create])
    end
  end

  describe "STI subclass dispatch" do
    it "fires :create for every subclass via the Field::Base parent declaration" do
      events = []
      TypedEAV::Config.on_field_change = ->(f, t) { events << [f.class.name, t] }

      create(:text_field, name: "sti_text")
      create(:integer_field, name: "sti_integer")

      expect(events).to contain_exactly(
        ["TypedEAV::Field::Text", :create],
        ["TypedEAV::Field::Integer", :create],
      )
    end
  end

  describe "internal-vs-user ordering" do
    it "internal subscriber fires before user proc with identical (field, change_type)" do
      sequence = []
      TypedEAV::EventDispatcher.register_internal_field_change(
        ->(f, t) { sequence << [:internal, f.id, t] },
      )
      TypedEAV::Config.on_field_change = ->(f, t) { sequence << [:user, f.id, t] }

      field = create(:text_field, name: "ordering_evt")
      field.update!(name: "ordering_evt_renamed")

      # Two events: :create then :rename, each with internal-then-user.
      expect(sequence.map(&:first)).to eq(%i[internal user internal user])
      expect(sequence[0][1..]).to eq(sequence[1][1..])
      expect(sequence[2][1..]).to eq(sequence[3][1..])
      expect(sequence[2][2]).to eq(:rename)
      expect(sequence[2][1]).to eq(field.id)
    end
  end

  describe "user-proc error policy" do
    it "user-proc raise is rescued + logged via Rails.logger.error; save succeeds" do
      allow(Rails.logger).to receive(:error)
      TypedEAV::Config.on_field_change = ->(_f, _t) { raise "boom" }

      field = nil
      expect { field = create(:text_field, name: "rescue_evt") }.not_to raise_error
      expect(field).to be_persisted

      expect(Rails.logger).to have_received(:error).with(/on_field_change raised/)
    end
  end

  describe "field_dependent: :nullify cascade interaction" do
    it "fires Field :destroy but NO Value :destroy events (FK SET NULL bypasses AR callbacks)" do
      contact = create(:contact)
      field = create(:text_field, name: "nullify_cascade", field_dependent: "nullify")
      TypedEAV::Value.create!(entity: contact, field: field, value: "v")

      field_events = []
      value_events = []
      TypedEAV::Config.on_field_change = ->(_f, t) { field_events << t }
      TypedEAV::Config.on_value_change = ->(_v, t, _c) { value_events << t }

      field.destroy!

      expect(field_events).to eq([:destroy])
      # Locked behavior per 03-RESEARCH.md §B: ON DELETE SET NULL fires at
      # the DB level, AR callbacks bypassed entirely. No Value :destroy
      # event. No Value :update event for the field_id NULLing either.
      expect(value_events).to be_empty
    end
  end
end
