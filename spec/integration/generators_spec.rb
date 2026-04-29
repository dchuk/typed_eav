# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "rails/generators"
require_relative "../../lib/generators/typed_eav/install/install_generator"
require_relative "../../lib/generators/typed_eav/scaffold/scaffold_generator"

RSpec.describe "TypedEAV generators" do
  let(:destination) do
    File.expand_path("../../tmp/generators_spec", __dir__)
  end

  around do |example|
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(File.join(destination, "config"))
    File.write(
      File.join(destination, "config/routes.rb"),
      "Rails.application.routes.draw do\nend\n",
    )
    # Silence the generator's `say` output (post-install instructions) so
    # the spec runner stays readable. RSpec/ExpectOutput is about asserting
    # on output, which is not what we're doing here.
    original_stdout = $stdout
    $stdout = StringIO.new # rubocop:disable RSpec/ExpectOutput
    begin
      example.run
    ensure
      $stdout = original_stdout # rubocop:disable RSpec/ExpectOutput
      FileUtils.rm_rf(destination)
    end
  end

  describe TypedEAV::Generators::ScaffoldGenerator do
    let(:templates_root) { described_class.source_root }

    before { described_class.start([], destination_root: destination) }

    it "copies the controller and concern" do
      expect(File).to exist(File.join(destination, "app/controllers/typed_eav_controller.rb"))
      expect(File).to exist(
        File.join(destination, "app/controllers/concerns/typed_eav_controller_concern.rb"),
      )
    end

    it "copies the helper and initializer" do
      expect(File).to exist(File.join(destination, "app/helpers/typed_eav_helper.rb"))
      expect(File).to exist(File.join(destination, "config/initializers/typed_eav.rb"))
    end

    it "copies every view template" do
      view_templates = Dir.glob(File.join(templates_root, "views/**/*.erb"))
      expect(view_templates).not_to be_empty

      missing = view_templates.reject do |path|
        rel = path.sub(File.join(templates_root, "views/"), "")
        File.exist?(File.join(destination, "app/views", rel))
      end
      expect(missing).to be_empty,
                         "scaffold did not generate: #{missing.join(", ")}"
    end

    it "copies every Stimulus controller" do
      js_templates = Dir.glob(File.join(templates_root, "javascript/controllers/*.js"))
      expect(js_templates).not_to be_empty

      missing = js_templates.reject do |path|
        File.exist?(File.join(destination, "app/javascript/controllers", File.basename(path)))
      end
      expect(missing).to be_empty,
                         "scaffold did not generate: #{missing.join(", ")}"
    end

    it "ships the controller with a fail-closed authorize hook" do
      controller = File.read(File.join(destination, "app/controllers/typed_eav_controller.rb"))
      expect(controller).to include("def authorize_typed_eav_admin!")
      expect(controller).to include("head :not_found")
    end

    it "appends the typed_eav_fields routes" do
      routes = File.read(File.join(destination, "config/routes.rb"))
      expect(routes).to include("resources :typed_eav_fields")
      expect(routes).to include("post :add_option")
      expect(routes).to include("delete :remove_option")
    end
  end

  describe TypedEAV::Generators::InstallGenerator do
    it "delegates migration installation to the engine's rake task" do
      generator = described_class.new
      allow(generator).to receive(:rake)

      generator.copy_migrations

      expect(generator).to have_received(:rake).with("typed_eav:install:migrations")
    end
  end
end
