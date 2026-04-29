# frozen_string_literal: true

require "timeout"

module TypedEAV
  module Field
    class Base < ApplicationRecord
      self.table_name = "typed_eav_fields"

      include TypedEAV::ColumnMapping

      # ── Associations ──

      belongs_to :section,
                 class_name: "TypedEAV::Section",
                 optional: true,
                 inverse_of: :fields

      has_many :values,
               class_name: "TypedEAV::Value",
               foreign_key: :field_id,
               inverse_of: :field,
               dependent: :destroy

      has_many :field_options,
               class_name: "TypedEAV::Option",
               foreign_key: :field_id,
               inverse_of: :field,
               dependent: :destroy

      # ── Validations ──

      RESERVED_NAMES = %w[id type class created_at updated_at].freeze

      validates :name, presence: true, uniqueness: { scope: %i[entity_type scope parent_scope] }
      validates :name, exclusion: { in: RESERVED_NAMES, message: "is reserved" }
      validates :type, presence: true
      validates :entity_type, presence: true
      validate :validate_default_value
      validate :validate_type_allowed_for_entity
      validate :validate_parent_scope_invariant

      # ── Scopes ──

      # Partition lookup across the three-key tuple `(entity_type, scope,
      # parent_scope)`. Both scope kwargs default to nil and are expanded via
      # `[val, nil].uniq` so a caller asking for "tenant t1, parent p1" also
      # picks up the partial-overlap rows: `(t1, nil)` and `(nil, nil)`.
      #
      # The orphan-parent invariant (`scope.nil? ⇒ parent_scope.nil?`,
      # enforced by `validate_parent_scope_invariant` below and the paired
      # partial unique indexes from the parent_scope migration) lets us write
      # `parent_scope: [parent_scope, nil].uniq` unconditionally — the
      # `(nil, parent_scope)` tuple cannot exist in the table, so widening
      # the IN-list never matches a stray orphan row.
      #
      # Backwards compatibility: single-scope callers `for_entity(et, scope: s)`
      # continue to work with no code change because `parent_scope` defaults
      # to nil and the `[nil, nil].uniq == [nil]` filter selects only rows
      # with parent_scope IS NULL — the only rows a single-scope tenant ever
      # has.
      scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil|
        where(
          entity_type: entity_type,
          scope: [scope, nil].uniq,
          parent_scope: [parent_scope, nil].uniq,
        )
      }

      scope :sorted, -> { order(sort_order: :asc, name: :asc) }
      scope :required_fields, -> { where(required: true) }

      # ── Default value handling ──
      # Stored in default_value_meta as {"v": <raw_value>} so the jsonb
      # column can hold any type's default without an extra typed column.

      def default_value
        cast(default_value_meta["v"]).first
      end

      def default_value=(val)
        default_value_meta["v"] = val
      end

      # ── Type casting ──
      # Returns a tuple: [casted_value, invalid?].
      #
      # - casted_value is the coerced value (or nil when raw is nil/blank)
      # - invalid? is true when raw was non-empty but unparseable for this
      #   type; Value#validate_value uses the flag to surface :invalid
      #   errors (vs :blank for nil-from-nil).
      #
      # Subclasses override to enforce type semantics. Default is an
      # identity pass-through that never flags invalid.
      #
      # Callers that only need the coerced value should use
      # `cast(raw).first`.
      def cast(raw)
        [raw, false]
      end

      # ── Introspection ──

      def field_type_name
        self.class.name.demodulize.underscore
      end

      def array_field?
        false
      end

      def optionable?
        false
      end

      # Allowed option values for select/multi-select validation.
      # When `field_options` is already loaded (eager-load path), read from
      # memory instead of issuing a fresh `pluck` query.
      def allowed_option_values
        if field_options.loaded?
          field_options.map(&:value)
        else
          field_options.pluck(:value)
        end
      end

      # Kept for backward compatibility but now a no-op since we don't cache.
      def clear_option_cache!
        # no-op
      end

      # ── Per-type value validation (polymorphic dispatch from Value) ──
      #
      # Default no-op. Subclasses override to enforce their constraints
      # (length, range, pattern, option inclusion, array size, etc.) and
      # add errors to `record.errors`. Shared helpers below (validate_length,
      # validate_pattern, validate_range, etc.) are available to subclasses.
      def validate_typed_value(record, val)
        # no-op by default
      end

      protected

      def options_hash
        options&.with_indifferent_access || {}
      end

      def validate_length(record, val)
        opts = options_hash
        str = val.to_s
        if opts[:min_length] && str.length < opts[:min_length].to_i
          record.errors.add(:value, :too_short, count: opts[:min_length])
        end
        return unless opts[:max_length] && str.length > opts[:max_length].to_i

        record.errors.add(:value, :too_long, count: opts[:max_length])
      end

      def validate_pattern(record, val)
        opts = options_hash
        pattern = opts[:pattern]
        return if pattern.blank?

        matched = Timeout.timeout(1) { Regexp.new(pattern).match?(val.to_s) }
        record.errors.add(:value, :invalid) unless matched
      rescue RegexpError
        record.errors.add(:value, "has an invalid pattern configured")
      rescue Timeout::Error
        record.errors.add(:value, "pattern validation timed out")
      end

      def validate_range(record, val)
        opts = options_hash
        record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min]) if opts[:min] && val < opts[:min].to_d
        return unless opts[:max] && val > opts[:max].to_d

        record.errors.add(:value, :less_than_or_equal_to, count: opts[:max])
      end

      def validate_date_range(record, val)
        opts = options_hash
        if opts[:min_date]
          min = ::Date.parse(opts[:min_date])
          record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min_date]) if val < min
        end
        if opts[:max_date]
          max = ::Date.parse(opts[:max_date])
          record.errors.add(:value, :less_than_or_equal_to, count: opts[:max_date]) if val > max
        end
      rescue ::Date::Error
        record.errors.add(:base, "field has invalid date configuration")
      end

      def validate_datetime_range(record, val)
        opts = options_hash
        if opts[:min_datetime]
          min = ::Time.zone.parse(opts[:min_datetime])
          record.errors.add(:value, :greater_than_or_equal_to, count: opts[:min_datetime]) if val < min
        end
        if opts[:max_datetime]
          max = ::Time.zone.parse(opts[:max_datetime])
          record.errors.add(:value, :less_than_or_equal_to, count: opts[:max_datetime]) if val > max
        end
      rescue ArgumentError
        record.errors.add(:base, "field has invalid datetime configuration")
      end

      def validate_option_inclusion(record, val)
        return if allowed_option_values.include?(val&.to_s)

        record.errors.add(:value, :inclusion)
      end

      def validate_multi_option_inclusion(record, val)
        invalid = Array(val).map(&:to_s) - allowed_option_values
        record.errors.add(:value, :inclusion) if invalid.any?
      end

      def validate_array_size(record, val)
        opts = options_hash
        arr = Array(val)
        if opts[:min_size] && arr.size < opts[:min_size].to_i
          record.errors.add(:value, :too_short, count: opts[:min_size])
        end
        return unless opts[:max_size] && arr.size > opts[:max_size].to_i

        record.errors.add(:value, :too_long, count: opts[:max_size])
      end

      private

      def validate_default_value
        return if default_value_meta.blank? || !default_value_meta.key?("v")

        raw = default_value_meta["v"]
        return if raw.nil?

        _, invalid = cast(raw)
        errors.add(:default_value, "is not valid for this field type") if invalid
      end

      # Enforces type restrictions set via `has_typed_eav types: [...]`.
      # Skips if the entity type isn't registered (e.g., in console before
      # models are loaded) — this is intentional fail-open behavior since
      # unregistered entity types have no restrictions to enforce.
      def validate_type_allowed_for_entity
        return unless entity_type.present? && type.present?
        return unless TypedEAV.registry.entity_types.include?(entity_type)
        return if TypedEAV.registry.type_allowed?(entity_type, self.class)

        errors.add(:type, "#{field_type_name} is not allowed for #{entity_type}")
      end

      # Orphan-parent invariant: when `scope` is nil (global field),
      # `parent_scope` MUST also be nil. A "global parent_scope" makes no
      # semantic sense — a field that's global across tenants cannot be
      # partitioned within one tenant.
      #
      # Without this, the paired-partial unique indexes from the
      # parent_scope migration would silently allow `(scope=nil,
      # parent_scope='p1')` rows: the global partial (`scope IS NULL`)
      # omits parent_scope from its column list and the scoped partials
      # only fire when `scope IS NOT NULL`. The model-level check is the
      # canonical guard — once enforced, the Value-side
      # `validate_field_scope_matches_entity` (plan 05) never has to
      # handle an orphan-field case.
      #
      # `blank?` rather than `nil?` rejects empty-string `parent_scope`
      # too, which would otherwise slip past a `.nil?` check and produce
      # the same incoherent state as a literal NULL. Same reasoning for
      # `scope.present?`.
      def validate_parent_scope_invariant
        return if parent_scope.blank?
        return if scope.present?

        errors.add(:parent_scope, "cannot be set when scope is blank")
      end
    end
  end
end
