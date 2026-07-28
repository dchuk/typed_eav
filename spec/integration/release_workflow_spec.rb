# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "release workflow" do
  let(:root) { TypedEAV::Engine.root }
  let(:workflow_path) { root.join(".github/workflows/release.yml") }
  let(:workflow) { YAML.safe_load(workflow_path.read, aliases: true) }
  let(:jobs) { workflow.fetch("jobs") }

  def commands(job)
    job.fetch("steps").filter_map { |step| step["run"] }.join("\n")
  end

  def actions(job)
    job.fetch("steps").filter_map { |step| step["uses"] }
  end

  it "dereferences the triggering tag and checks every job out at that exact commit" do
    source = jobs.fetch("source")

    expect(commands(source)).to include('git rev-parse "${FULL_REF}^{commit}"')
    expect(source.dig("outputs", "commit_sha")).to eq("${{ steps.source.outputs.commit_sha }}")
    %w[compatibility test package consumer-install publish].each do |job_name|
      checkout = jobs.fetch(job_name).fetch("steps").find { |step| step["uses"] == "actions/checkout@v7" }
      expect(checkout.dig("with", "ref")).to eq("${{ needs.source.outputs.commit_sha }}")
    end
  end

  it "runs every approved compatibility lane before the final gate" do
    test = jobs.fetch("test")
    gate = jobs.fetch("release-gate")

    expect(test.dig("strategy", "matrix")).to eq("${{ fromJSON(needs.compatibility.outputs.matrix) }}")
    expect(test.dig("services", "postgres", "image")).to eq("postgres:${{ matrix.postgresql }}")
    expect(test.dig("env", "RAILS_VERSION")).to eq("${{ matrix.rails }}")
    expect(gate.fetch("needs")).to contain_exactly("source", "compatibility", "test", "package", "consumer-install")
    expect(commands(gate)).to include("Release verification failed or was skipped")
  end

  it "lints, inspects, and passes one immutable gem artifact through the consumer test" do
    package = jobs.fetch("package")
    consumer = jobs.fetch("consumer-install")

    expect(commands(package)).to include("bundle exec rubocop --format github")
    expect(commands(package)).to include("script/package_contents_check")
    expect(actions(package)).to include("actions/upload-artifact@v7")
    expect(consumer.fetch("needs")).to include("package")
    expect(actions(consumer)).to include("actions/download-artifact@v8")
    expect(commands(consumer)).to include("sha256sum --check pkg/SHA256SUMS")
    expect(commands(consumer)).to include('TYPED_EAV_GEM_ARTIFACT="${artifacts[0]}"')
  end

  it "keeps trusted publishing isolated behind every verification result" do
    publish = jobs.fetch("publish")
    workflow_text = workflow_path.read

    expect(publish.fetch("needs")).to contain_exactly("source", "compatibility", "package", "release-gate")
    expect(publish.fetch("if")).to include("needs.release-gate.result == 'success'")
    expect(publish.dig("permissions", "contents")).to eq("write")
    expect(publish.dig("permissions", "id-token")).to eq("write")
    expect(publish.dig("environment", "name")).to eq("rubygems")
    expect(actions(publish)).to include(
      "rubygems/configure-rubygems-credentials@dc5a8d8553e6ee01fc26761a49e99e733d17954a",
    )
    expect(commands(publish)).to include("gem push pkg/*.gem --host https://rubygems.org")
    expect(workflow_text).not_to include("rubygems/release-gem@")
  end

  it "finishes publication with a stable GitHub release marked latest" do
    github_release = jobs.fetch("github-release")

    expect(github_release.fetch("needs")).to contain_exactly("source", "publish")
    expect(github_release.fetch("if")).to include("needs.publish.result == 'success'")
    expect(github_release.dig("permissions", "contents")).to eq("write")
    expect(github_release.dig("env", "GH_TOKEN")).to eq("${{ github.token }}")
    expect(commands(github_release)).to include('gh release view "$GITHUB_REF_NAME"')
    expect(commands(github_release)).to include('gh release create "$GITHUB_REF_NAME"')
    expect(commands(github_release)).to include("--verify-tag")
    expect(commands(github_release)).to include("--generate-notes")
    expect(commands(github_release)).to include("--latest")
    expect(commands(github_release)).to include('gh release edit "$GITHUB_REF_NAME" --latest')
  end

  it "retains tag-to-version guards and offers a non-publishing failed rehearsal" do
    package = jobs.fetch("package")
    gate = jobs.fetch("release-gate")
    publish = jobs.fetch("publish")

    expect(commands(package)).to include("Tag $tag_version does not match gem version $gem_version")
    expect(gate.fetch("steps").last.fetch("if")).to eq("inputs.fail_rehearsal == true")
    expect(commands(gate)).to include("Intentional rehearsal failure")
    expect(publish.fetch("if")).to include("github.event_name == 'push'")
    expect(publish.fetch("if")).to include("startsWith(github.ref, 'refs/tags/v')")
  end
end
