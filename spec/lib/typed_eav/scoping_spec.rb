# frozen_string_literal: true

require "spec_helper"

RSpec.describe "TypedEAV scope enforcement", :scoping do
  before do
    TypedEAV.config.scope_resolver = nil
    TypedEAV.config.require_scope = true
  end

  after do
    TypedEAV.config.reset!
  end

  describe ".with_scope" do
    it "sets the ambient scope inside the block" do
      TypedEAV.with_scope("t1") do
        expect(TypedEAV.current_scope).to eq(["t1", nil])
      end
    end

    it "restores the prior scope after the block exits" do
      TypedEAV.with_scope("outer") do
        TypedEAV.with_scope("inner") do
          expect(TypedEAV.current_scope).to eq(["inner", nil])
        end
        expect(TypedEAV.current_scope).to eq(["outer", nil])
      end
    end

    it "restores the prior scope even when the block raises" do
      expect do
        TypedEAV.with_scope("t1") { raise "boom" }
      end.to raise_error(RuntimeError, "boom")
      expect(TypedEAV.current_scope).to be_nil
    end

    it "accepts an AR-like object and normalizes to id.to_s" do
      fake_record = Struct.new(:id).new(42)
      TypedEAV.with_scope(fake_record) do
        expect(TypedEAV.current_scope).to eq(["42", nil])
      end
    end
  end

  describe ".with_scope (tuple form)" do
    # Phase 1 added a tuple-form input shape for `with_scope`. The
    # single-arg scalar form (`with_scope("t1")`) keeps its v0.1.x BC
    # meaning — `[scope, nil]` — and the new tuple form lets callers set
    # both partition keys at once.
    it "accepts [scope, parent_scope] and exposes both via current_scope" do
      TypedEAV.with_scope(%w[t1 w1]) do
        expect(TypedEAV.current_scope).to eq(%w[t1 w1])
      end
    end

    it "scalar form remains backwards-compatible (parent_scope=nil)" do
      TypedEAV.with_scope("t1") do
        expect(TypedEAV.current_scope).to eq(["t1", nil])
      end
    end

    it "normalizes AR-record halves to id.to_s within a tuple" do
      tenant = Struct.new(:id).new(7)
      workspace = Struct.new(:id).new(11)
      TypedEAV.with_scope([tenant, workspace]) do
        expect(TypedEAV.current_scope).to eq(%w[7 11])
      end
    end

    it "preserves the orphan-parent shape verbatim (validators run elsewhere)" do
      # `normalize_scope` is permissive on the with_scope block surface —
      # `[nil, "w1"]` is propagated unchanged. Orphan-parent rejection is
      # the model validator's job (Field::Base#validate_parent_scope_invariant),
      # not the resolver layer's.
      TypedEAV.with_scope([nil, "w1"]) do
        expect(TypedEAV.current_scope).to eq([nil, "w1"])
      end
    end
  end

  describe ".unscoped" do
    it "reports unscoped? true inside the block" do
      TypedEAV.unscoped do
        expect(TypedEAV.unscoped?).to be true
      end
      expect(TypedEAV.unscoped?).to be false
    end

    it "makes current_scope return nil even when a resolver would return a value" do
      TypedEAV.config.scope_resolver = -> { ["t1", nil] }
      TypedEAV.unscoped do
        expect(TypedEAV.current_scope).to be_nil
      end
    end
  end

  describe "resolver chain" do
    it "returns nil when nothing is set" do
      expect(TypedEAV.current_scope).to be_nil
    end

    it "uses the configured resolver when no block is active" do
      TypedEAV.config.scope_resolver = -> { ["from_resolver", nil] }
      expect(TypedEAV.current_scope).to eq(["from_resolver", nil])
    end

    it "with_scope wins over the configured resolver" do
      TypedEAV.config.scope_resolver = -> { ["from_resolver", nil] }
      TypedEAV.with_scope("from_block") do
        expect(TypedEAV.current_scope).to eq(["from_block", nil])
      end
    end

    it "normalizes AR-record return values from the resolver (per-slot coercion)" do
      fake_record = Struct.new(:id).new(7)
      TypedEAV.config.scope_resolver = -> { [fake_record, nil] }
      expect(TypedEAV.current_scope).to eq(["7", nil])
    end
  end

  describe "resolver-callable contract violation" do
    # Phase 1 made `Config.scope_resolver` a strict-contract surface: it
    # MUST return `nil` or a 2-element Array. The bare-scalar shape (the
    # v0.1.x default) raises `ArgumentError` — no auto-coercion. The
    # BC-shim alternative was rejected during Phase 1 design because
    # silent coercion would hide a contract violation in user-supplied
    # resolver code (see lib/typed_eav.rb#current_scope and
    # 01-CONTEXT.md § "Resolver protocol shape").
    it "raises ArgumentError when a configured resolver returns a bare scalar" do
      TypedEAV.config.scope_resolver = -> { "t1" } # v0.1.x style
      expect do
        TypedEAV.current_scope
      end.to raise_error(ArgumentError, /must return a 2-element \[scope, parent_scope\] Array/)
    end

    it "raises ArgumentError when a resolver returns a 1-element Array" do
      TypedEAV.config.scope_resolver = -> { ["t1"] }
      expect do
        TypedEAV.current_scope
      end.to raise_error(ArgumentError, /must return a 2-element/)
    end

    it "raises ArgumentError when a resolver returns a 3-element Array" do
      TypedEAV.config.scope_resolver = -> { %w[t1 w1 extra] }
      expect do
        TypedEAV.current_scope
      end.to raise_error(ArgumentError, /must return a 2-element/)
    end
  end

  describe "acts_as_tenant bridge (default resolver)" do
    before do
      TypedEAV.config.scope_resolver = TypedEAV::Config::DEFAULT_SCOPE_RESOLVER
    end

    it "reads ActsAsTenant.current_tenant when ActsAsTenant is defined" do
      fake_tenant = Struct.new(:id).new(99)
      stub_const("ActsAsTenant", Module.new.tap do |m|
        m.define_singleton_method(:current_tenant) { fake_tenant }
      end)
      # The DEFAULT_SCOPE_RESOLVER returns `[ActsAsTenant.current_tenant, nil]`
      # — there is no parent_scope analog in the AAT gem.
      expect(TypedEAV.current_scope).to eq(["99", nil])
    end

    it "returns nil when ActsAsTenant is not defined" do
      hide_const("ActsAsTenant") if defined?(ActsAsTenant)
      expect(TypedEAV.current_scope).to be_nil
    end
  end

  describe "fail-closed enforcement on scoped models" do
    before { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

    context "when Contact declares scope_method: :tenant_id" do
      it "raises ScopeRequired when no ambient scope resolves" do
        expect do
          Contact.where_typed_eav({ name: "age", op: :eq, value: 30 })
        end.to raise_error(TypedEAV::ScopeRequired, /No ambient scope resolvable for Contact/)
      end

      it "does NOT raise when wrapped in with_scope" do
        TypedEAV.with_scope("t1") do
          expect do
            Contact.where_typed_eav({ name: "age", op: :eq, value: 30 })
          end.not_to raise_error
        end
      end

      it "does NOT raise when wrapped in unscoped" do
        TypedEAV.unscoped do
          expect do
            Contact.where_typed_eav({ name: "age", op: :eq, value: 30 })
          end.not_to raise_error
        end
      end

      it "does NOT raise when an explicit scope: kwarg is passed (including nil)" do
        expect do
          Contact.where_typed_eav({ name: "age", op: :eq, value: 30 }, scope: nil)
        end.not_to raise_error
        expect do
          Contact.where_typed_eav({ name: "age", op: :eq, value: 30 }, scope: "t1")
        end.not_to raise_error
      end

      it "does NOT raise when the resolver returns a tuple" do
        TypedEAV.config.scope_resolver = -> { ["t1", nil] }
        expect do
          Contact.where_typed_eav({ name: "age", op: :eq, value: 30 })
        end.not_to raise_error
      end

      it "does NOT raise when require_scope is false" do
        TypedEAV.config.require_scope = false
        expect do
          Contact.where_typed_eav({ name: "age", op: :eq, value: 30 })
        end.not_to raise_error
      end
    end

    context "when Product does NOT declare scope_method:" do
      before { create(:integer_field, name: "weight", entity_type: "Product") }

      it "never raises regardless of require_scope setting" do
        TypedEAV.config.require_scope = true
        expect do
          Product.where_typed_eav({ name: "weight", op: :eq, value: 10 })
        end.not_to raise_error
      end
    end
  end

  describe "typed_eav_definitions scope behavior" do
    let!(:scoped_field) { create(:text_field, name: "foo", entity_type: "Contact", scope: "t1") }
    let!(:other_scoped) { create(:text_field, name: "bar", entity_type: "Contact", scope: "t2") }
    let!(:global_field) { create(:text_field, name: "baz", entity_type: "Contact", scope: nil) }

    it "filters to ambient scope + global when inside with_scope" do
      TypedEAV.with_scope("t1") do
        fields = Contact.typed_eav_definitions
        expect(fields).to include(scoped_field, global_field)
        expect(fields).not_to include(other_scoped)
      end
    end

    it "returns fields from all partitions inside unscoped block" do
      TypedEAV.unscoped do
        fields = Contact.typed_eav_definitions
        expect(fields).to include(scoped_field, other_scoped, global_field)
      end
    end

    it "explicit scope: nil kwarg still means global-only (prior behavior preserved)" do
      TypedEAV.with_scope("t1") do
        fields = Contact.typed_eav_definitions(scope: nil)
        expect(fields).to contain_exactly(global_field)
      end
    end
  end

  describe "typed_eav_definitions parent_scope kwarg" do
    # New Phase 1 surface: parent_scope: kwarg parallels scope: with the
    # same UNSET / explicit / nil semantics. The for_entity scope expands
    # both axes via `[val, nil].uniq`, so a (scope, parent_scope) match
    # also picks up scope-only and pure-global rows.
    let!(:full_triple) do
      create(:integer_field, name: "x_full", entity_type: "Project", scope: "t1", parent_scope: "w1")
    end
    let!(:scope_only)  { create(:integer_field, name: "x_scoped", entity_type: "Project", scope: "t1") }
    let!(:global)      { create(:integer_field, name: "x_global", entity_type: "Project") }

    it "filters to (full triple + scope-only + global) for matching (scope, parent_scope)" do
      fields = Project.typed_eav_definitions(scope: "t1", parent_scope: "w1")
      expect(fields).to contain_exactly(full_triple, scope_only, global)
    end

    it "filters to (scope-only + global) when parent_scope is nil" do
      fields = Project.typed_eav_definitions(scope: "t1", parent_scope: nil)
      expect(fields).to contain_exactly(scope_only, global)
    end

    it "filters to (global only) when both axes are explicitly nil" do
      fields = Project.typed_eav_definitions(scope: nil, parent_scope: nil)
      expect(fields).to contain_exactly(global)
    end
  end

  describe "name-collision resolution in instance methods" do
    let!(:global_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }
    let!(:scoped_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "t1") }

    it "scoped field wins over global when both share a name" do
      contact = Contact.new(name: "Alice", tenant_id: "t1")
      contact.set_typed_eav_value("age", 30)
      expect(contact.typed_values.first.field_id).to eq(scoped_field.id)
    end

    it "typed_eav_attributes= writes to the scoped field on collision" do
      contact = Contact.new(name: "Bob", tenant_id: "t1")
      contact.typed_eav_attributes = [{ name: "age", value: 25 }]
      expect(contact.typed_values.first.field_id).to eq(scoped_field.id)
    end

    it "falls back to the global field when no scoped field exists" do
      no_scope_contact = Contact.new(name: "Clara", tenant_id: "t2")
      no_scope_contact.set_typed_eav_value("age", 40)
      expect(no_scope_contact.typed_values.first.field_id).to eq(global_field.id)
    end
  end

  describe "name-collision resolution in class query methods" do
    # Regression: when a scoped field and a global field share the same name
    # on the same entity_type, the scoped definition MUST win inside a
    # matching `with_scope` block. Previously, `where_typed_eav` and
    # `with_field` used a bare `.index_by(&:name)` on the result of
    # `typed_eav_definitions`, whose ordering is DB-dependent — the global
    # could silently clobber the scoped definition. Mirrors the instance-side
    # guarantee in `InstanceMethods#typed_eav_defs_by_name`.
    #
    # Strategy: use a QueryBuilder spy to capture which field definition the
    # query path actually resolves. That's type-independent and doesn't
    # require seeding matching typed values.

    def capture_query_field
      captured = nil
      allow(TypedEAV::QueryBuilder).to receive(:entity_ids) do |field, _op, _value|
        captured = field
        TypedEAV::Value.none.select(:entity_id)
      end
      yield
      captured
    end

    context "when scoped + global share a name" do
      before { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

      let!(:scoped_age) { create(:text_field, name: "age", entity_type: "Contact", scope: "t1") }

      it "where_typed_eav picks the scoped field inside with_scope" do
        picked = capture_query_field do
          TypedEAV.with_scope("t1") do
            Contact.where_typed_eav({ name: "age", op: :eq, value: "anything" })
          end
        end
        expect(picked).to eq(scoped_age)
      end

      it "with_field picks the scoped field inside with_scope" do
        picked = capture_query_field do
          TypedEAV.with_scope("t1") do
            Contact.with_field("age", "anything")
          end
        end
        expect(picked).to eq(scoped_age)
      end
    end

    context "when there is no collision (global only)" do
      let!(:global_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }

      it "where_typed_eav uses the global field" do
        picked = capture_query_field do
          TypedEAV.with_scope("t1") do
            Contact.where_typed_eav({ name: "age", op: :eq, value: 1 })
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

      it "where_typed_eav still picks the scoped field" do
        picked = capture_query_field do
          TypedEAV.with_scope("t1") do
            Contact.where_typed_eav({ name: "age", op: :eq, value: "anything" })
          end
        end
        expect(picked).to eq(scoped_age)
      end
    end
  end

  describe "Section#for_entity" do
    let!(:scoped_section) { TypedEAV::Section.create!(name: "S1", code: "s1", entity_type: "Contact", scope: "t1") }
    let!(:other_scoped)   { TypedEAV::Section.create!(name: "S2", code: "s2", entity_type: "Contact", scope: "t2") }
    let!(:global_section) { TypedEAV::Section.create!(name: "G",  code: "g",  entity_type: "Contact", scope: nil) }

    it "returns scoped plus global sections for the given scope" do
      result = TypedEAV::Section.for_entity("Contact", scope: "t1")
      expect(result).to include(scoped_section, global_section)
      expect(result).not_to include(other_scoped)
    end

    it "returns only global sections when scope is omitted" do
      result = TypedEAV::Section.for_entity("Contact")
      expect(result).to contain_exactly(global_section)
    end
  end

  describe "Section#for_entity with parent_scope" do
    # Symmetric to Field::Base.for_entity — the section partition mirror
    # was added in Phase 1 to keep the Section/Field invariants aligned.
    let!(:full)        { TypedEAV::Section.create!(name: "F", code: "f", entity_type: "Project", scope: "t1", parent_scope: "w1") }
    let!(:scope_only)  { TypedEAV::Section.create!(name: "S", code: "s", entity_type: "Project", scope: "t1") }
    let!(:global)      { TypedEAV::Section.create!(name: "G", code: "g", entity_type: "Project") }
    let!(:other_scope) { TypedEAV::Section.create!(name: "O", code: "o", entity_type: "Project", scope: "t2", parent_scope: "w1") }

    it "returns full-triple + scope-only + global for matching axes" do
      result = TypedEAV::Section.for_entity("Project", scope: "t1", parent_scope: "w1")
      expect(result).to include(full, scope_only, global)
      expect(result).not_to include(other_scope)
    end

    it "returns scope-only + global when parent_scope omitted (kwarg defaults nil)" do
      # `for_entity` defaults parent_scope to nil, which expands to
      # `parent_scope IN (NULL)` — picks up only rows with parent_scope IS NULL.
      result = TypedEAV::Section.for_entity("Project", scope: "t1")
      expect(result).to include(scope_only, global)
      expect(result).not_to include(full, other_scope)
    end

    it "returns only globals when both scope and parent_scope omitted" do
      expect(TypedEAV::Section.for_entity("Project")).to contain_exactly(global)
    end
  end
end
