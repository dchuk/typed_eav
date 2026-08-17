# frozen_string_literal: true

require "spec_helper"

# Regression coverage for the Phase 8 atomic writer. Versioning is boot-latched
# onto Value's transactional callbacks; EventDispatcher remains the
# after_commit surface for public callbacks and has no internal version writer.
ATOMIC_VERSIONING_CALLBACKS = {
  create: :_write_version_create,
  update: :_write_version_update,
  destroy: :_write_version_destroy,
}.freeze
RSpec.describe "atomic versioning registration", :event_callbacks do
  def callback_count(event, filter)
    TypedEAV::Value.send(:get_callbacks, event).to_a.count { |callback| callback.filter == filter }
  end

  def remove_atomic_callbacks
    ATOMIC_VERSIONING_CALLBACKS.each do |event, filter|
      kind = event == :destroy ? :before : :after
      TypedEAV::Value.skip_callback(event, kind, filter) if callback_count(event, filter).positive?
    end
  end

  def restore_atomic_callbacks
    TypedEAV.config.versioning = true
    TypedEAV::Versioning.register_if_enabled
  end

  it "keeps the cold disabled state free of transactional callbacks" do
    remove_atomic_callbacks
    TypedEAV.config.versioning = false

    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(false)
    ATOMIC_VERSIONING_CALLBACKS.each { |event, filter| expect(callback_count(event, filter)).to eq(0) }
  ensure
    allow(TypedEAV::Value).to receive(:connection_pool).and_call_original
    restore_atomic_callbacks
  end

  it "reports and preserves one installed callback per lifecycle event" do
    remove_atomic_callbacks
    TypedEAV::EventDispatcher.value_change_internals.clear
    TypedEAV.config.versioning = true

    TypedEAV::Versioning.register_if_enabled
    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::EventDispatcher.value_change_internals).to be_empty
    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(true)
    ATOMIC_VERSIONING_CALLBACKS.each { |event, filter| expect(callback_count(event, filter)).to eq(1) }
  ensure
    restore_atomic_callbacks
  end

  it "reinstalls a callback removed from the actual chain" do
    restore_atomic_callbacks
    TypedEAV::Value.skip_callback(:update, :after, :_write_version_update)
    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(false)

    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(true)
    expect(callback_count(:update, :_write_version_update)).to eq(1)
  ensure
    restore_atomic_callbacks
  end

  it "keeps installed callbacks latched when the runtime switch is toggled" do
    restore_atomic_callbacks
    TypedEAV.config.versioning = false

    TypedEAV::Versioning.register_if_enabled

    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(true)
  ensure
    restore_atomic_callbacks
  end

  it "fails closed before callback installation when pools differ" do
    remove_atomic_callbacks
    TypedEAV.config.versioning = true
    allow(TypedEAV::Value).to receive(:connection_pool).and_return(Object.new)

    expect { TypedEAV::Versioning.register_if_enabled }
      .to raise_error(ArgumentError, /share a connection pool/)

    expect(TypedEAV::Versioning.atomic_callbacks_installed?).to be(false)
    ATOMIC_VERSIONING_CALLBACKS.each { |event, filter| expect(callback_count(event, filter)).to eq(0) }
  ensure
    allow(TypedEAV::Value).to receive(:connection_pool).and_call_original
    restore_atomic_callbacks
  end
end
