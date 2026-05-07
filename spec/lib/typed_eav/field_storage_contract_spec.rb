# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::FieldStorageContract, :unscoped do
  describe "single-cell fields" do
    it "describes value cells, logical reads/writes, defaults, query routing, snapshots, and change detection" do
      field = create(:text_field, default_value_meta: { "v" => "fallback" })
      value = build(:typed_value, field: field, entity: create(:contact))

      contract = field.storage_contract

      expect(contract.value_columns).to eq([:string_value])
      expect(contract.query_column(:eq)).to eq(:string_value)

      contract.write(value, "hello")
      expect(value.string_value).to eq("hello")
      expect(contract.read(value)).to eq("hello")

      value.string_value = nil
      contract.apply_default(value)
      expect(value.string_value).to eq("fallback")

      value.save!
      value.update!(value: "changed")

      expect(contract.changed?(value)).to be(true)
      expect(contract.before_snapshot(value, :update)).to eq("string_value" => "fallback")
      expect(contract.after_snapshot(value, :update)).to eq("string_value" => "changed")
    end
  end

  describe "multi-cell fields" do
    let(:field) do
      create(
        :currency_field,
        default_value_meta: { "v" => { amount: "12.50", currency: "USD" } },
      )
    end
    let(:value) { build(:typed_value, field: field, entity: create(:contact)) }
    let(:contract) { field.storage_contract }

    it "uses the Currency-specific storage contract" do
      expect(contract).to be_a(TypedEAV::CurrencyStorageContract)
    end

    it "keeps Currency's multi-cell instance storage details on the contract" do
      expect(TypedEAV::Field::Currency.instance_methods(false)).not_to include(
        :read_value,
        :write_value,
        :apply_default_to,
      )
    end

    it "describes Currency cells, query routing, and logical reads/writes" do
      expect(contract.value_columns).to eq(%i[decimal_value string_value])
      expect(contract.query_column(:eq)).to eq(:decimal_value)
      expect(contract.query_column(:currency_eq)).to eq(:string_value)

      contract.write(value, amount: BigDecimal("99.99"), currency: "CAD")
      expect(value.decimal_value).to eq(BigDecimal("99.99"))
      expect(value.string_value).to eq("CAD")
      expect(contract.read(value)).to eq(amount: BigDecimal("99.99"), currency: "CAD")
    end

    it "applies Currency defaults, snapshots both cells, and detects updates" do
      value.decimal_value = nil
      value.string_value = nil
      contract.apply_default(value)
      expect(value.decimal_value).to eq(BigDecimal("12.50"))
      expect(value.string_value).to eq("USD")

      value.save!
      value.update!(value: { amount: "12.50", currency: "EUR" })

      expect(contract.changed?(value)).to be(true)
      expect(contract.before_snapshot(value, :update)).to eq(
        "decimal_value" => BigDecimal("12.50"),
        "string_value" => "USD",
      )
      expect(contract.after_snapshot(value, :update)).to eq(
        "decimal_value" => BigDecimal("12.50"),
        "string_value" => "EUR",
      )
    end
  end
end
