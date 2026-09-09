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
    schema = root.join("docs/guides/schema.md").read
    architecture = root.join("docs/guides/architecture.md").read

    expect(schema).to include("typed_eav_value_versions")
    expect(schema).to include("append-only audit history")
    expect(architecture).to include("ADR-0006")
    expect(architecture).to include("effective_fields_by_name")
    expect(architecture).to include("find_visible_section!")
  end
end
