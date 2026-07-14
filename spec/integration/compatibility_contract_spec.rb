# frozen_string_literal: true

require "spec_helper"

RSpec.describe "runtime compatibility contract" do
  let(:root) { TypedEAV::Engine.root }
  let(:contract) { JSON.parse(root.join(".github/compatibility.json").read) }

  it "defines the approved support window" do
    expect(contract.dig("ruby", "series")).to eq(%w[3.3 3.4 4.0])
    expect(contract.dig("rails", "series")).to eq(%w[7.2 8.0 8.1])
    expect(contract.fetch("postgresql")).to include(
      "minimum" => "15",
      "maximum" => "18",
      "tested" => %w[15 16 18],
    )
    expect(contract.fetch("prereleases")).to eq("unsupported")
  end

  it "covers every supported release line with bounded representative lanes" do
    lanes = contract.fetch("lanes")

    expect(lanes.pluck("name")).to eq(%w[floor middle ceiling])
    expect(lanes.pluck("rails_series")).to eq(contract.dig("rails", "series"))
    expect(lanes.pluck("ruby")).to include(contract.dig("ruby", "series").first)
    expect(lanes.pluck("ruby")).to include(contract.dig("ruby", "series").last)
    expect(lanes.pluck("postgresql")).to include(contract.dig("postgresql", "minimum"))
    expect(lanes.pluck("postgresql")).to include(contract.dig("postgresql", "maximum"))
  end
end
