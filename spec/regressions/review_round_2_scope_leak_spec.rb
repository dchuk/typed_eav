# frozen_string_literal: true

require "spec_helper"

# Regression: ambient scope leaked into models that never opted into scoping.
#
# Before the fix, `typed_eav_definitions` on an un-scoped host (e.g. Product,
# which declares `has_typed_eav` without `scope_method:`) would consult
# `TypedEAV.current_scope` and, inside a `with_scope` block, return the
# union of tenant-scoped fields + globals. That's wrong on two counts:
#   1. Product has no per-instance scope accessor, so
#      `Value#validate_field_scope_matches_entity` rejects any attempt to
#      actually attach those scoped fields — forms/admin would silently fail.
#   2. A model that never opted into tenancy shouldn't see cross-model
#      ambient state.
#
# The fix short-circuits in `resolve_scope` when `typed_eav_scope_method`
# is not set, returning nil (globals-only). Explicit `scope:` overrides and
# `TypedEAV.unscoped { }` remain fully functional. Scoped models
# (Contact) are unchanged.
RSpec.describe "Round-2 review: ambient scope must not leak into un-scoped models", :scoping do
  before do
    TypedEAV.config.scope_resolver = nil
    TypedEAV.config.require_scope = true
  end

  after do
    TypedEAV.config.reset!
  end

  describe "Product (no scope_method: declared)" do
    let!(:product_scoped_a) do
      create(:integer_field, name: "weight_a", entity_type: "Product", scope: "tenant_a")
    end
    let!(:product_scoped_b) do
      create(:integer_field, name: "weight_b", entity_type: "Product", scope: "tenant_b")
    end
    let!(:product_global) do
      create(:integer_field, name: "weight", entity_type: "Product", scope: nil)
    end

    it "ignores ambient scope: with_scope('tenant_a') still returns globals only" do
      TypedEAV.with_scope("tenant_a") do
        fields = Product.typed_eav_definitions
        expect(fields).to contain_exactly(product_global)
        expect(fields).not_to include(product_scoped_a)
        expect(fields).not_to include(product_scoped_b)
      end
    end

    it "still honors an explicit scope: kwarg override (admin/test path)" do
      # Explicit override must work even for un-scoped models: admin tools
      # may want to inspect a specific tenant's field set directly.
      fields = Product.typed_eav_definitions(scope: "tenant_a")
      expect(fields).to include(product_scoped_a, product_global)
      expect(fields).not_to include(product_scoped_b)
    end

    it "explicit scope: nil still means global-only (unchanged)" do
      TypedEAV.with_scope("tenant_a") do
        fields = Product.typed_eav_definitions(scope: nil)
        expect(fields).to contain_exactly(product_global)
      end
    end

    it "inside TypedEAV.unscoped { } returns fields across ALL scopes (unchanged)" do
      TypedEAV.unscoped do
        fields = Product.typed_eav_definitions
        expect(fields).to include(product_scoped_a, product_scoped_b, product_global)
      end
    end

    it "does not raise ScopeRequired when require_scope is true (unchanged)" do
      # Un-scoped hosts never fail-closed; the fail-closed gate is keyed on
      # `typed_eav_scope_method`.
      TypedEAV.config.require_scope = true
      expect { Product.typed_eav_definitions }.not_to raise_error
    end

    it "ignores a configured ambient resolver too (not just with_scope)" do
      # The short-circuit sits before the ambient lookup, so a configured
      # resolver on an un-scoped host is equally inert.
      TypedEAV.config.scope_resolver = -> { ["tenant_a", nil] }
      fields = Product.typed_eav_definitions
      expect(fields).to contain_exactly(product_global)
    end

    # Phase 1 mirror: the un-scoped-host short-circuit must also ignore an
    # ambient parent_scope on the stack. A model that didn't opt into the
    # scope axis cannot have opted into the parent_scope axis (the macro
    # guard rejects parent_scope_method without scope_method), so any
    # ambient parent_scope is doubly inert here.
    it "ignores ambient parent_scope too: with_scope(['tenant_a', 'w1']) still returns globals only" do
      TypedEAV.with_scope(%w[tenant_a w1]) do
        fields = Product.typed_eav_definitions
        expect(fields).to contain_exactly(product_global)
      end
    end
  end

  describe "Contact (scope_method: :tenant_id declared) — unchanged semantics" do
    let!(:contact_scoped_a) do
      create(:text_field, name: "note_a", entity_type: "Contact", scope: "tenant_a")
    end
    let!(:contact_scoped_b) do
      create(:text_field, name: "note_b", entity_type: "Contact", scope: "tenant_b")
    end
    let!(:contact_global) do
      create(:text_field, name: "note_g", entity_type: "Contact", scope: nil)
    end

    it "with_scope('tenant_a'): returns tenant_a + global (scoped models still honor ambient)" do
      TypedEAV.with_scope("tenant_a") do
        fields = Contact.typed_eav_definitions
        expect(fields).to include(contact_scoped_a, contact_global)
        expect(fields).not_to include(contact_scoped_b)
      end
    end

    it "no ambient + require_scope=true: raises ScopeRequired (fail-closed preserved)" do
      expect do
        Contact.typed_eav_definitions
      end.to raise_error(TypedEAV::ScopeRequired, /No ambient scope resolvable for Contact/)
    end

    it "no ambient + require_scope=false: returns globals only (unchanged)" do
      TypedEAV.config.require_scope = false
      fields = Contact.typed_eav_definitions
      expect(fields).to contain_exactly(contact_global)
    end

    it "inside unscoped { }: returns fields across all scopes (unchanged)" do
      TypedEAV.unscoped do
        fields = Contact.typed_eav_definitions
        expect(fields).to include(contact_scoped_a, contact_scoped_b, contact_global)
      end
    end

    # Phase 1 BC pin: the scalar form of `with_scope` (the v0.1.x shape)
    # is preserved on a scope-only host. The block sees the scoped + global
    # rows just as it always did, even though the resolver chain now
    # internally routes through tuples. The exists-test above already
    # exercises this scenario; the assertion here pins a slightly different
    # invariant — `current_scope` exposes a `[scope, nil]` tuple inside the
    # block, NOT a bare scalar — so a future regression that drops the
    # tuple shape on the BC path would be caught here.
    it "with_scope('tenant_a') (scalar BC form): current_scope returns [scope, nil] tuple" do
      TypedEAV.with_scope("tenant_a") do
        expect(TypedEAV.current_scope).to eq(["tenant_a", nil])
        fields = Contact.typed_eav_definitions
        expect(fields).to include(contact_scoped_a, contact_global)
      end
    end
  end

  # Phase 1 mirror: a model that declares `scope_method:` but NOT
  # `parent_scope_method:` (Project would be a parent_scope-bearing host;
  # we use a dedicated entity_type here that mirrors Contact's declaration
  # — see `ContactScopeOnly` reasoning in the round_2 history).
  #
  # IMPORTANT: spec/dummy/Project actually declares BOTH scope_method: AND
  # parent_scope_method: (it's the full-triple host). The "scope-only host"
  # described here doesn't have a dedicated test model — we test the same
  # invariant via Project with explicit parent_scope: nil kwargs, which
  # exercises the same ignore-ambient-parent_scope short-circuit through
  # the explicit-override path.
  describe "Project (scope_method: AND parent_scope_method:) — short-circuit and explicit-override coverage" do
    let!(:project_full_triple) do
      create(:integer_field, name: "weight_full", entity_type: "Project", scope: "tenant_a", parent_scope: "w1")
    end
    let!(:project_scope_only) do
      create(:integer_field, name: "weight_scoped", entity_type: "Project", scope: "tenant_a")
    end
    let!(:project_global) do
      create(:integer_field, name: "weight", entity_type: "Project", scope: nil)
    end
    let!(:project_other_workspace) do
      create(:integer_field, name: "weight_other_w", entity_type: "Project", scope: "tenant_a", parent_scope: "w2")
    end

    it "with_scope tuple on the full-triple host returns full + scope-only + global; excludes other workspaces" do
      TypedEAV.with_scope(%w[tenant_a w1]) do
        fields = Project.typed_eav_definitions
        expect(fields).to include(project_full_triple, project_scope_only, project_global)
        expect(fields).not_to include(project_other_workspace)
      end
    end

    it "explicit parent_scope: kwarg overrides the ambient stack (admin/test path)" do
      fields = Project.typed_eav_definitions(scope: "tenant_a", parent_scope: "w1")
      expect(fields).to include(project_full_triple, project_scope_only, project_global)
      expect(fields).not_to include(project_other_workspace)
    end

    it "explicit parent_scope: nil bypasses ambient resolution (any explicit kwarg disables ambient)" do
      # Production semantic: passing EITHER `scope:` or `parent_scope:`
      # explicitly skips ambient resolution for BOTH axes (see
      # `resolve_scope` — `explicit_given` gates the whole tuple). So
      # `parent_scope: nil` while inside `with_scope(["tenant_a", "w1"])`
      # collapses to `(scope: nil, parent_scope: nil)` and returns globals
      # only. This parallels the existing `scope: nil` behavior pinned in
      # `spec/lib/typed_eav/scoping_spec.rb` ("explicit scope: nil kwarg
      # still means global-only").
      TypedEAV.with_scope(%w[tenant_a w1]) do
        fields = Project.typed_eav_definitions(parent_scope: nil)
        expect(fields).to contain_exactly(project_global)
      end
    end

    it "scope: nil, parent_scope: nil kwargs mean pure-global" do
      TypedEAV.with_scope(%w[tenant_a w1]) do
        fields = Project.typed_eav_definitions(scope: nil, parent_scope: nil)
        expect(fields).to contain_exactly(project_global)
      end
    end

    it "inside TypedEAV.unscoped { } returns fields across ALL (scope, parent_scope) combinations" do
      TypedEAV.unscoped do
        fields = Project.typed_eav_definitions
        expect(fields).to include(project_full_triple, project_scope_only, project_global, project_other_workspace)
      end
    end

    it "unscoped { } block must NOT leak parent_scope filters: every (scope, parent_scope) row appears" do
      # Create one more row to make the cross-product visible — different
      # (scope, parent_scope) tuple than any of the let!s above.
      cross_tenant = create(:integer_field, name: "weight_cross_t", entity_type: "Project", scope: "tenant_b",
                                            parent_scope: "wX")
      TypedEAV.unscoped do
        fields = Project.typed_eav_definitions
        expect(fields).to include(cross_tenant)
      end
    end

    it "does not raise even when require_scope is true (host opted into scope, ambient resolves cleanly)" do
      TypedEAV.with_scope("tenant_a") do
        expect { Project.typed_eav_definitions }.not_to raise_error
      end
    end
  end
end
