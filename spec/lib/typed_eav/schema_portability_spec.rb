# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::SchemaPortability, :unscoped do
  it "round-trips field and section definitions for an exact partition tuple" do
    create(:text_field, entity_type: "Contact", scope: "portable", name: "nickname", sort_order: 1)
    create(:integer_field, entity_type: "Contact", scope: "portable", name: "score", sort_order: 2)
    create(
      :typed_section,
      entity_type: "Contact",
      scope: "portable",
      name: "Details",
      code: "details",
      sort_order: 1,
    )

    exported = described_class.export_schema(entity_type: "Contact", scope: "portable")

    TypedEAV::Field::Base.where(entity_type: "Contact", scope: "portable").destroy_all
    TypedEAV::Section.where(entity_type: "Contact", scope: "portable").destroy_all

    result = described_class.import_schema(exported)

    expect(result).to include("created" => 3, "updated" => 0, "skipped" => 0, "unchanged" => 0)
    expect(described_class.export_schema(entity_type: "Contact", scope: "portable")).to eq(exported)
  end

  describe ".export_snapshot_schema" do
    it "returns the versioned envelope with snapshot_schema_version and fields keys" do
      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_empty")

      expect(result.keys).to contain_exactly("snapshot_schema_version", "fields")
      expect(result["snapshot_schema_version"]).to eq(1)
    end

    it "returns an empty fields array for an empty partition" do
      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_empty")

      expect(result).to eq("snapshot_schema_version" => 1, "fields" => [])
    end

    it "emits per-field entries with exactly the snapshot key set for non-optionable fields" do
      create(:text_field, entity_type: "Contact", scope: "snap_keys", name: "nickname", sort_order: 1)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_keys")

      expect(result["fields"].length).to eq(1)
      expect(result["fields"].first.keys).to contain_exactly(
        "name", "field_type_name", "required", "sort_order", "options",
      )
    end

    it "orders fields by sort_order" do
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "third", sort_order: 30)
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "first", sort_order: 10)
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "second", sort_order: 20)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_order")

      expect(result["fields"].map { |f| f["name"] }).to eq(%w[first second third])
    end

    it "includes options_data for optionable fields ordered by [sort_order, label, id]" do
      create(:select_field, entity_type: "Contact", scope: "snap_opt", name: "status", sort_order: 1)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_opt")
      entry = result["fields"].first

      expect(entry.keys).to include("options_data")
      expect(entry["options_data"]).to eq(
        [
          { "label" => "Active",   "value" => "active",   "sort_order" => 1 },
          { "label" => "Inactive", "value" => "inactive", "sort_order" => 2 },
          { "label" => "Lead",     "value" => "lead",     "sort_order" => 3 },
        ],
      )
    end

    it "omits the options_data key entirely for non-optionable fields" do
      create(:text_field, entity_type: "Contact", scope: "snap_no_opt", name: "nickname", sort_order: 1)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_no_opt")
      entry = result["fields"].first

      expect(entry).not_to have_key("options_data")
    end

    it "does not include default_value_meta even when populated" do
      create(
        :text_field,
        entity_type: "Contact",
        scope: "snap_dvm",
        name: "nickname",
        sort_order: 1,
        default_value_meta: { "mode" => "literal", "value" => "anon" },
      )

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_dvm")
      entry = result["fields"].first

      expect(entry).not_to have_key("default_value_meta")
    end

    it "does not include entity_type, scope, parent_scope, type, or field_dependent keys" do
      create(:text_field, entity_type: "Contact", scope: "snap_omit", name: "nickname", sort_order: 1)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_omit")
      entry = result["fields"].first

      %w[entity_type scope parent_scope type field_dependent].each do |key|
        expect(entry).not_to have_key(key)
      end
    end

    it "emits field_type_name as the underscored demodulized class name" do
      create(:select_field, entity_type: "Contact", scope: "snap_ftn", name: "status", sort_order: 1)
      create(:text_field, entity_type: "Contact", scope: "snap_ftn", name: "nickname", sort_order: 2)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_ftn")
      by_name = result["fields"].index_by { |f| f["name"] }

      expect(by_name["status"]["field_type_name"]).to eq("select")
      expect(by_name["nickname"]["field_type_name"]).to eq("text")
    end

    it "scopes to the exact partition tuple and excludes other partitions" do
      create(:text_field, entity_type: "Contact", scope: "snap_in", name: "included", sort_order: 1)
      create(:text_field, entity_type: "Contact", scope: "snap_out", name: "excluded", sort_order: 1)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_in")

      expect(result["fields"].map { |f| f["name"] }).to eq(["included"])
    end
  end

  describe "export_schema regression" do
    it "preserves the existing export_schema envelope keys (unchanged)" do
      create(:text_field, entity_type: "Contact", scope: "regress", name: "nickname", sort_order: 1)

      result = described_class.export_schema(entity_type: "Contact", scope: "regress")

      expect(result.keys).to contain_exactly(
        "schema_version", "entity_type", "scope", "parent_scope", "fields", "sections",
      )
      expect(result["fields"].first.keys).to include(
        "name", "type", "entity_type", "scope", "parent_scope",
        "required", "sort_order", "field_dependent", "options", "default_value_meta",
      )
    end
  end
end
