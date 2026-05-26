# frozen_string_literal: true

module TypedEAV
  # Localized semantics for the `(scope, parent_scope)` tuple.
  #
  # Five files used to smear tuple shape/coercion/invariant logic across
  # themselves (`lib/typed_eav.rb`, `Config`, `Partition`,
  # `HasTypedEav#resolve_scope`, `Field::Base#for_entity`). This module
  # gathers them in one place:
  #
  # - `normalize_permissive(value)` — the v0.1.x-BC scalar-friendly coercer
  #   used by the `with_scope` block surface and by callers that already
  #   know they may receive a loose value (single scalar, AR record, or
  #   2-element Array). Mirrors what `TypedEAV.normalize_scope` did before
  #   this refactor; the public method is now a 1-line BC alias to this.
  #
  # - `normalize_strict(value)` — the contract-surface coercer used by
  #   `TypedEAV.current_scope` when consuming a configured
  #   `Config.scope_resolver` return. Bare scalars / 1-element / 3-element
  #   Arrays raise `ArgumentError` — this is the Phase-1 strict-contract
  #   chokepoint that makes a misshaped resolver fail loudly instead of
  #   silently coercing.
  #
  # - `invariant_satisfied?(scope, parent_scope)` — Boolean orphan-parent
  #   check. Returns `false` only when `parent_scope` is present and
  #   `scope` is blank (the dead-letter shape: a parent-scope predicate
  #   with no scope predicate). Each caller picks its own response policy
  #   (raise / AR error / silent narrow) on a `false` result; this helper
  #   never raises.
  #
  # The split between permissive and strict normalization is the Phase-1
  # asymmetric contract preserved verbatim: `with_scope` block input is
  # BC-permissive (scalars are sugar for `[scalar, nil]`), `scope_resolver`
  # callable return is strict (scalars are a contract violation).
  module ScopeTuple
    class << self
      # BC-permissive normalizer for `with_scope` block input and explicit
      # tuple inputs. Always returns either `nil` or a 2-element tuple
      # `[scope, parent_scope]` where each element is a `String` or `nil`.
      #
      # Accepted inputs:
      #
      # - `nil`                                → `nil` (sentinel: nothing resolved).
      # - `[a, b]` (2-element Array)           → `[normalize_one(a), normalize_one(b)]`.
      #   Canonical Phase-1 input shape. `[scope, nil]` is the "scope-only"
      #   tuple; `[nil, "ps1"]` (orphan-parent) is intentionally accepted at
      #   this layer — orphan-parent rejection happens at the calling site
      #   (Field validator → AR error, Partition query → ArgumentError,
      #   resolve_scope → silent narrow). Keeping normalize permissive lets
      #   tests construct invalid states intentionally.
      # - any other value (scalar / AR record) → `[normalize_one(value), nil]`.
      #   BC path for `with_scope(scalar)`: single-arg block usage continues
      #   to mean "scope=scalar, parent_scope=nil".
      def normalize_permissive(value)
        return nil if value.nil?
        return [normalize_one(value[0]), normalize_one(value[1])] if value.is_a?(Array) && value.size == 2

        [normalize_one(value), nil]
      end

      # Strict-contract normalizer for `Config.scope_resolver` return values.
      # Accepts ONLY `nil` or a 2-element Array. Bare scalars, 1-element
      # Arrays, and 3-element Arrays raise `ArgumentError` quoting the bad
      # input and pointing at the migration note — this is the chokepoint
      # that makes a v0.1.x bare-scalar resolver fail loudly under Phase 1.
      def normalize_strict(value)
        return nil if value.nil?

        unless value.is_a?(Array) && value.size == 2
          raise ArgumentError,
                "TypedEAV.config.scope_resolver must return a 2-element " \
                "[scope, parent_scope] Array (or nil). Got: #{value.inspect}. " \
                "v0.1.x resolvers returning a bare scalar must be updated — " \
                "see CHANGELOG and the README migration note."
        end

        [normalize_one(value[0]), normalize_one(value[1])]
      end

      # Orphan-parent invariant predicate. Returns `true` when the tuple is
      # internally coherent, `false` ONLY when `parent_scope` is present
      # while `scope` is blank — the dead-letter shape that cannot match
      # any row under the partition predicates.
      #
      # Truth table:
      #   (nil, nil)     → true
      #   ("t1", nil)    → true
      #   ("t1", "w1")   → true
      #   (nil, "w1")    → false
      #   ("",  "w1")    → false   (empty string treated as blank on scope axis)
      #   (nil, "")      → true    (empty string treated as blank on parent axis)
      #
      # Callers each pick their own response policy on a false result:
      # `Partition.visible_fields` raises `ArgumentError`; `Field`'s model
      # validator adds an AR error; `HasTypedEAV#resolve_scope` silently
      # narrows the query. Returning a Boolean (not raising) keeps the
      # per-caller decision local.
      def invariant_satisfied?(scope, parent_scope)
        return true if parent_scope.blank?

        scope.present?
      end

      private

      # Coerce a single scope slot (scalar or AR record) into a String or nil.
      # The pre-refactor v0.1.x scalar-coercion preserved verbatim — applied
      # per-slot now that scope is a tuple.
      def normalize_one(value)
        return nil if value.nil?

        value.respond_to?(:id) ? value.id.to_s : value.to_s
      end
    end
  end
end
