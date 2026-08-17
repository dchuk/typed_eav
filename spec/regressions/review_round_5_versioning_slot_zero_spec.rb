# frozen_string_literal: true

require "spec_helper"

# Regression coverage for the Phase 8 atomic writer. Versioning is boot-latched
# onto Value's transactional callbacks; EventDispatcher remains the
# after_commit surface for public callbacks and has no internal version writer.
RSpec.describe "atomic versioning registration", :event_callbacks do
  it "does not install a dispatcher writer when versioning is disabled" do
    TypedEAV::EventDispatcher.value_change_internals.clear
    TypedEAV.config.versioning = false

    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::EventDispatcher.value_change_internals).to be_empty
    expect(TypedEAV::EventDispatcher.value_change_internals)
      .not_to include(TypedEAV::Versioning::Subscriber.method(:call))
  end

  it "installs one transactional callback set and no dispatcher writer when enabled" do
    TypedEAV::EventDispatcher.value_change_internals.clear
    TypedEAV.config.versioning = true

    TypedEAV::Versioning.register_if_enabled
    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::EventDispatcher.value_change_internals).to be_empty
    expect(TypedEAV::Value._create_callbacks.count { |callback| callback.filter == :_write_version_create })
      .to eq(1)
    expect(TypedEAV::Value._update_callbacks.count { |callback| callback.filter == :_write_version_update })
      .to eq(1)
    expect(TypedEAV::Value._destroy_callbacks.count { |callback| callback.filter == :_write_version_destroy })
      .to eq(1)
  end

  it "fails closed before callback installation when pools differ" do
    TypedEAV.config.versioning = true
    original_pool = TypedEAV::Value.connection_pool
    allow(TypedEAV::Value).to receive(:connection_pool).and_return(Object.new)

    expect { TypedEAV::Versioning.register_if_enabled }
      .to raise_error(ArgumentError, /share a connection pool/)

    expect(TypedEAV::Value.connection_pool).not_to equal(original_pool)
  end
end
