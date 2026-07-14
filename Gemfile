# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Compatibility CI sets RAILS_VERSION to constrain each representative lane.
# Without it, Bundler resolves the newest Rails allowed by the gemspec.
rails_version = ENV.fetch("RAILS_VERSION", nil)
gem "rails", rails_version if rails_version

group :development, :test do
  gem "factory_bot_rails"
  gem "pg"
  gem "rspec-rails"
  gem "shoulda-matchers"

  gem "rubocop", "~> 1.86", require: false
  gem "rubocop-performance", "~> 1.26", require: false
  gem "rubocop-rails", "~> 2.34", require: false
  gem "rubocop-rspec", "~> 3.9", require: false
end
