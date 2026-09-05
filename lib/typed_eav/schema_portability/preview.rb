# frozen_string_literal: true

module TypedEAV
  module SchemaPortability
    # Read-only comparator for the portable schema wire format. This class is
    # intentionally separate from import_schema: a preview must not run
    # validations, callbacks, jobs, conversions, or a dry-run transaction.
    # Each incoming entry must carry the exact entity_type/scope/parent_scope
    # identity declared by the envelope; preview does not retarget entries.
    # rubocop:disable Metrics/ClassLength -- the validator and comparator form
    # one small, private implementation behind the single preview API.
    class Preview
      FIELD_IDENTITY_KEYS = %w[name entity_type scope parent_scope].freeze
      SECTION_IDENTITY_KEYS = %w[code entity_type scope parent_scope].freeze
      OPTION_KEYS = %w[label value sort_order].freeze
      CONFLICT_STATUSES = %w[changed conflict].freeze
      def initialize(hash, on_conflict:)
        @hash = hash
        @on_conflict = on_conflict
      end

      def call
        validate_input!

        fields = @hash["fields"]
        sections = @hash["sections"]
        import_index = ImportIndex.new(fields, sections)
        field_previews = preview_fields(fields, import_index)
        section_previews = preview_sections(sections, import_index)
        entries = field_previews + section_previews

        {
          "schema_version" => @hash["schema_version"],
          "entity_type" => @hash["entity_type"],
          "scope" => @hash["scope"],
          "parent_scope" => @hash["parent_scope"],
          "on_conflict" => @on_conflict.to_s,
          "importable" => entries.none? { |entry| entry["action"] == "error" },
          "summary" => summary_for(entries),
          "fields" => field_previews,
          "sections" => section_previews,
          "risks" => entries.flat_map { |entry| entry["risks"] }.uniq.sort,
        }
      end

      private

      def validate_input!
        raise ArgumentError, "schema preview expects a Hash export" unless @hash.is_a?(Hash)

        SchemaPortability.send(:validate_schema_version!, @hash)
        SchemaPortability.send(:validate_conflict_policy!, @on_conflict)

        required_keys = %w[entity_type scope parent_scope fields sections]
        missing_keys = required_keys.reject { |key| @hash.key?(key) }
        unless missing_keys.empty?
          raise ArgumentError, "Schema preview is missing required keys: #{missing_keys.join(", ")}"
        end

        validate_target!
        validate_entries!(@hash["fields"], FIELD_IDENTITY_KEYS, "field") do |entry|
          validate_field_entry!(entry)
        end
        validate_entries!(@hash["sections"], SECTION_IDENTITY_KEYS, "section") do |entry|
          validate_section_entry!(entry)
        end
      end

      def validate_target!
        unless @hash["entity_type"].is_a?(String) && @hash["entity_type"].present?
          raise ArgumentError, "Schema preview entity_type must be a non-empty String"
        end

        validate_scope_slot!(@hash["scope"], "scope")
        validate_scope_slot!(@hash["parent_scope"], "parent_scope")
        return if TypedEAV::ScopeTuple.invariant_satisfied?(@hash["scope"], @hash["parent_scope"])

        raise ArgumentError, "Schema preview target parent_scope requires a non-blank scope"
      end

      def validate_scope_slot!(value, name)
        return if value.nil? || value.is_a?(String)

        raise ArgumentError, "Schema preview #{name} must be a String or nil"
      end

      def validate_entries!(entries, identity_keys, kind)
        raise ArgumentError, "Schema preview #{kind}s must be an Array" unless entries.is_a?(Array)

        seen = {}
        entries.each do |entry|
          validate_entry_identity!(entry, identity_keys, kind, seen)
          yield(entry) if block_given?
        end
      end

      def validate_entry_identity!(entry, identity_keys, kind, seen)
        raise ArgumentError, "Schema preview #{kind} entries must be Hashes" unless entry.is_a?(Hash)

        validate_identity_keys!(entry, identity_keys, kind)
        validate_identity_values!(entry, identity_keys, kind)
        identity = entry.values_at(*identity_keys)
        raise ArgumentError, "Duplicate #{kind} identity in schema preview: #{identity.inspect}" if seen.key?(identity)

        seen[identity] = true
      end

      def validate_identity_keys!(entry, identity_keys, kind)
        missing_keys = identity_keys.reject { |key| entry.key?(key) }
        return if missing_keys.empty?

        raise ArgumentError,
              "Schema preview #{kind} entry is missing identity keys: #{missing_keys.join(", ")}"
      end

      def validate_identity_values!(entry, identity_keys, kind)
        name_key = identity_keys.first
        unless entry[name_key].is_a?(String) && entry[name_key].present?
          raise ArgumentError, "Schema preview #{kind} #{name_key} must be a non-empty String"
        end
        return if entry.values_at("entity_type", "scope", "parent_scope") ==
                  @hash.values_at("entity_type", "scope", "parent_scope") &&
                  TypedEAV::ScopeTuple.invariant_satisfied?(entry["scope"], entry["parent_scope"])

        raise ArgumentError,
              "Schema preview #{kind} entry #{entry[name_key].inspect} identity must match " \
              "the declared entity_type/scope/parent_scope target"
      end

      def validate_field_entry!(entry)
        validate_field_type!(entry)
        validate_option_rows!(entry) if entry.key?("options_data")
      end

      def validate_section_entry!(entry)
        return if entry["name"].is_a?(String) && entry["name"].present?

        raise ArgumentError, "Schema preview section #{entry["code"].inspect} name must be a non-empty String"
      end

      def validate_field_type!(entry)
        type = entry["type"]
        unless type.is_a?(String) && type.present?
          raise ArgumentError, "Schema preview field #{entry["name"].inspect} type must be a non-empty String"
        end

        type_class = type.safe_constantize
        return if type_class.is_a?(Class) && type_class <= TypedEAV::Field::Base

        raise ArgumentError,
              "Schema preview field #{entry["name"].inspect} type #{type.inspect} " \
              "must be a TypedEAV::Field::Base subclass"
      end

      def validate_option_rows!(entry)
        options = entry["options_data"]
        unless options.is_a?(Array)
          raise ArgumentError,
                "Schema preview field #{entry["name"].inspect} options_data must be an Array"
        end

        seen_values = {}
        options.each do |option|
          validate_option_row!(entry, option)

          value = option["value"]
          if seen_values.key?(value)
            raise ArgumentError,
                  "Duplicate option value #{value.inspect} for field #{entry["name"].inspect} in schema preview"
          end

          seen_values[value] = true
        end
      end

      # rubocop:disable Metrics/AbcSize -- validation errors stay adjacent to
      # the wire-format checks so malformed payloads fail before any query.
      def validate_option_row!(entry, option)
        unless option.is_a?(Hash)
          raise ArgumentError, "Schema preview field #{entry["name"].inspect} option rows must be Hashes"
        end

        missing_keys = OPTION_KEYS.reject { |key| option.key?(key) }
        unless missing_keys.empty?
          raise ArgumentError,
                "Schema preview field #{entry["name"].inspect} option is missing key #{missing_keys.first.inspect}"
        end
        unless option["label"].is_a?(String) && option["label"].present?
          raise ArgumentError,
                "Schema preview field #{entry["name"].inspect} option label must be a non-empty String"
        end
        unless option["value"].is_a?(String) && option["value"].present?
          raise ArgumentError,
                "Schema preview field #{entry["name"].inspect} option value must be a non-empty String"
        end
        return if option["sort_order"].nil? || option["sort_order"].is_a?(Integer)

        raise ArgumentError,
              "Schema preview field #{entry["name"].inspect} option sort_order must be an Integer or nil"
      end
      # rubocop:enable Metrics/AbcSize

      def preview_fields(entries, import_index)
        entries.map { |entry| preview_field(entry, import_index.fields[field_identity(entry)]) }
      end

      def preview_sections(entries, import_index)
        entries.map { |entry| preview_section(entry, import_index.sections[section_identity(entry)]) }
      end

      def preview_field(entry, existing)
        identity = identity_hash(entry, "name")
        options = existing ? option_diff(existing_entry(existing), entry) : option_diff({}, entry)
        return added_preview(identity, options) unless existing

        current = existing_entry(existing)
        changes = field_changes(current, entry)
        risks = field_risks(current, entry, options)
        status = field_status(current, entry)
        action = field_action(status)

        entry_preview(
          identity,
          status: status,
          action: action,
          changes: changes,
          options: options,
          risks: risks,
        )
      end

      def field_status(current, incoming)
        return "conflict" if current["type"] != incoming["type"]
        return "unchanged" if current == incoming

        "changed"
      end

      def field_action(status)
        return "error" if status == "conflict"
        return "unchanged" if status == "unchanged"

        conflict_action
      end

      def field_changes(current, incoming)
        changes = attribute_changes(current, incoming, comparable_keys(current, incoming, FIELD_IDENTITY_KEYS))
        same_options = current["options_data"] == incoming["options_data"] &&
                       current.key?("options_data") == incoming.key?("options_data")
        return changes if same_options

        changes["options_data"] = presence_change(current, incoming, "options_data")
        changes
      end

      def preview_section(entry, existing)
        identity = identity_hash(entry, "code")
        return entry_preview(identity, status: "added", action: "create", changes: {}, risks: []) unless existing

        current = SchemaPortability.send(:export_section_entry, existing)
        changes = attribute_changes(current, entry, comparable_keys(current, entry, SECTION_IDENTITY_KEYS))
        if current == entry
          entry_preview(identity, status: "unchanged", action: "unchanged", changes: changes, risks: [])
        else
          entry_preview(identity, status: "changed", action: conflict_action, changes: changes, risks: [])
        end
      end

      def existing_entry(existing)
        SchemaPortability.send(:export_field_entry, existing)
      end

      def identity_hash(entry, key)
        {
          key => entry[key],
          "entity_type" => entry["entity_type"],
          "scope" => entry["scope"],
          "parent_scope" => entry["parent_scope"],
        }
      end

      def field_identity(entry)
        entry.values_at(*FIELD_IDENTITY_KEYS)
      end

      def section_identity(entry)
        entry.values_at(*SECTION_IDENTITY_KEYS)
      end

      def added_preview(identity, options)
        entry_preview(identity, status: "added", action: "create", changes: {}, options: options, risks: [])
      end

      # rubocop:disable Metrics/ParameterLists -- these are the explicit
      # dimensions of one stable result entry.
      def entry_preview(identity, status:, action:, changes:, risks:, options: nil)
        result = {
          "identity" => identity.deep_dup,
          "status" => status,
          "action" => action,
          "changes" => changes.deep_dup,
          "risks" => risks,
        }
        result["options"] = options.deep_dup if options
        result
      end
      # rubocop:enable Metrics/ParameterLists

      def attribute_changes(current, incoming, keys)
        keys.each_with_object({}) do |key, changes|
          next if current[key] == incoming[key] && current.key?(key) == incoming.key?(key)

          changes[key] = { "from" => current[key], "to" => incoming[key] }
        end
      end

      def option_diff(current, incoming)
        current_by_value = options_by_value(current)
        incoming_by_value = options_by_value(incoming)

        {
          "added" => option_rows(incoming_by_value, incoming_by_value.keys - current_by_value.keys),
          "removed" => option_rows(current_by_value, current_by_value.keys - incoming_by_value.keys),
          "changed" => changed_option_rows(current_by_value, incoming_by_value),
        }
      end

      def options_by_value(entry)
        Array(entry["options_data"]).index_by { |row| row["value"] }
      end

      def option_rows(rows_by_value, values)
        values.sort.map { |value| rows_by_value[value] }
      end

      def changed_option_rows(current_by_value, incoming_by_value)
        (current_by_value.keys & incoming_by_value.keys).sort.filter_map do |value|
          next if current_by_value[value] == incoming_by_value[value]

          { "from" => current_by_value[value], "to" => incoming_by_value[value] }
        end
      end

      def presence_change(current, incoming, key)
        { "from" => current[key], "to" => incoming[key] }
      end

      def comparable_keys(current, incoming, identity_keys)
        (current.keys | incoming.keys) - identity_keys - ["options_data"]
      end

      def field_risks(current, incoming, options)
        risks = []
        risks << "type_change" if current["type"] != incoming["type"]
        risks << "option_removal" unless options["removed"].empty?
        risks << "required_false_to_true" if current["required"] == false && incoming["required"] == true
        risks << "potentially_breaking_options" if current["options"] != incoming["options"]
        risks << "default_value_change" if current["default_value_meta"] != incoming["default_value_meta"]
        risks << "field_dependent_change" if current["field_dependent"] != incoming["field_dependent"]
        risks
      end

      def conflict_action
        @on_conflict == :error ? "error" : @on_conflict.to_s
      end

      def summary_for(entries)
        {
          "unchanged" => entries.count { |entry| entry["status"] == "unchanged" },
          "added" => entries.count { |entry| entry["status"] == "added" },
          "changed" => entries.count { |entry| entry["status"] == "changed" },
          "conflicts" => entries.count { |entry| CONFLICT_STATUSES.include?(entry["status"]) },
          "risks" => entries.sum { |entry| entry["risks"].size },
        }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
