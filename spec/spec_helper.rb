# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rspec/rails"
require "factory_bot_rails"
require "shoulda-matchers"

# Explicitly load test models (Zeitwerk can't autoload them from test_models.rb
# since the filename doesn't match the class names Contact/Product)
require_relative "dummy/app/models/test_models"

ActiveRecord::Migration.maintain_test_schema!

# Ensure engine migrations are included in the migration paths
engine_migration_path = TypedFields::Engine.root.join("db/migrate").to_s
unless ActiveRecord::Migrator.migrations_paths.include?(engine_migration_path)
  ActiveRecord::Migrator.migrations_paths << engine_migration_path
end

# Tell FactoryBot where to find our factory definitions
FactoryBot.definition_file_paths = [
  File.expand_path("factories", __dir__),
]
FactoryBot.find_definitions

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :active_record
    with.library :active_model
  end
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods

  # No registry reset — let has_typed_fields registrations from
  # class loading persist so registration tests are meaningful.

  # Scope-handling metadata contract:
  #
  #   :scoping  - "I manage scope explicitly, don't wrap me." These specs
  #               drive `with_scope` / `unscoped` / resolver config themselves
  #               and must run with a clean ambient state.
  #   :unscoped - "Wrap me in `TypedFields.unscoped` so the fail-closed default
  #               on scoped models (e.g. Contact with `scope_method: :tenant_id`)
  #               doesn't raise when the example calls class-level query
  #               methods without setting up a scope."
  #
  # Everything else runs as-is. Previously this block wrapped every example
  # in `unscoped` by default, which masked scoped+global name-collision bugs
  # in the class-level query path — opt-in is the safer contract.
  config.around do |example|
    if example.metadata[:unscoped]
      TypedFields.unscoped { example.run }
    else
      example.run
    end
  end
end
