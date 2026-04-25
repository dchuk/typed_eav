# frozen_string_literal: true

require "spec_helper"

RSpec.describe "TypedFields scope enforcement", :scoping do
  before do
    TypedFields.config.scope_resolver = nil
    TypedFields.config.require_scope = true
  end

  after do
    TypedFields.config.reset!
  end

  describe ".with_scope" do
    it "sets the ambient scope inside the block" do
      TypedFields.with_scope("t1") do
        expect(TypedFields.current_scope).to eq("t1")
      end
    end

    it "restores the prior scope after the block exits" do
      TypedFields.with_scope("outer") do
        TypedFields.with_scope("inner") do
          expect(TypedFields.current_scope).to eq("inner")
        end
        expect(TypedFields.current_scope).to eq("outer")
      end
    end

    it "restores the prior scope even when the block raises" do
      expect do
        TypedFields.with_scope("t1") { raise "boom" }
      end.to raise_error(RuntimeError, "boom")
      expect(TypedFields.current_scope).to be_nil
    end

    it "accepts an AR-like object and normalizes to id.to_s" do
      fake_record = Struct.new(:id).new(42)
      TypedFields.with_scope(fake_record) do
        expect(TypedFields.current_scope).to eq("42")
      end
    end
  end

  describe ".unscoped" do
    it "reports unscoped? true inside the block" do
      TypedFields.unscoped do
        expect(TypedFields.unscoped?).to be true
      end
      expect(TypedFields.unscoped?).to be false
    end

    it "makes current_scope return nil even when a resolver would return a value" do
      TypedFields.config.scope_resolver = -> { "t1" }
      TypedFields.unscoped do
        expect(TypedFields.current_scope).to be_nil
      end
    end
  end

  describe "resolver chain" do
    it "returns nil when nothing is set" do
      expect(TypedFields.current_scope).to be_nil
    end

    it "uses the configured resolver when no block is active" do
      TypedFields.config.scope_resolver = -> { "from_resolver" }
      expect(TypedFields.current_scope).to eq("from_resolver")
    end

    it "with_scope wins over the configured resolver" do
      TypedFields.config.scope_resolver = -> { "from_resolver" }
      TypedFields.with_scope("from_block") do
        expect(TypedFields.current_scope).to eq("from_block")
      end
    end

    it "normalizes AR-record return values from the resolver" do
      fake_record = Struct.new(:id).new(7)
      TypedFields.config.scope_resolver = -> { fake_record }
      expect(TypedFields.current_scope).to eq("7")
    end
  end

  describe "acts_as_tenant bridge (default resolver)" do
    before do
      TypedFields.config.scope_resolver = TypedFields::Config::DEFAULT_SCOPE_RESOLVER
    end

    it "reads ActsAsTenant.current_tenant when ActsAsTenant is defined" do
      fake_tenant = Struct.new(:id).new(99)
      stub_const("ActsAsTenant", Module.new.tap do |m|
        m.define_singleton_method(:current_tenant) { fake_tenant }
      end)
      expect(TypedFields.current_scope).to eq("99")
    end

    it "returns nil when ActsAsTenant is not defined" do
      hide_const("ActsAsTenant") if defined?(ActsAsTenant)
      expect(TypedFields.current_scope).to be_nil
    end
  end

  describe "fail-closed enforcement on scoped models" do
    before { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

    context "when Contact declares scope_method: :tenant_id" do
      it "raises ScopeRequired when no ambient scope resolves" do
        expect do
          Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
        end.to raise_error(TypedFields::ScopeRequired, /No ambient scope resolvable for Contact/)
      end

      it "does NOT raise when wrapped in with_scope" do
        TypedFields.with_scope("t1") do
          expect do
            Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
          end.not_to raise_error
        end
      end

      it "does NOT raise when wrapped in unscoped" do
        TypedFields.unscoped do
          expect do
            Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
          end.not_to raise_error
        end
      end

      it "does NOT raise when an explicit scope: kwarg is passed (including nil)" do
        expect do
          Contact.where_typed_fields({ name: "age", op: :eq, value: 30 }, scope: nil)
        end.not_to raise_error
        expect do
          Contact.where_typed_fields({ name: "age", op: :eq, value: 30 }, scope: "t1")
        end.not_to raise_error
      end

      it "does NOT raise when the resolver returns a value" do
        TypedFields.config.scope_resolver = -> { "t1" }
        expect do
          Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
        end.not_to raise_error
      end

      it "does NOT raise when require_scope is false" do
        TypedFields.config.require_scope = false
        expect do
          Contact.where_typed_fields({ name: "age", op: :eq, value: 30 })
        end.not_to raise_error
      end
    end

    context "when Product does NOT declare scope_method:" do
      before { create(:integer_field, name: "weight", entity_type: "Product") }

      it "never raises regardless of require_scope setting" do
        TypedFields.config.require_scope = true
        expect do
          Product.where_typed_fields({ name: "weight", op: :eq, value: 10 })
        end.not_to raise_error
      end
    end
  end

  describe "typed_field_definitions scope behavior" do
    let!(:scoped_field) { create(:text_field, name: "foo", entity_type: "Contact", scope: "t1") }
    let!(:other_scoped) { create(:text_field, name: "bar", entity_type: "Contact", scope: "t2") }
    let!(:global_field) { create(:text_field, name: "baz", entity_type: "Contact", scope: nil) }

    it "filters to ambient scope + global when inside with_scope" do
      TypedFields.with_scope("t1") do
        fields = Contact.typed_field_definitions
        expect(fields).to include(scoped_field, global_field)
        expect(fields).not_to include(other_scoped)
      end
    end

    it "returns fields from all partitions inside unscoped block" do
      TypedFields.unscoped do
        fields = Contact.typed_field_definitions
        expect(fields).to include(scoped_field, other_scoped, global_field)
      end
    end

    it "explicit scope: nil kwarg still means global-only (prior behavior preserved)" do
      TypedFields.with_scope("t1") do
        fields = Contact.typed_field_definitions(scope: nil)
        expect(fields).to contain_exactly(global_field)
      end
    end
  end

  describe "name-collision resolution in instance methods" do
    let!(:global_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }
    let!(:scoped_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }

    it "scoped field wins over global when both share a name" do
      contact = Contact.new(name: "Alice", tenant_id: "t1")
      contact.set_typed_field_value("age", 30)
      expect(contact.typed_values.first.field_id).to eq(scoped_field.id)
    end

    it "typed_fields_attributes= writes to the scoped field on collision" do
      contact = Contact.new(name: "Bob", tenant_id: "t1")
      contact.typed_fields_attributes = [{ name: "age", value: 25 }]
      expect(contact.typed_values.first.field_id).to eq(scoped_field.id)
    end

    it "falls back to the global field when no scoped field exists" do
      no_scope_contact = Contact.new(name: "Clara", tenant_id: "t2")
      no_scope_contact.set_typed_field_value("age", 40)
      expect(no_scope_contact.typed_values.first.field_id).to eq(global_field.id)
    end
  end

  describe "name-collision resolution in class query methods" do
    # Regression: when a scoped field and a global field share the same name
    # on the same entity_type, the scoped definition MUST win inside a
    # matching `with_scope` block. Previously, `where_typed_fields` and
    # `with_field` used a bare `.index_by(&:name)` on the result of
    # `typed_field_definitions`, whose ordering is DB-dependent — the global
    # could silently clobber the scoped definition. Mirrors the instance-side
    # guarantee in `InstanceMethods#typed_fields_defs_by_name`.
    #
    # Strategy: use a QueryBuilder spy to capture which field definition the
    # query path actually resolves. That's type-independent and doesn't
    # require seeding matching typed values.

    def capture_query_field
      captured = nil
      allow(TypedFields::QueryBuilder).to receive(:entity_ids) do |field, _op, _value|
        captured = field
        TypedFields::Value.none.select(:entity_id)
      end
      yield
      captured
    end

    context "when scoped + global share a name" do
      before { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

      let!(:scoped_age) { create(:text_field, name: "age", entity_type: "Contact", scope: "t1") }

      it "where_typed_fields picks the scoped field inside with_scope" do
        picked = capture_query_field do
          TypedFields.with_scope("t1") do
            Contact.where_typed_fields({ name: "age", op: :eq, value: "anything" })
          end
        end
        expect(picked).to eq(scoped_age)
      end

      it "with_field picks the scoped field inside with_scope" do
        picked = capture_query_field do
          TypedFields.with_scope("t1") do
            Contact.with_field("age", "anything")
          end
        end
        expect(picked).to eq(scoped_age)
      end
    end

    context "when there is no collision (global only)" do
      let!(:global_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

      it "where_typed_fields uses the global field" do
        picked = capture_query_field do
          TypedFields.with_scope("t1") do
            Contact.where_typed_fields({ name: "age", op: :eq, value: 1 })
          end
        end
        expect(picked).to eq(global_age)
      end
    end

    context "with determinism under reverse creation order" do
      # Create scoped FIRST, global SECOND — a naive implementation driven by
      # DB row order would pick global (inserted later / higher id). Scoped
      # must still win.
      let!(:scoped_age) { create(:text_field, name: "age", entity_type: "Contact", scope: "t1") }

      before { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

      it "where_typed_fields still picks the scoped field" do
        picked = capture_query_field do
          TypedFields.with_scope("t1") do
            Contact.where_typed_fields({ name: "age", op: :eq, value: "anything" })
          end
        end
        expect(picked).to eq(scoped_age)
      end
    end
  end

  describe "Section#for_entity" do
    let!(:scoped_section) { TypedFields::Section.create!(name: "S1", code: "s1", entity_type: "Contact", scope: "t1") }
    let!(:other_scoped)   { TypedFields::Section.create!(name: "S2", code: "s2", entity_type: "Contact", scope: "t2") }
    let!(:global_section) { TypedFields::Section.create!(name: "G",  code: "g",  entity_type: "Contact", scope: nil) }

    it "returns scoped plus global sections for the given scope" do
      result = TypedFields::Section.for_entity("Contact", scope: "t1")
      expect(result).to include(scoped_section, global_section)
      expect(result).not_to include(other_scoped)
    end

    it "returns only global sections when scope is omitted" do
      result = TypedFields::Section.for_entity("Contact")
      expect(result).to contain_exactly(global_section)
    end
  end
end
