# frozen_string_literal: true

module TypedEAV
  module Field
    # Concern (mixin) for field types whose valid values are constrained
    # to an enumeration of `Field::Option` rows.
    #
    # Included by: `Field::Select`, `Field::MultiSelect`. Both leaves stay
    # as direct children of `Field::Base` — Select uses `string_value`,
    # MultiSelect uses `json_value`. Inheritance can't unify storage for
    # both, so we use a concern instead of an intermediate class.
    #
    # Provides:
    #
    # - `optionable?` overridden to `true` (default on `Field::Base` is
    #   `false`).
    # - `allowed_values` — the public-facing, **sorted** option-values
    #   helper. When `field_options` is loaded, sorts in memory by
    #   `[sort_order || 0, label]`; otherwise issues a `sorted.pluck`
    #   query. Matches the per-leaf implementation that was duplicated
    #   verbatim between Select and MultiSelect pre-refactor.
    # - `validate_option_inclusion` / `validate_multi_option_inclusion`
    #   protected helpers (moved from `Field::Base`). Both call into
    #   `allowed_option_values` (the validator-facing fast path that still
    #   lives on `Field::Base`) so they avoid the sort overhead on the hot
    #   validation path.
    #
    # Public extension point: external authors can `include
    # TypedEAV::Field::Optionable` to opt into the option-set surface
    # without joining the Select/MultiSelect inheritance chain (see
    # README §"Custom field types").
    module Optionable
      extend ActiveSupport::Concern

      def optionable? = true

      def allowed_values
        if field_options.loaded?
          field_options.sort_by { |o| [o.sort_order || 0, o.label.to_s] }.map(&:value)
        else
          field_options.sorted.pluck(:value)
        end
      end

      protected

      def validate_option_inclusion(record, val)
        return if allowed_option_values.include?(val&.to_s)

        record.errors.add(:value, :inclusion)
      end

      def validate_multi_option_inclusion(record, val)
        invalid = Array(val).map(&:to_s) - allowed_option_values
        record.errors.add(:value, :inclusion) if invalid.any?
      end
    end
  end
end
