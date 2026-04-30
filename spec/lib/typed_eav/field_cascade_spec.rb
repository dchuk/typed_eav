# frozen_string_literal: true

require "spec_helper"

# Cascade-policy coverage for `field_dependent` on TypedEAV::Field::Base.
# Three policies × partition variations (global / scoped / parent-scoped),
# with the `:scoping` metadata on every example because the partitioned
# variants set up scope explicitly via the entity's typed_eav_scope and
# typed_eav_parent_scope rather than via TypedEAV.with_scope.
#
# Why this file lives in spec/lib/typed_eav/ rather than spec/models/: the
# behaviour under test is the cascade *policy dispatch* (a cross-cutting
# concern owned by Field::Base + the FK), not Field's per-type validation.
# Mirrors the precedent of spec/lib/typed_eav/scoping_spec.rb covering
# scope-resolution behaviour outside the per-class field_spec/value_spec
# files.
# rubocop:disable RSpec/SpecFilePathFormat -- file lives under spec/lib/ to
# group cross-cutting cascade-policy behavior alongside scoping_spec.rb;
# moving it under spec/models/typed_eav/field/ would split the partition-
# variation matrix away from the spec/lib/ pattern documented in TESTING.md.
RSpec.describe TypedEAV::Field::Base, type: :model do
  describe "field_dependent: 'destroy'" do
    it "destroys all Value rows for a global field when the field is destroyed", :scoping do
      contact = create(:contact)
      field = create(:text_field, name: "global_destroy", entity_type: "Contact", field_dependent: "destroy")
      TypedEAV::Value.create!(entity: contact, field: field, value: "v")

      expect { field.destroy }
        .to change(TypedEAV::Value, :count).by(-1)
      expect(TypedEAV::Value.where(field_id: nil).count).to eq(0)
    end

    it "destroys only the Value rows for the destroyed scoped field, leaving siblings intact", :scoping do
      sibling_contact = create(:contact, tenant_id: "t2")
      target_contact = create(:contact, tenant_id: "t1")

      target_field = create(:text_field, name: "scoped_destroy", entity_type: "Contact", scope: "t1",
                                         field_dependent: "destroy")
      sibling_field = create(:text_field, name: "scoped_destroy", entity_type: "Contact", scope: "t2",
                                          field_dependent: "destroy")

      TypedEAV::Value.create!(entity: target_contact, field: target_field, value: "x")
      TypedEAV::Value.create!(entity: sibling_contact, field: sibling_field, value: "y")

      expect { target_field.destroy }.to change(TypedEAV::Value, :count).by(-1)

      expect(TypedEAV::Value.where(field_id: target_field.id).count).to eq(0)
      expect(TypedEAV::Value.where(field_id: sibling_field.id).count).to eq(1)
    end

    it "destroys Value rows for a parent-scoped field; orphaned scope siblings unaffected", :scoping do
      project = create(:project, tenant_id: "t1", workspace_id: "w1")
      project_other = create(:project, tenant_id: "t1", workspace_id: "w2")

      target_field = create(:text_field, name: "ps_destroy", entity_type: "Project",
                                         scope: "t1", parent_scope: "w1",
                                         field_dependent: "destroy")
      other_field = create(:text_field, name: "ps_destroy", entity_type: "Project",
                                        scope: "t1", parent_scope: "w2",
                                        field_dependent: "destroy")

      TypedEAV::Value.create!(entity: project, field: target_field, value: "a")
      TypedEAV::Value.create!(entity: project_other, field: other_field, value: "b")

      expect { target_field.destroy }.to change(TypedEAV::Value, :count).by(-1)
      expect(TypedEAV::Value.where(field_id: other_field.id).count).to eq(1)
    end
  end

  describe "field_dependent: 'nullify'" do
    it "leaves Value rows in DB with field_id IS NULL when a global field is destroyed", :scoping do
      contact = create(:contact)
      field = create(:text_field, name: "global_nullify", entity_type: "Contact", field_dependent: "nullify")
      TypedEAV::Value.create!(entity: contact, field: field, value: "v")

      field.destroy

      expect(TypedEAV::Value.where(field_id: nil).count).to eq(1)
      expect(TypedEAV::Value.count).to eq(1)
    end

    it "nullifies field_id on a parent-scoped field; entity reads silently skip orphans", :scoping do
      project = create(:project, tenant_id: "t1", workspace_id: "w1")
      field = create(:text_field, name: "ps_nullify", entity_type: "Project",
                                  scope: "t1", parent_scope: "w1",
                                  field_dependent: "nullify")
      TypedEAV::Value.create!(entity: project, field: field, value: "v")

      field.destroy

      expect(TypedEAV::Value.where(field_id: nil).count).to eq(1)
      # Read-path orphan guard: typed_eav_hash silently skips field-nil rows
      # (PATTERNS.md §"Defend the read path"). Reload to drop the stale
      # association cache before re-reading.
      project.reload
      expect(project.typed_eav_hash).to eq({})
    end
  end

  describe "field_dependent: 'restrict_with_error'" do
    it "blocks destroy when Values exist; field row remains and base error is added", :scoping do
      contact = create(:contact)
      field = create(:text_field, name: "global_restrict", entity_type: "Contact",
                                  field_dependent: "restrict_with_error")
      TypedEAV::Value.create!(entity: contact, field: field, value: "v")

      result = field.destroy

      expect(result).to be(false)
      expect(field.errors[:base]).to include(a_string_matching(/Cannot delete field/))
      expect(described_class.where(id: field.id)).to exist
      expect(TypedEAV::Value.where(field_id: field.id).count).to eq(1)
      # field_dependent is unchanged (not flipped to nullify by the failed destroy)
      expect(field.reload.field_dependent).to eq("restrict_with_error")
    end

    it "permits destroy when no Values exist", :scoping do
      field = create(:text_field, name: "empty_restrict", entity_type: "Contact",
                                  field_dependent: "restrict_with_error")

      expect { field.destroy }.to change(described_class, :count).by(-1)
    end

    it "blocks destroy on a parent-scoped field with Values; siblings unaffected", :scoping do
      project = create(:project, tenant_id: "t1", workspace_id: "w1")
      target = create(:text_field, name: "ps_restrict", entity_type: "Project",
                                   scope: "t1", parent_scope: "w1",
                                   field_dependent: "restrict_with_error")
      sibling = create(:text_field, name: "ps_restrict", entity_type: "Project",
                                    scope: "t1", parent_scope: "w2",
                                    field_dependent: "restrict_with_error")
      TypedEAV::Value.create!(entity: project, field: target, value: "a")

      expect(target.destroy).to be(false)
      expect(target.errors[:base]).to be_present
      expect(described_class.where(id: target.id)).to exist
      # sibling has no values — should still destroy cleanly
      expect { sibling.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
# rubocop:enable RSpec/SpecFilePathFormat
