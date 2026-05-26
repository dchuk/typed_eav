# frozen_string_literal: true

require "spec_helper"

# Unit specs for TypedEAV::EntityQuery — the macro-level class-method module
# that wraps FilterQuery and BulkRead. Covers the thin wrappers and the
# resolve_scope chain (ALL_SCOPES atomic bypass, explicit-overrides path,
# ambient fall-through, ScopeRequired raise behavior).
RSpec.describe TypedEAV::EntityQuery do
  describe ".where_typed_eav (wrapper)", :unscoped do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact") }
    let!(:alice)     { create(:contact, name: "Alice") }
    let!(:bob)       { create(:contact, name: "Bob") }

    before do
      TypedEAV::Value.create!(entity: alice, field: age_field).tap do |v|
        v.value = 30
        v.save!
      end
      TypedEAV::Value.create!(entity: bob, field: age_field).tap do |v|
        v.value = 25
        v.save!
      end
    end

    it "delegates to FilterQuery and returns the same AR relation shape" do
      relation = Contact.where_typed_eav({ name: "age", op: :gt, value: 28 })
      expect(relation).to contain_exactly(alice)
    end

    it "preserves chaining with standard AR scopes" do
      relation = Contact.where(name: "Alice").where_typed_eav([{ name: "age", op: :gt, value: 20 }])
      expect(relation).to eq([alice])
    end
  end

  describe ".with_field (wrapper)", :unscoped do
    let!(:score_field) { create(:integer_field, name: "score", entity_type: "Contact") }
    let!(:alice)       { create(:contact, name: "Alice") }

    before do
      TypedEAV::Value.create!(entity: alice, field: score_field).tap do |v|
        v.value = 95
        v.save!
      end
    end

    it "two-arg form implies :eq" do
      expect(Contact.with_field("score", 95)).to eq([alice])
    end

    it "three-arg form passes operator through" do
      expect(Contact.with_field("score", :gteq, 90)).to eq([alice])
    end
  end

  describe "include_missing: kwarg threading (G3)", :unscoped do
    # Verifies both wrappers thread `include_missing:` through to FilterQuery
    # and that the kwarg is opt-in (default false preserves prior `:is_null`
    # semantic byte-for-byte).
    let!(:status_field)  { create(:text_field, name: "status", entity_type: "Contact") }
    let!(:with_null_row) { create(:contact, name: "WithNullRow") }
    let!(:populated)     { create(:contact, name: "Populated") }
    let!(:no_row)        { create(:contact, name: "NoRow") }

    before do
      TypedEAV::Value.create!(entity: with_null_row, field: status_field) # NULL string_value
      TypedEAV::Value.create!(entity: populated, field: status_field).tap do |v|
        v.value = "active"
        v.save!
      end
    end

    it "Entity.with_field default :is_null matches only NULL-column rows (regression guard)" do
      expect(Contact.with_field("status", :is_null)).to contain_exactly(with_null_row)
    end

    it "Entity.with_field threads include_missing: true to FilterQuery" do
      expect(
        Contact.with_field("status", :is_null, include_missing: true),
      ).to contain_exactly(with_null_row, no_row)
    end

    it "Entity.where_typed_eav threads include_missing: true to FilterQuery" do
      expect(
        Contact.where_typed_eav({ name: "status", op: :is_null }, include_missing: true),
      ).to contain_exactly(with_null_row, no_row)
    end

    it "Entity.where_typed_eav accepts include_missing: independently of with_field" do
      relation = Contact.where_typed_eav(
        [{ name: "status", op: :is_null }],
        include_missing: true,
      )
      expect(relation).to contain_exactly(with_null_row, no_row)
    end

    it "Entity.with_field with :is_not_null ignores include_missing: true (no-op)" do
      base       = Contact.with_field("status", :is_not_null)
      with_kwarg = Contact.with_field("status", :is_not_null, include_missing: true)
      expect(base).to contain_exactly(populated)
      expect(with_kwarg).to contain_exactly(populated)
    end
  end

  describe ".typed_eav_definitions (wrapper)" do
    it "returns visible fields for the explicit scope override" do
      age_field = create(:integer_field, name: "age", entity_type: "Contact")
      scoped = create(:text_field, name: "dept", entity_type: "Contact", scope: "t1")
      fields = Contact.typed_eav_definitions(scope: "t1")
      expect(fields).to include(age_field, scoped)
    end
  end

  describe ".typed_eav_hash_for (wrapper)", :unscoped do
    let!(:title) { create(:text_field, name: "title", entity_type: "Product") }
    let!(:p1) { create(:product, title: "Widget A") }

    before do
      TypedEAV::Value.create!(entity: p1, field: title).tap do |v|
        v.value = "Hello"
        v.save!
      end
    end

    it "delegates to BulkRead and returns { id => { name => value } }" do
      expect(Product.typed_eav_hash_for([p1])).to eq(p1.id => { "title" => "Hello" })
    end
  end

  describe "resolve_scope chain (through .typed_eav_definitions)" do
    it "returns all-partition fields inside TypedEAV.unscoped { }" do
      t1 = create(:text_field, name: "dept", entity_type: "Contact", scope: "t1")
      t2 = create(:text_field, name: "dept", entity_type: "Contact", scope: "t2")

      result = TypedEAV.unscoped { Contact.typed_eav_definitions }
      expect(result).to include(t1, t2)
    end

    it "honors an explicit scope override even when ambient scope is set" do
      tenant1_field = create(:text_field, name: "dept", entity_type: "Contact", scope: "t1")
      tenant2_field = create(:text_field, name: "dept", entity_type: "Contact", scope: "t2")

      result = TypedEAV.with_scope("t1") do
        Contact.typed_eav_definitions(scope: "t2")
      end

      expect(result).to include(tenant2_field)
      expect(result).not_to include(tenant1_field)
    end

    it "silently narrows parent_scope when scope is nil (orphan-parent invariant)" do
      # parent_scope passed without scope is dead-letter — ps narrows to nil
      # so the resulting query degrades to global rather than always-empty-set.
      global = create(:text_field, name: "tag", entity_type: "Contact", scope: nil)
      expect { Contact.typed_eav_definitions(scope: nil, parent_scope: "w1") }.not_to raise_error
      expect(Contact.typed_eav_definitions(scope: nil, parent_scope: "w1")).to include(global)
    end

    it "returns global-only fields when the model has no scope_method (Product is unscoped)" do
      global_title = create(:text_field, name: "title", entity_type: "Product")
      expect(Product.typed_eav_definitions).to include(global_title)
    end

    it "raises ScopeRequired when scope_method is declared, no ambient scope resolves, and require_scope is true" do
      original = TypedEAV.config.require_scope
      TypedEAV.config.require_scope = true
      expect { Contact.typed_eav_definitions }.to raise_error(TypedEAV::ScopeRequired)
    ensure
      TypedEAV.config.require_scope = original
    end
  end

  describe "sentinels" do
    it "exposes UNSET_SCOPE as a frozen object" do
      expect(described_class::UNSET_SCOPE).to be_frozen
    end

    it "exposes ALL_SCOPES as a frozen object distinct from UNSET_SCOPE" do
      expect(described_class::ALL_SCOPES).to be_frozen
      expect(described_class::ALL_SCOPES).not_to equal(described_class::UNSET_SCOPE)
    end
  end
end
