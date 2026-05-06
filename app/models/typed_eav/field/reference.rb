# frozen_string_literal: true

module TypedEAV
  module Field
    # Foreign-key field type. Stores the target record's integer ID in
    # `integer_value`. The `:references` operator accepts AR record
    # instances OR Integer IDs at query time, normalizing to the FK via
    # `field.cast` before predicate emission.
    #
    # ## Phase 05 Gating Decision 2 (RESOLVED)
    #
    # Reference target-scope validation runs along a DIFFERENT axis than
    # the existing `Value#validate_field_scope_matches_entity` guard
    # (which checks the SOURCE entity against the FIELD's `scope`).
    # Reference checks the TARGET entity against the FIELD's
    # `target_scope` option:
    #
    # - `target_scope` NIL → references to any entity type (scoped or
    #   unscoped) are accepted; no cross-scope check at value save time.
    # - `target_scope` SET + `target_entity_type` is unscoped (no
    #   `has_typed_eav scope_method:`) → field save FAILS with explicit
    #   error. Mirrors the `field.scope.present?` guard pattern in
    #   `Value#validate_field_scope_matches_entity` (value.rb:403-408)
    #   — fail fast at field-config time rather than letting every
    #   value save dead-letter.
    # - `target_scope` SET + target scoped + target's `typed_eav_scope`
    #   does not match `target_scope` → value save FAILS.
    #
    # ## Operators (explicit narrowing)
    #
    # `:eq, :is_null, :is_not_null, :references`. Does NOT inherit
    # `:integer_value`'s default operator set (which includes `:gt`,
    # `:lt`, `:between`) since arithmetic comparisons on FKs don't
    # carry useful semantics. The `:references` operator is registered
    # ONLY on this class — QueryBuilder's operator-validation gate
    # rejects it on every other field type.
    #
    # `:references` semantics are equivalent to `:eq` on integer_value
    # but additionally accept AR record instances (normalized via
    # `field.cast`). This gives ergonomic parity with Rails AR
    # association queries (`Contact.where(manager: alice)`) — the EAV
    # equivalent accepts a model instance directly. Allowing `:eq` to
    # accept AR records would require a casting fork inside
    # QueryBuilder.filter's `:eq` branch which would touch every other
    # field type; adding a separate operator symbol is the minimal path.
    #
    # ## Options
    #
    # - `target_entity_type`: REQUIRED. String class name of the target
    #   AR model (e.g., `"Contact"`). Validated to constantize.
    # - `target_scope`: OPTIONAL. The expected `typed_eav_scope` value
    #   for target records. Type-loose comparison (`to_s == to_s`)
    #   matches the Phase 1 `entity_partition_axis_matches?` pattern.
    #
    # ## Storage column
    #
    # `:integer_value`. String FK targets and UUID FK targets are out
    # of scope (the dummy app and prevailing AR convention is integer
    # PK; UUID support would require schema changes to typed_eav_values
    # that are not Phase 5).
    class Reference < Base
      value_column :integer_value

      operators(*%i[eq is_null is_not_null references])

      store_accessor :options, :target_entity_type, :target_scope

      validates :target_entity_type, presence: true
      validate :target_entity_type_resolves
      validate :target_scope_requires_scoped_target

      # Cast contract:
      # - nil / blank → [nil, false]
      # - Integer → [int, false]
      # - numeric String (e.g., "42") → [int, false]
      # - non-numeric String → [nil, true]
      # - AR record matching target_entity_type → [record.id, false]
      # - AR record of a different class → [nil, true] (configured for a
      #   specific target type — rejecting other types catches typos at
      #   write time)
      # - any other shape → [nil, true]
      #
      # Accepts both Integer FKs AND model instances for ergonomic
      # parity with Rails AR association API (`belongs_to :manager;
      # contact.manager = alice` works whether `alice` is a Contact or
      # an id).
      def cast(raw)
        return [nil, false] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

        # CRITICAL: top-level `::Integer` (and `::String` below). Inside
        # `module TypedEAV; module Field`, the bare `Integer` constant
        # resolves to TypedEAV::Field::Integer (a Field subclass), not
        # the Ruby Integer class — so `raw.is_a?(Integer)` would always
        # be false. Same hazard with String. The leading `::` anchors
        # constant lookup to ::Object and avoids the namespace shadow.
        return [raw, false] if raw.is_a?(::Integer)

        if raw.is_a?(::String)
          # Integer(...) with exception: false returns nil for non-numeric
          # input (including decimals like "1.5" — fractional FKs are
          # nonsense). Same rejection pattern as Field::Integer#cast.
          # `Integer(...)` is the Kernel method (not the constant —
          # method-call syntax routes through Kernel#Integer rather
          # than constant lookup, so the TypedEAV::Field::Integer
          # constant shadow that bites `is_a?(::Integer)` above does
          # NOT bite this call form).
          int = Integer(raw, exception: false)
          return [int, false] if int

          return [nil, true]
        end

        # AR record path: must match target_entity_type. Class-mismatch
        # is treated as :invalid at cast time so the error surface lines
        # up with other type-mismatch failures (cast-tuple invalid bit
        # → Value#validate_value → errors.add(:value, :invalid)).
        if raw.respond_to?(:id) && raw.class.respond_to?(:name)
          target_class = resolve_target_class
          return [nil, true] if target_class.nil?
          return [raw.id, false] if raw.is_a?(target_class)

          return [nil, true]
        end

        [nil, true]
      end

      # Value-time validation: when target_scope is set on the field,
      # the target record's typed_eav_scope must match. When target_scope
      # is nil, no cross-scope check fires (the field author is declaring
      # "this reference is to a global/unscoped entity"). When target
      # lookup fails (record was deleted or never existed), errors.add
      # (:value, :invalid) — reuses the existing :invalid symbol from
      # cast-time invalidation for UX consistency.
      def validate_typed_value(record, val)
        return if val.nil?
        return if target_scope.blank?

        target_class = resolve_target_class
        # Field-save validators above already reject the (target_scope
        # set + unscoped target) combination. These guards are defense
        # in depth: if a Reference field somehow exists with a stale
        # target_class reference, fail soft at value save rather than
        # raise NoMethodError on `target_class.nil?` chains.
        return unless target_class
        return unless target_class.respond_to?(:typed_eav_scope_method)
        return unless target_class.typed_eav_scope_method

        target_record = target_class.find_by(id: val)
        if target_record.nil?
          record.errors.add(:value, :invalid)
          return
        end

        return if target_partition_matches?(target_record, target_scope)

        record.errors.add(:value, "target's scope does not match target_scope")
      end

      private

      # Constantizes target_entity_type via safe_constantize so a typo
      # in the option (or a class that's been removed) returns nil
      # rather than raising NameError. The target_entity_type_resolves
      # validator surfaces the nil → invalid path with a specific
      # error message at field save time.
      def resolve_target_class
        return nil if target_entity_type.blank?

        target_entity_type.safe_constantize
      end

      # Structurally parallel to Field::Base#entity_partition_axis_matches?
      # (field/base.rb:654-665) but reads from the field's `target_scope`
      # option rather than a `scope`/`parent_scope` class-attribute axis.
      # Refactoring to a shared base helper is OUT OF SCOPE for Phase 5
      # (existing helper signature is `(entity, axis)` reading via
      # `public_send(axis)` — this helper reads from a different option
      # surface). Future cleanup is a Phase 7 ergonomics pass at most.
      #
      # Type-loose comparison via `.to_s == .to_s` mirrors the Phase 1
      # entity_partition_axis_matches? pattern (field/base.rb:664) — a
      # numeric tenant_id and a String "1" must match correctly,
      # especially after jsonb deserialization which can return either.
      def target_partition_matches?(target_record, expected_scope)
        return true if expected_scope.blank?
        return false unless target_record.respond_to?(:typed_eav_scope)

        actual = target_record.typed_eav_scope
        return false if actual.nil?

        expected_scope.to_s == actual.to_s
      end

      # Field-save validation: target_entity_type must constantize.
      # presence is handled separately via `validates :target_entity_type,
      # presence: true` so this validator only fires when a value is
      # given — avoids "blank AND unresolvable" double error.
      def target_entity_type_resolves
        return if target_entity_type.blank?
        return if resolve_target_class

        errors.add(:target_entity_type,
                   "must be a valid class name (got #{target_entity_type.inspect})")
      end

      # Field-save validation (Gating Decision 2): target_scope SET +
      # target_entity_type unscoped → fail. target_scope nil → no check
      # (the field author is declaring "no cross-scope filtering" — any
      # entity type is acceptable target). The two earlier validators
      # cover the (blank target_entity_type) and (unresolvable
      # target_entity_type) cases; this validator focuses on the
      # scope-vs-no-scope-method axis.
      def target_scope_requires_scoped_target
        return if target_scope.blank?
        return if target_entity_type.blank? # other validators catch this

        target_class = resolve_target_class
        return if target_class.nil? # other validators catch this

        return if target_class.respond_to?(:typed_eav_scope_method) &&
                  target_class.typed_eav_scope_method

        errors.add(:target_scope,
                   "cannot be set when target_entity_type (#{target_entity_type}) " \
                   "is not registered with `has_typed_eav scope_method:`")
      end
    end
  end
end
