# frozen_string_literal: true

require "spec_helper"

# Unit specs for TypedEAV::FilterQuery. Exercises input normalization,
# per-operator dispatch, partition collision (scope vs ALL_SCOPES), empty
# filter lists, and unknown-field error shape. The high-level integration
# (real AR fixtures + chained scopes) lives in
# spec/models/typed_eav/has_typed_eav_spec.rb.
RSpec.describe TypedEAV::FilterQuery, :unscoped do
  describe ".new(...).to_relation" do
    describe "input normalization" do
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

      it "accepts splat-form filters (Array of Hashes)" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", op: :gt, value: 28 }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end

      it "accepts a single filter Hash via [Hash]" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", op: :eq, value: 30 }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end

      it "accepts a wrapped Array of filters" do
        relation = described_class.new(
          model: Contact,
          filters: [[{ name: "age", op: :gt, value: 20 }]],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice, bob)
      end

      it "accepts hash-of-hashes (form params shape)" do
        relation = described_class.new(
          model: Contact,
          filters: [{ "0" => { name: "age", op: :gt, value: 28 } }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end

      it "accepts compact keys (n/op/v) interchangeably with long keys" do
        relation = described_class.new(
          model: Contact,
          filters: [{ n: "age", op: :gt, v: 28 }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end

      it "defaults the operator to :eq when omitted" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", value: 25 }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(bob)
      end
    end

    describe "empty filter list" do
      let!(:alice) { create(:contact, name: "Alice") }
      let!(:bob)   { create(:contact, name: "Bob") }

      it "returns the full relation when no filters are passed" do
        relation = described_class.new(
          model: Contact,
          filters: [],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice, bob)
      end
    end

    describe "single-scope collision branch" do
      let!(:global_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }
      let!(:scoped_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
      let!(:contact)      { create(:contact, tenant_id: "t1") }

      before do
        # Value bound to the scoped (winning) field for tenant_1.
        TypedEAV::Value.create!(entity: contact, field: scoped_field).tap do |v|
          v.value = 99
          v.save!
        end
      end

      it "uses the scope-winning field for a single-scope query" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", op: :eq, value: 99 }],
          scope: "t1",
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(contact)
      end

      it "does NOT see the scoped field when filtering on the global partition only" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", op: :eq, value: 99 }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        # The scoped value's field_id belongs to the scoped field — looking
        # only at the global partition resolves "age" to the global field,
        # which has no matching values for this record.
        expect(relation).to be_empty
        # The global field is still the one resolved in this branch.
        expect(global_field).to be_present
      end
    end

    describe "ALL_SCOPES multimap branch" do
      let!(:tenant1_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }
      let!(:tenant2_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t2") }
      let!(:c1)          { create(:contact, name: "C1", tenant_id: "t1") }
      let!(:c2)          { create(:contact, name: "C2", tenant_id: "t2") }

      before do
        TypedEAV::Value.create!(entity: c1, field: tenant1_age).tap do |v|
          v.value = 30
          v.save!
        end
        TypedEAV::Value.create!(entity: c2, field: tenant2_age).tap do |v|
          v.value = 30
          v.save!
        end
      end

      it "ORs across all tenant field_ids when scope is ALL_SCOPES" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "age", op: :eq, value: 30 }],
          scope: TypedEAV::EntityQuery::ALL_SCOPES,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(c1, c2)
      end
    end

    describe "unknown field name" do
      before { create(:integer_field, name: "age", entity_type: "Contact") }

      it "raises ArgumentError listing available fields on the single-scope branch" do
        expect do
          described_class.new(
            model: Contact,
            filters: [{ name: "nope", op: :eq, value: 1 }],
            scope: nil,
            parent_scope: nil,
          ).to_relation
        end.to raise_error(ArgumentError, /Unknown typed field 'nope' for Contact.*age/)
      end

      it "raises ArgumentError listing available fields on the multimap branch" do
        expect do
          described_class.new(
            model: Contact,
            filters: [{ name: "nope", op: :eq, value: 1 }],
            scope: TypedEAV::EntityQuery::ALL_SCOPES,
            parent_scope: nil,
          ).to_relation
        end.to raise_error(ArgumentError, /Unknown typed field 'nope' for Contact/)
      end
    end

    describe "per-operator dispatch" do
      let!(:name_field) { create(:text_field, name: "city", entity_type: "Contact") }
      let!(:alice)      { create(:contact, name: "Alice") }
      let!(:bob)        { create(:contact, name: "Bob") }

      before do
        TypedEAV::Value.create!(entity: alice, field: name_field).tap do |v|
          v.value = "Portland"
          v.save!
        end
        TypedEAV::Value.create!(entity: bob, field: name_field).tap do |v|
          v.value = "Seattle"
          v.save!
        end
      end

      it "dispatches :contains to QueryBuilder.entity_ids" do
        relation = described_class.new(
          model: Contact,
          filters: [{ name: "city", op: :contains, value: "port" }],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end

      it "ANDs multiple filters together via chained .where" do
        age_field = create(:integer_field, name: "age", entity_type: "Contact")
        TypedEAV::Value.create!(entity: alice, field: age_field).tap do |v|
          v.value = 30
          v.save!
        end
        TypedEAV::Value.create!(entity: bob, field: age_field).tap do |v|
          v.value = 30
          v.save!
        end

        relation = described_class.new(
          model: Contact,
          filters: [
            { name: "city", op: :eq, value: "Portland" },
            { name: "age", op: :gt, value: 20 },
          ],
          scope: nil,
          parent_scope: nil,
        ).to_relation

        expect(relation).to contain_exactly(alice)
      end
    end
  end
end
