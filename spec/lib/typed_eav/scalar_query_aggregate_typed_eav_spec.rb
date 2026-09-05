# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/ExampleLength -- SQL instrumentation verifies the public aggregate query contract in one slice.
RSpec.describe TypedEAV::ScalarQuery, ".aggregate_typed_eav", :aggregate_failures do
  def create_value(entity, field, value)
    TypedEAV::Value.create!(entity: entity, field: field, value: value)
  end

  describe "integer aggregates" do
    let!(:measure_field) { create(:integer_field, name: "measure", entity_type: "Product") }
    let!(:extra_field) { create(:text_field, name: "extra", entity_type: "Product") }
    let!(:negative) { create(:product, title: "Negative") }
    let!(:zero) { create(:product, title: "Zero") }
    let!(:positive) { create(:product, title: "Positive") }
    let!(:explicit_null) { create(:product, title: "Explicit null") }
    let!(:missing) { create(:product, title: "Missing") }

    before do
      create_value(negative, measure_field, -5)
      create_value(zero, measure_field, 0)
      create_value(positive, measure_field, 10)
      create_value(explicit_null, measure_field, nil)
      create_value(negative, extra_field, "duplicate join row")
    end

    it "returns min, max, and sum from SQL while preserving integer values" do
      expect(Product.aggregate_typed_eav(:measure, operation: :min)).to eq(-5)
      expect(Product.aggregate_typed_eav(:measure, operation: :max)).to eq(10)
      expect(Product.aggregate_typed_eav(:measure, operation: :sum)).to eq(5)
      expect(Product.where(id: missing.id).aggregate_typed_eav(:measure, operation: :min)).to be_nil
      expect(Product.where(id: missing.id).aggregate_typed_eav(:measure, operation: :max)).to be_nil
      expect(Product.where(id: missing.id).aggregate_typed_eav(:measure, operation: :sum)).to eq(0)
    end

    it "preserves caller filters and paginated distinct joins in the aggregate host set" do
      relation = Product.joins(:typed_values).distinct.order(id: :asc).limit(2)

      expect(relation.aggregate_typed_eav(:measure, operation: :min)).to eq(-5)
      expect(relation.aggregate_typed_eav(:measure, operation: :max)).to eq(0)
      expect(relation.aggregate_typed_eav(:measure, operation: :sum)).to eq(-5)
      expect(Product.where(id: positive.id).aggregate_typed_eav(:measure, operation: :sum)).to eq(10)
    end

    it "executes the aggregate in SQL without hydrating hosts or values" do
      queries = []
      value_instantiations = 0
      host_instantiations = 0
      value_instantiate = TypedEAV::Value.method(:instantiate)
      host_instantiate = Product.method(:instantiate)
      allow(TypedEAV::Value).to receive(:instantiate) do |*args|
        value_instantiations += 1
        value_instantiate.call(*args)
      end
      allow(Product).to receive(:instantiate) do |*args|
        host_instantiations += 1
        host_instantiate.call(*args)
      end
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      result = nil
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        result = Product.aggregate_typed_eav(:measure, operation: :sum)
      end

      aggregate_queries = queries.grep(/FROM "typed_eav_values"/i)
      expect(result).to eq(5)
      expect(host_instantiations).to eq(0)
      expect(value_instantiations).to eq(0)
      expect(aggregate_queries.size).to eq(1)
      expect(aggregate_queries.first).to include("SUM", "integer_value")
    end
  end

  describe "decimal aggregates" do
    let!(:measure_field) { create(:decimal_field, name: "decimal_measure", entity_type: "Product") }
    let!(:large) { create(:product, title: "Large") }
    let!(:small) { create(:product, title: "Small") }
    let!(:empty_relation) { Product.where(id: -1) }

    before do
      create_value(large, measure_field, BigDecimal("123456789012345.6789012345"))
      create_value(small, measure_field, BigDecimal("-0.6789012345"))
    end

    it "preserves BigDecimal precision and returns a decimal zero for an empty sum" do
      minimum = Product.aggregate_typed_eav(:decimal_measure, operation: :min)
      maximum = Product.aggregate_typed_eav(:decimal_measure, operation: :max)
      total = Product.aggregate_typed_eav(:decimal_measure, operation: :sum)
      empty_total = empty_relation.aggregate_typed_eav(:decimal_measure, operation: :sum)

      expect(minimum).to eq(BigDecimal("-0.6789012345"))
      expect(maximum).to eq(BigDecimal("123456789012345.6789012345"))
      expect(total).to eq(BigDecimal("123456789012345.0000000000"))
      expect([minimum, maximum, total, empty_total]).to all(be_a(BigDecimal))
      expect(empty_total).to eq(BigDecimal("0"))
    end
  end

  describe "percentage aggregates" do
    let!(:percentage_field) { create(:percentage_field, name: "completion", entity_type: "Contact") }
    let!(:first) { create(:contact, name: "First") }
    let!(:second) { create(:contact, name: "Second") }

    before do
      create_value(first, percentage_field, BigDecimal("0.25"))
      create_value(second, percentage_field, BigDecimal("0.50"))
    end

    it "treats Percentage as a decimal numeric family" do
      expect(Contact.aggregate_typed_eav(:completion, operation: :min, scope: nil)).to eq(BigDecimal("0.25"))
      expect(Contact.aggregate_typed_eav(:completion, operation: :max, scope: nil)).to eq(BigDecimal("0.50"))
      expect(Contact.aggregate_typed_eav(:completion, operation: :sum, scope: nil)).to eq(BigDecimal("0.75"))
    end
  end

  describe "scope and STI resolution" do
    it "selects the visible partition definition for numeric aggregates" do
      global = create(:integer_field, name: "partition_measure", entity_type: "Contact")
      scoped = create(:integer_field, name: "partition_measure", entity_type: "Contact", scope: "tenant-1")
      global_contact = create(:contact, name: "Global", tenant_id: "tenant-1")
      scoped_contact = create(:contact, name: "Scoped", tenant_id: "tenant-1")
      create_value(global_contact, global, 90)
      create_value(scoped_contact, scoped, 10)

      expect(Contact.aggregate_typed_eav(:partition_measure, operation: :min, scope: "tenant-1")).to eq(10)
      expect(Contact.aggregate_typed_eav(:partition_measure, operation: :max, scope: "tenant-1")).to eq(10)
      expect(Contact.aggregate_typed_eav(:partition_measure, operation: :sum, scope: "tenant-1")).to eq(10)
    end

    it "restricts numeric aggregates to the requested STI class" do
      field = create(:integer_field, name: "sti_measure", entity_type: "Contact")
      premium = PremiumContact.create!(name: "Premium", tenant_id: nil)
      sibling_class = stub_const("SiblingAggregateContact", Class.new(Contact))
      sibling = sibling_class.create!(name: "Sibling", tenant_id: nil)
      base = Contact.create!(name: "Base", tenant_id: nil)
      create_value(premium, field, 7)
      create_value(sibling, field, 8)
      create_value(base, field, 9)

      expect(PremiumContact.aggregate_typed_eav(:sti_measure, operation: :min, scope: nil)).to eq(7)
      expect(PremiumContact.aggregate_typed_eav(:sti_measure, operation: :max, scope: nil)).to eq(7)
      expect(PremiumContact.aggregate_typed_eav(:sti_measure, operation: :sum, scope: nil)).to eq(7)
    end
  end

  describe "validation" do
    it "accepts only min, max, and sum operations" do
      create(:integer_field, name: "measure", entity_type: "Product")

      expect { Product.aggregate_typed_eav(:measure) }
        .to raise_error(ArgumentError, /missing keyword.*operation/i)
      expect { Product.aggregate_typed_eav(:measure, operation: :average) }
        .to raise_error(ArgumentError, /operation.*min.*max.*sum/i)
    end

    it "rejects references, text, collections, and multi-cell fields" do
      create(:text_field, name: "label", entity_type: "Product")
      create(:reference_field, name: "reference", entity_type: "Contact")
      create(:integer_array_field, name: "tags", entity_type: "Contact")
      create(:currency_field, name: "money", entity_type: "Contact")

      expect { Product.aggregate_typed_eav(:label, operation: :min) }
        .to raise_error(ArgumentError, /numeric/i)
      expect { Contact.aggregate_typed_eav(:reference, operation: :min, scope: nil) }
        .to raise_error(ArgumentError, /numeric/i)
      expect { Contact.aggregate_typed_eav(:tags, operation: :min, scope: nil) }
        .to raise_error(ArgumentError, /numeric/i)
      expect { Contact.aggregate_typed_eav(:money, operation: :min, scope: nil) }
        .to raise_error(ArgumentError, /numeric/i)
    end

    it "fails clearly when all-partition numeric definitions are ambiguous" do
      create(:integer_field, name: "ambiguous_measure", entity_type: "Contact", scope: "tenant-1")
      create(:integer_field, name: "ambiguous_measure", entity_type: "Contact", scope: "tenant-2")

      expect { TypedEAV.unscoped { Contact.aggregate_typed_eav(:ambiguous_measure, operation: :min) } }
        .to raise_error(ArgumentError, /all partitions|ambiguous/i)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
