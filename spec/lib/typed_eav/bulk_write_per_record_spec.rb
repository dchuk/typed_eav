# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/LetSetup, RSpec/AnyInstance -- bulk_set_typed_eav_values_per_record is a class-method API on host models (no single class to describe); let! field/record records are referenced indirectly via the bulk method's name lookup so the cop's static analysis can't see the connection; allow_any_instance_of is used to inject deterministic save failures across all records of a class for the savepoint-isolation specs.

require "spec_helper"

# G1 (issue #18) — `Entity.bulk_set_typed_eav_values_per_record` is the
# per-record-varying sibling to `bulk_set_typed_eav_values`. Takes a
# `Hash<host_record, Hash<field_name_string, value>>` and routes each
# record's value-set through the same outer-transaction-plus-savepoint
# envelope, with the same `{ successes: [...], errors_by_record: {...} }`
# return shape.
RSpec.describe "Entity.bulk_set_typed_eav_values_per_record" do
  # ────────────────────────────────────────────────────────────
  # Happy path — versioning off
  # ────────────────────────────────────────────────────────────
  describe "happy path" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice) { create(:contact, name: "Alice", tenant_id: "tenant_1") }
    let!(:bob)   { create(:contact, name: "Bob",   tenant_id: "tenant_1") }

    it "writes per-record values; each record gets its own value hash" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record(
          { alice => { "name" => "Alice2", "age" => 31 },
            bob => { "name" => "Bob2", "age" => 42 } },
        )
      end

      expect(result[:successes]).to contain_exactly(alice, bob)
      expect(result[:errors_by_record]).to eq({})

      expect(alice.reload.typed_eav_hash).to eq("name" => "Alice2", "age" => 31)
      expect(bob.reload.typed_eav_hash).to eq("name" => "Bob2", "age" => 42)
    end

    it "accepts symbol keys inside per-record value hashes" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { name: "A2", age: 22 } })
      end

      expect(result[:successes]).to eq([alice])
      expect(alice.reload.typed_eav_hash).to eq("name" => "A2", "age" => 22)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Failure isolation
  # ────────────────────────────────────────────────────────────
  describe "failure isolation (savepoint-per-record)" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    it "rolls back only the failing record's savepoint; others commit" do
      original_save = Contact.instance_method(:save)
      allow_any_instance_of(Contact).to receive(:save).and_wrap_original do |orig|
        receiver = orig.receiver
        if receiver == bob
          receiver.errors.add(:base, "deliberately rejected for spec")
          false
        else
          original_save.bind(receiver).call
        end
      end

      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record(
          { alice => { "age" => 11 },
            bob => { "age" => 22 },
            charlie => { "age" => 33 } },
        )
      end

      expect(result[:successes]).to contain_exactly(alice, charlie)
      expect(result[:errors_by_record].keys).to eq([bob])
      expect(result[:errors_by_record][bob]).to have_key("base")

      expect(alice.reload.typed_eav_hash).to eq("age" => 11)
      expect(charlie.reload.typed_eav_hash).to eq("age" => 33)
      expect(TypedEAV::Value.where(entity_type: "Contact", entity_id: bob.id).count).to eq(0)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Thread-local memo lifecycle
  # ────────────────────────────────────────────────────────────
  describe "thread-local definition memo lifecycle" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)     { create(:contact, name: "Alice", tenant_id: "tenant_1") }

    it "populates the memo during the call and clears it afterward" do
      observed_memo = nil
      original_save = TypedEAV::BulkWrite.method(:apply_record_save)
      allow(TypedEAV::BulkWrite).to receive(:apply_record_save) do |**kwargs|
        observed_memo = Thread.current[:typed_eav_bulk_defs_memo]&.dup
        original_save.call(**kwargs)
      end

      expect(Thread.current[:typed_eav_bulk_defs_memo]).to be_nil

      TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { "age" => 99 } })
      end

      expect(observed_memo).to be_a(Hash) # populated during call
      expect(Thread.current[:typed_eav_bulk_defs_memo]).to be_nil # cleared after
    end
  end

  # ────────────────────────────────────────────────────────────
  # Empty input — no transaction opened
  # ────────────────────────────────────────────────────────────
  describe "empty input" do
    it "returns the empty result shape without opening a transaction" do
      transactions_observed = []
      callback = lambda do |_, _, _, _, payload|
        transactions_observed << payload[:sql] if payload[:sql] =~ /\A(BEGIN|SAVEPOINT)/i
      end

      result = nil
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        result = Contact.bulk_set_typed_eav_values_per_record({})
      end

      expect(result).to eq(successes: [], errors_by_record: {})
      expect(transactions_observed).to be_empty
    end
  end

  # ────────────────────────────────────────────────────────────
  # Input validation
  # ────────────────────────────────────────────────────────────
  describe "input validation" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)     { create(:contact, tenant_id: "tenant_1") }

    it "raises ArgumentError when values_by_record is not a Hash" do
      expect { Contact.bulk_set_typed_eav_values_per_record([alice]) }
        .to raise_error(ArgumentError, /bulk_set_typed_eav_values_per_record.*requires a Hash/)
    end

    it "raises ArgumentError when a key is not an instance of host_class", :unscoped do
      product = create(:product, title: "X")
      expect { Contact.bulk_set_typed_eav_values_per_record({ product => {} }) }
        .to raise_error(ArgumentError, /bulk_set_typed_eav_values_per_record.*expects records of class Contact/)
    end

    it "raises ArgumentError when a value is not a Hash" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record({ alice => "not a hash" })
        end
      end.to raise_error(ArgumentError, /bulk_set_typed_eav_values_per_record.*per-record value.*must be a Hash/)
    end

    it "raises ArgumentError on unknown version_grouping" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record({ alice => { "age" => 1 } }, version_grouping: :per_galaxy)
        end
      end.to raise_error(ArgumentError, /not supported/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Sparse-update semantic — unlisted fields untouched
  # ────────────────────────────────────────────────────────────
  describe "sparse-update semantic" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)      { create(:contact, name: "Alice", tenant_id: "tenant_1") }

    it "leaves unlisted fields' values untouched on subsequent calls" do
      TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { "name" => "First", "age" => 21 } })
      end
      expect(alice.reload.typed_eav_hash).to eq("name" => "First", "age" => 21)

      # Second call: only "name" — "age" must remain untouched.
      TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { "name" => "Second" } })
      end
      expect(alice.reload.typed_eav_hash).to eq("name" => "Second", "age" => 21)
    end
  end

  # ────────────────────────────────────────────────────────────
  # _destroy: true semantic
  # ────────────────────────────────────────────────────────────
  describe "_destroy semantic" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)      { create(:contact, name: "Alice", tenant_id: "tenant_1") }

    it "removes the typed_value row when the per-field value is { _destroy: true }" do
      TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { "name" => "Keep", "age" => 7 } })
      end
      expect(alice.reload.typed_eav_hash).to eq("name" => "Keep", "age" => 7)

      TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values_per_record({ alice => { "age" => { _destroy: true } } })
      end

      expect(alice.reload.typed_eav_hash).to eq("name" => "Keep")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Mixed-scope records — different partitions in one call
  # ────────────────────────────────────────────────────────────
  describe "mixed-scope records", :unscoped do
    let!(:age_field_t1) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field_t2) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_2") }
    let!(:alice)        { create(:contact, name: "Alice", tenant_id: "tenant_1") }
    let!(:bob)          { create(:contact, name: "Bob",   tenant_id: "tenant_2") }

    it "honors each record's own scope when records span multiple partitions" do
      result = Contact.bulk_set_typed_eav_values_per_record(
        { alice => { "age" => 10 },
          bob => { "age" => 20 } },
      )

      expect(result[:successes]).to contain_exactly(alice, bob)
      expect(result[:errors_by_record]).to eq({})

      # Alice's "age" Value points at tenant_1's field; Bob's at tenant_2's.
      alice_value = TypedEAV::Value.find_by(entity_type: "Contact", entity_id: alice.id)
      bob_value   = TypedEAV::Value.find_by(entity_type: "Contact", entity_id: bob.id)
      expect(alice_value.field_id).to eq(age_field_t1.id)
      expect(bob_value.field_id).to eq(age_field_t2.id)
      expect(alice_value.value).to eq(10)
      expect(bob_value.value).to eq(20)
    end
  end

  # ────────────────────────────────────────────────────────────
  # version_grouping when versioning is ON
  # ────────────────────────────────────────────────────────────
  describe "version_grouping when versioning is ON", :event_callbacks, :real_commits do
    before do
      TypedEAV.config.versioning = true
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::EventDispatcher.register_internal_value_change(
        TypedEAV::Versioning::Subscriber.method(:call),
      )
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:city_field) { create(:text_field, name: "city", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    describe ":per_record (default when versioning is on)" do
      it "stamps one UUID per record across that record's version rows" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record(
            { alice => { "name" => "A", "age" => 1 },
              bob => { "name" => "B", "age" => 2 } },
          )
        end

        [alice, bob].each do |c|
          rows = TypedEAV::ValueVersion.where(entity_id: c.id)
          expect(rows.count).to eq(2)
          expect(rows.distinct.pluck(:version_group_id).size).to eq(1)
        end

        alice_uuid = TypedEAV::ValueVersion.where(entity_id: alice.id).pick(:version_group_id)
        bob_uuid   = TypedEAV::ValueVersion.where(entity_id: bob.id).pick(:version_group_id)
        expect(alice_uuid).not_to eq(bob_uuid)
      end
    end

    describe ":per_field UNION semantic" do
      it "shares a UUID for an overlapping field across records, and allocates fresh UUIDs for non-shared fields" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record(
            { alice => { "name" => "A", "age" => 1 },
              bob => { "name" => "B", "city" => "Portland" } },
            version_grouping: :per_field,
          )
        end

        rows = TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id]).includes(:field)
        rows_by_name = rows.group_by { |v| v.field.name }
        expect(rows_by_name.keys).to match_array(%w[name age city])

        # "name" is shared across alice + bob — both rows share one UUID.
        name_uuids = rows_by_name["name"].map(&:version_group_id).uniq
        expect(name_uuids.size).to eq(1)

        # "age" only on alice — one row, one distinct UUID.
        age_uuids = rows_by_name["age"].map(&:version_group_id).uniq
        expect(age_uuids.size).to eq(1)

        # "city" only on bob — one row, one distinct UUID.
        city_uuids = rows_by_name["city"].map(&:version_group_id).uniq
        expect(city_uuids.size).to eq(1)

        # All three field UUIDs differ from each other.
        expect([name_uuids.first, age_uuids.first, city_uuids.first].uniq.size).to eq(3)
      end
    end

    describe ":none" do
      it "leaves version_group_id NULL on all version rows" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record(
            { alice => { "age" => 1 }, bob => { "age" => 2 } },
            version_grouping: :none,
          )
        end

        rows = TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id])
        expect(rows.count).to eq(2)
        rows.each { |r| expect(r.version_group_id).to be_nil }
      end
    end

    describe ":default with versioning ON behaves as :per_record" do
      it "stamps a UUID per record when version_grouping is omitted" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record(
            { alice => { "age" => 5 },
              bob => { "age" => 6 } },
          )
        end

        alice_uuid = TypedEAV::ValueVersion.where(entity_id: alice.id).pick(:version_group_id)
        bob_uuid   = TypedEAV::ValueVersion.where(entity_id: bob.id).pick(:version_group_id)
        expect(alice_uuid).to be_present
        expect(bob_uuid).to be_present
        expect(alice_uuid).not_to eq(bob_uuid)
      end
    end
  end

  # ────────────────────────────────────────────────────────────
  # version_grouping when versioning is OFF — :default resolves to :none
  # ────────────────────────────────────────────────────────────
  describe "version_grouping when versioning is OFF", :event_callbacks do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)     { create(:contact, tenant_id: "tenant_1") }

    before { TypedEAV.config.versioning = false }

    it ":default resolves to :none without raising" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record({ alice => { "age" => 1 } })
        end
      end.not_to raise_error
    end

    it "explicit :per_record raises ArgumentError" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values_per_record(
            { alice => { "age" => 1 } },
            version_grouping: :per_record,
          )
        end
      end.to raise_error(ArgumentError, /versioning is disabled/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Regression: existing `bulk_set_typed_eav_values` with duplicate
  # in-memory instances of the same persisted row iterates each
  # instance separately. The shared-helper refactor must NOT import
  # the new API's Hash-key-collision gotcha into the old API.
  # ────────────────────────────────────────────────────────────
  describe "regression: duplicate in-memory instances in execute (old API)" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice)     { create(:contact, name: "Alice", tenant_id: "tenant_1") }

    it "iterates each instance separately, applying vbn twice in caller order" do
      # Reload the same row twice so we have two distinct AR objects that
      # both refer to alice's DB row. A Hash<record, vbn> would collide
      # these by `class + id` and drop one — ordered pairs must not.
      a1 = Contact.find(alice.id)
      a2 = Contact.find(alice.id)
      expect(a1).to eq(a2)
      expect(a1.object_id).not_to eq(a2.object_id) # different objects, same row

      call_count = 0
      original = TypedEAV::BulkWrite.method(:apply_record_save)
      allow(TypedEAV::BulkWrite).to receive(:apply_record_save) do |**kwargs|
        call_count += 1
        original.call(**kwargs)
      end

      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values([a1, a2], { "age" => 88 })
      end

      # Both instances iterated — apply_record_save called twice.
      expect(call_count).to eq(2)
      # Both reported as successes in caller order (ordered pairs preserve duplicates).
      expect(result[:successes]).to eq([a1, a2])
      expect(alice.reload.typed_eav_hash).to eq("age" => 88)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/LetSetup, RSpec/AnyInstance
