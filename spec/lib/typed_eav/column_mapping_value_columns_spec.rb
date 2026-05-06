# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::ColumnMapping do
  describe ".value_columns (default delegation)" do
    it "returns [value_column] for a single-cell field type" do
      # Use any built-in single-cell field type as the canonical example.
      expect(TypedEAV::Field::Integer.value_columns).to eq([:integer_value])
    end

    it "returns [value_column] for the Text type" do
      expect(TypedEAV::Field::Text.value_columns).to eq([:string_value])
    end

    it "returns [value_column] for jsonb-backed multi-select" do
      expect(TypedEAV::Field::MultiSelect.value_columns).to eq([:json_value])
    end

    it "covers every built-in field type with the default" do
      # 17 built-in types. Every one inherits the default value_columns →
      # [value_column] until Phase 05 Currency overrides. This spec is
      # the regression guard: if anyone adds a built-in type that
      # overrides value_columns without also overriding value_column,
      # this fails. Acceptable failure: Phase 05 Currency lands and adds
      # the override deliberately — at that point this spec is updated
      # to skip Currency and assert the new override returns the
      # expected two-element Array.
      TypedEAV::Config::BUILTIN_FIELD_TYPES.each_value do |class_name|
        klass = class_name.constantize
        expect(klass.value_columns).to eq([klass.value_column]),
                                       "Expected #{klass}.value_columns to default to " \
                                       "[#{klass.value_column.inspect}], got #{klass.value_columns.inspect}"
      end
    end

    it "raises NotImplementedError when called on a subclass without value_column declared" do
      # Build an anonymous subclass that does NOT declare value_column.
      # The default value_columns delegates to value_column, which raises.
      bad_subclass = Class.new(TypedEAV::Field::Base) do
        self.table_name = "typed_eav_fields"
      end
      expect { bad_subclass.value_columns }.to raise_error(NotImplementedError, /must declare `value_column/)
    end
  end

  describe ".value_columns (override path — Phase 05 forward-compat)" do
    # Demonstrates that a subclass overriding value_columns with a
    # multi-cell return is supported by the contract. Phase 05 Currency
    # will use exactly this pattern.
    let(:multi_cell_subclass) do
      Class.new(TypedEAV::Field::Base) do
        self.table_name = "typed_eav_fields"
        value_column :decimal_value

        def self.value_columns
          %i[decimal_value string_value]
        end
      end
    end

    it "returns the override Array when a subclass overrides value_columns" do
      expect(multi_cell_subclass.value_columns).to eq(%i[decimal_value string_value])
    end

    it "leaves the singular value_column untouched (backward compat)" do
      expect(multi_cell_subclass.value_column).to eq(:decimal_value)
    end
  end
end
