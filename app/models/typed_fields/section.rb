# frozen_string_literal: true

module TypedFields
  class Section < ApplicationRecord
    self.table_name = "typed_field_sections"

    has_many :fields,
             class_name: "TypedFields::Field::Base",
             inverse_of: :section,
             dependent: :nullify

    validates :name, presence: true
    validates :code, presence: true, uniqueness: { scope: %i[entity_type scope] }
    validates :entity_type, presence: true

    scope :active, -> { where(active: true) }
    # Mirror Field::Base.for_entity: scoped rows plus global (scope=NULL) rows
    # so global sections are visible across partitions while scoped sections
    # stay isolated. Pass the section's scope key as a string.
    scope :for_entity, lambda { |entity_type, scope: nil|
      where(entity_type: entity_type, scope: [scope, nil].uniq)
    }
    scope :sorted, -> { order(sort_order: :asc, name: :asc) }
  end
end
