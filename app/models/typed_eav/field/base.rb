# frozen_string_literal: true

require "timeout"

module TypedEAV
  module Field
    # rubocop:disable Metrics/ClassLength -- Field::Base is the central STI parent: associations,
    # validations, cascade dispatch, partition-aware ordering helpers, default-value handling,
    # and the partition-aware backfill all live here together because they share the (entity_type,
    # scope, parent_scope) partition contract. Splitting into concerns would scatter that contract
    # and obscure the cross-cutting invariants the validators and helpers enforce together.
    class Base < ApplicationRecord
      self.table_name = "typed_eav_fields"

      include TypedEAV::ColumnMapping

      # ── Associations ──

      belongs_to :section,
                 class_name: "TypedEAV::Section",
                 optional: true,
                 inverse_of: :fields

      # No `dependent: :destroy` here: cascade behavior is now driven by the
      # `field_dependent` column and dispatched in the `before_destroy`
      # callback below. Keeping `dependent: :destroy` would double-fire for
      # the "destroy" policy and short-circuit the `:nullify` /
      # `:restrict_with_error` policies entirely.
      has_many :values,
               class_name: "TypedEAV::Value",
               foreign_key: :field_id,
               inverse_of: :field

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

      # Cascade policy for Value rows when this Field is destroyed. Stored as
      # a string (not enum) so future policies don't require an additive enum
      # remap. Default "destroy" matches v0.1.0 behavior — see Phase 02
      # CONTEXT §"Cascade behavior wiring + schema delivery".
      validates :field_dependent, inclusion: {
        in: %w[destroy nullify restrict_with_error],
        message: "must be one of: destroy, nullify, restrict_with_error",
      }

      # ── Callbacks ──

      # Dispatch on `field_dependent`. Runs BEFORE the field row is deleted so
      # the "destroy" policy can clean up Value rows while the FK still points
      # somewhere valid. With the FK on ON DELETE SET NULL (post-Phase-02
      # migration), the AR-level `destroy_all` is the canonical mechanism for
      # "destroy" — without it, the FK would NULL the rows out instead and
      # leave orphans behind. The "nullify" branch is intentionally a no-op:
      # the FK does the work. The "restrict_with_error" branch adds an error
      # and `throw(:abort)`s, mirroring AR's `dependent: :restrict_with_error`.
      before_destroy :dispatch_field_dependent

      # Phase 03 event dispatch. SINGLE callback (no `on:` filter) that
      # branches across the four change_types in `_dispatch_field_change`.
      # Three reasons for one-callback-with-branch over the three-callback-
      # with-on:-filter form used on Value:
      #
      #   1. :rename is a sub-case of :update (it requires
      #      `saved_change_to_attribute?(:name)` which is only meaningful
      #      in the update lifecycle). Splitting :rename and :update across
      #      two declarations duplicates the branch logic.
      #   2. :create / :destroy / :update / :rename are mutually exclusive
      #      per save — `created? && destroyed?` cannot both be true — so
      #      a single if/elsif chain expresses the contract directly.
      #   3. STI: this declaration on Field::Base fires for every subclass
      #      instance (Text, Integer, Select, MultiSelect, IntegerArray,
      #      etc.). One callback covers them all without per-subclass
      #      duplication.
      #
      # Note: this is NOT the alias-collision form — `after_commit :method`
      # (no `on:`) is one callback, one method, no aliasing. The Rails 8.1
      # alias-collision bug only bites when the convenience alias forms
      # (after_create_commit / after_update_commit / after_destroy_commit)
      # are reused with the same method name.
      after_commit :_dispatch_field_change

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

      # ── Display ordering ──
      #
      # Partition-aware ordering helpers, keyed by (entity_type, scope,
      # parent_scope). Names mirror acts_as_list for muscle memory; the
      # implementation is in-house per CONVENTIONS.md "one hard dep, soft-detect
      # everything else" — adopting acts_as_list as a runtime dep would force
      # every consumer to pull it in.
      #
      # Race semantics: each operation runs inside an AR transaction and
      # acquires a partition-level row lock via
      # `for_entity(...).order(:id).lock("FOR UPDATE")`. This issues
      # SELECT ... FOR UPDATE on every member of the partition (including
      # self) in deterministic ID order — concurrent reorders within the same
      # partition serialize on the lock acquisition, and the deterministic
      # order prevents deadlocks across threads. Cross-partition operations
      # never block each other because they lock disjoint row sets.
      #
      # Why a partition-level lock (not with_lock on self): two threads
      # moving DIFFERENT records within the SAME partition would both pass a
      # per-record lock on self and race on the sibling list / normalization.
      # The partition-level FOR UPDATE is the only correct serialization
      # boundary.
      #
      # Sort-order semantics: every operation normalizes the partition's
      # sort_order column to consecutive integers 1..N (no gaps) on completion.
      # Records with sort_order: nil are positioned after all positioned rows
      # during normalization (Postgres NULLS LAST).
      #
      # Boundary moves are no-ops, not errors. move_higher on the top item
      # returns without raising; move_lower on the bottom item likewise.

      def move_higher
        reorder_within_partition do |siblings|
          idx = siblings.index { |r| r.id == id }
          next siblings if idx.nil? || idx.zero? # already at top, or not in partition

          siblings[idx], siblings[idx - 1] = siblings[idx - 1], siblings[idx]
          siblings
        end
      end

      def move_lower
        reorder_within_partition do |siblings|
          idx = siblings.index { |r| r.id == id }
          next siblings if idx.nil? || idx == siblings.size - 1 # already at bottom

          siblings[idx], siblings[idx + 1] = siblings[idx + 1], siblings[idx]
          siblings
        end
      end

      def move_to_top
        reorder_within_partition do |siblings|
          idx = siblings.index { |r| r.id == id }
          next siblings if idx.nil? || idx.zero?

          moving = siblings.delete_at(idx)
          siblings.unshift(moving)
          siblings
        end
      end

      def move_to_bottom
        reorder_within_partition do |siblings|
          idx = siblings.index { |r| r.id == id }
          next siblings if idx.nil? || idx == siblings.size - 1

          moving = siblings.delete_at(idx)
          siblings.push(moving)
          siblings
        end
      end

      # Insert at 1-based position. Clamps position to [1, partition_count]:
      # insert_at(0) and any non-positive value behaves as move_to_top;
      # insert_at(999) on a 5-item partition behaves as move_to_bottom.
      # Mirrors acts_as_list's clamp behavior.
      def insert_at(position)
        reorder_within_partition do |siblings|
          idx = siblings.index { |r| r.id == id }
          next siblings if idx.nil?

          target = position.clamp(1, siblings.size) - 1
          next siblings if idx == target

          moving = siblings.delete_at(idx)
          siblings.insert(target, moving)
          siblings
        end
      end

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

      # ── Phase 05 multi-cell extension points ──
      #
      # These three instance methods are the field-side surface that resolves
      # Value#value semantics, the write path, and the default-application
      # path. Single-cell field types (every built-in as of Phase 04) inherit
      # the defaults below and behave identically to the pre-Phase-05 direct-
      # column-access shape.
      #
      # Multi-cell field types (Phase 05: Currency stores `{amount, currency}`
      # across decimal_value + string_value) override these to compose /
      # unpack the logical value across multiple physical columns. The
      # dispatch keeps Value#value, Value#value=, and Value#apply_field_default
      # oblivious to multi-cell — they always go through the field, so adding
      # new multi-cell types in the future requires no Value-side changes.
      #
      # IMPORTANT: read_value, write_value, and apply_default_to are paired.
      # Currency overrides ALL THREE — overriding only one creates an
      # asymmetry where reads see the multi-cell shape but writes / defaults
      # populate only one column (or vice versa).

      # Returns the logical value for this field as stored on the given
      # Value record. Default reads `value_record[self.class.value_column]`.
      # Override in multi-cell field types to compose a hash from multiple
      # columns (e.g., Field::Currency returns
      # `{amount: r[:decimal_value], currency: r[:string_value]}`).
      #
      # Called from Value#value. The Value#value `return nil unless field`
      # guard runs before this method, so `self` is always set.
      def read_value(value_record)
        value_record[self.class.value_column]
      end

      # Writes a casted value to the given Value record. Default writes
      # `value_record[self.class.value_column] = casted`. Override in multi-
      # cell types to unpack a composite casted value into multiple columns
      # (e.g., Field::Currency unpacks `{amount: BigDecimal, currency: String}`
      # into decimal_value + string_value).
      #
      # Called from Value#value=. The cast invariant is preserved: `casted`
      # is whatever the field's `cast(raw)` returned as the first element.
      # For single-cell types that's a scalar; for Currency it's a Hash.
      # Without this dispatch, a Currency cast result (a Hash) would be
      # written to a single typed column, raising TypeMismatch at save time.
      def write_value(value_record, casted)
        value_record[self.class.value_column] = casted
      end

      # Writes this field's configured default to the given Value record.
      # Default writes `value_record[self.class.value_column] = default_value`,
      # bypassing Value#value= to avoid re-casting an already-cast default
      # (default_value is cast at field save time via validate_default_value).
      # Override in multi-cell types to populate multiple columns from a
      # composite default (e.g., Field::Currency unpacks `default_value`'s
      # `{amount: ..., currency: ...}` hash into decimal_value + string_value).
      #
      # Called from Value#apply_field_default in two contexts:
      #   1. Initial value assignment when no `value:` kwarg was passed
      #      (UNSET_VALUE sentinel resolution path).
      #   2. Pending-value resolution (apply_pending_value branch where
      #      @pending_value was UNSET_VALUE and the field arrived later).
      def apply_default_to(value_record)
        value_record[self.class.value_column] = default_value
      end

      # ── Introspection ──

      def storage_contract
        @storage_contract ||= TypedEAV::FieldStorageContract.new(self)
      end

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

      # ── Backfill ──

      # Backfills existing entities with this field's configured default value.
      # Iterates entities of `entity_type` in batches of 1000 via
      # `find_in_batches`, filtering each batch member by the field's
      # (scope, parent_scope) partition. Each WHOLE batch runs inside one
      # transaction so:
      #  - a long-running backfill can be interrupted and resumed (each
      #    completed batch is committed; the caller re-runs to pick up where
      #    they stopped — the skip rule re-checks each batch member),
      #  - per-batch transaction overhead is bounded: at 1M entities × 1000
      #    per batch, this is ~1000 transactions, not 1M.
      #
      # Skip rule (per-record, applied INSIDE the batch loop): skip when the
      # entity already has a non-nil typed value for this field. A Value row
      # whose typed column is nil is still a candidate for backfill — the
      # skip rule is "non-nil typed column," not "Value row exists" (matches
      # CONTEXT.md).
      #
      # Partition match: when field.scope is non-nil, the entity must respond
      # to typed_eav_scope and the value must match field.scope (as String).
      # When field.parent_scope is non-nil, same check for typed_eav_parent_scope.
      # When field.scope is nil (global field), no scope filter — iterate all
      # entities of entity_type.
      #
      # Why find_in_batches (not find_each): we need the batch as a unit so
      # the transaction boundary aligns with the batch boundary. find_each
      # yields records one-at-a-time, which would either force per-record
      # transactions (wrong — burns overhead, contradicts CONTEXT.md) or
      # require us to buffer batches manually outside AR's batching logic.
      #
      # Why explicit `value: default_value` (not the UNSET_VALUE sentinel):
      # backfill knows the default, so passing it explicitly bypasses the
      # sentinel resolution path on Value#value=. Explicit `value: x`
      # continues to store x in both pre-sentinel and post-sentinel code,
      # which keeps backfill BC-safe regardless of plan ordering.
      #
      # Synchronous by default. For async dispatch, define your own job:
      #
      #   class BackfillJob < ApplicationJob
      #     def perform(field_id) = TypedEAV::Field::Base.find(field_id).backfill_default!
      #   end
      #   BackfillJob.perform_later(field.id)
      #
      # (Documented inline as RDoc; not built-in to keep the gem dep-free.)
      def backfill_default!
        # Short-circuit: nothing to backfill if no default configured. We
        # explicitly do NOT write nil rows — backfill is for propagating a
        # configured default, not for materializing empty Value rows.
        return if default_value.nil?

        entity_class = entity_type.constantize
        column = self.class.value_column

        entity_class.find_in_batches(batch_size: 1000) do |batch|
          # One transaction per batch (NOT per record). If the transaction
          # raises mid-batch, the WHOLE batch rolls back and the exception
          # surfaces; prior batches stay committed. Caller re-runs idempotently
          # because the per-record skip rule re-checks each entity.
          ActiveRecord::Base.transaction(requires_new: true) do
            batch.each do |entity|
              next unless partition_matches?(entity)

              backfill_one(entity, column)
            end
          end
        end
      end

      # ── Schema export / import ──

      # Backward-compatible public entry point. Implementation lives in
      # SchemaPortability so Field::Base does not carry schema projection,
      # conflict policy, option replacement, and section import details.
      def self.export_schema(entity_type:, scope: nil, parent_scope: nil)
        TypedEAV::SchemaPortability.export_schema(
          entity_type: entity_type,
          scope: scope,
          parent_scope: parent_scope,
        )
      end

      # Backward-compatible public entry point. Implementation lives in
      # SchemaPortability; this delegator preserves existing callers.
      def self.import_schema(hash, on_conflict: :error)
        TypedEAV::SchemaPortability.import_schema(hash, on_conflict: on_conflict)
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

      # before_destroy hook. Reads the `field_dependent` policy column and
      # acts before the field row is deleted (and before the FK ON DELETE SET
      # NULL fires). The three branches are exhaustive because the
      # `field_dependent` inclusion validator narrows to exactly these
      # values; an unrecognized value would have failed save earlier and
      # cannot reach destroy.
      def dispatch_field_dependent
        case field_dependent
        when "destroy"
          # Explicit `destroy_all`: with ON DELETE SET NULL on the FK, the
          # database would otherwise NULL field_id out instead of deleting
          # the rows. AR callbacks run inside the destroy transaction, so
          # this is atomic with the field row deletion.
          values.destroy_all
        when "nullify"
          # No-op: the FK ON DELETE SET NULL nulls field_id automatically.
          # Read-path orphan guards in `InstanceMethods#typed_eav_value` and
          # `#typed_eav_hash` silently skip these rows — the documented
          # fail-soft path (see PATTERNS.md §"Defend the read path").
        when "restrict_with_error"
          return unless values.exists?

          # Errors tell you how to fix it (CONVENTIONS.md): list the two
          # recovery paths — change the policy or remove the values first.
          errors.add(
            :base,
            "Cannot delete field that has values. Use field_dependent: :nullify or destroy values first.",
          )
          throw(:abort)
        end
      end

      # Wraps a block in: (1) an AR transaction, (2) a partition-level row
      # lock acquired via `for_entity(...).order(:id).lock("FOR UPDATE")`,
      # (3) re-ordering of the locked array by sort_order ASC NULLS LAST then
      # name ASC (the canonical display order), (4) the caller's mutation of
      # the resulting siblings array, (5) normalization back to 1..N.
      #
      # The :id ordering of the lock acquisition is load-bearing — without it,
      # two threads acquiring locks on the same partition could deadlock on
      # different acquisition orders. Postgres documents `FOR UPDATE` ordering
      # as the canonical deadlock-avoidance technique.
      #
      # Yielding the siblings array (already locked) to the caller lets each
      # move helper express its mutation declaratively while sharing the
      # locking + normalization scaffold.
      def reorder_within_partition
        self.class.transaction do
          locked = self.class
                       .for_entity(entity_type, scope: scope, parent_scope: parent_scope)
                       .order(:id)
                       .lock("FOR UPDATE")
                       .to_a

          # Sort the locked snapshot into display order (the lock was acquired
          # in :id order for deadlock safety; we reorder in memory for the
          # mutation step).
          siblings = locked.sort_by { |r| [r.sort_order.nil? ? 1 : 0, r.sort_order || 0, r.name.to_s] }

          siblings = yield(siblings)
          normalize_partition_sort_order(siblings)
        end
      end

      # Normalizes the partition to consecutive integers 1..N. Issues one
      # UPDATE per row whose sort_order changed (the in-memory comparison
      # avoids no-op writes). Runs inside the caller's transaction.
      def normalize_partition_sort_order(siblings)
        siblings.each_with_index do |record, index|
          desired = index + 1
          next if record.sort_order == desired

          record.update_columns(sort_order: desired) # rubocop:disable Rails/SkipsModelValidations -- intentional: this is partition normalization, not a user-facing edit; validations don't apply to sort_order shuffling.
        end
      end

      # Partition-match check used by backfill_default!. Skips entities whose
      # scope axis disagrees with the field's. The check is symmetric to the
      # Value#validate_field_scope_matches_entity validator (which guards the
      # write path) — backfill must not write Values that the validator would
      # reject.
      def partition_matches?(entity)
        return false unless entity_partition_axis_matches?(entity, :scope)
        return false unless entity_partition_axis_matches?(entity, :parent_scope)

        true
      end

      # Per-axis matcher. `axis` is :scope or :parent_scope. When the field's
      # value on that axis is blank (global on this axis), every entity
      # matches. Otherwise the entity must respond to the corresponding
      # `typed_eav_<axis>` reader (defined by has_typed_eav InstanceMethods),
      # have a non-nil value there, and that value (stringified) must equal
      # the field's value (stringified). Stringification mirrors the
      # `&.to_s` normalization in InstanceMethods#typed_eav_scope /
      # #typed_eav_parent_scope so a numeric tenant_id and a String "1"
      # match correctly.
      def entity_partition_axis_matches?(entity, axis)
        field_axis_value = public_send(axis) # field.scope or field.parent_scope
        return true if field_axis_value.blank? # global on this axis: any entity matches

        reader_method = :"typed_eav_#{axis}"
        return false unless entity.respond_to?(reader_method)

        entity_value = entity.public_send(reader_method)
        return false if entity_value.nil?

        field_axis_value.to_s == entity_value.to_s
      end

      # Backfills a single entity. Existing-row detection uses
      # WHERE field_id = id (not the AR `field:` association) so the lookup
      # works even when the Value row was written before this Field instance
      # was loaded. The Value-side uniqueness validator on (entity_type,
      # entity_id, field_id) guarantees at most one row per (entity, field).
      #
      # Three states:
      #  - no row → create with explicit `value: default_value`. Passing
      #    `value:` explicitly bypasses the UNSET_VALUE sentinel path on
      #    Value#initialize (backfill knows the default; no need to re-
      #    resolve via the sentinel).
      #  - row exists with nil typed column → update to default. This is the
      #    case the skip rule deliberately allows backfill to fix (a Value
      #    row created via explicit `value: nil` is still a backfill
      #    candidate per CONTEXT.md).
      #  - row exists with non-nil typed column → skip (idempotence).
      def backfill_one(entity, column)
        existing = TypedEAV::Value.where(entity: entity, field_id: id).first

        if existing.nil?
          TypedEAV::Value.create!(entity: entity, field: self, value: default_value)
        elsif existing[column].nil?
          existing.update!(value: default_value)
        end
        # else: row exists with non-nil typed column → skip (skip rule).
      end

      # ── Phase 03 event dispatch ──
      #
      # Branches the four change_types via lifecycle predicates in the order
      # locked by 03-CONTEXT.md §"`on_field_change` change_type set" → "Mechanism":
      #
      #   previously_new_record? → :create
      #   destroyed?             → :destroy
      #   saved_change_to_attribute?(:name) → :rename
      #   else                   → :update
      #
      # The four predicates are mutually exclusive per save
      # (`previously_new_record?` and `destroyed?` cannot both be true;
      # rename/update only reachable when neither create nor destroy fired),
      # so the ordering is behaviorally equivalent to any other ordering —
      # but matching CONTEXT.md verbatim keeps the code grep-able against
      # the locked decision and avoids the next reader wondering whether
      # the order was intentional or accidental.
      #
      # `previously_new_record?` is the documented Rails AR predicate that
      # answers "was this row newly inserted in the just-committed save?"
      # (true after a successful create-commit, false after update/destroy).
      # The plan referenced `created?` as a "Rails 6.1+ alias" but that
      # alias does NOT exist on ActiveRecord records on the pinned
      # activerecord 8.1.3 (NoMethodError verified via dummy app probe in
      # plan 03-02 P02 — see SUMMARY deviations). `id_previously_changed?`
      # works incidentally (PK goes nil→assigned during INSERT) but is
      # less intent-revealing. `previously_new_record?` is the correct
      # documented form for this lifecycle-state question.
      #
      # Rename detection is structural: any save where the :name column changed
      # counts as a rename, even if combined with other attribute changes
      # (sort_order, options, default_value, field_dependent). This false-
      # positive bias is intentional — Phase 07's matview must regenerate
      # column DDL on rename; missing a rename combined with other edits would
      # corrupt the matview's column-name → field-name map.
      #
      # `:name` is the only attribute name we hardcode in this callback, and
      # it's structural (the locked rename-detection mechanism per 03-CONTEXT.md),
      # not a data access — we don't read the value of `name`, only that it
      # changed.
      def _dispatch_field_change
        change_type = if previously_new_record?
                        :create
                      elsif destroyed?
                        :destroy
                      elsif saved_change_to_attribute?(:name)
                        :rename
                      else
                        :update
                      end
        TypedEAV::EventDispatcher.dispatch_field_change(self, change_type)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
