# frozen_string_literal: true

require "spec_helper"
require "csv"

RSpec.describe TypedEAV::CSVMapper do
  # Build Field instances directly (no DB persistence required) — `field.cast`
  # is a pure function on the field's per-type configuration. The mapper never
  # reads `field.id` / `field.persisted?`, so unsaved Field rows work for
  # exercising the cast path. This keeps the spec fast and free of DB writes.
  let(:name_field) { TypedEAV::Field::Text.new(name: "name", entity_type: "Contact", options: {}) }
  let(:age_field)  { TypedEAV::Field::Integer.new(name: "age", entity_type: "Contact", options: {}) }
  let(:price_field) { TypedEAV::Field::Decimal.new(name: "price", entity_type: "Contact", options: {}) }

  let(:fields_by_name) do
    { "name" => name_field, "age" => age_field, "price" => price_field }
  end

  describe ".row_to_attributes" do
    context "with header-mapped CSV::Row (typed mode)" do
      it "casts each cell through field.cast and returns success" do
        row     = CSV::Row.new(%w[Name Age], %w[Alice 30])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => 30)
        expect(result.errors).to eq({})
      end
    end

    context "with index-mapped Array (typed mode)" do
      it "reads cells by Integer index and casts through field.cast" do
        row     = %w[Alice 30]
        mapping = { 0 => :name, 1 => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => 30)
        expect(result.errors).to eq({})
      end
    end

    context "with passthrough mode (2-arg form, no fields_by_name)" do
      # Honors CONTEXT line 13 + ROADMAP §Phase 6 2-arg public signature.
      # Raw cell values flow through unchanged keyed by mapped field name —
      # no `field.cast` invocation, no errors possible.
      it "preserves raw cell values verbatim and returns success" do
        row     = CSV::Row.new(%w[Name Age], %w[Alice 30])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => "30")
        expect(result.errors).to eq({})
      end

      it "preserves raw values for index-mapped Array passthrough" do
        row     = %w[Alice 30]
        mapping = { 0 => :name, 1 => :age }

        result = described_class.row_to_attributes(row, mapping)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => "30")
      end
    end

    context "with empty cell (typed mode)" do
      # Per `field.cast` tuple contract: nil/empty → [nil, false]. Empty cells
      # produce attributes[name] = nil and NO error.
      it "treats nil cells as nil with no error" do
        row     = CSV::Row.new(%w[Name Age], ["Alice", nil])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => nil)
        expect(result.errors).to eq({})
      end

      it "treats empty-string cells as nil with no error" do
        row     = CSV::Row.new(%w[Name Age], ["Alice", ""])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => nil)
        expect(result.errors).to eq({})
      end
    end

    context "with passthrough mode + empty cell" do
      it "preserves nil cell verbatim" do
        row     = CSV::Row.new(%w[Name Age], ["Alice", nil])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice", "age" => nil)
        expect(result.errors).to eq({})
      end
    end

    context "with cast failure (typed mode)" do
      it "adds 'is invalid' under the field name in errors and marks failure" do
        row     = CSV::Row.new(%w[Name Age], %w[Alice not-a-number])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_failure
        expect(result.errors).to eq("age" => ["is invalid"])
        # `attributes` for the bad cell is intentionally not populated — the
        # cast invalid path skips the assignment.
        expect(result.attributes).to eq("name" => "Alice")
      end
    end

    context "with multiple errors per row (typed mode)" do
      it "aggregates one error entry per failing field" do
        row     = CSV::Row.new(%w[Name Age Price], ["Alice", "not-a-number", "not-a-number"])
        mapping = { "Name" => :name, "Age" => :age, "Price" => :price }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_failure
        # Order-independent assertion via to_h equality on the keys we care about.
        expect(result.errors).to eq(
          "age" => ["is invalid"],
          "price" => ["is invalid"],
        )
        expect(result.attributes).to eq("name" => "Alice")
      end
    end

    context "with unknown field in mapping (typed mode)" do
      # Mapper is a pure transform; mapping misconfiguration is a caller
      # concern. Caller can compare `result.attributes.keys` against expected
      # fields to detect misconfiguration if needed.
      it "silently skips cells whose mapped name has no matching Field" do
        row     = CSV::Row.new(%w[Name Unknown], %w[Alice payload])
        mapping = { "Name" => :name, "Unknown" => :nonexistent_field }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result).to be_success
        expect(result.attributes).to eq("name" => "Alice")
        expect(result.errors).to eq({})
      end
    end

    context "with mixed-key mapping (String + Integer)" do
      it "raises ArgumentError immediately with a remediation message" do
        row     = CSV::Row.new(%w[Name Age], %w[Alice 30])
        mapping = { "Name" => :name, 1 => :age }

        expect do
          described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)
        end.to raise_error(ArgumentError, /must use either all String keys.*or all Integer keys/m)
      end

      it "raises in passthrough mode (2-arg form) too" do
        row     = %w[Alice 30]
        mapping = { "Name" => :name, 1 => :age }

        expect do
          described_class.row_to_attributes(row, mapping)
        end.to raise_error(ArgumentError, /must use either all String keys.*or all Integer keys/m)
      end
    end

    context "with symbol-vs-string field-name values" do
      it "treats `{header => :name}` and `{header => 'name'}` as equivalent" do
        row = CSV::Row.new(%w[Name], ["Alice"])
        mapping_sym = { "Name" => :name }
        mapping_str = { "Name" => "name" }

        result_sym = described_class.row_to_attributes(row, mapping_sym, fields_by_name: fields_by_name)
        result_str = described_class.row_to_attributes(row, mapping_str, fields_by_name: fields_by_name)

        expect(result_sym.attributes).to eq("name" => "Alice")
        expect(result_str.attributes).to eq("name" => "Alice")
      end

      it "uses string-coerced field name in passthrough mode regardless of mapping value type" do
        row = CSV::Row.new(%w[Name], ["Alice"])

        sym_result = described_class.row_to_attributes(row, { "Name" => :name })
        str_result = described_class.row_to_attributes(row, { "Name" => "name" })

        expect(sym_result.attributes).to eq("name" => "Alice")
        expect(str_result.attributes).to eq("name" => "Alice")
      end
    end

    context "with Result frozen invariants" do
      it "freezes both Hashes on the returned Result" do
        row     = CSV::Row.new(%w[Name Age], %w[Alice 30])
        mapping = { "Name" => :name, "Age" => :age }

        result = described_class.row_to_attributes(row, mapping, fields_by_name: fields_by_name)

        expect(result.attributes).to be_frozen
        expect(result.errors).to be_frozen
      end
    end
  end

  describe TypedEAV::CSVMapper::Result do
    it "is success when errors is empty" do
      r = described_class.new(attributes: {}, errors: {})
      expect(r.success?).to be true
      expect(r.failure?).to be false
    end

    it "is failure when errors has any entry" do
      r = described_class.new(attributes: {}, errors: { "x" => ["bad"] })
      expect(r.success?).to be false
      expect(r.failure?).to be true
    end

    it "freezes attributes and errors on construction" do
      r = described_class.new(attributes: { "a" => 1 }, errors: {})
      expect(r.attributes).to be_frozen
      expect(r.errors).to be_frozen
    end

    it "exposes attr_readers for attributes and errors" do
      r = described_class.new(attributes: { "k" => "v" }, errors: { "f" => ["bad"] })
      expect(r.attributes).to eq("k" => "v")
      expect(r.errors).to eq("f" => ["bad"])
    end
  end
end
