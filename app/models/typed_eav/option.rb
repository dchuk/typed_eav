# frozen_string_literal: true

module TypedEAV
  class Option < ApplicationRecord
    self.table_name = "typed_eav_options"

    belongs_to :field,
               class_name: "TypedEAV::Field::Base",
               inverse_of: :field_options

    validates :label, presence: true
    validates :value, presence: true, uniqueness: { scope: :field_id }

    scope :sorted, -> { order(sort_order: :asc, label: :asc, id: :asc) }
  end
end
