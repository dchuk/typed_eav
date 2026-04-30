# frozen_string_literal: true

require_relative "lib/typed_eav/version"

Gem::Specification.new do |spec|
  spec.name        = "typed_eav"
  spec.version     = TypedEAV::VERSION
  spec.authors     = ["Darrin Chuk"]
  spec.email       = ["me@dchuk.com"]
  spec.summary     = "Typed custom fields for ActiveRecord models"
  spec.description = <<~DESC.tr("\n", " ").strip
    Add dynamic custom fields to ActiveRecord models at runtime using native
    database typed columns instead of jsonb blobs. Hybrid EAV with real
    indexes, real types, real query performance.
  DESC
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/dchuk/typed_eav"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.add_dependency "rails", ">= 7.1"
end
