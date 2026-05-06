# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Registry do
  # NOTE: This spec mutates the global Registry. Snapshot/restore is
  # handled by careful `before/after` blocks rather than spec_helper
  # metadata — Registry doesn't have an :event_callbacks-style hook
  # because production usage registers once at class-load and never
  # again. We simulate that here via direct register calls.
  # rubocop:disable RSpec/InstanceVariable -- snapshot/restore across before/after needs cross-hook state; let blocks don't span hooks.
  before { @saved_entities = described_class.entities.dup }
  after  { described_class.instance_variable_set(:@entities, @saved_entities) }
  # rubocop:enable RSpec/InstanceVariable

  describe ".register with versioned: kwarg" do
    it "stores versioned: false by default (backward compat)" do
      described_class.register("Foo", types: %i[text])
      expect(described_class.entities["Foo"]).to eq(types: %i[text], versioned: false)
    end

    it "stores versioned: true when explicitly passed" do
      described_class.register("Bar", types: %i[text], versioned: true)
      expect(described_class.entities["Bar"]).to eq(types: %i[text], versioned: true)
    end

    it "preserves the prior types: behavior" do
      described_class.register("Baz", types: nil, versioned: true)
      expect(described_class.entities["Baz"]).to eq(types: nil, versioned: true)
    end

    it "overwrites a prior registration (last register wins, same as before)" do
      described_class.register("Quux", types: %i[text], versioned: false)
      described_class.register("Quux", types: %i[text integer], versioned: true)
      expect(described_class.entities["Quux"]).to eq(types: %i[text integer], versioned: true)
    end
  end

  describe ".versioned?" do
    it "returns true for an entity registered with versioned: true" do
      described_class.register("V1", versioned: true)
      expect(described_class.versioned?("V1")).to be(true)
    end

    it "returns false for an entity registered without versioned:" do
      described_class.register("V2", types: %i[text])
      expect(described_class.versioned?("V2")).to be(false)
    end

    it "returns false for an entity registered with versioned: false explicitly" do
      described_class.register("V3", versioned: false)
      expect(described_class.versioned?("V3")).to be(false)
    end

    it "returns false for an unregistered entity (defensive lookup)" do
      expect(described_class.versioned?("UnregisteredEntity")).to be(false)
    end

    it "is O(1) Hash#dig — no per-write performance concern" do
      # Documentation-shape spec: not a real perf benchmark, just
      # confirming the implementation uses Hash#dig (one method call,
      # no iteration). Spy on Hash#dig via allow + have_received.
      described_class.register("V4", versioned: true)
      allow(described_class.entities).to receive(:dig).and_call_original
      described_class.versioned?("V4")
      expect(described_class.entities).to have_received(:dig).with("V4", :versioned)
    end
  end

  describe ".allowed_types_for / .type_allowed? (BC check — not affected by versioned: kwarg)" do
    it "still returns the types: list when versioned: is set" do
      described_class.register("BC1", types: %i[text integer], versioned: true)
      expect(described_class.allowed_types_for("BC1")).to eq(%i[text integer])
    end

    it "still resolves type_allowed? correctly when versioned: is set" do
      described_class.register("BC2", types: %i[text], versioned: true)
      expect(described_class.type_allowed?("BC2", TypedEAV::Field::Text)).to be(true)
      expect(described_class.type_allowed?("BC2", TypedEAV::Field::Integer)).to be(false)
    end
  end

  describe "has_typed_eav versioned: kwarg integration" do
    # Define a throwaway model class to test the macro forwarding.
    let(:host_class) do
      # rubocop:disable Rails/ApplicationRecord -- gem-level spec uses AR::Base directly because the dummy host's ApplicationRecord is app-specific; we want no inheritance side effects from the dummy app's base.
      Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        # Stub the class name for Registry lookup. Registry uses `name`
        # (the AR class name string), so an anonymous Class.new produces
        # nil unless we set it explicitly.
        def self.name = "VersionedHost04Plan02Test"
      end
    end

    after { described_class.entities.delete("VersionedHost04Plan02Test") }

    it "forwards versioned: true from has_typed_eav to Registry.register" do
      host_class.has_typed_eav(versioned: true)
      expect(described_class.versioned?("VersionedHost04Plan02Test")).to be(true)
    end

    it "defaults to versioned: false when omitted" do
      host_class.has_typed_eav
      expect(described_class.versioned?("VersionedHost04Plan02Test")).to be(false)
    end

    it "forwards versioned: alongside types: and scope_method:" do
      host_class.has_typed_eav(scope_method: :tenant_id, types: %i[text], versioned: true)
      entry = described_class.entities["VersionedHost04Plan02Test"]
      expect(entry).to eq(types: %i[text], versioned: true)
    end
  end
end
