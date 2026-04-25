# frozen_string_literal: true

module TypedFields
  class Option < ApplicationRecord
    self.table_name = "typed_field_options"

    belongs_to :field,
               class_name: "TypedFields::Field::Base",
               inverse_of: :field_options

    validates :label, presence: true
    validates :value, presence: true, uniqueness: { scope: :field_id }

    scope :sorted, -> { order(sort_order: :asc, label: :asc, id: :asc) }

    after_commit :clear_field_option_cache

    private

    def clear_field_option_cache
      field&.clear_option_cache!
    end
  end
end
