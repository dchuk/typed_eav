# frozen_string_literal: true

require "spec_helper"

# Round-4 review: cross-cutting parent_scope scenarios for the two-level
# scope partition introduced in Phase 1.
#
# Round_2 owns the leak axis (extended in this phase to cover both scope
# and parent_scope leaks). Round_3 owns the collision axis (extended in
# this phase to cover three-way precedence). This file owns the genuinely-
# new failure modes that don't have a round_2 or round_3 ancestor:
#
# Scenario A — Orphan-parent rejection at Field level: a Field row with
#   parent_scope set and scope nil is invalid. The model-level invariant
#   (Field::Base#validate_parent_scope_invariant from plan 03) prevents
#   the row from ever existing in the DB. This is a wholly new validator
#   introduced by Phase 1 — there is no two-level-scope ancestor to extend.
#
# Scenario B — Orphan-parent rejection at Section level: symmetric guard
#   inline-duplicated on Section per the CONTEXT.md "do NOT extract
#   Scopable" decision. Same rationale as A.
#
# Scenario C — Cross-(scope, parent_scope) Value rejection: a Value
#   attached to a Field whose parent_scope doesn't match the entity's
#   typed_eav_parent_scope is invalid. The Value-side guard
#   (Value#validate_field_scope_matches_entity from plan 04) extends the
#   single-axis check to the second axis. Lives at a different layer than
#   round_2 (definition-time leak) and round_3 (definition-time collision).
RSpec.describe "Round-4 review: parent_scope cross-cutting", :scoping do
  before do
    TypedEAV.config.scope_resolver = nil
    TypedEAV.config.require_scope = true
  end

  after { TypedEAV.config.reset! }

  describe "Scenario A: orphan-parent rejection at Field level" do
    it "rejects parent_scope.present? && scope.blank? at validation" do
      f = build(:integer_field, name: "x_round4_a1", entity_type: "Project", scope: nil, parent_scope: "w1")
      expect(f).not_to be_valid
      expect(f.errors[:parent_scope]).to be_present
    end

    it "rejects parent_scope.present? && scope set to empty string (treats blank like nil)" do
      f = build(:integer_field, name: "x_round4_a2", entity_type: "Project", scope: "", parent_scope: "w1")
      expect(f).not_to be_valid
      expect(f.errors[:parent_scope]).to be_present
    end

    it "accepts (scope set, parent_scope set) — the canonical full-triple shape" do
      f = build(:integer_field, name: "y_round4_a", entity_type: "Project", scope: "t1", parent_scope: "w1")
      expect(f).to be_valid
    end

    it "accepts (scope set, parent_scope nil) — the scope-only shape" do
      f = build(:integer_field, name: "z_round4_a", entity_type: "Project", scope: "t1", parent_scope: nil)
      expect(f).to be_valid
    end

    it "accepts (scope nil, parent_scope nil) — the pure-global shape" do
      f = build(:integer_field, name: "g_round4_a", entity_type: "Project", scope: nil, parent_scope: nil)
      expect(f).to be_valid
    end
  end

  describe "Scenario B: orphan-parent rejection at Section level (symmetric guard)" do
    # Symmetric to the Field-level guard: Section also rejects orphan
    # parents. Per CONTEXT.md, the validator is inline-duplicated on both
    # files rather than extracted into a shared concern.
    it "rejects orphan-parent at Section as well" do
      s = TypedEAV::Section.new(name: "S_r4_b1", code: "x_r4_b1", entity_type: "Project", scope: nil,
                                parent_scope: "w1")
      expect(s).not_to be_valid
      expect(s.errors[:parent_scope]).to be_present
    end

    it "rejects orphan-parent with empty-string scope" do
      s = TypedEAV::Section.new(name: "S_r4_b2", code: "x_r4_b2", entity_type: "Project", scope: "", parent_scope: "w1")
      expect(s).not_to be_valid
      expect(s.errors[:parent_scope]).to be_present
    end

    it "accepts (scope set, parent_scope set) on Section — symmetric to Field" do
      s = TypedEAV::Section.new(name: "S_r4_b3", code: "y_r4_b3", entity_type: "Project", scope: "t1",
                                parent_scope: "w1")
      expect(s).to be_valid
    end

    it "accepts (scope set, parent_scope nil) on Section — scope-only shape" do
      s = TypedEAV::Section.new(name: "S_r4_b4", code: "z_r4_b4", entity_type: "Project", scope: "t1",
                                parent_scope: nil)
      expect(s).to be_valid
    end

    it "accepts pure-global (scope nil, parent_scope nil) on Section" do
      s = TypedEAV::Section.new(name: "S_r4_b5", code: "g_r4_b5", entity_type: "Project", scope: nil, parent_scope: nil)
      expect(s).to be_valid
    end
  end

  describe "Scenario C: cross-(scope, parent_scope) Value rejection" do
    # Value-level guard: a Value attached to a Field with `parent_scope`
    # set must come from an entity whose `typed_eav_parent_scope` matches.
    # The Field-level orphan-parent invariant (Scenario A) guarantees that
    # `field.parent_scope.present?` implies `field.scope.present?`, so by
    # the time we reach the parent_scope branch the scope half has already
    # been validated (or was global). Hosts that didn't declare
    # `parent_scope_method:` cannot satisfy a parent_scope-bearing field —
    # `typed_eav_parent_scope` returns nil for them, which can never match
    # a non-nil `field.parent_scope`.
    let!(:full_triple_field) do
      create(:integer_field, name: "x_round4_c", entity_type: "Project", scope: "t1", parent_scope: "w1")
    end
    let!(:project_w1) { create(:project, tenant_id: "t1", workspace_id: "w1") }
    let!(:project_w2) { create(:project, tenant_id: "t1", workspace_id: "w2") }

    it "rejects a Value bound to a project in a different workspace" do
      v = TypedEAV::Value.new(entity: project_w2, field: full_triple_field, value: 1)
      expect(v).not_to be_valid
      expect(v.errors.added?(:field, :invalid)).to be true
    end

    it "accepts a Value bound to a project in the matching workspace" do
      v = TypedEAV::Value.new(entity: project_w1, field: full_triple_field, value: 1)
      expect(v).to be_valid
    end

    it "rejects a Value bound to an entity host without parent_scope_method (Contact -> full-triple field)" do
      # Contact declares only `scope_method: :tenant_id`. Its
      # `typed_eav_parent_scope` returns nil unconditionally, which can
      # never match the non-nil `field.parent_scope`. Build the Field with
      # entity_type "Contact" so the entity_type validator doesn't fire
      # first and mask the parent_scope-axis rejection.
      contact_full_triple = create(:integer_field,
                                   name: "x_round4_c_contact",
                                   entity_type: "Contact",
                                   scope: "t1",
                                   parent_scope: "w1")
      contact = create(:contact, tenant_id: "t1")
      v = TypedEAV::Value.new(entity: contact, field: contact_full_triple, value: 1)
      expect(v).not_to be_valid
      expect(v.errors.added?(:field, :invalid)).to be true
    end

    it "rejects a Value bound to a project whose workspace_id is nil (entity has no parent_scope value)" do
      # Even when the host declares `parent_scope_method:`, an instance
      # whose `workspace_id` is nil cannot match a non-nil
      # `field.parent_scope`. This is the per-instance-side mirror of
      # the host-without-parent_scope_method case above.
      project_no_workspace = create(:project, tenant_id: "t1", workspace_id: nil)
      v = TypedEAV::Value.new(entity: project_no_workspace, field: full_triple_field, value: 1)
      expect(v).not_to be_valid
      expect(v.errors.added?(:field, :invalid)).to be true
    end
  end
end
