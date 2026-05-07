# frozen_string_literal: true

module TypedEAV
  # Export and import field + section definitions for an exact partition
  # tuple. Value rows are intentionally out of scope.
  module SchemaPortability
    class << self
      def export_schema(entity_type:, scope: nil, parent_scope: nil)
        fields = TypedEAV::Field::Base
                 .where(entity_type: entity_type, scope: scope, parent_scope: parent_scope)
                 .includes(:field_options)
                 .order(:sort_order)
                 .map { |field| export_field_entry(field) }

        sections = TypedEAV::Section
                   .where(entity_type: entity_type, scope: scope, parent_scope: parent_scope)
                   .order(:sort_order)
                   .map { |section| export_section_entry(section) }

        {
          "schema_version" => 1,
          "entity_type" => entity_type,
          "scope" => scope,
          "parent_scope" => parent_scope,
          "fields" => fields,
          "sections" => sections,
        }
      end

      def import_schema(hash, on_conflict: :error)
        validate_schema_version!(hash)
        validate_conflict_policy!(on_conflict)

        result = { "created" => 0, "updated" => 0, "skipped" => 0, "unchanged" => 0, "errors" => [] }

        TypedEAV::Field::Base.transaction do
          Array(hash["fields"]).each do |entry|
            import_field_entry(entry, on_conflict, result)
          end

          Array(hash["sections"]).each do |entry|
            import_section_entry(entry, on_conflict, result)
          end
        end

        result
      end

      private

      # rubocop:disable Metrics/AbcSize -- flat projection is the canonical field export shape.
      def export_field_entry(field)
        entry = {
          "name" => field.name,
          "type" => field.type,
          "entity_type" => field.entity_type,
          "scope" => field.scope,
          "parent_scope" => field.parent_scope,
          "required" => field.required,
          "sort_order" => field.sort_order,
          "field_dependent" => field.field_dependent,
          "options" => field.options,
          "default_value_meta" => field.default_value_meta,
        }

        if field.optionable?
          options_rows = if field.field_options.loaded?
                           field.field_options.sort_by do |option|
                             [option.sort_order || 0, option.label.to_s, option.id]
                           end
                         else
                           field.field_options.sorted
                         end
          entry["options_data"] = options_rows.map do |option|
            { "label" => option.label, "value" => option.value, "sort_order" => option.sort_order }
          end
        end

        entry
      end
      # rubocop:enable Metrics/AbcSize

      def export_section_entry(section)
        {
          "name" => section.name,
          "code" => section.code,
          "entity_type" => section.entity_type,
          "scope" => section.scope,
          "parent_scope" => section.parent_scope,
          "sort_order" => section.sort_order,
          "active" => section.active,
        }
      end

      def validate_schema_version!(hash)
        return if hash["schema_version"] == 1

        raise ArgumentError,
              "Unsupported schema_version: #{hash["schema_version"].inspect}. " \
              "Expected 1. Re-export from a current typed_eav version."
      end

      def validate_conflict_policy!(on_conflict)
        valid_policies = %i[error skip overwrite]
        return if valid_policies.include?(on_conflict)

        raise ArgumentError,
              "Unsupported on_conflict: #{on_conflict.inspect}. " \
              "Supported: #{valid_policies.map { |policy| ":#{policy}" }.join(", ")}."
      end

      def import_field_entry(entry, on_conflict, result)
        existing = TypedEAV::Field::Base.find_by(
          name: entry["name"],
          entity_type: entry["entity_type"],
          scope: entry["scope"],
          parent_scope: entry["parent_scope"],
        )

        if existing
          reject_type_swap!(existing, entry)

          if field_export_row_equal?(existing, entry)
            result["unchanged"] += 1
            return
          end

          case on_conflict
          when :error
            raise_divergent_field!(entry)
          when :skip
            result["skipped"] += 1
          when :overwrite
            overwrite_field!(existing, entry)
            result["updated"] += 1
          end
        else
          create_field!(entry)
          result["created"] += 1
        end
      end

      def reject_type_swap!(existing, entry)
        return if existing.type == entry["type"]

        raise ArgumentError,
              "Cannot change field '#{entry["name"]}' from #{existing.type} to #{entry["type"]}: " \
              "data-loss guard. The gem cannot infer a safe migration of existing typed values " \
              "across *_value columns. Manually destroy and recreate the field if the type change " \
              "is intentional."
      end

      def raise_divergent_field!(entry)
        raise ArgumentError,
              "Field '#{entry["name"]}' already exists for #{entry["entity_type"]} " \
              "(scope=#{entry["scope"].inspect}, parent_scope=#{entry["parent_scope"].inspect}) " \
              "and its attributes diverge from the incoming schema. " \
              "Pass on_conflict: :skip or :overwrite to import over the existing field, " \
              "or re-export from the source environment to confirm the divergence is intentional."
      end

      def overwrite_field!(existing, entry)
        existing.assign_attributes(
          required: entry["required"],
          sort_order: entry["sort_order"],
          field_dependent: entry["field_dependent"],
          options: entry["options"],
        )
        existing.default_value_meta = entry["default_value_meta"]
        existing.save!

        return unless existing.optionable?

        existing.field_options.destroy_all
        Array(entry["options_data"]).each do |option|
          existing.field_options.create!(
            label: option["label"],
            value: option["value"],
            sort_order: option["sort_order"],
          )
        end
      end

      def create_field!(entry)
        field = TypedEAV::Field::Base.create!(entry.except("options_data"))
        return unless field.optionable?

        Array(entry["options_data"]).each do |option|
          field.field_options.create!(
            label: option["label"],
            value: option["value"],
            sort_order: option["sort_order"],
          )
        end
      end

      # rubocop:disable Metrics/MethodLength -- mirrors field import for section rows without option replacement.
      def import_section_entry(entry, on_conflict, result)
        existing = TypedEAV::Section.find_by(
          code: entry["code"],
          entity_type: entry["entity_type"],
          scope: entry["scope"],
          parent_scope: entry["parent_scope"],
        )

        if existing
          if section_export_row_equal?(existing, entry)
            result["unchanged"] += 1
            return
          end

          case on_conflict
          when :error
            raise_divergent_section!(entry)
          when :skip
            result["skipped"] += 1
          when :overwrite
            existing.update!(
              name: entry["name"],
              sort_order: entry["sort_order"],
              active: entry["active"],
            )
            result["updated"] += 1
          end
        else
          TypedEAV::Section.create!(entry)
          result["created"] += 1
        end
      end
      # rubocop:enable Metrics/MethodLength

      def raise_divergent_section!(entry)
        raise ArgumentError,
              "Section '#{entry["code"]}' already exists for #{entry["entity_type"]} " \
              "(scope=#{entry["scope"].inspect}, parent_scope=#{entry["parent_scope"].inspect}) " \
              "and its attributes diverge from the incoming schema. " \
              "Pass on_conflict: :skip or :overwrite to import over the existing section, " \
              "or re-export from the source environment to confirm the divergence is intentional."
      end

      def field_export_row_equal?(existing, incoming)
        export_field_entry(existing) == incoming
      end

      def section_export_row_equal?(existing, incoming)
        export_section_entry(existing) == incoming
      end
    end
  end
end
