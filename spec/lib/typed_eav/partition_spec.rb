# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Partition, :scoping do
  describe ".visible_fields" do
    it "returns global, scope-only, and full-tuple fields for an explicit partition tuple" do
      global = create(:text_field, name: "global_status", entity_type: "Project")
      scope_only = create(:text_field, name: "tenant_status", entity_type: "Project", scope: "t1")
      full_tuple = create(
        :text_field,
        name: "workspace_status",
        entity_type: "Project",
        scope: "t1",
        parent_scope: "w1",
      )
      other_scope = create(:text_field, name: "other_tenant_status", entity_type: "Project", scope: "t2")
      other_parent = create(
        :text_field,
        name: "other_workspace_status",
        entity_type: "Project",
        scope: "t1",
        parent_scope: "w2",
      )

      fields = described_class.visible_fields(entity_type: "Project", scope: "t1", parent_scope: "w1")

      expect(fields).to contain_exactly(global, scope_only, full_tuple)
      expect(fields).not_to include(other_scope, other_parent)
    end

    it "keeps global partition lookup distinct from all-partitions admin bypass" do
      global = create(:text_field, name: "global_status", entity_type: "Project")
      scoped = create(:text_field, name: "tenant_status", entity_type: "Project", scope: "t1")

      global_partition = described_class.visible_fields(entity_type: "Project", scope: nil, parent_scope: nil)
      all_partitions = described_class.visible_fields(entity_type: "Project", mode: :all_partitions)

      expect(global_partition).to contain_exactly(global)
      expect(all_partitions).to contain_exactly(global, scoped)
    end
  end

  describe ".effective_fields_by_name" do
    it "returns one field per name with the most-specific field winning" do
      create(:text_field, name: "status", entity_type: "Project")
      create(:text_field, name: "status", entity_type: "Project", scope: "t1")
      full_tuple = create(:text_field, name: "status", entity_type: "Project", scope: "t1", parent_scope: "w1")
      other = create(:integer_field, name: "priority", entity_type: "Project", scope: "t1", parent_scope: "w1")

      fields_by_name = described_class.effective_fields_by_name(entity_type: "Project", scope: "t1", parent_scope: "w1")

      expect(fields_by_name).to eq("status" => full_tuple, "priority" => other)
    end
  end

  describe ".visible_sections" do
    it "returns global, scope-only, and full-tuple sections for an explicit partition tuple" do
      global = project_section(name: "Global", code: "global")
      scope_only = project_section(name: "Tenant", code: "tenant", scope: "t1")
      full_tuple = project_section(name: "Workspace", code: "workspace", scope: "t1", parent_scope: "w1")
      other_scope = project_section(name: "Other tenant", code: "other_tenant", scope: "t2")
      other_parent = project_section(name: "Other workspace", code: "other_workspace", scope: "t1", parent_scope: "w2")

      sections = described_class.visible_sections(entity_type: "Project", scope: "t1", parent_scope: "w1")

      expect(sections).to contain_exactly(global, scope_only, full_tuple)
      expect(sections).not_to include(other_scope, other_parent)
    end
  end

  describe ".find_visible_section!" do
    it "returns a visible section and rejects a section outside the tuple" do
      visible = create(:typed_section, name: "Visible", code: "visible", entity_type: "Project", scope: "t1")
      hidden = create(:typed_section, name: "Hidden", code: "hidden", entity_type: "Project", scope: "t2")

      found = described_class.find_visible_section!(visible.id, entity_type: "Project", scope: "t1", parent_scope: nil)

      expect(found).to eq(visible)
      expect do
        described_class.find_visible_section!(hidden.id, entity_type: "Project", scope: "t1", parent_scope: nil)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "rejects parent_scope without scope" do
    expect do
      described_class.visible_fields(entity_type: "Project", scope: nil, parent_scope: "w1")
    end.to raise_error(ArgumentError, /parent_scope cannot be set when scope is blank/)
  end

  def project_section(name:, code:, scope: nil, parent_scope: nil)
    create(
      :typed_section,
      name: name,
      code: code,
      entity_type: "Project",
      scope: scope,
      parent_scope: parent_scope,
    )
  end
end
