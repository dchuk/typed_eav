# frozen_string_literal: true

module TypedEAV
  # Mixin that opts a host entity into Phase 04 versioning AFTER it has
  # already called `has_typed_eav`. Equivalent in effect to passing
  # `versioned: true` directly to `has_typed_eav`, but useful for:
  #   - Codebases that group versioning concerns separately from the
  #     `has_typed_eav` macro (e.g., audited models in a `Auditable`
  #     mixin pattern).
  #   - Apps that conditionally include versioning via Rails initializers
  #     based on environment (`include TypedEAV::Versioned if Rails.env.production?`).
  #
  # ## Usage
  #
  #   class Contact < ActiveRecord::Base
  #     has_typed_eav scope_method: :tenant_id, types: %i[text integer]
  #     include TypedEAV::Versioned
  #   end
  #
  # The order matters: `has_typed_eav` first, `include TypedEAV::Versioned`
  # second. The concern's `included` hook re-registers the entity with
  # `versioned: true`, preserving the existing `types:` restriction by
  # reading the current Registry entry. If `has_typed_eav` was not called
  # first, the included hook raises ArgumentError with a clear message.
  #
  # Why post-`has_typed_eav` (not standalone): `has_typed_eav` sets up
  # the `has_many :typed_values` association, defines `typed_eav_scope` /
  # `typed_eav_parent_scope` accessors, and includes the InstanceMethods
  # mixin. Without that infrastructure, Phase 04 versioning has nothing
  # to version — the host model can't even hold typed values. So
  # `Versioned` is a *post*-step, not a replacement (Scout §2 confirmed
  # this design).
  #
  # ## Equivalent to `has_typed_eav versioned: true`
  #
  # The two forms produce identical Registry state:
  #   has_typed_eav versioned: true
  #   # OR
  #   has_typed_eav
  #   include TypedEAV::Versioned
  #
  # The kwarg form is preferred for new code (one declaration, less to
  # remember). The concern form is for codebases with established
  # mixin-based feature wiring conventions.
  module Versioned
    extend ActiveSupport::Concern

    included do
      # Precondition: has_typed_eav must have run first.
      # has_typed_eav sets `typed_eav_scope_method` as a class_attribute
      # (lib/typed_eav/has_typed_eav.rb:115-116) — even when scope_method
      # is nil, the class_attribute is defined. We test for the presence
      # of the class_attribute reader as the canonical "did has_typed_eav
      # run" check. `respond_to?` distinguishes "method defined" from
      # "method missing" without false-positives from nil values.
      unless respond_to?(:typed_eav_scope_method)
        raise ArgumentError,
              "include TypedEAV::Versioned requires `has_typed_eav` to have run first on #{name}. " \
              "Add `has_typed_eav` (with any options you need) BEFORE `include TypedEAV::Versioned`. " \
              "Alternatively, pass `versioned: true` directly to has_typed_eav."
      end

      # Re-register with versioned: true. Preserve the existing types:
      # restriction by reading the current Registry entry.
      # has_typed_eav already called register(name, types: types,
      # versioned: false) — we overwrite with versioned: true while
      # keeping the same types. If the entry doesn't exist (defensive
      # — shouldn't happen post-has_typed_eav), default types to nil.
      existing = TypedEAV.registry.entities[name] || {}
      TypedEAV.registry.register(name, types: existing[:types], versioned: true)
    end
  end
end
