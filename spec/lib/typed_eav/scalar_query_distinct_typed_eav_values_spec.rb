# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::ScalarQuery, ".distinct_typed_eav_values", :aggregate_failures do
  def create_value(entity, field, value)
    TypedEAV::Value.create!(entity: entity, field: field, value: value)
  end

  describe "Product.distinct_typed_eav_values" do
    let!(:rating_field) { create(:integer_field, name: "rating", entity_type: "Product") }
    let!(:first) { create(:product, title: "First") }
    let!(:second) { create(:product, title: "Second") }
    let!(:third) { create(:product, title: "Third") }
    let!(:explicit_null) { create(:product, title: "Explicit null") }
    let!(:missing) { create(:product, title: "Missing") }

    before do
      create_value(first, rating_field, 7)
      create_value(second, rating_field, 3)
      create_value(third, rating_field, 7)
      create_value(explicit_null, rating_field, nil)
    end

    it "returns bounded distinct values in native ascending order, including explicit NULL as nil" do
      expect(Product.distinct_typed_eav_values(:rating)).to eq([3, 7, nil])
    end

    it "applies caller filters and pagination before collecting distinct values" do
      relation = Product.where(id: [first.id, second.id, explicit_null.id, missing.id])
                        .order(id: :asc).limit(2).offset(1)

      expect(relation.distinct_typed_eav_values(:rating)).to eq([3, nil])
    end

    it "bounds the database result before transferring values to Ruby" do
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      result = nil
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        result = Product.distinct_typed_eav_values(:rating, limit: 2)
      end

      value_queries = queries.grep(/FROM "typed_eav_values"/i)
      expect(result).to eq([3, 7])
      expect(value_queries.size).to eq(1)
      expect(value_queries.first).to include("SELECT DISTINCT", "NULLS LAST")
      expect(value_queries.first).to match(/LIMIT \$?\d+/)
    end

    it "rejects limits outside the documented positive range" do
      [0, -1, 1_001, 1.5, nil].each do |invalid_limit|
        expect { Product.distinct_typed_eav_values(:rating, limit: invalid_limit) }
          .to raise_error(ArgumentError, /positive Integer.*1000/)
      end
    end
  end

  describe "Product.count_distinct_typed_eav_values" do
    let!(:rating_field) { create(:integer_field, name: "rating", entity_type: "Product") }
    let!(:first) { create(:product, title: "First") }
    let!(:second) { create(:product, title: "Second") }
    let!(:third) { create(:product, title: "Third") }
    let!(:explicit_null) { create(:product, title: "Explicit null") }
    let!(:missing) { create(:product, title: "Missing") }

    before do
      create_value(first, rating_field, 7)
      create_value(second, rating_field, 3)
      create_value(third, rating_field, 7)
      create_value(explicit_null, rating_field, nil)
    end

    it "counts distinct non-missing values and the explicit NULL category exactly" do
      expect(Product.count_distinct_typed_eav_values(:rating)).to eq(3)
      expect(Product.where(id: missing.id).count_distinct_typed_eav_values(:rating)).to eq(0)
    end

    it "counts in SQL without hydrating hosts or values" do
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
        result = Product.count_distinct_typed_eav_values(:rating)
      end

      expect(result).to eq(3)
      expect(host_instantiations).to eq(0)
      expect(value_instantiations).to eq(0)
      expect(queries.grep(/FROM "typed_eav_values"/i).size).to eq(1)
      expect(Product.where(id: -1).count_distinct_typed_eav_values(:rating)).to eq(0)
    end
  end

  describe "Product.typed_eav_value_counts" do
    let!(:rating_field) { create(:integer_field, name: "rating", entity_type: "Product") }
    let!(:extra_field_one) { create(:text_field, name: "extra_one", entity_type: "Product") }
    let!(:extra_field_two) { create(:text_field, name: "extra_two", entity_type: "Product") }
    let!(:first) { create(:product, title: "First") }
    let!(:second) { create(:product, title: "Second") }
    let!(:third) { create(:product, title: "Third") }
    let!(:explicit_null) { create(:product, title: "Explicit null") }
    let!(:missing) { create(:product, title: "Missing") }

    before do
      create_value(first, rating_field, 7)
      create_value(second, rating_field, 3)
      create_value(third, rating_field, 7)
      create_value(explicit_null, rating_field, nil)
      create_value(first, extra_field_one, "one")
      create_value(first, extra_field_two, "two")
    end

    it "returns an insertion-ordered value-to-host count hash including nil" do
      expect(Product.typed_eav_value_counts(:rating)).to eq({ 3 => 1, 7 => 2, nil => 1 })
      expect(Product.where(id: missing.id).typed_eav_value_counts(:rating)).to eq({})
    end

    it "deduplicates joined caller hosts before applying pagination" do
      relation = Product.joins(:typed_values).distinct.order(id: :asc).limit(2)

      expect(relation.typed_eav_value_counts(:rating)).to eq({ 3 => 1, 7 => 1 })
    end

    it "retains false and empty scalar values while omitting missing rows" do
      active_field = create(:boolean_field, name: "active", entity_type: "Product")
      label_field = create(:text_field, name: "label", entity_type: "Product")
      false_product = create(:product, title: "False")
      true_product = create(:product, title: "True")
      empty_product = create(:product, title: "Empty")
      null_product = create(:product, title: "Null")
      missing_product = create(:product, title: "Missing")

      create_value(false_product, active_field, false)
      create_value(true_product, active_field, true)
      create_value(null_product, active_field, nil)
      create_value(empty_product, label_field, "")
      create_value(null_product, label_field, nil)

      expect(Product.distinct_typed_eav_values(:active)).to eq([false, true, nil])
      expect(Product.typed_eav_value_counts(:active)).to eq({ false => 1, true => 1, nil => 1 })
      expect(Product.distinct_typed_eav_values(:label)).to eq(["", nil])
      expect(Product.typed_eav_value_counts(:label)).to eq({ "" => 1, nil => 1 })
      expect(Product.where(id: missing_product.id).distinct_typed_eav_values(:active)).to eq([])
    end

    it "returns an empty hash for an empty caller relation" do
      expect(Product.where(id: -1).typed_eav_value_counts(:rating)).to eq({})
    end

    it "enforces the documented limit range for grouped counts" do
      [0, 1_001, 1.5, nil].each do |invalid_limit|
        expect { Product.typed_eav_value_counts(:rating, limit: invalid_limit) }
          .to raise_error(ArgumentError, /positive Integer.*1000/)
      end
    end
  end

  describe "scope resolution" do
    it "uses the selected partition definition for all distinct query APIs" do
      global = create(:integer_field, name: "partition_rating", entity_type: "Contact")
      scoped = create(:integer_field, name: "partition_rating", entity_type: "Contact", scope: "tenant-1")
      global_contact = create(:contact, name: "Global", tenant_id: "tenant-1")
      scoped_contact = create(:contact, name: "Scoped", tenant_id: "tenant-1")
      create_value(global_contact, global, 90)
      create_value(scoped_contact, scoped, 10)

      expect(Contact.distinct_typed_eav_values(:partition_rating, scope: "tenant-1")).to eq([10])
      expect(Contact.count_distinct_typed_eav_values(:partition_rating, scope: "tenant-1")).to eq(1)
      expect(Contact.typed_eav_value_counts(:partition_rating, scope: "tenant-1")).to eq({ 10 => 1 })
    end

    it "resolves an ambient partition for all distinct query APIs" do
      field = create(:integer_field, name: "ambient_rating", entity_type: "Contact", scope: "tenant-1")
      contact = create(:contact, tenant_id: "tenant-1")
      create_value(contact, field, 11)

      values = TypedEAV.with_scope("tenant-1") { Contact.distinct_typed_eav_values(:ambient_rating) }
      count = TypedEAV.with_scope("tenant-1") { Contact.count_distinct_typed_eav_values(:ambient_rating) }
      groups = TypedEAV.with_scope("tenant-1") { Contact.typed_eav_value_counts(:ambient_rating) }

      expect(values).to eq([11])
      expect(count).to eq(1)
      expect(groups).to eq({ 11 => 1 })
    end
  end

  describe "validation" do
    it "rejects collection and multi-cell fields for every distinct query API" do
      create(:integer_array_field, name: "tags", entity_type: "Contact")
      create(:currency_field, name: "money", entity_type: "Contact")

      [
        -> { Contact.distinct_typed_eav_values(:tags, scope: nil) },
        -> { Contact.count_distinct_typed_eav_values(:tags, scope: nil) },
        -> { Contact.typed_eav_value_counts(:tags, scope: nil) },
        -> { Contact.distinct_typed_eav_values(:money, scope: nil) },
        -> { Contact.count_distinct_typed_eav_values(:money, scope: nil) },
        -> { Contact.typed_eav_value_counts(:money, scope: nil) },
      ].each do |query|
        expect(&query).to raise_error(ArgumentError, /scalar/i)
      end
    end

    it "rejects ambiguous all-partition lookups for every distinct query API" do
      create(:integer_field, name: "ambiguous_rating", entity_type: "Contact", scope: "tenant-1")
      create(:integer_field, name: "ambiguous_rating", entity_type: "Contact", scope: "tenant-2")

      [
        -> { Contact.distinct_typed_eav_values(:ambiguous_rating) },
        -> { Contact.count_distinct_typed_eav_values(:ambiguous_rating) },
        -> { Contact.typed_eav_value_counts(:ambiguous_rating) },
      ].each do |query|
        expect { TypedEAV.unscoped(&query) }
          .to raise_error(ArgumentError, /all partitions|ambiguous/i)
      end
    end
  end

  describe "STI host identity" do
    let!(:score_field) { create(:integer_field, name: "sti_rating", entity_type: "Contact") }
    let!(:premium) { PremiumContact.create!(name: "Premium", tenant_id: nil) }
    let!(:sibling_class) { stub_const("SiblingDistinctContact", Class.new(Contact)) }
    let!(:sibling) { sibling_class.create!(name: "Sibling", tenant_id: nil) }
    let!(:base) { Contact.create!(name: "Base", tenant_id: nil) }

    before do
      create_value(premium, score_field, 7)
      create_value(sibling, score_field, 8)
      create_value(base, score_field, 9)
    end

    it "restricts distinct values and grouped counts to the requested STI class" do
      expect(PremiumContact.distinct_typed_eav_values(:sti_rating, scope: nil)).to eq([7])
      expect(PremiumContact.count_distinct_typed_eav_values(:sti_rating, scope: nil)).to eq(1)
      expect(PremiumContact.typed_eav_value_counts(:sti_rating, scope: nil)).to eq({ 7 => 1 })
    end
  end
end
