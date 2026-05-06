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

    it "covers every built-in single-cell field type with the default" do
      # All built-in single-cell types inherit the default value_columns →
      # [value_column]. This spec is the regression guard: if anyone adds
      # a built-in single-cell type that overrides value_columns without
      # also overriding value_column, this fails.
      #
      # Phase 05 multi-cell types (Currency) deliberately override
      # value_columns; they are listed in MULTI_CELL_BUILTINS and
      # excluded here. The override is asserted positively in the
      # multi-cell block below.
      multi_cell_class_names = %w[TypedEAV::Field::Currency]
      TypedEAV::Config::BUILTIN_FIELD_TYPES.each_value do |class_name|
        next if multi_cell_class_names.include?(class_name)

        klass = class_name.constantize
        expect(klass.value_columns).to eq([klass.value_column]),
                                       "Expected #{klass}.value_columns to default to " \
                                       "[#{klass.value_column.inspect}], got #{klass.value_columns.inspect}"
      end
    end

    it "Currency (Phase 05 multi-cell) returns [:decimal_value, :string_value]" do
      # Currency is the canonical multi-cell consumer of the override.
      # decimal_value carries the amount; string_value carries the ISO
      # 4217 currency code. Versioning's snapshot loop and Value's
      # _dispatch_value_change_update filter both iterate this array.
      expect(TypedEAV::Field::Currency.value_columns).to eq(%i[decimal_value string_value])
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
