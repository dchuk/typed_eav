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

    describe "include_missing: kwarg (G3)" do
      describe "single-scope :is_null branch" do
        # Three-entity fixture exercising Reading A semantics ("no non-NULL
        # value"): `with_null_row` has a row whose value-column is NULL;
        # `non_null` has a populated row; `no_row` has no `typed_eav_values`
        # row at all. Default `:is_null` matches only `with_null_row`; with
        # `include_missing: true` it matches both `with_null_row` and `no_row`.
        let!(:status_field)  { create(:text_field, name: "status", entity_type: "Contact") }
        let!(:with_null_row) { create(:contact, name: "WithNullRow") }
        let!(:non_null)      { create(:contact, name: "NonNull") }
        let!(:no_row)        { create(:contact, name: "NoRow") }

        before do
          TypedEAV::Value.create!(entity: with_null_row, field: status_field) # NULL string_value
          TypedEAV::Value.create!(entity: non_null, field: status_field).tap do |v|
            v.value = "active"
            v.save!
          end
        end

        it "default :is_null (no kwarg) matches only entities with a NULL-column row" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "status", op: :is_null }],
            scope: nil,
            parent_scope: nil,
          ).to_relation
          expect(relation).to contain_exactly(with_null_row)
        end

        it ":is_null + include_missing: true matches NULL-column rows AND no-row entities" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "status", op: :is_null }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(with_null_row, no_row)
        end

        it ":is_not_null is unaffected by include_missing: true (no-op)" do
          base = described_class.new(
            model: Contact,
            filters: [{ name: "status", op: :is_not_null }],
            scope: nil,
            parent_scope: nil,
          ).to_relation
          with_kwarg = described_class.new(
            model: Contact,
            filters: [{ name: "status", op: :is_not_null }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(base).to contain_exactly(non_null)
          expect(with_kwarg).to contain_exactly(non_null)
        end
      end

      describe "non-:is_null operators silently ignore include_missing:" do
        let!(:city_field) { create(:text_field, name: "city", entity_type: "Contact") }
        let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact") }
        let!(:date_field) { create(:date_field, name: "born", entity_type: "Contact") }
        let!(:ref_field) do
          create(:reference_field, name: "buddy", entity_type: "Contact",
                                   options: { target_entity_type: "Contact" })
        end
        let!(:alice) { create(:contact, name: "Alice") }
        let!(:bob)   { create(:contact, name: "Bob") }

        before do
          TypedEAV::Value.create!(entity: alice, field: city_field).tap { |v| v.value = "Portland"; v.save! }
          TypedEAV::Value.create!(entity: bob, field: city_field).tap   { |v| v.value = "Seattle";  v.save! }
          TypedEAV::Value.create!(entity: alice, field: age_field).tap  { |v| v.value = 30; v.save! }
          TypedEAV::Value.create!(entity: bob, field: age_field).tap    { |v| v.value = 25; v.save! }
          TypedEAV::Value.create!(entity: alice, field: date_field).tap { |v| v.value = Date.new(1990, 6, 1); v.save! }
          TypedEAV::Value.create!(entity: bob, field: date_field).tap   { |v| v.value = Date.new(2000, 6, 1); v.save! }
          TypedEAV::Value.create!(entity: alice, field: ref_field).tap  { |v| v.value = bob.id; v.save! }
        end

        it "ignores include_missing: true for :eq" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "city", op: :eq, value: "Portland" }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(alice)
        end

        it "ignores include_missing: true for :gt" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "age", op: :gt, value: 28 }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(alice)
        end

        it "ignores include_missing: true for :contains" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "city", op: :contains, value: "port" }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(alice)
        end

        it "ignores include_missing: true for :starts_with" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "city", op: :starts_with, value: "Sea" }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(bob)
        end

        it "ignores include_missing: true for :between" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "age", op: :between, value: [20, 27] }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(bob)
        end

        it "ignores include_missing: true for :references (Reference field via :eq)" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "buddy", op: :eq, value: bob.id }],
            scope: nil,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(relation).to contain_exactly(alice)
        end
      end

      describe "scoped-vs-global field-name collision" do
        # When the same name exists at global + scoped partitions, the scoped
        # partition wins under a resolved scope tuple. `:is_null` +
        # `include_missing: true` applies set-complement against the SCOPED
        # field's `:is_not_null` subquery (not the global field's).
        let!(:global_status)  { create(:text_field, name: "status", entity_type: "Contact", scope: nil) }
        let!(:scoped_status)  { create(:text_field, name: "status", entity_type: "Contact", scope: "t1") }
        let!(:scoped_filled)  { create(:contact, name: "ScopedFilled", tenant_id: "t1") }
        let!(:scoped_missing) { create(:contact, name: "ScopedMissing", tenant_id: "t1") }

        before do
          TypedEAV::Value.create!(entity: scoped_filled, field: scoped_status).tap { |v| v.value = "active"; v.save! }
          # `scoped_missing` has NO row on the scoped field — but a row on the
          # global field, which should be ignored under the scoped query.
          TypedEAV::Value.create!(entity: scoped_missing, field: global_status).tap { |v| v.value = "shadowed"; v.save! }
        end

        it "uses the scope-winning field's :is_not_null as the complement" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "status", op: :is_null }],
            scope: "t1",
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          # Under scope "t1" the scoped field wins. `scoped_missing` has no
          # row on the scoped field → included. `scoped_filled` has a non-NULL
          # value on the scoped field → excluded.
          expect(relation).to include(scoped_missing)
          expect(relation).not_to include(scoped_filled)
        end
      end

      describe "ALL_SCOPES multimap branch", :unscoped do
        # Reading A across multiple workspaces. Three field definitions for
        # "name" — one per workspace. The fixture distinguishes "no row
        # anywhere" (C) from "mixed: NULL in ws-1 + populated in ws-2" (D).
        # D must NOT match because it has a non-NULL value somewhere.
        let!(:name_ws1) { create(:text_field, name: "name", entity_type: "Contact", scope: "ws-1") }
        let!(:name_ws2) { create(:text_field, name: "name", entity_type: "Contact", scope: "ws-2") }
        let!(:name_ws3) { create(:text_field, name: "name", entity_type: "Contact", scope: "ws-3") }

        # `Value#validate_field_scope_matches_entity` requires each host to
        # actually live in the field's scope, so D is split across two Contact
        # rows (one in ws-1, one in ws-2). Reading A unions the non-missing
        # entity_ids across all matching field defs; the ws-2 instance of D
        # is non-missing → both D instances are excluded.
        let!(:entity_a)    { create(:contact, name: "A", tenant_id: "ws-1") }
        let!(:entity_b)    { create(:contact, name: "B", tenant_id: "ws-1") }
        let!(:entity_c)    { create(:contact, name: "C", tenant_id: "ws-1") }
        let!(:entity_d_w1) { create(:contact, name: "D", tenant_id: "ws-1") }
        let!(:entity_d_w2) { create(:contact, name: "D", tenant_id: "ws-2") }

        before do
          TypedEAV::Value.create!(entity: entity_a, field: name_ws1).tap { |v| v.value = "Alice"; v.save! }
          TypedEAV::Value.create!(entity: entity_b, field: name_ws1) # NULL row
          TypedEAV::Value.create!(entity: entity_d_w1, field: name_ws1) # NULL row
          TypedEAV::Value.create!(entity: entity_d_w2, field: name_ws2).tap { |v| v.value = "Delta"; v.save! }
          _ = name_ws3 # force-load so the multimap sees the third field def
        end

        it ":is_null + include_missing: true returns hosts with no non-NULL value across any matching field" do
          relation = described_class.new(
            model: Contact,
            filters: [{ name: "name", op: :is_null }],
            scope: TypedEAV::EntityQuery::ALL_SCOPES,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          # Reading A: a host matches iff NO matching field def has a non-NULL
          # value for it. entity_a (non-NULL in ws-1) → excluded. entity_d_w2
          # (non-NULL in ws-2) → excluded. entity_b (NULL row in ws-1),
          # entity_c (no row anywhere), and entity_d_w1 (NULL row in ws-1)
          # all qualify.
          expect(relation).to contain_exactly(entity_b, entity_c, entity_d_w1)
        end

        it ":is_not_null + include_missing: true is a no-op on the multimap branch" do
          base = described_class.new(
            model: Contact,
            filters: [{ name: "name", op: :is_not_null }],
            scope: TypedEAV::EntityQuery::ALL_SCOPES,
            parent_scope: nil,
          ).to_relation
          with_kwarg = described_class.new(
            model: Contact,
            filters: [{ name: "name", op: :is_not_null }],
            scope: TypedEAV::EntityQuery::ALL_SCOPES,
            parent_scope: nil,
            include_missing: true,
          ).to_relation
          expect(with_kwarg).to match_array(base)
        end
      end
    end
  end
end
