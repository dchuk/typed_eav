# frozen_string_literal: true

require "spec_helper"

RSpec.describe "runtime compatibility contract" do
  let(:root) { TypedEAV::Engine.root }
  let(:contract) { JSON.parse(root.join(".github/compatibility.json").read) }
  let(:gemspec) { Gem::Specification.load(root.join("typed_eav.gemspec").to_s) }

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

  it "enforces the approved Ruby and Rails bounds in package metadata" do
    ruby_requirement = Gem::Requirement.new(*contract.dig("ruby", "requirement"))
    rails_requirement = Gem::Requirement.new(*contract.dig("rails", "requirement"))
    rails_dependency = gemspec.runtime_dependencies.find { |dependency| dependency.name == "rails" }

    expect(gemspec.required_ruby_version).to eq(ruby_requirement)
    expect(rails_dependency.requirement).to eq(rails_requirement)
    expect(ruby_requirement).not_to be_satisfied_by(Gem::Version.new("4.1.0"))
    expect(rails_requirement).not_to be_satisfied_by(Gem::Version.new("8.2.0"))
  end

  it "publishes the contract and its canonical source to consumers" do
    readme = root.join("README.md").read

    expect(readme).to include(".github/compatibility.json")
    expect(readme).to include("Ruby | 3.3 through 4.0")
    expect(readme).to include("Rails | 7.2 through 8.1")
    expect(readme).to include("PostgreSQL | 15 through 18")
    expect(readme).to include("prerelease versions")
  end

  it "drives CI and release workflow runtime selection from the canonical contract" do
    ci = root.join(".github/workflows/ci.yml").read
    release = root.join(".github/workflows/release.yml").read

    expect(ci).to include("fromJSON(needs.compatibility.outputs.matrix)")
    expect(ci).to include("postgres:${{ matrix.postgresql }}")
    expect(ci).to include("RAILS_VERSION: ${{ matrix.rails }}")
    expect(ci).to include("needs.compatibility.outputs.ceiling_ruby")
    expect(release).to include("needs.compatibility.outputs.ceiling_ruby")
    expect(ci.scan("actions/checkout@v7").length).to eq(4)
    expect(ci).not_to include("actions/checkout@v4")
  end
end
