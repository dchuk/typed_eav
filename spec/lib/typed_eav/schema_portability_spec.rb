# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::SchemaPortability, :unscoped do
  def capture_schema_lookup_queries(&block)
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name])

      queries << payload[:sql] if payload[:sql].match?(/FROM "typed_eav_(fields|options|sections)"/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    queries
  end

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

  it "preloads existing fields with options and sections in bounded queries" do
    6.times do |index|
      create(
        :select_field,
        entity_type: "Contact",
        scope: "bounded_import",
        name: "select_#{index}",
        sort_order: index,
      )
      create(
        :typed_section,
        entity_type: "Contact",
        scope: "bounded_import",
        name: "Section #{index}",
        code: "section_#{index}",
        sort_order: index,
      )
    end
    exported = described_class.export_schema(entity_type: "Contact", scope: "bounded_import")
    result = nil
    lookup_queries = capture_schema_lookup_queries do
      result = described_class.import_schema(exported)
    end

    expect(result).to include("unchanged" => 12)
    expect(lookup_queries.size).to eq(3)
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
        "name", "field_type_name", "display_name", "required", "sort_order", "options"
      )
    end

    it "orders fields by sort_order" do
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "third", sort_order: 30)
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "first", sort_order: 10)
      create(:text_field, entity_type: "Contact", scope: "snap_order", name: "second", sort_order: 20)

      result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_order")

      expect(result["fields"].pluck("name")).to eq(%w[first second third])
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

      expect(result["fields"].pluck("name")).to eq(["included"])
    end
  end

  describe "export_schema regression" do
    it "preserves the existing export_schema envelope keys (unchanged)" do
      create(:text_field, entity_type: "Contact", scope: "regress", name: "nickname", sort_order: 1)

      result = described_class.export_schema(entity_type: "Contact", scope: "regress")

      expect(result.keys).to contain_exactly(
        "schema_version", "entity_type", "scope", "parent_scope", "fields", "sections"
      )
      expect(result["fields"].first.keys).to include(
        "name", "type", "entity_type", "scope", "parent_scope",
        "required", "sort_order", "field_dependent", "options", "default_value_meta"
      )
    end
  end

  describe "field label round-trip (issue #21)" do
    it "export_schema emits a 'label' key carrying the raw label" do
      create(:text_field, entity_type: "Contact", scope: "lbl_exp", name: "nickname", sort_order: 1, label: "Nick Name")

      result = described_class.export_schema(entity_type: "Contact", scope: "lbl_exp")
      entry = result["fields"].first

      expect(entry).to have_key("label")
      expect(entry["label"]).to eq("Nick Name")
    end

    it "emits the raw label (nil), NOT a resolved display_name, when label is unset" do
      create(:text_field, entity_type: "Contact", scope: "lbl_raw_nil", name: "sub_category", sort_order: 1, label: nil)

      result = described_class.export_schema(entity_type: "Contact", scope: "lbl_raw_nil")
      entry = result["fields"].first

      expect(entry["label"]).to be_nil
      # The regular (non-snapshot) export carries the RAW label, never the
      # resolved name.humanize fallback.
      expect(entry).not_to have_key("display_name")
    end

    it "round-trips the label through export_schema -> import_schema on a created field" do
      create(:text_field, entity_type: "Contact", scope: "lbl_rt", name: "nickname", sort_order: 1, label: "Nick Name")

      exported = described_class.export_schema(entity_type: "Contact", scope: "lbl_rt")
      TypedEAV::Field::Base.where(entity_type: "Contact", scope: "lbl_rt").destroy_all

      result = described_class.import_schema(exported)
      expect(result).to include("created" => 1)

      imported = TypedEAV::Field::Base.find_by(entity_type: "Contact", scope: "lbl_rt", name: "nickname")
      expect(imported.label).to eq("Nick Name")
      expect(imported.display_name).to eq("Nick Name")
    end

    # rubocop:disable RSpec/ExampleLength -- explicit legacy wire payload is the compatibility fixture.
    it "imports a pre-feature payload (no 'label' key) as label nil with no version gate" do
      # Legacy export entry: every current key EXCEPT "label".
      legacy = {
        "schema_version" => 1,
        "entity_type" => "Contact",
        "scope" => "lbl_legacy",
        "parent_scope" => nil,
        "fields" => [
          {
            "name" => "sub_category",
            "type" => "TypedEAV::Field::Text",
            "entity_type" => "Contact",
            "scope" => "lbl_legacy",
            "parent_scope" => nil,
            "required" => false,
            "sort_order" => 1,
            "field_dependent" => "destroy",
            "options" => nil,
            "default_value_meta" => {},
          },
        ],
        "sections" => [],
      }

      expect { described_class.import_schema(legacy) }.not_to raise_error

      imported = TypedEAV::Field::Base.find_by(entity_type: "Contact", scope: "lbl_legacy", name: "sub_category")
      expect(imported).to be_present
      expect(imported.label).to be_nil
      expect(imported.display_name).to eq("Sub category")
    end
    # rubocop:enable RSpec/ExampleLength

    it "updates label on conflict with on_conflict: :overwrite" do
      create(:text_field, entity_type: "Contact", scope: "lbl_ow", name: "nickname", sort_order: 1, label: "Old Label")

      exported = described_class.export_schema(entity_type: "Contact", scope: "lbl_ow")
      exported["fields"].first["label"] = "New Label"

      result = described_class.import_schema(exported, on_conflict: :overwrite)
      expect(result).to include("updated" => 1)

      field = TypedEAV::Field::Base.find_by(entity_type: "Contact", scope: "lbl_ow", name: "nickname")
      expect(field.label).to eq("New Label")
    end

    describe "divergence detection (on_conflict: :error)" do
      it "treats a differing label as a divergence (raises)" do
        create(:text_field, entity_type: "Contact", scope: "lbl_div", name: "nickname", sort_order: 1,
                            label: "Original")

        exported = described_class.export_schema(entity_type: "Contact", scope: "lbl_div")
        exported["fields"].first["label"] = "Different"

        expect { described_class.import_schema(exported, on_conflict: :error) }
          .to raise_error(ArgumentError, /diverge/)
      end

      it "treats an identical label as unchanged (no raise)" do
        create(:text_field, entity_type: "Contact", scope: "lbl_same", name: "nickname", sort_order: 1, label: "Same")

        exported = described_class.export_schema(entity_type: "Contact", scope: "lbl_same")

        result = described_class.import_schema(exported, on_conflict: :error)
        expect(result).to include("unchanged" => 1)
      end
    end

    describe "snapshot export carries the RESOLVED display_name" do
      it "emits the label as display_name when label is present" do
        create(:text_field, entity_type: "Contact", scope: "snap_lbl", name: "sub_category", sort_order: 1,
                            label: "Sub-Category")

        result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_lbl")
        entry = result["fields"].first

        expect(entry).to have_key("display_name")
        expect(entry["display_name"]).to eq("Sub-Category")
        # Snapshot is render-oriented: it carries display_name, NOT the raw label.
        expect(entry).not_to have_key("label")
      end

      it "emits the name.humanize fallback as display_name when label is nil" do
        create(:text_field, entity_type: "Contact", scope: "snap_lbl_nil", name: "sub_category", sort_order: 1,
                            label: nil)

        result = described_class.export_snapshot_schema(entity_type: "Contact", scope: "snap_lbl_nil")
        entry = result["fields"].first

        expect(entry["display_name"]).to eq("Sub category")
      end
    end
  end
end
