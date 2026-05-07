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
end
