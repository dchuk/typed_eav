# frozen_string_literal: true

# rubocop:disable RSpec/SpecFilePathFormat

require "spec_helper"

RSpec.describe TypedEAV::SchemaPortability, ".preview_schema", :unscoped do
  describe "an unchanged schema" do
    # rubocop:disable RSpec/ExampleLength -- this is the public result-shape tracer bullet.
    it "reports unchanged field and section actions without applying them" do
      create(:text_field, entity_type: "Contact", scope: "preview_same", name: "nickname", sort_order: 1)
      create(
        :typed_section,
        entity_type: "Contact",
        scope: "preview_same",
        name: "Profile",
        code: "profile",
        sort_order: 1,
      )
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_same")

      result = described_class.preview_schema(schema)

      expect(result).to include(
        "schema_version" => 1,
        "entity_type" => "Contact",
        "scope" => "preview_same",
        "parent_scope" => nil,
        "importable" => true,
      )
      expect(result["summary"]).to include(
        "unchanged" => 2,
        "added" => 0,
        "changed" => 0,
        "conflicts" => 0,
      )
      expect(result["fields"].first).to include(
        "status" => "unchanged",
        "action" => "unchanged",
        "changes" => {},
        "options" => { "added" => [], "removed" => [], "changed" => [] },
        "risks" => [],
      )
      expect(result["sections"].first).to include(
        "status" => "unchanged",
        "action" => "unchanged",
        "changes" => {},
        "risks" => [],
      )
    end
    # rubocop:enable RSpec/ExampleLength
  end

  describe "additions, changes, and omissions" do
    it "reports an added field and does not treat omitted target rows as deletions" do
      existing = create(:text_field, entity_type: "Contact", scope: "preview_add", name: "kept", sort_order: 1)
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_add")
      added_entry = schema["fields"].first.merge("name" => "new_name")
      schema["fields"] = [added_entry]

      result = described_class.preview_schema(schema)

      expect(result["fields"]).to contain_exactly(
        include(
          "identity" => {
            "name" => "new_name",
            "entity_type" => "Contact",
            "scope" => "preview_add",
            "parent_scope" => nil,
          },
          "status" => "added",
          "action" => "create",
        ),
      )
      expect(result["summary"]).to include("added" => 1, "unchanged" => 0, "conflicts" => 0)
      expect(result["importable"]).to be(true)
      expect(TypedEAV::Field::Base.find(existing.id)).to be_present
      expect(result).not_to include("deletions")
    end

    # rubocop:disable RSpec/ExampleLength -- field and section differences are
    # asserted together to prove one preview envelope and policy action.
    it "reports changed field and section attributes with policy-dependent actions" do
      field = create(
        :integer_field,
        entity_type: "Contact",
        scope: "preview_change",
        name: "age",
        required: false,
        sort_order: 1,
        options: { "min" => 0, "max" => 100 },
      )
      create(
        :typed_section,
        entity_type: "Contact",
        scope: "preview_change",
        code: "profile",
        name: "Profile",
        sort_order: 1,
        active: true,
      )
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_change")
      schema["fields"].first["required"] = true
      schema["fields"].first["options"] = { "min" => 10, "max" => 100 }
      schema["sections"].first["name"] = "Details"
      schema["sections"].first["active"] = false

      result = described_class.preview_schema(schema, on_conflict: :skip)
      field_result = result["fields"].first
      section_result = result["sections"].first

      expect(field_result).to include("status" => "changed", "action" => "skip")
      expect(field_result["changes"]).to include(
        "required" => { "from" => false, "to" => true },
        "options" => { "from" => { "min" => 0, "max" => 100 }, "to" => { "min" => 10, "max" => 100 } },
      )
      expect(field_result["risks"]).to include("required_false_to_true", "potentially_breaking_options")
      expect(section_result).to include("status" => "changed", "action" => "skip")
      expect(section_result["changes"]).to include(
        "name" => { "from" => "Profile", "to" => "Details" },
        "active" => { "from" => true, "to" => false },
      )
      expect(section_result).not_to have_key("options")
      expect(result["importable"]).to be(true)
      expect(field.reload.required).to be(false)
    end
    # rubocop:enable RSpec/ExampleLength
  end

  describe "field option differences" do
    it "reports option additions, removals, and row changes explicitly" do
      create(:select_field, entity_type: "Contact", scope: "preview_options", name: "status")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_options")
      options = schema["fields"].first["options_data"]
      options.delete_if { |option| option["value"] == "active" }
      options.find { |option| option["value"] == "inactive" }.merge!("label" => "Paused")
      options << { "label" => "Archived", "value" => "archived", "sort_order" => 4 }

      result = described_class.preview_schema(schema, on_conflict: :overwrite)
      field_result = result["fields"].first

      expect(field_result).to include("status" => "changed", "action" => "overwrite")
      expect(field_result["options"]).to eq(
        "added" => [{ "label" => "Archived", "value" => "archived", "sort_order" => 4 }],
        "removed" => [{ "label" => "Active", "value" => "active", "sort_order" => 1 }],
        "changed" => [
          {
            "from" => { "label" => "Inactive", "value" => "inactive", "sort_order" => 2 },
            "to" => { "label" => "Paused", "value" => "inactive", "sort_order" => 2 },
          },
        ],
      )
      expect(field_result["risks"]).to include("option_removal")
      expect(result["risks"]).to include("option_removal")
    end

    it "treats option order and option key presence as importer-visible changes" do
      create(:select_field, entity_type: "Contact", scope: "preview_option_order", name: "status")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_option_order")
      schema["fields"].first["options_data"].reverse!

      result = described_class.preview_schema(schema)
      field_result = result["fields"].first

      expect(field_result).to include("status" => "changed", "action" => "error")
      expect(field_result["changes"]).to have_key("options_data")
      expect(result["importable"]).to be(false)
    end

    it "treats a legacy missing label key as an importer-visible change" do
      create(:text_field, entity_type: "Contact", scope: "preview_legacy", name: "nickname", label: nil)
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_legacy")
      schema["fields"].first.delete("label")

      result = described_class.preview_schema(schema)
      field_result = result["fields"].first

      expect(field_result).to include("status" => "changed", "action" => "error")
      expect(field_result["changes"]["label"]).to eq("from" => nil, "to" => nil)
      expect(result["importable"]).to be(false)
    end
  end

  describe "input validation" do
    def empty_schema(scope: "preview_invalid")
      {
        "schema_version" => 1,
        "entity_type" => "Contact",
        "scope" => scope,
        "parent_scope" => nil,
        "fields" => [],
        "sections" => [],
      }
    end

    it "uses the existing schema version and conflict policy validators" do
      expect { described_class.preview_schema(empty_schema.merge("schema_version" => 2)) }
        .to raise_error(ArgumentError, /Unsupported schema_version: 2/)
      expect { described_class.preview_schema(empty_schema, on_conflict: :bogus) }
        .to raise_error(ArgumentError, /Unsupported on_conflict.*:error.*:skip.*:overwrite/m)
    end

    it "rejects a field entry whose exact identity differs from the envelope" do
      schema = empty_schema
      schema["fields"] << {
        "name" => "nickname",
        "type" => "TypedEAV::Field::Text",
        "entity_type" => "Contact",
        "scope" => "another_scope",
        "parent_scope" => nil,
      }

      expect { described_class.preview_schema(schema) }
        .to raise_error(ArgumentError, /identity must match.*target/)
    end

    it "rejects duplicate field identities before querying definitions" do
      entry = {
        "name" => "nickname",
        "type" => "TypedEAV::Field::Text",
        "entity_type" => "Contact",
        "scope" => "preview_duplicate",
        "parent_scope" => nil,
      }
      schema = empty_schema(scope: "preview_duplicate").merge("fields" => [entry, entry.dup])

      expect { described_class.preview_schema(schema) }
        .to raise_error(ArgumentError, /Duplicate field identity/)
    end

    it "rejects an unknown field STI type without constructing or saving it" do
      schema = empty_schema(scope: "preview_unknown_type")
      schema["fields"] << {
        "name" => "mystery",
        "type" => "TypedEAV::Field::DoesNotExist",
        "entity_type" => "Contact",
        "scope" => "preview_unknown_type",
        "parent_scope" => nil,
      }

      expect { described_class.preview_schema(schema) }
        .to raise_error(ArgumentError, /must be a TypedEAV::Field::Base subclass/)
    end

    it "rejects malformed top-level and option collections" do
      expect { described_class.preview_schema(empty_schema.merge("fields" => "not an array")) }
        .to raise_error(ArgumentError, /fields must be an Array/)

      schema = empty_schema
      schema["fields"] << {
        "name" => "status",
        "type" => "TypedEAV::Field::Select",
        "entity_type" => "Contact",
        "scope" => "preview_invalid",
        "parent_scope" => nil,
        "options_data" => [],
      }
      schema["fields"].first["options_data"] = "not an array"

      expect { described_class.preview_schema(schema) }
        .to raise_error(ArgumentError, /options_data must be an Array/)
    end

    it "rejects a section entry without the required importer name" do
      schema = empty_schema(scope: "preview_section_invalid")
      schema["sections"] << {
        "code" => "profile",
        "entity_type" => "Contact",
        "scope" => "preview_section_invalid",
        "parent_scope" => nil,
      }

      expect { described_class.preview_schema(schema) }
        .to raise_error(ArgumentError, /section .*name must be a non-empty String/)
    end
  end

  describe "read-only prediction" do
    def capture_writes
      writes = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        payload = args.last
        sql = payload[:sql].to_s
        next if payload[:name] == "SCHEMA"
        next unless sql.match?(/\A\s*(INSERT|UPDATE|DELETE)\s/i)
        next unless sql.match?(/typed_eav_(fields|options|sections)/i)

        writes << sql
      end
      yield
      writes
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it "does not write or change definition state while previewing" do
      field = create(:text_field, entity_type: "Contact", scope: "preview_read_only", name: "nickname")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_read_only")
      schema["fields"].first["required"] = true
      before = TypedEAV::Field::Base.where(id: field.id).pick(:required, :updated_at)

      writes = capture_writes { described_class.preview_schema(schema, on_conflict: :overwrite) }

      expect(writes).to be_empty
      expect(TypedEAV::Field::Base.where(id: field.id).pick(:required, :updated_at)).to eq(before)
    end

    it "predicts create and unchanged actions that agree with a subsequent import" do
      create(:text_field, entity_type: "Contact", scope: "preview_parity", name: "kept")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_parity")
      schema["fields"] << schema["fields"].first.merge("name" => "new_name")

      preview = described_class.preview_schema(schema)
      import_result = described_class.import_schema(schema)

      expect(preview["summary"]).to include("unchanged" => 1, "added" => 1, "conflicts" => 0)
      expect(import_result).to include("unchanged" => 1, "created" => 1)
    end

    it "predicts skip and overwrite outcomes for ordinary divergence" do
      create(:text_field, entity_type: "Contact", scope: "preview_policy", name: "nickname")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_policy")
      schema["fields"].first["required"] = true

      skip_preview = described_class.preview_schema(schema, on_conflict: :skip)
      overwrite_preview = described_class.preview_schema(schema, on_conflict: :overwrite)

      expect(skip_preview["fields"].first["action"]).to eq("skip")
      expect(overwrite_preview["fields"].first["action"]).to eq("overwrite")
      expect(skip_preview["importable"]).to be(true)
      expect(overwrite_preview["importable"]).to be(true)
      expect(described_class.import_schema(schema, on_conflict: :skip)).to include("skipped" => 1)
      expect(described_class.import_schema(schema, on_conflict: :overwrite)).to include("updated" => 1)
    end

    it "blocks type changes under every conflict policy" do
      create(:integer_field, entity_type: "Contact", scope: "preview_type_swap", name: "age")
      schema = described_class.export_schema(entity_type: "Contact", scope: "preview_type_swap")
      schema["fields"].first["type"] = "TypedEAV::Field::Decimal"

      %i[error skip overwrite].each do |policy|
        result = described_class.preview_schema(schema, on_conflict: policy)

        expect(result["fields"].first).to include(
          "status" => "conflict",
          "action" => "error",
        )
        expect(result["fields"].first["risks"]).to include("type_change")
        expect(result["importable"]).to be(false)
      end
    end
  end
end

# rubocop:enable RSpec/SpecFilePathFormat
