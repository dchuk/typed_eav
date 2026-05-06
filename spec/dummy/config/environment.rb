# frozen_string_literal: true

require_relative "boot"
require "rails/all"

Bundler.require(*Rails.groups)

require "typed_eav"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.root = File.expand_path("..", __dir__)

    # Phase 05 Active Storage scaffolding for the dummy app. The :test
    # service is declared in spec/dummy/config/storage.yml (Disk-backed
    # under tmp/storage so test runs don't pollute the repo storage/
    # directory). Active Storage itself is loaded via `require "rails/all"`
    # above; the gem's runtime soft-detect lives in lib/typed_eav/engine.rb
    # (config.after_initialize block) — when AS is absent, the dummy-app
    # path is not exercised. The integration specs run against the loaded
    # path; the unloaded path is covered by a testable seam in
    # active_storage_soft_detect_spec.rb.
    config.active_storage.service = :test
  end
end

Rails.application.initialize!
