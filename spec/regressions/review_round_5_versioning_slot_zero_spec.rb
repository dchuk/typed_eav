# frozen_string_literal: true

require "spec_helper"

# Regression: Phase 04 versioning subscriber registration honors the
# locked hook-ordering decision (04-CONTEXT.md §Phase Boundary, ROADMAP
# §"Hook ordering is locked at Phase 3"). Two halves of the contract:
#
#   1. When TypedEAV.config.versioning is false (default), no callable
#      is registered with EventDispatcher.value_change_internals. This
#      is the locked CONTEXT line 17 zero-overhead contract — for apps
#      that don't enable versioning, the dispatcher chain stays empty
#      (no method dispatch, no per-write config read).
#
#   2. When TypedEAV.config.versioning is true at engine
#      `config.after_initialize` time, the Subscriber is registered at
#      slot 0 of the chain. Versioning runs FIRST; the user
#      `Config.on_value_change` proc fires LAST. Phase 07's future
#      matview block will declare its own `config.after_initialize`
#      LATER in the same engine class to keep matview at slot ≥ 1.
#
# Both halves are tested here by invoking the extracted helper
# `TypedEAV::Versioning.register_if_enabled` against freshly-cleared
# state. The helper is the same code the engine's `config.after_initialize`
# block calls — so this spec exercises the production registration logic
# directly without rebooting Rails (which is impractical inside RSpec).
#
# Spec uses :event_callbacks so the around hook snapshot/restores
# value_change_internals AND Config.versioning between examples — the
# manual mutations inside each example body do not leak.
RSpec.describe "Phase 04 versioning subscriber registration (round 5 regression)", :event_callbacks do
  describe "when TypedEAV.config.versioning is false (default)" do
    it "register_if_enabled does NOT register the subscriber — value_change_internals stays empty" do
      # The :event_callbacks around hook already cleared value_change_internals
      # at example entry. Reset config to the default false explicitly to
      # document the precondition (the around hook also resets Config.versioning).
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = false

      TypedEAV::Versioning.register_if_enabled

      empty_msg = "Default boot (versioning=false) must leave value_change_internals empty. " \
                  "Locked CONTEXT line 17 zero-overhead contract: no callable in the chain " \
                  "when versioning is off. If this fails, register_if_enabled stopped honoring " \
                  "the master switch — check lib/typed_eav/versioning.rb."
      expect(TypedEAV::EventDispatcher.value_change_internals).to be_empty, empty_msg

      not_include_msg = "Subscriber.method(:call) must NOT appear in value_change_internals when " \
                        "Config.versioning is false. Defense-in-depth check against future regressions " \
                        "that might add the subscriber via a side path."
      expect(TypedEAV::EventDispatcher.value_change_internals)
        .not_to include(TypedEAV::Versioning::Subscriber.method(:call)), not_include_msg
    end
  end

  describe "when TypedEAV.config.versioning is true at boot" do
    it "register_if_enabled places the subscriber at slot 0 of value_change_internals" do
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = true

      TypedEAV::Versioning.register_if_enabled

      slot0_msg = "Slot 0 of value_change_internals is " \
                  "#{TypedEAV::EventDispatcher.value_change_internals.first.inspect}, " \
                  "expected TypedEAV::Versioning::Subscriber.method(:call). " \
                  "Locked ordering from 04-CONTEXT.md §Phase Boundary: versioning runs FIRST. " \
                  "If a future engine block registers a different subscriber BEFORE versioning, " \
                  "this spec catches the regression. The fix is to declare the new block AFTER " \
                  "the versioning block in lib/typed_eav/engine.rb (Rails runs " \
                  "`config.after_initialize` blocks in declaration order within a single Engine)."
      expect(TypedEAV::EventDispatcher.value_change_internals.first)
        .to eq(TypedEAV::Versioning::Subscriber.method(:call)), slot0_msg
    end

    it "register_if_enabled is semantically equivalent to manual registration" do
      # Defense-in-depth: verify the helper's external behavior matches a manual
      # equivalent. If someone refactors register_if_enabled to take a different
      # code path, this spec catches semantic drift between "what the engine block
      # does" and "what specs assert it does".
      #
      # Method#== compares receiver+name (semantic equality), which is what we
      # want — register_if_enabled and a manual register call produce different
      # Method instances (every `.method(:call)` returns a fresh object), but
      # they refer to the same callable so they compare equal under ==. The
      # `eq` matcher uses Ruby `==`, NOT object identity (`equal?`).
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = true

      TypedEAV::Versioning.register_if_enabled
      from_helper = TypedEAV::EventDispatcher.value_change_internals.dup

      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV::EventDispatcher.register_internal_value_change(
        TypedEAV::Versioning::Subscriber.method(:call),
      )
      manual = TypedEAV::EventDispatcher.value_change_internals.dup

      eq_msg = "TypedEAV::Versioning.register_if_enabled must produce the semantically " \
               "equivalent state as a direct EventDispatcher.register_internal_value_change " \
               "call (Method#== compares receiver+name; fresh Method instances compare equal). " \
               "If they diverge, the engine's `config.after_initialize` block is no longer " \
               "equivalent to the specs' re-registration pattern (Discrepancy D4 from plan 04-02 amendment)."
      expect(from_helper).to eq(manual), eq_msg
    end

    it "register_if_enabled is idempotent — calling twice does not double-register" do
      # Long-term invariant guard: register_if_enabled uses Array#include?
      # against Subscriber.method(:call) to short-circuit re-registration.
      # Method#== compares receiver+name (semantic equality), so even though
      # each `Subscriber.method(:call)` returns a fresh Method object, the
      # include? check correctly detects "already registered". Production
      # currently calls the helper exactly once at engine boot; this spec
      # locks the idempotency contract so future refactors (e.g., a new
      # code path that re-invokes the helper) can't accidentally double-register.
      TypedEAV::EventDispatcher.value_change_internals.clear
      TypedEAV.config.versioning = true

      TypedEAV::Versioning.register_if_enabled
      TypedEAV::Versioning.register_if_enabled

      matching = TypedEAV::EventDispatcher.value_change_internals.count do |m|
        m == TypedEAV::Versioning::Subscriber.method(:call)
      end
      idempotent_msg = "Calling register_if_enabled twice with versioning=true must produce " \
                       "exactly ONE Subscriber.method(:call) entry, got #{matching}. The helper's " \
                       "Array#include? guard depends on Method#== semantic equality (receiver+name); " \
                       "if this fails, the guard was removed."
      expect(matching).to eq(1), idempotent_msg
    end
  end
end
