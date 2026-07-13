# frozen_string_literal: true

require "spec_helper"

RSpec.describe "maintainer and architecture documentation" do
  let(:root) { TypedEAV::Engine.root }

  it "keeps both agent entrypoints synchronized with the current release" do
    agents = root.join("AGENTS.md").read
    claude = root.join("CLAUDE.md").read

    expect(claude).to eq(agents)
    expect(agents).to include("Last shipped:** #{TypedEAV::VERSION}")
    expect(agents).to include("canonical release-status sources")
  end

  it "documents the complete schema and public partition seam" do
    readme = root.join("README.md").read

    expect(readme).to include("typed_eav_value_versions")
    expect(readme).to include("append-only audit history")
    expect(readme).to include("ADR-0006")
    expect(readme).to include("effective_fields_by_name")
    expect(readme).to include("find_visible_section!")
  end
end
