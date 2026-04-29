# frozen_string_literal: true

require "spec_helper"

# Round-3 review: two correctness bugs around field-name collisions across
# scope partitions and the global/scoped overlap.
#
# Bug 1 — `TypedEAV.unscoped { Contact.where_typed_eav(...) }` collapsed
#   per-tenant field rows that share a name to a single definition via
#   `index_by(&:name)`. Result: a query that should match across N tenants
#   silently dropped N-1 of them. Fix: under ALL_SCOPES, OR-across all
#   matching field_ids per filter while preserving AND between filters.
#
# Bug 2 — On a scoped record where both a global (scope=NULL) and a same-name
#   scoped field exist, `initialize_typed_values` iterated raw definitions
#   (two rows) and built TWO value rows, while every other read/write path
#   collapsed via `definitions_by_name` (scoped wins). Forms rendered duplicate
#   inputs but only one round-tripped on save. Fix: route through the
#   collapsed view so exactly one value row is built, and harden read paths
#   to prefer the row tied to the winning field_id.
RSpec.describe "Round-3 review: field-name collisions across scopes", :scoping do
  before do
    TypedEAV.config.scope_resolver = nil
    TypedEAV.config.require_scope = true
  end

  after do
    TypedEAV.config.reset!
  end

  describe "Bug 1: TypedEAV.unscoped + where_typed_eav across tenants" do
    # Three tenants, each with their own per-tenant `status` field of type
    # text. Each tenant has one contact with status="active".
    let!(:status_a) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_a") }
    let!(:status_b) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_b") }
    let!(:status_c) { create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_c") }

    let!(:contact_a) do
      create(:contact, tenant_id: "tenant_a").tap do |c|
        TypedEAV::Value.create!(entity: c, field: status_a, value: "active")
      end
    end
    let!(:contact_b) do
      create(:contact, tenant_id: "tenant_b").tap do |c|
        TypedEAV::Value.create!(entity: c, field: status_b, value: "active")
      end
    end
    let!(:contact_c) do
      create(:contact, tenant_id: "tenant_c").tap do |c|
        TypedEAV::Value.create!(entity: c, field: status_c, value: "active")
      end
    end

    # Negative-control: another tenant_a contact whose status is NOT "active";
    # must NOT be returned by the eq filter.
    let!(:contact_a_inactive) do
      create(:contact, tenant_id: "tenant_a").tap do |c|
        TypedEAV::Value.create!(entity: c, field: status_a, value: "inactive")
      end
    end

    it "returns matches across ALL tenants under TypedEAV.unscoped { }" do
      results = TypedEAV.unscoped do
        Contact.where_typed_eav({ name: "status", op: :eq, value: "active" })
      end

      expect(results).to include(contact_a, contact_b, contact_c)
      expect(results).not_to include(contact_a_inactive)
    end

    it "ANDs across multiple filters under unscoped (per-filter OR over name, AND across filters)" do
      # Add an `age` integer field per tenant + values.
      age_a = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_a")
      age_b = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_b")
      age_c = create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_c")

      TypedEAV::Value.create!(entity: contact_a, field: age_a, value: 30) # match
      TypedEAV::Value.create!(entity: contact_b, field: age_b, value: 18) # status match, age fails
      TypedEAV::Value.create!(entity: contact_c, field: age_c, value: 40) # match
      TypedEAV::Value.create!(entity: contact_a_inactive, field: age_a, value: 50) # age match, status fails

      results = TypedEAV.unscoped do
        Contact.where_typed_eav(
          { name: "age", op: :gt, value: 21 },
          { name: "status", op: :eq, value: "active" },
        )
      end

      expect(results).to include(contact_a, contact_c)
      expect(results).not_to include(contact_b)            # age fails
      expect(results).not_to include(contact_a_inactive)   # status fails
    end

    it "still raises ArgumentError for unknown field names under unscoped" do
      expect do
        TypedEAV.unscoped do
          Contact.where_typed_eav({ name: "nonexistent_typo", op: :eq, value: "x" })
        end
      end.to raise_error(ArgumentError, /Unknown typed field 'nonexistent_typo'/)
    end
  end

  describe "Bug 2: global+scoped name collision on a scoped record" do
    let!(:status_global) do
      create(:text_field, name: "status", entity_type: "Contact", scope: nil)
    end
    let!(:status_scoped) do
      create(:text_field, name: "status", entity_type: "Contact", scope: "tenant_a")
    end
    let(:contact) { create(:contact, tenant_id: "tenant_a") }

    it "initialize_typed_values builds exactly ONE value row (scoped wins)" do
      TypedEAV.with_scope("tenant_a") do
        contact.initialize_typed_values
      end

      status_rows = contact.typed_values.select { |tv| tv.field.name == "status" }
      expect(status_rows.size).to eq(1)
      expect(status_rows.first.field_id).to eq(status_scoped.id)
    end

    it "typed_eav_value('status') returns the scoped value when both definitions exist" do
      # Even if a stray value row attached to the global field somehow exists
      # on this record, the scoped winner's value must be the one returned.
      #
      # Create the stray global row FIRST (smaller id, appears first under the
      # default id-asc ordering) so this test has discriminative power: a buggy
      # `candidates.first` implementation would return "global-stray", while the
      # winner-preference branch returns "scoped-wins".
      stray = TypedEAV::Value.new
      stray.entity = contact
      stray.field = status_global
      stray.value = "global-stray"
      stray.save(validate: false)
      TypedEAV::Value.create!(entity: contact, field: status_scoped, value: "scoped-wins")

      contact.reload
      expect(contact.typed_eav_value("status")).to eq("scoped-wins")
    end

    it "typed_eav_hash prefers the scoped row when both exist on the same record" do
      TypedEAV::Value.create!(entity: contact, field: status_scoped, value: "scoped-wins")
      stray = TypedEAV::Value.new
      stray.entity = contact
      stray.field = status_global
      stray.value = "global-stray"
      stray.save(validate: false)

      contact.reload
      expect(contact.typed_eav_hash["status"]).to eq("scoped-wins")
    end

    it "read paths skip orphaned value rows (field deleted out from under value)" do
      # Build a fresh field + value, then delete the field row directly to
      # simulate an FK cascade that didn't fire (or a raw-SQL delete).
      # `delete_all` bypasses `dependent: :destroy` on the field, leaving the
      # value row dangling with `field_id` pointing at a now-missing row.
      orphan_field = create(:text_field, name: "orphaned_name", entity_type: "Contact", scope: "tenant_a")
      TypedEAV::Value.create!(entity: contact, field: orphan_field, value: "stale")
      TypedEAV::Field::Base.where(id: orphan_field.id).delete_all

      contact.reload

      TypedEAV.with_scope("tenant_a") do
        expect { contact.typed_eav_value("orphaned_name") }.not_to raise_error
        expect(contact.typed_eav_value("orphaned_name")).to be_nil
        expect { contact.typed_eav_hash }.not_to raise_error
        expect(contact.typed_eav_hash).not_to have_key("orphaned_name")
      end
    end
  end

  # Phase 1 mirror of Bug 1: under TypedEAV.unscoped { }, the multimap
  # branch must OR-collapse matches across ALL (scope, parent_scope)
  # combinations, not just across scope. The `definitions_multimap_by_name`
  # helper groups by name without filtering on either axis, so every
  # tenant × workspace partition for a given field name participates in
  # the OR'd field_id IN (...) predicate.
  describe "Bug 1 mirror: TypedEAV.unscoped + where_typed_eav across (tenant, workspace)" do
    let!(:status_t1_w1) { create(:text_field, name: "status", entity_type: "Project", scope: "t1", parent_scope: "w1") }
    let!(:status_t1_w2) { create(:text_field, name: "status", entity_type: "Project", scope: "t1", parent_scope: "w2") }
    let!(:status_t2_w1) { create(:text_field, name: "status", entity_type: "Project", scope: "t2", parent_scope: "w1") }

    let!(:p_t1_w1) do
      create(:project, tenant_id: "t1", workspace_id: "w1").tap do |p|
        TypedEAV::Value.create!(entity: p, field: status_t1_w1, value: "active")
      end
    end
    let!(:p_t1_w2) do
      create(:project, tenant_id: "t1", workspace_id: "w2").tap do |p|
        TypedEAV::Value.create!(entity: p, field: status_t1_w2, value: "active")
      end
    end
    let!(:p_t2_w1) do
      create(:project, tenant_id: "t2", workspace_id: "w1").tap do |p|
        TypedEAV::Value.create!(entity: p, field: status_t2_w1, value: "active")
      end
    end
    let!(:p_t1_w1_inactive) do
      create(:project, tenant_id: "t1", workspace_id: "w1").tap do |p|
        TypedEAV::Value.create!(entity: p, field: status_t1_w1, value: "inactive")
      end
    end

    it "OR-collapses matches across all (scope, parent_scope) combinations under unscoped" do
      results = TypedEAV.unscoped do
        Project.where_typed_eav({ name: "status", op: :eq, value: "active" })
      end
      expect(results).to include(p_t1_w1, p_t1_w2, p_t2_w1)
      expect(results).not_to include(p_t1_w1_inactive)
    end

    it "ANDs across multiple filters under unscoped (per-filter OR over (scope, parent_scope), AND across)" do
      age_t1_w1 = create(:integer_field, name: "age", entity_type: "Project", scope: "t1", parent_scope: "w1")
      age_t1_w2 = create(:integer_field, name: "age", entity_type: "Project", scope: "t1", parent_scope: "w2")
      age_t2_w1 = create(:integer_field, name: "age", entity_type: "Project", scope: "t2", parent_scope: "w1")
      TypedEAV::Value.create!(entity: p_t1_w1, field: age_t1_w1, value: 30)            # match
      TypedEAV::Value.create!(entity: p_t1_w2, field: age_t1_w2, value: 18)            # status match, age fails
      TypedEAV::Value.create!(entity: p_t2_w1, field: age_t2_w1, value: 40)            # match
      TypedEAV::Value.create!(entity: p_t1_w1_inactive, field: age_t1_w1, value: 50)   # age match, status fails

      results = TypedEAV.unscoped do
        Project.where_typed_eav(
          { name: "age", op: :gt, value: 21 },
          { name: "status", op: :eq, value: "active" },
        )
      end
      expect(results).to include(p_t1_w1, p_t2_w1)
      expect(results).not_to include(p_t1_w2)
      expect(results).not_to include(p_t1_w1_inactive)
    end

    it "still raises ArgumentError for unknown field names under unscoped (parent_scope axis)" do
      expect do
        TypedEAV.unscoped do
          Project.where_typed_eav({ name: "nonexistent_typo", op: :eq, value: "x" })
        end
      end.to raise_error(ArgumentError, /Unknown typed field 'nonexistent_typo'/)
    end
  end

  # Phase 1 mirror of Bug 2: with three definitions sharing a name across
  # the three valid partition shapes (global / scope-only / full-triple),
  # `definitions_by_name` collapses them to the most-specific row via the
  # `[scope.nil? ? 0 : 1, parent_scope.nil? ? 0 : 1]` sort_by + index_by-
  # last-wins pattern. Today's two-way precedence (scoped > global)
  # generalizes to three-way (full-triple > scope-only > global).
  describe "Bug 2 mirror: three-way collision (global / scope-only / full-triple)" do
    let!(:status_global) do
      create(:text_field, name: "status", entity_type: "Project", scope: nil)
    end
    let!(:status_scope_only) do
      create(:text_field, name: "status", entity_type: "Project", scope: "tenant_a")
    end
    let!(:status_full_triple) do
      create(:text_field, name: "status", entity_type: "Project", scope: "tenant_a", parent_scope: "w1")
    end
    let(:project) { create(:project, tenant_id: "tenant_a", workspace_id: "w1") }

    it "initialize_typed_values builds exactly ONE value row (full-triple wins)" do
      TypedEAV.with_scope(%w[tenant_a w1]) do
        project.initialize_typed_values
      end
      status_rows = project.typed_values.select { |tv| tv.field.name == "status" }
      expect(status_rows.size).to eq(1)
      expect(status_rows.first.field_id).to eq(status_full_triple.id)
    end

    it "typed_eav_value('status') returns the full-triple value when all three definitions exist" do
      # Save stray rows for the lower-precedence definitions FIRST (smaller
      # ids, would appear first under id-asc) so a buggy `candidates.first`
      # implementation would return one of the strays. The winner-preference
      # branch must return the full-triple row.
      stray_global = TypedEAV::Value.new
      stray_global.entity = project
      stray_global.field = status_global
      stray_global.value = "global-stray"
      stray_global.save(validate: false)

      stray_scope_only = TypedEAV::Value.new
      stray_scope_only.entity = project
      stray_scope_only.field = status_scope_only
      stray_scope_only.value = "scope-only-stray"
      stray_scope_only.save(validate: false)

      TypedEAV::Value.create!(entity: project, field: status_full_triple, value: "full-triple-wins")

      project.reload
      TypedEAV.with_scope(%w[tenant_a w1]) do
        expect(project.typed_eav_value("status")).to eq("full-triple-wins")
      end
    end

    it "typed_eav_hash prefers the full-triple row when all three exist on the same record" do
      TypedEAV::Value.create!(entity: project, field: status_full_triple, value: "full-triple-wins")
      stray = TypedEAV::Value.new
      stray.entity = project
      stray.field = status_scope_only
      stray.value = "scope-only-stray"
      stray.save(validate: false)
      project.reload
      TypedEAV.with_scope(%w[tenant_a w1]) do
        expect(project.typed_eav_hash["status"]).to eq("full-triple-wins")
      end
    end

    it "scope-only wins over global when no full-triple exists (degenerate case matches today's two-way precedence)" do
      status_full_triple.destroy
      TypedEAV.with_scope(%w[tenant_a w1]) do
        project.initialize_typed_values
      end
      status_rows = project.typed_values.select { |tv| tv.field.name == "status" }
      expect(status_rows.size).to eq(1)
      expect(status_rows.first.field_id).to eq(status_scope_only.id)
    end
  end
end
