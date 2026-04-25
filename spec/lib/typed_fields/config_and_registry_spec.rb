# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedFields::Config do
  let(:config) { described_class }

  describe "#field_types" do
    it "includes all builtin types" do
      expect(config.type_names).to include(
        :text, :long_text, :integer, :decimal, :boolean,
        :date, :date_time, :select, :multi_select,
        :integer_array, :text_array, :email, :url, :color, :json
      )
    end
  end

  describe "#field_class_for" do
    it "resolves type name to class" do
      expect(config.field_class_for(:integer)).to eq(TypedFields::Field::Integer)
    end

    it "raises for unknown types" do
      expect { config.field_class_for(:nonexistent) }.to raise_error(ArgumentError)
    end
  end

  describe "#register_field_type" do
    after { config.field_types.delete(:custom_test) }

    it "registers a custom field type" do
      config.register_field_type(:custom_test, "TypedFields::Field::Text")
      expect(config.type_names).to include(:custom_test)
      expect(config.field_class_for(:custom_test)).to eq(TypedFields::Field::Text)
    end
  end

  describe "#type_names completeness" do
    it "includes decimal_array and date_array" do
      expect(config.type_names).to include(:decimal_array, :date_array)
    end

    it "resolves all 17 builtin types" do
      TypedFields::Config::BUILTIN_FIELD_TYPES.each_key do |name|
        expect { config.field_class_for(name) }.not_to raise_error
      end
    end
  end
end

RSpec.describe TypedFields::Registry do
  let(:registry) { described_class }

  before { registry.reset! }

  after do
    # Re-register test models so other specs aren't affected by reset
    registry.reset!
    registry.register("Contact", types: nil)
    registry.register("Product", types: %i[text integer decimal boolean])
  end

  describe "#register" do
    it "tracks registered entity types" do
      registry.register("Contact", types: nil)
      expect(registry.entity_types).to include("Contact")
    end
  end

  describe "#allowed_types_for" do
    it "returns nil when no restrictions (all types allowed)" do
      registry.register("Contact", types: nil)
      expect(registry.allowed_types_for("Contact")).to be_nil
    end

    it "returns the type list when restricted" do
      registry.register("Product", types: %i[text integer])
      expect(registry.allowed_types_for("Product")).to eq(%i[text integer])
    end
  end

  describe "#type_allowed?" do
    before do
      registry.register("Contact", types: nil)
      registry.register("Product", types: %i[text integer])
    end

    it "allows any type when unrestricted" do
      expect(registry.type_allowed?("Contact", TypedFields::Field::Json)).to be true
    end

    it "allows permitted types" do
      expect(registry.type_allowed?("Product", TypedFields::Field::Integer)).to be true
    end

    it "rejects non-permitted types" do
      expect(registry.type_allowed?("Product", TypedFields::Field::Json)).to be false
    end
  end

  describe "#reset!" do
    it "clears all registered entities" do
      registry.register("TestEntity")
      registry.reset!
      expect(registry.entity_types).to be_empty
    end
  end
end
