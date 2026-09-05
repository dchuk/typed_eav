# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/ExampleLength -- the instrumentation and two-axis scope examples each verify one end-to-end public contract.
RSpec.describe TypedEAV::ScalarQuery, "#order_typed_eav", :aggregate_failures do
  def create_value(entity, field, value)
    TypedEAV::Value.create!(entity: entity, field: field, value: value)
  end

  describe "scalar ordering" do
    let!(:score_field) { create(:integer_field, name: "score", entity_type: "Contact") }
    let!(:high) { create(:contact, name: "High") }
    let!(:low) { create(:contact, name: "Low") }
    let!(:explicit_null) { create(:contact, name: "Explicit null") }
    let!(:missing) { create(:contact, name: "Missing") }

    before do
      create_value(low, score_field, 10)
      create_value(high, score_field, 20)
      create_value(explicit_null, score_field, nil)
    end

    it "orders ascending and descending in SQL with NULLS LAST by default" do
      expected_nulls = [explicit_null, missing].sort_by(&:id)

      expect(Contact.order_typed_eav("score", scope: nil)).to eq([low, high] + expected_nulls)
      expect(
        Contact.order_typed_eav("score", direction: :desc, scope: nil),
      ).to eq([high, low] + expected_nulls)
    end

    it "allows explicit NULLS FIRST placement" do
      expected_nulls = [explicit_null, missing].sort_by(&:id)

      expect(Contact.order_typed_eav("score", nulls: :first, scope: nil)).to eq(expected_nulls + [low, high])
      expect(
        Contact.order_typed_eav("score", direction: :desc, nulls: :first, scope: nil),
      ).to eq(expected_nulls + [high, low])
    end

    it "keeps caller filters and pagination while typed ordering has precedence" do
      relation = Contact.where(id: [low.id, high.id, missing.id]).order(name: :desc).limit(2)

      expect(relation.order_typed_eav("score", scope: nil)).to eq([low, high])
      expect(relation.order_typed_eav("score", scope: nil).to_sql).to include("LIMIT 2")

      paged = Contact.where(id: [low.id, high.id, missing.id]).limit(1).offset(1)
      expect(paged.order_typed_eav("score", scope: nil)).to eq([high])
      expect(paged.order_typed_eav("score", scope: nil).to_sql).to include("OFFSET 1")
    end

    it "does not hydrate hosts or values until the returned relation executes" do
      observed_sql = []
      value_instantiations = 0
      host_instantiations = 0
      value_instantiate = TypedEAV::Value.method(:instantiate)
      host_instantiate = Contact.method(:instantiate)

      allow(TypedEAV::Value).to receive(:instantiate) do |*args|
        value_instantiations += 1
        value_instantiate.call(*args)
      end
      allow(Contact).to receive(:instantiate) do |*args|
        host_instantiations += 1
        host_instantiate.call(*args)
      end

      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        observed_sql << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      relation = nil
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        relation = Contact.order_typed_eav("score", scope: nil)
      end

      expect(value_instantiations).to eq(0)
      expect(host_instantiations).to eq(0)
      expect(observed_sql).not_to include(a_string_matching(/FROM "contacts"/i))
      expect(observed_sql).not_to include(a_string_matching(/FROM "typed_eav_values"/i))

      observed_sql.clear
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.load }

      expect(host_instantiations).to eq(4)
      expect(value_instantiations).to eq(0)
      expect(observed_sql.count { |sql| sql.match?(/FROM "contacts"/i) }).to eq(1)
      expect(observed_sql.count { |sql| sql.match?(/FROM "typed_eav_values"/i) }).to eq(1)
    end

    it "uses a correlated typed-value scalar subquery with a stable PK tie-break" do
      tie_late = create(:contact, name: "Tie late")
      tie_early = create(:contact, name: "Tie early")
      create_value(tie_late, score_field, 30)
      create_value(tie_early, score_field, 30)

      expect(Contact.order_typed_eav("score", scope: nil).to_a[2, 2]).to eq([tie_late, tie_early].sort_by(&:id))

      sql = Contact.order_typed_eav("score", scope: nil).to_sql

      expect(sql).to include("SELECT \"typed_eav_values\".\"integer_value\"")
      expect(sql).to include("\"typed_eav_values\".\"entity_id\" = \"contacts\".\"id\"")
      expect(sql).to include("NULLS LAST")
      expect(sql).to include("\"contacts\".\"id\" ASC")
    end
  end

  describe "definition resolution", :scoping do
    it "uses the most-specific field definition for an explicit partition" do
      global = create(:integer_field, name: "score", entity_type: "Contact")
      scoped = create(:integer_field, name: "score", entity_type: "Contact", scope: "tenant-1")
      global_contact = create(:contact, name: "Global", tenant_id: "tenant-1")
      scoped_contact = create(:contact, name: "Scoped", tenant_id: "tenant-1")

      create_value(global_contact, global, 90)
      create_value(scoped_contact, scoped, 10)

      expect(Contact.order_typed_eav("score", scope: "tenant-1")).to eq([scoped_contact, global_contact])
    end

    it "resolves the ambient scope and both partition axes without filtering hosts" do
      tenant_one = create(:integer_field, name: "ambient_score", entity_type: "Contact", scope: "tenant-1")
      tenant_two = create(:integer_field, name: "ambient_score", entity_type: "Contact", scope: "tenant-2")
      first = create(:contact, name: "First", tenant_id: "tenant-1")
      second = create(:contact, name: "Second", tenant_id: "tenant-2")

      create_value(first, tenant_one, 20)
      create_value(second, tenant_two, 10)

      tenant_one_order = TypedEAV.with_scope("tenant-1") do
        Contact.order_typed_eav("ambient_score", direction: :desc)
      end
      tenant_two_order = TypedEAV.with_scope("tenant-2") do
        Contact.order_typed_eav("ambient_score", direction: :desc)
      end

      expect(tenant_one_order).to eq([first, second])
      expect(tenant_two_order).to eq([second, first])

      workspace_one = create(
        :integer_field,
        name: "workspace_score",
        entity_type: "Project",
        scope: "tenant-1",
        parent_scope: "workspace-1",
      )
      workspace_two = create(
        :integer_field,
        name: "workspace_score",
        entity_type: "Project",
        scope: "tenant-1",
        parent_scope: "workspace-2",
      )
      project_one = create(:project, name: "Project 1", tenant_id: "tenant-1", workspace_id: "workspace-1")
      project_two = create(:project, name: "Project 2", tenant_id: "tenant-1", workspace_id: "workspace-2")
      create_value(project_one, workspace_one, 20)
      create_value(project_two, workspace_two, 10)

      relation = TypedEAV.with_scope(%w[tenant-1 workspace-1]) do
        Project.order_typed_eav("workspace_score", direction: :desc)
      end
      expect(relation).to eq([project_one, project_two])
    end

    it "resolves inherited hosts through their canonical polymorphic type" do
      score = create(:integer_field, name: "sti_score", entity_type: "Contact")
      premium = PremiumContact.create!(name: "Premium", tenant_id: nil)
      sibling_class = stub_const("SiblingPremiumContact", Class.new(Contact))
      sibling = sibling_class.create!(name: "Sibling", tenant_id: nil)
      base = Contact.create!(name: "Base", tenant_id: nil)
      create_value(premium, score, 7)
      create_value(sibling, score, 8)
      create_value(base, score, 9)

      expect(PremiumContact.order_typed_eav("sti_score", scope: nil)).to eq([premium])
      expect(PremiumContact.order_typed_eav("sti_score", scope: nil).to_sql).to include("'Contact'")
    end
  end

  describe "validation" do
    it "rejects invalid direction and null placement" do
      create(:integer_field, name: "score", entity_type: "Product")

      expect { Product.order_typed_eav("score", direction: :sideways) }
        .to raise_error(ArgumentError, /direction.*asc.*desc/i)
      expect { Product.order_typed_eav("score", nulls: :middle) }
        .to raise_error(ArgumentError, /nulls.*first.*last/i)
    end

    it "rejects blank and unknown field names" do
      expect { Product.order_typed_eav(nil) }
        .to raise_error(ArgumentError, /field name.*non-empty/i)
      expect { Product.order_typed_eav("unknown") }
        .to raise_error(ArgumentError, /Unknown typed field 'unknown'/)
    end

    it "rejects collection and multi-cell field definitions" do
      create(:integer_array_field, name: "tags", entity_type: "Contact")
      create(:currency_field, name: "money", entity_type: "Contact")

      expect { Contact.order_typed_eav("tags", scope: nil) }
        .to raise_error(ArgumentError, /integer_array.*scalar/i)
      expect { Contact.order_typed_eav("money", scope: nil) }
        .to raise_error(ArgumentError, /currency.*scalar/i)
    end

    it "fails clearly when unscoped field definitions are ambiguous" do
      create(:integer_field, name: "score", entity_type: "Contact", scope: "tenant-1")
      create(:integer_field, name: "score", entity_type: "Contact", scope: "tenant-2")

      expect { TypedEAV.unscoped { Contact.order_typed_eav("score") } }
        .to raise_error(ArgumentError, /all partitions|ambiguous/i)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
