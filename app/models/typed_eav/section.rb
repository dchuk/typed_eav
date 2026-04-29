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
  end
end
