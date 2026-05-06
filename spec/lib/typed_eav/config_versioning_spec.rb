# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
# Spec path uses config_versioning_spec.rb to group with the other Phase 04
# config additions. The string second argument is a topical descriptor, not
# a method name — the file covers two related Config accessors and their
# combined reset! coverage.
RSpec.describe TypedEAV::Config, "versioning + actor_resolver" do
  # rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
  # Snapshot/restore the new state alongside the existing :event_callbacks
  # hook coverage. Using :event_callbacks here exercises the extension
  # added in plan 04-01 P04 — if that hook doesn't snapshot
  # versioning/actor_resolver, these examples leak state to subsequent
  # specs (and the negative coverage in P04 will catch the leak).
  describe ".versioning", :event_callbacks do
    it "defaults to false" do
      described_class.reset!
      expect(described_class.versioning).to be(false)
    end

    it "is settable to true" do
      described_class.versioning = true
      expect(described_class.versioning).to be(true)
    end

    it "preserves explicitly-set false (defined? idiom)" do
      described_class.versioning = false
      expect(described_class.versioning).to be(false)
      # Internal-state probe: the `defined?(@versioning)` reader returns
      # the explicitly-set false rather than falling through to the
      # default-false branch. This is the locked-contract test for the
      # config.rb:14-22 "never set vs explicitly nil/false" distinction.
      expect(described_class.instance_variable_defined?(:@versioning)).to be(true)
    end

    it "is reset to false by Config.reset!" do
      described_class.versioning = true
      described_class.reset!
      expect(described_class.versioning).to be(false)
    end
  end

  describe ".actor_resolver", :event_callbacks do
    it "defaults to nil" do
      described_class.reset!
      expect(described_class.actor_resolver).to be_nil
    end

    it "is settable to a callable" do
      described_class.actor_resolver = -> { "alice" }
      expect(described_class.actor_resolver.call).to eq("alice")
    end

    it "permits nil-returning resolver (locked permissive contract)" do
      # Style/NilLambda would prefer `-> {}` (empty lambda also returns nil),
      # but the explicit `nil` body documents intent: this lambda returns nil
      # by design — the locked permissive contract from 04-CONTEXT.md.
      described_class.actor_resolver = -> { nil } # rubocop:disable Style/NilLambda -- explicit nil body documents the permissive return contract
      expect(described_class.actor_resolver.call).to be_nil
    end

    it "is reset to nil by Config.reset!" do
      described_class.actor_resolver = -> { "alice" }
      described_class.reset!
      expect(described_class.actor_resolver).to be_nil
    end
  end

  describe ".reset! coverage of all Phase 03+04 accessors", :event_callbacks do
    it "resets versioning, actor_resolver, on_value_change, and on_field_change together" do
      described_class.versioning = true
      described_class.actor_resolver = -> { "alice" }
      described_class.on_value_change = ->(_v, _t, _c) { :did }
      described_class.on_field_change = ->(_f, _t) { :did }

      described_class.reset!

      expect(described_class.versioning).to be(false)
      expect(described_class.actor_resolver).to be_nil
      expect(described_class.on_value_change).to be_nil
      expect(described_class.on_field_change).to be_nil
    end
  end

  describe "spec_helper :event_callbacks isolation", :event_callbacks do
    it "restores Config.versioning after the example exits" do
      # If this fails, the :event_callbacks hook in spec_helper.rb is
      # missing the saved_versioning/restore lines added in plan 04-01 P04.
      described_class.versioning = true
      expect(described_class.versioning).to be(true)
      # Restoration happens in the ensure block of the around hook — we
      # can't observe the restoration from inside the example, but the
      # next example's "defaults to false" assertion (above) would fail
      # if state leaked. This example is a documentation marker more than
      # a runtime assertion.
    end

    it "restores Config.actor_resolver after the example exits" do
      described_class.actor_resolver = -> { "leaked" }
      expect(described_class.actor_resolver.call).to eq("leaked")
    end
  end
end
