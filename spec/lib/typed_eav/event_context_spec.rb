# frozen_string_literal: true

require "spec_helper"

# Specs for TypedEAV.with_context / TypedEAV.current_context. Mirrors the
# scoping_spec.rb structure for `with_scope` — sets/restores a thread-local
# stack with shallow per-key merge across nesting and ensure-pop on raise.
#
# These specs do NOT need :event_callbacks metadata — they don't touch
# Config.on_value_change / EventDispatcher state. They only exercise the
# thread-local stack.
# rubocop:disable RSpec/SpecFilePathFormat
# Spec path uses event_context_spec.rb to group with event_dispatcher_spec.rb
# and value/field_event_spec.rb under "Phase 03 event hooks" naming. The
# enforcing cop expects `with_context` in the filename; the grouping
# convention beats the path-format heuristic here.
RSpec.describe TypedEAV, ".with_context" do
  # rubocop:enable RSpec/SpecFilePathFormat
  it "sets the ambient context inside the block" do
    described_class.with_context(request_id: "abc") do
      expect(described_class.current_context).to eq(request_id: "abc")
    end
  end

  it "returns to a frozen empty Hash outside any block" do
    expect(described_class.current_context).to eq({})
    expect(described_class.current_context).to be_frozen
  end

  it "restores the prior context after a normal exit" do
    described_class.with_context(outer: 1) do
      described_class.with_context(inner: 2) do
        expect(described_class.current_context).to eq(outer: 1, inner: 2)
      end
      expect(described_class.current_context).to eq(outer: 1)
    end
    expect(described_class.current_context).to eq({})
  end

  it "restores the prior context even when the block raises (ensure-pop)" do
    expect do
      described_class.with_context(a: 1) { raise "boom" }
    end.to raise_error(RuntimeError, "boom")
    expect(described_class.current_context).to eq({})
  end

  it "shallow-merges across nesting (outer keys remain visible inside inner)" do
    described_class.with_context(a: 1) do
      described_class.with_context(b: 2) do
        expect(described_class.current_context).to eq(a: 1, b: 2)
      end
    end
  end

  it "inner key overrides outer on collision" do
    described_class.with_context(a: 1) do
      described_class.with_context(a: 2) do
        expect(described_class.current_context).to eq(a: 2)
      end
      # outer unchanged after inner exits
      expect(described_class.current_context).to eq(a: 1)
    end
  end

  it "returns a frozen Hash inside the block; mutation raises FrozenError" do
    described_class.with_context(a: 1) do
      ctx = described_class.current_context
      expect(ctx).to be_frozen
      expect { ctx[:b] = 2 }.to raise_error(FrozenError)
    end
  end

  it "returns the shared frozen empty instance when no block is active" do
    a = described_class.current_context
    b = described_class.current_context
    expect(a).to eq({})
    expect(a).to be_frozen
    expect(a).to equal(b) # single shared instance — no per-call allocation
  end

  it "rejects positional Hash form (Ruby 3 kwargs/Hash separation)" do
    expect do
      described_class.with_context({ a: 1 }) { :unreached }
    end.to raise_error(ArgumentError)
  end

  it "passes the block return value through (yield return falls through ensure-pop)" do
    result = described_class.with_context(a: 1) { 42 }
    expect(result).to eq(42)
  end
end
