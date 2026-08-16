# frozen_string_literal: true

# The filename is a public task artifact; its examples cover the shared seam.
# rubocop:disable RSpec/SpecFilePathFormat

require "spec_helper"

RSpec.describe TypedEAV::Field::TypedStorage do
  let(:integer_field) { build(:integer_field, name: "query_integer") }

  it "uses write casting for scalar operands and rejects invalid values" do
    expect(integer_field.cast_query_operand(:eq, "12")).to eq(12)
    expect { integer_field.cast_query_operand(:eq, 3.7) }.to raise_error(ArgumentError, /Invalid/)
  end

  it "requires exactly two between bounds and casts each endpoint" do
    expect(integer_field.cast_query_operand(:between, %w[1 4])).to eq(1..4)
    expect { integer_field.cast_query_operand(:between, [1, 2, 3]) }.to raise_error(ArgumentError, /between/)
  end

  it "normalizes array operands through the field caster" do
    field = build(:integer_array_field, name: "query_integer_array")

    expect(field.cast_query_operand(:any_eq, "4")).to eq(4)
    expect(field.cast_query_operand(:all_eq, %w[4 5])).to eq([4, 5])
    expect { field.cast_query_operand(:all_eq, "4") }.to raise_error(ArgumentError, /all_eq/)
  end
end

# rubocop:enable RSpec/SpecFilePathFormat
