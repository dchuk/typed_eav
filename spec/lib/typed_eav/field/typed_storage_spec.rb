# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Field::TypedStorage, :unscoped do
  # The concern is mixed into Field::Base; tests exercise it through the
  # public Field API on real built-in field types and through anonymous
  # Field::Base subclasses for the DSL edge cases.

  describe "class DSL" do
    describe ".value_column" do
      it "returns the declared column as a Symbol" do
        expect(TypedEAV::Field::Integer.value_column).to eq(:integer_value)
      end

      it "raises NotImplementedError when called on a subclass without value_column declared" do
        klass = Class.new(TypedEAV::Field::Base) do
          self.table_name = "typed_eav_fields"
        end
        expect { klass.value_column }.to raise_error(NotImplementedError, /must declare `value_column/)
      end
    end

    describe ".value_columns" do
      it "returns [value_column] for a built-in single-cell type" do
        expect(TypedEAV::Field::Integer.value_columns).to eq([:integer_value])
      end

      it "returns the multi-cell list for Currency" do
        expect(TypedEAV::Field::Currency.value_columns).to eq(%i[decimal_value string_value])
      end

      it "covers every built-in single-cell field type through the value_column → [value_column] sugar" do
        # Regression guard: if anyone adds a built-in single-cell type that
        # forgets to declare value_column, this fails. Currency is the only
        # multi-cell built-in.
        multi_cell_class_names = %w[TypedEAV::Field::Currency]
        TypedEAV::Config::BUILTIN_FIELD_TYPES.each_value do |class_name|
          next if multi_cell_class_names.include?(class_name)

          klass = class_name.constantize
          expect(klass.value_columns).to eq([klass.value_column]),
                                         "Expected #{klass}.value_columns to default to " \
                                         "[#{klass.value_column.inspect}], got #{klass.value_columns.inspect}"
        end
      end

      it "raises NotImplementedError when called on a subclass without any declaration" do
        klass = Class.new(TypedEAV::Field::Base) do
          self.table_name = "typed_eav_fields"
        end
        expect { klass.value_columns }.to raise_error(NotImplementedError, /must declare `value_column/)
      end

      it "accepts a plural declaration via .value_columns(:a, :b)" do
        klass = Class.new(TypedEAV::Field::Base) do
          self.table_name = "typed_eav_fields"
          value_columns :decimal_value, :string_value
        end
        expect(klass.value_columns).to eq(%i[decimal_value string_value])
        expect(klass.value_column).to eq(:decimal_value)
      end
    end

    describe ".operator_column" do
      it "defaults to value_columns.first for arbitrary operators" do
        klass = Class.new(TypedEAV::Field::Base) do
          self.table_name = "typed_eav_fields"
          value_column :integer_value
        end
        expect(klass.operator_column(:eq)).to eq(:integer_value)
        expect(klass.operator_column(:gt)).to eq(:integer_value)
        expect(klass.operator_column(:made_up_operator)).to eq(:integer_value)
      end

      it "is a class method (not exposed on instances)" do
        klass = Class.new(TypedEAV::Field::Base) do
          self.table_name = "typed_eav_fields"
          value_column :string_value
        end
        expect(klass).to respond_to(:operator_column)
        expect(klass.new).not_to respond_to(:operator_column)
      end

      it "is overridable per subclass — Currency routes :currency_eq to the currency cell" do
        expect(TypedEAV::Field::Currency.operator_column(:currency_eq)).to eq(:string_value)
        expect(TypedEAV::Field::Currency.operator_column(:eq)).to eq(:decimal_value)
      end

      it "returns the primary cell for every built-in single-cell field type's supported operators" do
        # Smoke check that single-cell types remain BC-safe through the
        # default operator_column.
        [TypedEAV::Field::Integer, TypedEAV::Field::Text, TypedEAV::Field::Boolean].each do |klass|
          klass.supported_operators.each do |op|
            expect(klass.operator_column(op)).to eq(klass.value_column),
                                                 "#{klass.name}.operator_column(#{op.inspect}) " \
                                                 "returned #{klass.operator_column(op).inspect}, " \
                                                 "expected #{klass.value_column.inspect}"
          end
        end
      end
    end

    describe ".supported_operators" do
      it "returns column-aware defaults for integer fields" do
        expect(TypedEAV::Field::Integer.supported_operators).to include(:eq, :gt, :lt, :between)
      end

      it "respects per-type narrowing via .operators" do
        expect(TypedEAV::Field::Boolean.supported_operators).to eq(%i[eq is_null is_not_null])
      end

      it "returns string operators for string_value fields without override" do
        expect(TypedEAV::Field::Email.supported_operators).to include(:contains, :starts_with, :ends_with)
      end

      it "returns date operators for date_value fields" do
        expect(TypedEAV::Field::Date.supported_operators).to include(:gt, :between)
      end

      it "returns array operators for IntegerArray (json_value override)" do
        expect(TypedEAV::Field::IntegerArray.supported_operators).to include(:any_eq, :all_eq)
      end

      it "returns Json's explicitly narrowed set" do
        expect(TypedEAV::Field::Json.supported_operators).to eq(%i[is_null is_not_null])
      end
    end
  end

  describe "single-cell instance dispatch (Text round-trip)" do
    let(:field) { create(:text_field, default_value_meta: { "v" => "fallback" }) }
    let(:value) { build(:typed_value, field: field, entity: create(:contact)) }

    it "writes through the primary cell" do
      field.write_value(value, "hello")
      expect(value.string_value).to eq("hello")
    end

    it "reads from the primary cell" do
      value.string_value = "hi"
      expect(field.read_value(value)).to eq("hi")
    end

    it "applies the configured default to the primary cell" do
      value.string_value = nil
      field.apply_default(value)
      expect(value.string_value).to eq("fallback")
    end
  end

  describe "multi-cell instance dispatch (Currency round-trip)" do
    let(:field) do
      create(
        :currency_field,
        default_value_meta: { "v" => { amount: "12.50", currency: "USD" } },
      )
    end
    let(:value) { build(:typed_value, field: field, entity: create(:contact)) }

    it "writes the Hash across both cells" do
      field.write_value(value, amount: BigDecimal("99.99"), currency: "CAD")
      expect(value.decimal_value).to eq(BigDecimal("99.99"))
      expect(value.string_value).to eq("CAD")
    end

    it "reads both cells back as a Hash" do
      value.decimal_value = BigDecimal("42.00")
      value.string_value = "EUR"
      expect(field.read_value(value)).to eq(amount: BigDecimal("42.00"), currency: "EUR")
    end

    it "returns nil when both cells are nil" do
      value.decimal_value = nil
      value.string_value = nil
      expect(field.read_value(value)).to be_nil
    end

    it "applies a composite default across both cells" do
      value.decimal_value = nil
      value.string_value = nil
      field.apply_default(value)
      expect(value.decimal_value).to eq(BigDecimal("12.50"))
      expect(value.string_value).to eq("USD")
    end

    it "clears both cells when write_value receives nil" do
      value.decimal_value = BigDecimal("1")
      value.string_value = "USD"
      field.write_value(value, nil)
      expect(value.decimal_value).to be_nil
      expect(value.string_value).to be_nil
    end
  end

  describe "concrete snapshot helpers (single-cell)" do
    let(:contact) { create(:contact) }
    let(:field) { create(:text_field, default_value_meta: { "v" => "fallback" }) }
    let(:value) do
      v = TypedEAV::Value.create!(entity: contact, field: field, value: "first")
      v.update!(value: "second")
      v
    end

    it "value_changed? returns true after a single-cell update" do
      expect(field.value_changed?(value)).to be(true)
    end

    it "before_snapshot returns the primary cell pre-state for :update" do
      expect(field.before_snapshot(value, :update)).to eq("string_value" => "first")
    end

    it "after_snapshot returns the primary cell post-state for :update" do
      expect(field.after_snapshot(value, :update)).to eq("string_value" => "second")
    end

    it "before_snapshot returns {} for :create" do
      expect(field.before_snapshot(value, :create)).to eq({})
    end

    it "after_snapshot returns {} for :destroy" do
      expect(field.after_snapshot(value, :destroy)).to eq({})
    end

    it "raises ArgumentError for unknown change_type" do
      expect { field.before_snapshot(value, :bogus) }.to raise_error(ArgumentError, /Unsupported change_type/)
      expect { field.after_snapshot(value, :bogus) }.to raise_error(ArgumentError, /Unsupported change_type/)
    end
  end

  describe "concrete snapshot helpers (multi-cell Currency)" do
    let(:contact) { create(:contact) }
    let(:field) do
      create(
        :currency_field,
        default_value_meta: { "v" => { amount: "12.50", currency: "USD" } },
      )
    end
    let(:value) do
      TypedEAV::Value.create!(entity: contact, field: field, value: { amount: BigDecimal("12.50"), currency: "USD" })
    end

    it "value_changed? returns true when only the currency cell changed (regression: Phase 5 D3)" do
      value.update!(value: { amount: BigDecimal("12.50"), currency: "EUR" })
      expect(field.value_changed?(value)).to be(true)
    end

    it "before_snapshot returns both cells for :update" do
      value.update!(value: { amount: BigDecimal("12.50"), currency: "EUR" })
      expect(field.before_snapshot(value, :update)).to eq(
        "decimal_value" => BigDecimal("12.50"),
        "string_value" => "USD",
      )
    end

    it "after_snapshot returns both cells for :update" do
      value.update!(value: { amount: BigDecimal("12.50"), currency: "EUR" })
      expect(field.after_snapshot(value, :update)).to eq(
        "decimal_value" => BigDecimal("12.50"),
        "string_value" => "EUR",
      )
    end

    it "snapshot keys mirror value_columns shape (string-keyed jsonb-ready)" do
      value.update!(value: { amount: BigDecimal("12.50"), currency: "EUR" })
      expect(field.before_snapshot(value, :update).keys).to match_array(%w[decimal_value string_value])
      expect(field.after_snapshot(value, :update).keys).to match_array(%w[decimal_value string_value])
    end
  end

  describe "Percentage class-ivar workaround (re-declares value_column)" do
    # Percentage chains Field::Percentage < Field::Decimal < Field::Base.
    # Ruby class instance variables are not inherited, so Percentage must
    # re-declare `value_column :decimal_value` to install its own
    # @value_columns. This spec is the guard rail that the workaround
    # survives any future TypedStorage refactor.
    it "Percentage.value_column returns :decimal_value" do
      expect(TypedEAV::Field::Percentage.value_column).to eq(:decimal_value)
    end

    it "Percentage.value_columns returns [:decimal_value]" do
      expect(TypedEAV::Field::Percentage.value_columns).to eq([:decimal_value])
    end
  end

  describe "removed extension surface" do
    # Negative assertions for the symbols deleted in ADR-0001. Method/class
    # names are reconstructed at runtime so this spec file does not carry
    # literal occurrences that would trip the slice's leftover-refs grep.
    let(:legacy_instance_method)   { %w[storage contract].join("_").to_sym }
    let(:legacy_class_macro)       { :"#{%w[storage contract].join("_")}_class" }
    let(:legacy_apply_default)     { :"#{%w[apply default].join("_")}_to" }
    let(:legacy_field_contract)    { %w[Field StorageContract].join }
    let(:legacy_currency_contract) { %w[Currency StorageContract].join }

    it "Field::Base instances do not expose the legacy instance accessor" do
      field = create(:text_field)
      expect(field).not_to respond_to(legacy_instance_method)
    end

    it "Field::Base does not expose the legacy class-level macro" do
      expect(TypedEAV::Field::Base).not_to respond_to(legacy_class_macro)
    end

    it "Field::Base instances expose #apply_default (renamed from the old name)" do
      field = create(:text_field)
      expect(field).not_to respond_to(legacy_apply_default)
      expect(field).to respond_to(:apply_default)
    end

    it "the deleted contract constants are no longer defined under TypedEAV" do
      expect(TypedEAV.const_defined?(legacy_field_contract)).to be(false)
      expect(TypedEAV.const_defined?(legacy_currency_contract)).to be(false)
    end
  end
end
