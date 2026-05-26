# frozen_string_literal: true

# Pure-function unit spec for TypedEAV::ScopeTuple — deliberately bypasses
# spec_helper / Rails / ActiveRecord. The module is a normalization +
# predicate seam with zero coupling to the DB; loading the full dummy
# Rails app would only obscure that contract.
#
# The `require "active_support/core_ext/object/blank"` line is the one
# external dependency: `String#blank?` is the orphan-parent predicate's
# load-bearing call (empty-string-is-blank semantics matter for both
# axes of `invariant_satisfied?`).

require "active_support/core_ext/object/blank"
require "typed_eav/scope_tuple"

RSpec.describe TypedEAV::ScopeTuple do
  describe ".normalize_permissive" do
    it "returns nil for nil input" do
      expect(described_class.normalize_permissive(nil)).to be_nil
    end

    it "coerces a bare scalar to [scalar_string, nil]" do
      expect(described_class.normalize_permissive("t1")).to eq(["t1", nil])
    end

    it "coerces an Integer scalar to its string form" do
      expect(described_class.normalize_permissive(42)).to eq(["42", nil])
    end

    it "coerces an AR-like record (responds to :id) via id.to_s" do
      record = Struct.new(:id).new(7)
      expect(described_class.normalize_permissive(record)).to eq(["7", nil])
    end

    it "passes through a 2-element Array with per-slot coercion" do
      expect(described_class.normalize_permissive(%w[t1 w1])).to eq(%w[t1 w1])
    end

    it "coerces AR-record halves inside a tuple via id.to_s" do
      tenant = Struct.new(:id).new(7)
      workspace = Struct.new(:id).new(11)
      expect(described_class.normalize_permissive([tenant, workspace])).to eq(%w[7 11])
    end

    it "preserves nil halves inside a tuple (scope-only shape)" do
      expect(described_class.normalize_permissive(["t1", nil])).to eq(["t1", nil])
    end

    it "preserves the orphan-parent shape verbatim (validation belongs to callers)" do
      # The permissive normalizer deliberately does NOT enforce the
      # orphan-parent invariant — that is `invariant_satisfied?`'s job and
      # each caller decides whether to raise / AR-error / narrow.
      expect(described_class.normalize_permissive([nil, "w1"])).to eq([nil, "w1"])
    end

    it "treats a 1-element Array as a bare scalar (BC: scalar → [s, nil])" do
      # A 1-element Array does not match the 2-element tuple branch and so
      # falls through to the bare-scalar branch, producing [array.to_s, nil].
      # This is the v0.1.x BC shape — `with_scope([x])` is rare in practice
      # but the coercion is well-defined.
      expect(described_class.normalize_permissive(["only"])).to eq(['["only"]', nil])
    end

    it "treats a 3-element Array as a bare scalar (BC: scalar → [s, nil])" do
      expect(described_class.normalize_permissive(%w[a b c])).to eq(['["a", "b", "c"]', nil])
    end
  end

  describe ".normalize_strict" do
    it "returns nil for nil input" do
      expect(described_class.normalize_strict(nil)).to be_nil
    end

    it "accepts a 2-element Array and coerces per-slot" do
      expect(described_class.normalize_strict(%w[t1 w1])).to eq(%w[t1 w1])
    end

    it "coerces AR-record halves inside a tuple via id.to_s" do
      tenant = Struct.new(:id).new(7)
      expect(described_class.normalize_strict([tenant, nil])).to eq(["7", nil])
    end

    it "raises ArgumentError on a bare scalar (v0.1.x resolver shape)" do
      expect do
        described_class.normalize_strict("t1")
      end.to raise_error(ArgumentError, /must return a 2-element/)
    end

    it "raises ArgumentError on a 1-element Array" do
      expect do
        described_class.normalize_strict(["t1"])
      end.to raise_error(ArgumentError, /must return a 2-element/)
    end

    it "raises ArgumentError on a 3-element Array" do
      expect do
        described_class.normalize_strict(%w[t1 w1 extra])
      end.to raise_error(ArgumentError, /must return a 2-element/)
    end

    it "quotes the bad input in the error message" do
      expect do
        described_class.normalize_strict(:t1)
      end.to raise_error(ArgumentError, /:t1/)
    end

    it "mentions the migration note (CHANGELOG / README) in the error message" do
      expect do
        described_class.normalize_strict("bad")
      end.to raise_error(ArgumentError, /CHANGELOG/)
    end
  end

  describe ".invariant_satisfied?" do
    it "returns true for (nil, nil) — pure-global shape" do
      expect(described_class.invariant_satisfied?(nil, nil)).to be(true)
    end

    it "returns true for (scope, nil) — scope-only shape" do
      expect(described_class.invariant_satisfied?("t1", nil)).to be(true)
    end

    it "returns true for (scope, parent_scope) — canonical full-triple shape" do
      expect(described_class.invariant_satisfied?("t1", "w1")).to be(true)
    end

    it "returns false for (nil, parent_scope) — orphan parent" do
      expect(described_class.invariant_satisfied?(nil, "w1")).to be(false)
    end

    it "returns false for ('', parent_scope) — empty-string scope is blank" do
      expect(described_class.invariant_satisfied?("", "w1")).to be(false)
    end

    it "returns true for (nil, '') — empty-string parent_scope is blank on parent axis" do
      expect(described_class.invariant_satisfied?(nil, "")).to be(true)
    end

    it "returns true for ('', '') — both axes blank counts as pure-global" do
      expect(described_class.invariant_satisfied?("", "")).to be(true)
    end

    it "never raises, only returns a Boolean (per-caller response policy)" do
      # The Boolean shape is load-bearing: each calling site (Field
      # validator → AR error; Partition query → ArgumentError; HasTypedEAV
      # resolver → silent narrow) picks its own response.
      expect { described_class.invariant_satisfied?(nil, "w1") }.not_to raise_error
      expect { described_class.invariant_satisfied?("t1", "w1") }.not_to raise_error
    end
  end
end
