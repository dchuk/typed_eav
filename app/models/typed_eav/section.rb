# frozen_string_literal: true

module TypedEAV
  class Section < ApplicationRecord
    self.table_name = "typed_eav_sections"

    has_many :fields,
             class_name: "TypedEAV::Field::Base",
             inverse_of: :section,
             dependent: :nullify

    validates :name, presence: true
    validates :code, presence: true, uniqueness: { scope: %i[entity_type scope parent_scope] }
    validates :entity_type, presence: true
    validate :validate_parent_scope_invariant

    scope :active, -> { where(active: true) }
    # Mirror Field::Base.for_entity: scoped rows plus global (scope=NULL) rows
    # so global sections are visible across partitions while scoped sections
    # stay isolated. Pass the section's scope key as a string. The
    # `parent_scope` axis expands the same way: callers passing
    # `parent_scope:` get rows matching that parent_scope plus parent-scope
    # globals (parent_scope IS NULL), keeping the symmetric set semantics
    # across both partition keys.
    scope :for_entity, lambda { |entity_type, scope: nil, parent_scope: nil|
      where(
        entity_type: entity_type,
        scope: [scope, nil].uniq,
        parent_scope: [parent_scope, nil].uniq,
      )
    }
    scope :sorted, -> { order(sort_order: :asc, name: :asc) }

    # ── Display ordering ──
    #
    # Mirrors Field::Base ordering helpers byte-for-byte (per CONTEXT.md
    # inline-duplication decision; see Phase 01 validate_parent_scope_invariant
    # precedent). Keep the two implementations symmetric — when one changes,
    # the other should change in the same commit. See field/base.rb for
    # rationale comments on the partition-level FOR UPDATE locking strategy.

    def move_higher
      reorder_within_partition do |siblings|
        idx = siblings.index { |r| r.id == id }
        next siblings if idx.nil? || idx.zero?

        siblings[idx], siblings[idx - 1] = siblings[idx - 1], siblings[idx]
        siblings
      end
    end

    def move_lower
      reorder_within_partition do |siblings|
        idx = siblings.index { |r| r.id == id }
        next siblings if idx.nil? || idx == siblings.size - 1

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

    private

    # Orphan-parent invariant: a section with `scope` blank cannot have a
    # `parent_scope` set. Mirrors Field::Base#validate_parent_scope_invariant —
    # CONTEXT.md decision: inline-duplicate across the two files (not a shared
    # concern this phase) so each file is self-contained.
    def validate_parent_scope_invariant
      return if parent_scope.blank?
      return if scope.present?

      errors.add(:parent_scope, "cannot be set when scope is blank")
    end

    def reorder_within_partition
      self.class.transaction do
        locked = self.class
                     .for_entity(entity_type, scope: scope, parent_scope: parent_scope)
                     .order(:id)
                     .lock("FOR UPDATE")
                     .to_a

        siblings = locked.sort_by { |r| [r.sort_order.nil? ? 1 : 0, r.sort_order || 0, r.name.to_s] }

        siblings = yield(siblings)
        normalize_partition_sort_order(siblings)
      end
    end

    def normalize_partition_sort_order(siblings)
      siblings.each_with_index do |record, index|
        desired = index + 1
        next if record.sort_order == desired

        record.update_columns(sort_order: desired) # rubocop:disable Rails/SkipsModelValidations -- intentional: this is partition normalization, not a user-facing edit; validations don't apply to sort_order shuffling.
      end
    end
  end
end
