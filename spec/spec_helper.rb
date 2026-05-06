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
engine_migration_path = TypedEAV::Engine.root.join("db/migrate").to_s
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

  # No registry reset — let has_typed_eav registrations from
  # class loading persist so registration tests are meaningful.

  # Spec metadata contract:
  #
  #   :scoping         - "I manage scope explicitly, don't wrap me." These
  #                      specs drive `with_scope` / `unscoped` / resolver
  #                      config themselves and must run with a clean
  #                      ambient state.
  #   :unscoped        - "Wrap me in `TypedEAV.unscoped` so the fail-closed
  #                      default on scoped models (e.g. Contact with
  #                      `scope_method: :tenant_id`) doesn't raise when the
  #                      example calls class-level query methods without
  #                      setting up a scope."
  #   :event_callbacks - "I exercise Phase 03 or Phase 04 event dispatch —
  #                      snapshot/restore Config.on_value_change,
  #                      Config.on_field_change, Config.versioning,
  #                      Config.actor_resolver, and the EventDispatcher
  #                      internal-subscribers arrays around the example so
  #                      Phase 04+ engine-load registrations survive."
  #   :real_commits    - "I create real AR records and need after_commit to
  #                      fire durably." Disables transactional fixtures for
  #                      the example; manually deletes ValueVersion → Value →
  #                      Option → Field → Section → Contact/Product/Project
  #                      rows after. Combine with :event_callbacks on
  #                      integration specs that exercise Phase 03 or Phase
  #                      04 dispatch.
  #
  # Everything else runs as-is. Previously the around block wrapped every
  # example in `unscoped` by default, which masked scoped+global name-
  # collision bugs in the class-level query path — opt-in is the safer
  # contract.
  config.around do |example|
    if example.metadata[:unscoped]
      TypedEAV.unscoped { example.run }
    else
      example.run
    end
  end

  # :event_callbacks - snapshot/restore Phase 03 + Phase 04 dispatch state
  # per example. Snapshot list: Config.on_value_change, Config.on_field_change,
  # Config.versioning, Config.actor_resolver, EventDispatcher.value_change_internals,
  # EventDispatcher.field_change_internals. Uses snapshot-and-restore rather
  # than EventDispatcher.reset! / Config.reset! because Phase 04 versioning
  # registers internal subscribers at engine load (plan 04-02) — wiping the
  # internal list in test teardown would break Phase 04 specs that follow.
  # Mirrors the :scoping / :unscoped opt-in metadata pattern.
  config.around(:each, :event_callbacks) do |example|
    saved_on_value_change = TypedEAV::Config.on_value_change
    saved_on_field_change = TypedEAV::Config.on_field_change
    saved_versioning      = TypedEAV::Config.versioning
    saved_actor_resolver  = TypedEAV::Config.actor_resolver
    saved_value_internals = TypedEAV::EventDispatcher.value_change_internals.dup
    saved_field_internals = TypedEAV::EventDispatcher.field_change_internals.dup

    TypedEAV::Config.on_value_change = nil
    TypedEAV::Config.on_field_change = nil
    TypedEAV::Config.versioning      = false
    TypedEAV::Config.actor_resolver  = nil
    TypedEAV::EventDispatcher.value_change_internals.clear
    TypedEAV::EventDispatcher.field_change_internals.clear

    example.run
  ensure
    TypedEAV::Config.on_value_change = saved_on_value_change
    TypedEAV::Config.on_field_change = saved_on_field_change
    TypedEAV::Config.versioning      = saved_versioning
    TypedEAV::Config.actor_resolver  = saved_actor_resolver
    TypedEAV::EventDispatcher.instance_variable_set(:@value_change_internals, saved_value_internals)
    TypedEAV::EventDispatcher.instance_variable_set(:@field_change_internals, saved_field_internals)
  end

  # :real_commits - disable transactional-fixtures wrap so after_commit fires
  # durably; manually clean up rows in FK-respecting order after.
  #
  # The per-example toggle MUST be `use_transactional_tests`, not
  # `use_transactional_fixtures`. The latter is the global RSpec.configure
  # slot above; rspec-rails 8 copies that slot into the per-example-group
  # attribute `use_transactional_tests` at example startup
  # (lib/rspec/rails/fixture_support.rb:25 in rspec-rails-8.x:
  # `self.use_transactional_tests = RSpec.configuration.use_transactional_fixtures`)
  # and consults `use_transactional_tests` at runtime to decide whether to
  # wrap. Setting `use_transactional_fixtures` on the example group has no
  # effect — the runtime never reads it.
  #
  # Cleanup order matters: ValueVersion rows reference Value/Field via FK
  # (ON DELETE SET NULL — would NULL on Value/Field delete, but explicit
  # delete keeps the table empty between examples for "exactly N versions
  # written" assertions in Phase 04 specs). Value rows reference Field via
  # FK (ON DELETE SET NULL post Phase 02). Field rows reference Section
  # via FK. Delete children before parents so we don't trip FK constraints
  # on Postgres. Option rows belong to Field (dependent: :destroy), so
  # deleting Field rows takes them along — but we delete Option explicitly
  # first to keep the cleanup ordering grep-able and not depend on AR's
  # destroy chain (delete_all bypasses callbacks anyway). Contact / Product /
  # Project are the dummy app's host entities — clean them too so cross-
  # test row counts stay stable.
  #
  # We do NOT use database_cleaner — the gem has no such dependency and
  # the manual cleanup is short enough to inline.
  config.around(:each, :real_commits) do |example|
    saved_setting = example.example_group.use_transactional_tests
    example.example_group.use_transactional_tests = false
    example.run
  ensure
    TypedEAV::ValueVersion.delete_all
    TypedEAV::Value.delete_all
    TypedEAV::Option.delete_all
    TypedEAV::Field::Base.delete_all
    TypedEAV::Section.delete_all
    Contact.delete_all if defined?(Contact)
    Product.delete_all if defined?(Product)
    Project.delete_all if defined?(Project)
    example.example_group.use_transactional_tests = saved_setting
  end
end
