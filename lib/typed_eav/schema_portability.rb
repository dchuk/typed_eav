# frozen_string_literal: true

require_relative "schema_portability/import_index"
require_relative "schema_portability/preview"

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

      # Lean, restore-oriented projection of the field schema for a partition
      # tuple. Sibling to {.export_schema} — same partition filter, narrower
      # per-field surface, no sections, no partition-identity keys.
      #
      # The envelope is:
      #
      #   {
      #     "snapshot_schema_version" => 1,
      #     "fields" => [ <snapshot_field_entry>, ... ]   # ordered by sort_order
      #   }
      #
      # The `snapshot_schema_version` integer will be bumped explicitly when
      # the inner per-field shape evolves in a non-additive way — it is NOT
      # frozen forever. Consumers should branch on the version to handle
      # cross-version snapshots.
      #
      # Each per-field entry is a strict subset of the full
      # {.export_field_entry} shape:
      #
      #   {
      #     "name" => field.name,
      #     "field_type_name" => field.field_type_name,
      #     "required" => field.required,
      #     "sort_order" => field.sort_order,
      #     "options" => field.options,
      #     "options_data" => [...]   # ONLY present when field.optionable?
      #   }
      #
      # Omitted vs the full schema export: `entity_type`, `scope`,
      # `parent_scope`, `type` (the AR STI class name), `field_dependent`,
      # and `default_value_meta`. Non-optionable fields omit `options_data`
      # entirely (absent, not nil, not an empty array).
      #
      # The `field_type_name` value is the documented field-type dispatch
      # identifier — robust to namespace relocations of the field class
      # because it strips the namespace via `demodulize` before
      # `underscore`-ing. It is NOT robust to renames of the leaf class
      # itself: `Field::Select` → `"select"`, but renaming the class to
      # `Field::Status` would change the dispatch identifier to `"status"`.
      #
      # @param entity_type [String] host AR model class name (e.g. "Contact")
      # @param scope [String, nil] first partition axis
      # @param parent_scope [String, nil] second partition axis
      # @return [Hash] versioned snapshot envelope
      def export_snapshot_schema(entity_type:, scope: nil, parent_scope: nil)
        fields = TypedEAV::Field::Base
                 .where(entity_type: entity_type, scope: scope, parent_scope: parent_scope)
                 .includes(:field_options)
                 .order(:sort_order)
                 .map { |field| export_snapshot_field_entry(field) }

        {
          "snapshot_schema_version" => 1,
          "fields" => fields,
        }
      end

      # Compare an exported schema with the exact target partition without
      # invoking the import pipeline. The result is a JSON-safe, read-only
      # snapshot of the definitions currently in the database and the
      # conditional action the requested conflict policy would take.
      #
      # `:error` marks divergent definitions as blocked, `:skip` predicts
      # leaving them unchanged, and `:overwrite` predicts replacement. Type
      # changes are always blocked because the importer refuses unsafe typed
      # value conversions under every policy. Omitted target definitions are
      # intentionally absent from the result: import_schema never deletes
      # them. A preview is advisory and does not lock or reserve the target;
      # custom validations and concurrent changes can still affect a later
      # import. Every field/section entry must also repeat the exact
      # entity_type/scope/parent_scope envelope identity; inconsistent
      # payloads are rejected instead of being silently retargeted.
      def preview_schema(hash, on_conflict: :error)
        TypedEAV::SchemaPortability::Preview.new(hash, on_conflict: on_conflict).call
      end

      def import_schema(hash, on_conflict: :error)
        validate_schema_version!(hash)
        validate_conflict_policy!(on_conflict)

        result = { "created" => 0, "updated" => 0, "skipped" => 0, "unchanged" => 0, "errors" => [] }
        field_entries = Array(hash["fields"])
        section_entries = Array(hash["sections"])

        TypedEAV::Field::Base.transaction do
          import_index = ImportIndex.new(field_entries, section_entries)

          field_entries.each do |entry|
            import_field_entry(entry, on_conflict, result, import_index)
          end

          section_entries.each do |entry|
            import_section_entry(entry, on_conflict, result, import_index)
          end
        end

        result
      end

      private

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- flat projection is the canonical field export shape.
      def export_field_entry(field)
        entry = {
          "name" => field.name,
          "type" => field.type,
          "entity_type" => field.entity_type,
          "scope" => field.scope,
          "parent_scope" => field.parent_scope,
          # Raw label (issue #21) — NOT the resolved display_name. The regular
          # export round-trips the stored value verbatim so import reproduces
          # it exactly and divergence detection (field_export_row_equal?) treats
          # a differing label as a difference. Legacy payloads lack this key →
          # entry["label"] is nil on import → label stays NULL (no version gate).
          "label" => field.label,
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
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Lean per-field projection used by {.export_snapshot_schema}. Mirrors
      # the option-row ordering rule from {.export_field_entry} — sort
      # loaded-association rows by `[sort_order || 0, label, id]`, and
      # delegate to the `field_options.sorted` scope on the unloaded path.
      def export_snapshot_field_entry(field)
        entry = {
          "name" => field.name,
          "field_type_name" => field.field_type_name,
          # RESOLVED display_name (issue #21), NOT the raw label — snapshots are
          # render-oriented (CONTEXT decision 3). This is intentionally
          # asymmetric to the regular export's raw "label": a snapshot consumer
          # gets the ready-to-render string (label when present, else
          # name.humanize) without re-deriving it.
          "display_name" => field.display_name,
          "required" => field.required,
          "sort_order" => field.sort_order,
          "options" => field.options,
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

      def import_field_entry(entry, on_conflict, result, import_index)
        identity = import_index.field_identity(entry)
        existing = import_index.fields[identity]

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
          import_index.fields[identity] = create_field!(entry)
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
          label: entry["label"],
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
        return field unless field.optionable?

        Array(entry["options_data"]).each do |option|
          field.field_options.create!(
            label: option["label"],
            value: option["value"],
            sort_order: option["sort_order"],
          )
        end
        field
      end

      def import_section_entry(entry, on_conflict, result, import_index)
        identity = import_index.section_identity(entry)
        existing = import_index.sections[identity]

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
          import_index.sections[identity] = TypedEAV::Section.create!(entry)
          result["created"] += 1
        end
      end

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
