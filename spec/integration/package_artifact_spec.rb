# frozen_string_literal: true

require "open3"
require "spec_helper"
require "tmpdir"

RSpec.describe "release gem artifact" do
  let(:root) { TypedEAV::Engine.root }
  let(:checker) { root.join("script/package_contents_check") }

  it "matches the gemspec and contains the files consumers require" do
    Dir.mktmpdir("typed-eav-artifact-spec-") do |tmp|
      artifact = File.join(tmp, "typed_eav-#{TypedEAV::VERSION}.gem")
      build_output, build_status = Open3.capture2e(
        Gem.ruby,
        "-S",
        "gem",
        "build",
        root.join("typed_eav.gemspec").to_s,
        "--output",
        artifact,
        chdir: root.to_s,
      )
      expect(build_status).to be_success, build_output

      check_output, check_status = Open3.capture2e(Gem.ruby, checker.to_s, artifact, chdir: root.to_s)

      expect(check_status).to be_success, check_output
      expect(check_output).to include("Package contents verified")
    end
  end

  it "rejects a missing artifact" do
    output, status = Open3.capture2e(Gem.ruby, checker.to_s, "/does/not/exist.gem", chdir: root.to_s)

    expect(status).not_to be_success
    expect(output).to include("gem artifact does not exist")
  end

  it "allows the consumer smoke test to reuse the verified artifact" do
    smoke = root.join("script/consumer_install_smoke").read

    expect(smoke).to include('ENV.fetch("TYPED_EAV_GEM_ARTIFACT", nil)')
    expect(smoke).to include('artifact_spec.name == "typed_eav"')
    expect(smoke).to include("artifact_spec.version.to_s == TypedEAV::VERSION")
  end
end
