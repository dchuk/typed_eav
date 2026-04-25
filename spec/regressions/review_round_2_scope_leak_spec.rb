# frozen_string_literal: true

require "spec_helper"

# Regression: ambient scope leaked into models that never opted into scoping.
#
# Before the fix, `typed_field_definitions` on an un-scoped host (e.g. Product,
# which declares `has_typed_fields` without `scope_method:`) would consult
# `TypedFields.current_scope` and, inside a `with_scope` block, return the
# union of tenant-scoped fields + globals. That's wrong on two counts:
#   1. Product has no per-instance scope accessor, so
#      `Value#validate_field_scope_matches_entity` rejects any attempt to
#      actually attach those scoped fields — forms/admin would silently fail.
#   2. A model that never opted into tenancy shouldn't see cross-model
#      ambient state.
#
# The fix short-circuits in `resolve_scope` when `typed_fields_scope_method`
# is not set, returning nil (globals-only). Explicit `scope:` overrides and
# `TypedFields.unscoped { }` remain fully functional. Scoped models
# (Contact) are unchanged.
RSpec.describe "Round-2 review: ambient scope must not leak into un-scoped models", :scoping do
  before do
    TypedFields.config.scope_resolver = nil
    TypedFields.config.require_scope = true
  end

  after do
    TypedFields.config.reset!
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
      TypedFields.with_scope("tenant_a") do
        fields = Product.typed_field_definitions
        expect(fields).to contain_exactly(product_global)
        expect(fields).not_to include(product_scoped_a)
        expect(fields).not_to include(product_scoped_b)
      end
    end

    it "still honors an explicit scope: kwarg override (admin/test path)" do
      # Explicit override must work even for un-scoped models: admin tools
      # may want to inspect a specific tenant's field set directly.
      fields = Product.typed_field_definitions(scope: "tenant_a")
      expect(fields).to include(product_scoped_a, product_global)
      expect(fields).not_to include(product_scoped_b)
    end

    it "explicit scope: nil still means global-only (unchanged)" do
      TypedFields.with_scope("tenant_a") do
        fields = Product.typed_field_definitions(scope: nil)
        expect(fields).to contain_exactly(product_global)
      end
    end

    it "inside TypedFields.unscoped { } returns fields across ALL scopes (unchanged)" do
      TypedFields.unscoped do
        fields = Product.typed_field_definitions
        expect(fields).to include(product_scoped_a, product_scoped_b, product_global)
      end
    end

    it "does not raise ScopeRequired when require_scope is true (unchanged)" do
      # Un-scoped hosts never fail-closed; the fail-closed gate is keyed on
      # `typed_fields_scope_method`.
      TypedFields.config.require_scope = true
      expect { Product.typed_field_definitions }.not_to raise_error
    end

    it "ignores a configured ambient resolver too (not just with_scope)" do
      # The short-circuit sits before the ambient lookup, so a configured
      # resolver on an un-scoped host is equally inert.
      TypedFields.config.scope_resolver = -> { "tenant_a" }
      fields = Product.typed_field_definitions
      expect(fields).to contain_exactly(product_global)
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
      TypedFields.with_scope("tenant_a") do
        fields = Contact.typed_field_definitions
        expect(fields).to include(contact_scoped_a, contact_global)
        expect(fields).not_to include(contact_scoped_b)
      end
    end

    it "no ambient + require_scope=true: raises ScopeRequired (fail-closed preserved)" do
      expect do
        Contact.typed_field_definitions
      end.to raise_error(TypedFields::ScopeRequired, /No ambient scope resolvable for Contact/)
    end

    it "no ambient + require_scope=false: returns globals only (unchanged)" do
      TypedFields.config.require_scope = false
      fields = Contact.typed_field_definitions
      expect(fields).to contain_exactly(contact_global)
    end

    it "inside unscoped { }: returns fields across all scopes (unchanged)" do
      TypedFields.unscoped do
        fields = Contact.typed_field_definitions
        expect(fields).to include(contact_scoped_a, contact_scoped_b, contact_global)
      end
    end
  end
end
