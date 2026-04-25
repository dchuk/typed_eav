# frozen_string_literal: true

require_relative "lib/typed_fields/version"

Gem::Specification.new do |spec|
  spec.name        = "typed_fields"
  spec.version     = TypedFields::VERSION
  spec.authors     = ["Darrin Chuk"]
  spec.summary     = "Typed custom fields for ActiveRecord models"
  spec.description = <<~DESC.tr("\n", " ").strip
    Add dynamic custom fields to ActiveRecord models at runtime using native
    database typed columns instead of jsonb blobs. Hybrid EAV with real
    indexes, real types, real query performance.
  DESC
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/dchuk/typed_fields"

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.1"
end
