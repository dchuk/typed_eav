# frozen_string_literal: true

require "spec_helper"

# Regression guard for issue #21 (Field display label).
#
# WHY this is pinned (CONTEXT decision 5): `label` is purely cosmetic. A
# label change does NOT alter the (entity_type, scope, parent_scope) partition
# tuple, the machine slug `name`, or the matview column map. Phase-07's
# materialized-index DDL regeneration keys on the `:rename` change_type
# (`saved_change_to_attribute?(:name)`); regenerating DDL on a label-only edit
# would be wasted work at best and, if a future refactor ever WIDENED the
# rename discriminator to also key on `:label`, would corrupt the
# column-name → field-name map. This spec fails if a label-only edit ever
# dispatches `:rename` instead of `:update`.
#
# The assertions target the change_type, not merely event presence — for
# contrast we also pin that a `:name` change still fires `:rename`, so the
# discriminator is proven, not just "something fired".
#
# Uses the same metadata as field_event_spec.rb: `:event_callbacks` (callback
# state isolation) AND `:real_commits` (durable after_commit firing + manual
# cleanup).
RSpec.describe "issue #21: label-only edit dispatches :update, never :rename",
               :event_callbacks, :real_commits, type: :model do
  it "fires :update (NEVER :rename) when ONLY label changes" do
    field = create(:text_field, name: "label_only_edit", label: "Original")
    events = []
    TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

    field.update!(label: "Renamed Label")

    expect(events).to eq([:update])
    expect(events).not_to include(:rename)
  end

  it "fires :update when label changes from nil to a value" do
    field = create(:text_field, name: "label_set_first_time", label: nil)
    events = []
    TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

    field.update!(label: "Now Has A Label")

    expect(events).to eq([:update])
    expect(events).not_to include(:rename)
  end

  it "still fires :rename when :name changes (discriminator proof)" do
    field = create(:text_field, name: "before_rename_guard", label: "Stable Label")
    events = []
    TypedEAV::Config.on_field_change = ->(_f, t) { events << t }

    field.update!(name: "after_rename_guard")

    expect(events).to eq([:rename])
  end
end
