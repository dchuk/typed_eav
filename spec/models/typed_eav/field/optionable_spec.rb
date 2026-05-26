# frozen_string_literal: true

require "spec_helper"

# Family-base spec for Field::Optionable concern. Covers optionable?,
# allowed_values (loaded vs pluck branches), and the
# option-inclusion validators ONCE for Select/MultiSelect instead of
# the previous per-leaf duplication.
RSpec.describe TypedEAV::Field::Optionable, type: :model do
  describe "concern shape" do
    it "is a Module (concern), not a class" do
      expect(described_class).to be_a(Module)
      expect(described_class).not_to be_a(Class)
    end

    it "is included by Field::Select" do
      expect(TypedEAV::Field::Select.include?(described_class)).to be(true)
    end

    it "is included by Field::MultiSelect" do
      expect(TypedEAV::Field::MultiSelect.include?(described_class)).to be(true)
    end

    it "leaves Field::Select as a direct child of Field::Base" do
      expect(TypedEAV::Field::Select.superclass).to eq(TypedEAV::Field::Base)
    end

    it "leaves Field::MultiSelect as a direct child of Field::Base" do
      expect(TypedEAV::Field::MultiSelect.superclass).to eq(TypedEAV::Field::Base)
    end
  end

  describe "#optionable?" do
    it "is true on Select" do
      expect(build(:select_field)).to be_optionable
    end

    it "is true on MultiSelect" do
      expect(build(:multi_select_field)).to be_optionable
    end

    it "is false on Field::Base by default" do
      expect(TypedEAV::Field::Base.new).not_to be_optionable
    end
  end

  describe "#allowed_values (public-facing, sorted)" do
    context "with the field_options association NOT loaded (pluck branch)" do
      let(:field) { create(:select_field) }

      it "returns the values in sorted order via SQL pluck" do
        # Force a fresh field reference so the association is unloaded.
        fresh = TypedEAV::Field::Select.find(field.id)
        expect(fresh.field_options.loaded?).to be(false)
        expect(fresh.allowed_values).to eq(%w[active inactive lead])
      end
    end

    context "with the field_options association already loaded (in-memory branch)" do
      let(:field) { create(:select_field) }

      it "returns the values in sorted order from memory" do
        field.field_options.load
        expect(field.field_options.loaded?).to be(true)
        expect(field.allowed_values).to eq(%w[active inactive lead])
      end

      it "respects sort_order when it differs from insertion order" do
        # Insertion order is alphabetic by label; we want to confirm
        # sort_order drives the ordering.
        f = create(:select_field)
        f.field_options.destroy_all
        f.field_options.create!([
                                  { label: "Zeta",  value: "zeta",  sort_order: 1 },
                                  { label: "Alpha", value: "alpha", sort_order: 2 },
                                ])
        f.field_options.load
        expect(f.allowed_values).to eq(%w[zeta alpha])
      end
    end

    it "is also available on MultiSelect" do
      ms = create(:multi_select_field)
      expect(ms.allowed_values).to eq(%w[vip partner prospect])
    end
  end

  describe "#allowed_option_values (validator-facing fast path on Field::Base)" do
    it "stays on Field::Base after Optionable extraction" do
      f = create(:select_field)
      expect(f.allowed_option_values).to match_array(%w[active inactive lead])
    end
  end

  describe "Select validate_option_inclusion (via Value validation)" do
    let(:contact) { create(:contact) }
    let(:field) { create(:select_field) }

    it "rejects a value not in the option set" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "unknown")
      expect(v).not_to be_valid
    end

    it "accepts a value in the option set" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: "active")
      expect(v).to be_valid
    end
  end

  describe "MultiSelect validate_multi_option_inclusion (via Value validation)" do
    let(:contact) { create(:contact) }
    let(:field) { create(:multi_select_field) }

    it "rejects an array containing any unknown value" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: %w[vip not_a_real_option])
      expect(v).not_to be_valid
    end

    it "accepts an array entirely within the option set" do
      v = TypedEAV::Value.new(entity: contact, field: field, value: %w[vip prospect])
      expect(v).to be_valid
    end
  end
end
