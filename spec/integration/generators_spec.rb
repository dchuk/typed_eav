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

    it "routes generated admin field visibility and section checks through the partition seam" do
      controller = File.read(File.join(destination, "app/controllers/typed_eav_controller.rb"))

      expect(controller).to include("TypedEAV::Partition.visible_fields")
      expect(controller).to include("TypedEAV::Partition.find_visible_section!")
      expect(controller).not_to include("TypedEAV::Field::Base.where(scope: [scope, nil])")
      expect(controller).not_to include("TypedEAV::Section.for_entity(entity_type, scope: scope).find")
    end

    it "shows both partition axes in the generated admin views" do
      index = File.read(File.join(destination, "app/views/typed_eav/index.html.erb"))
      common_fields = File.read(File.join(destination, "app/views/typed_eav/forms/_common_fields.html.erb"))

      expect(index).to include("<th>Parent Scope</th>")
      expect(index).to include("field.parent_scope.inspect")
      expect(common_fields).to include("<label>Parent Scope</label>")
      expect(common_fields).to include("field.parent_scope")
    end

    it "documents tuple-shaped scope resolver examples in the generated initializer" do
      initializer = File.read(File.join(destination, "config/initializers/typed_eav.rb"))

      expect(initializer).to include("returns `[scope, parent_scope]`")
      expect(initializer).to include("c.scope_resolver = -> { [Current.account&.id, nil] }")
      expect(initializer).not_to include("c.scope_resolver = -> { Current.account&.id }")
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
