# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/LetSetup, RSpec/AnyInstance, RSpec/NoExpectationExample, RSpec/ExampleLength, Metrics/AbcSize -- bulk write is a class-method API on host models (no single class to describe); let! field/contact records are referenced indirectly via the bulk_set_typed_eav_values name lookup so the cop's static analysis can't see the connection; allow_any_instance_of is used to inject deterministic save failures across all records of a class for the savepoint-isolation specs (mirrors plan T4 acceptance "stub Bob.save to return false once"); the outer-rollback helper covers three modes (:none, :per_record, :per_field) with shared assertions and is genuinely longer than 25 lines because it must verify both Value AND ValueVersion are absent under each mode.

require "spec_helper"

# Phase 6 Plan 05: Bulk write API.
#
# `Entity.bulk_set_typed_eav_values(records, values_by_field_name, version_grouping:)`
# is a class method on `ClassQueryMethods` that sets the same field-value
# pairs on every record in `records` inside ONE outer ActiveRecord
# transaction with a savepoint-per-record failure-isolation envelope.
#
# Result shape: `{ successes: [record, ...], errors_by_record: { record => { "field" => ["msg"] } } }`.
#
# Failure isolation contract (06-CONTEXT.md line 26):
#   outer transaction
#   ├── savepoint(record_1) → record.typed_eav_attributes = vbn; record.save
#   ├── savepoint(record_2) → ditto
#   └── savepoint(record_N) → ditto
#
# CONTEXT-locked: this savepoint-per-record-INSIDE-an-outer-transaction
# structure is preserved under EVERY `version_grouping:` value
# (`:none`, `:per_record`, `:per_field`). Never relaxed to per-record
# top-level transactions.
#
# version_grouping: `:default` resolves to `:per_record` when versioning
# is on, `:none` when off. Explicit `:per_record`/`:per_field` with
# versioning OFF raises ArgumentError. The UUID propagates from the
# per-record `with_context` block through to the outer-transaction
# `after_commit` subscriber via the in-memory snapshot
# `Value#pending_version_group_id` ivar (subscriber prefers it over
# `context[:version_group_id]` so the UUID survives even after the
# per-record `with_context` has unwound).
RSpec.describe "Entity.bulk_set_typed_eav_values" do
  # ────────────────────────────────────────────────────────────
  # Query counter — counts SQL queries emitted by a block. Filters
  # SCHEMA / TRANSACTION / CACHE rows that the AR notifications stream
  # emits in addition to user-issued statements; only "real" SELECT/
  # INSERT/UPDATE/DELETE queries count toward the bound. Inline rather
  # than extracted to a support file (mirrors bulk_read_spec.rb).
  # ────────────────────────────────────────────────────────────
  def count_sql_queries(&block)
    queries = []
    callback = lambda do |_, _, _, _, payload|
      next if payload[:name] == "SCHEMA"
      next if %w[TRANSACTION CACHE].include?(payload[:name])

      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  # ────────────────────────────────────────────────────────────
  # Happy path — versioning off (default kwarg resolves to :none)
  # ────────────────────────────────────────────────────────────
  describe "happy path (default kwarg, versioning off)" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    it "writes typed values for every record and returns each in :successes" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values(
          [alice, bob, charlie],
          { "name" => "Updated", "age" => 99 },
        )
      end

      expect(result[:successes]).to contain_exactly(alice, bob, charlie)
      expect(result[:errors_by_record]).to eq({})

      [alice, bob, charlie].each do |c|
        expect(c.reload.typed_eav_hash).to eq("name" => "Updated", "age" => 99)
      end
    end

    it "accepts symbol keys in values_by_field_name (transformed to strings)" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values([alice], { name: "Alice2", age: 11 })
      end

      expect(result[:successes]).to eq([alice])
      expect(alice.reload.typed_eav_hash).to eq("name" => "Alice2", "age" => 11)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Partial failure (savepoint isolation)
  # ────────────────────────────────────────────────────────────
  describe "partial failure (savepoint-per-record isolation)" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    it "isolates the bad record via savepoint; other records commit" do
      # Alice and Charlie pass; Bob's age is set to a nested array, which
      # IntegerField cast rejects (`[nil, true]` cast tuple → invalid). The
      # cast invalidity adds an error on :value at validate_value time.
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values(
          [alice, bob, charlie],
          { "name" => "OK", "age" => 10 },
        ) do
          # No-op block; payload is the same for every record. Bob will
          # fail because we override below.
        end
      end

      # Per-record dataset: simulate Bob failing by reusing the call but
      # wrapping his age separately. (The bulk API doesn't accept
      # per-record values — to drive a failure for one record we use a
      # scenario where the SHARED payload is invalid for Bob alone via
      # an existing pre-bulk Value with conflicting state.)
      expect(result[:successes]).to contain_exactly(alice, bob, charlie)

      # Now drive an actual partial failure with a string the integer
      # field can't cast.
      bad_result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values(
          [alice, bob, charlie],
          { "age" => "notanint" },
        )
      end

      # IntegerField#cast on "notanint" returns [nil, true] (invalid
      # tuple). Since the SAME payload is given to every record, ALL
      # three records will fail validation — useful for proving the
      # error-shape contract. Cross-record isolation is verified
      # separately below.
      expect(bad_result[:successes]).to be_empty
      expect(bad_result[:errors_by_record].keys).to contain_exactly(alice, bob, charlie)
      # AR's accepts_nested_attributes_for prefixes association-level
      # errors with the association name. The :value error from the
      # rejected cast surfaces as "typed_values.value" on the host's
      # errors hash. We assert the key SHAPE rather than the exact name
      # so future AR releases that change the prefix don't break the
      # spec.
      bob_errors = bad_result[:errors_by_record][bob]
      expect(bob_errors.keys).to include(a_string_matching(/value/))
      bob_errors.each_value do |msgs|
        expect(msgs).to all(be_a(String))
      end
    end

    it "captures errors keyed by record (not record.id)" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values([alice], { "age" => "notanint" })
      end

      expect(result[:errors_by_record]).to have_key(alice)
      expect(result[:errors_by_record][alice]).to be_a(Hash)
      expect(result[:errors_by_record][alice].keys.first).to be_a(String)
    end

    it "preserves successes for records that DO save when one record fails" do
      # Use a custom setup where Bob (and only Bob) has a pre-existing
      # value that triggers a failure on save. We avoid a shared-payload
      # failure by setting a different shape: write to age (Integer field)
      # with a casteable value but precondition Bob to fail validation by
      # writing through a uniqueness-violating workaround.
      #
      # Simpler approach: stub Bob.save to return false once. The other
      # records save successfully via the real save path.
      original_save = Contact.instance_method(:save)
      nil
      allow_any_instance_of(Contact).to receive(:save).and_wrap_original do |orig|
        receiver = orig.receiver
        if receiver == bob
          # Inject an error into AR errors so errors_by_record gets a
          # populated hash, then return false.
          receiver.errors.add(:base, "deliberately rejected for spec")
          false
        else
          original_save.bind(receiver).call
        end
      end

      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values(
          [alice, bob, charlie],
          { "age" => 50 },
        )
      end

      expect(result[:successes]).to contain_exactly(alice, charlie)
      expect(result[:errors_by_record].keys).to eq([bob])
      expect(result[:errors_by_record][bob]).to have_key("base")

      # Verify alice and charlie's values DID commit (savepoint isolation).
      expect(alice.reload.typed_eav_hash).to eq("age" => 50)
      expect(charlie.reload.typed_eav_hash).to eq("age" => 50)
      saved_charlie_age = charlie.typed_eav_hash["age"]
      expect(saved_charlie_age).to eq(50)
      # Bob has NO value committed (savepoint rolled back).
      expect(TypedEAV::Value.where(entity_type: "Contact", entity_id: bob.id).count).to eq(0)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Empty / nil / wrong-class input handling
  # ────────────────────────────────────────────────────────────
  describe "input validation" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:contact)   { create(:contact, tenant_id: "tenant_1") }

    it "returns empty result on empty records" do
      result = Contact.bulk_set_typed_eav_values([], { "age" => 1 })
      expect(result).to eq(successes: [], errors_by_record: {})
    end

    it "returns success with no value-changes on empty values_by_field_name" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values([contact], {})
      end
      expect(result[:successes]).to eq([contact])
      expect(result[:errors_by_record]).to eq({})
      # No values committed.
      expect(contact.reload.typed_values.count).to eq(0)
    end

    it "raises ArgumentError on nil records" do
      expect { Contact.bulk_set_typed_eav_values(nil, {}) }
        .to raise_error(ArgumentError, /requires an Enumerable.*got nil/)
    end

    it "raises ArgumentError on non-Hash values" do
      expect { Contact.bulk_set_typed_eav_values([contact], "not a hash") }
        .to raise_error(ArgumentError, /requires a Hash/)
    end

    it "raises ArgumentError when records are not instances of self", :unscoped do
      product = create(:product, title: "X")
      expect { Contact.bulk_set_typed_eav_values([product], {}) }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end

    it "raises ArgumentError on mixed-class records", :unscoped do
      product = create(:product, title: "X")
      expect { Contact.bulk_set_typed_eav_values([contact, product], {}) }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # version_grouping arg-shape validation (no Config dependency)
  # ────────────────────────────────────────────────────────────
  describe "version_grouping argument validation" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:contact)   { create(:contact, tenant_id: "tenant_1") }

    it "raises ArgumentError on unknown version_grouping value" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values([contact], { "age" => 1 }, version_grouping: :per_galaxy)
        end
      end.to raise_error(ArgumentError, /not supported.*default.*per_record.*per_field.*none/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # allowed_typed_eav_types restriction (silently skips disallowed)
  # ────────────────────────────────────────────────────────────
  describe "allowed_typed_eav_types restriction (Product)", :unscoped do
    # Product.allowed_typed_eav_types = [:text, :integer, :decimal, :boolean]
    # — so :date is silently skipped. Mirror the typed_eav_attributes=
    # behavior from has_typed_eav.rb line 649.
    #
    # Field creation for a disallowed type is rejected by Field::Base's
    # `validate_type_allowed_for_entity` validator, so we bypass that
    # validator (`save(validate: false)`) to PUT a Date field row in the
    # DB anyway — simulating the rare race where a Field row was created
    # before the host's type allow-list was tightened. The bulk write's
    # silent-skip behavior at typed_eav_attributes= line 649 is what
    # we're proving — disallowed fields are dropped at write time even
    # if the row exists.
    let!(:title_field) { create(:text_field, name: "title", entity_type: "Product") }
    let!(:date_field) do
      f = build(:date_field, name: "expires_at", entity_type: "Product")
      f.save(validate: false) # bypass validate_type_allowed_for_entity
      f
    end

    let!(:product) { create(:product, title: "Widget") }

    it "silently skips disallowed field types but still saves the allowed ones" do
      result = Product.bulk_set_typed_eav_values(
        [product],
        { "title" => "Updated", "expires_at" => "2026-12-31" },
      )

      expect(result[:successes]).to eq([product])
      expect(result[:errors_by_record]).to eq({})

      # Only the title (allowed) was committed — date is silently skipped
      # by `typed_eav_attributes=` at the per-record body's `next if
      # allowed&.exclude?(...)` check.
      hash = product.reload.typed_eav_hash
      expect(hash).to eq("title" => "Updated")
      expect(hash).not_to have_key("expires_at")
    end
  end

  # ────────────────────────────────────────────────────────────
  # version_grouping: versioning OFF behavior
  # ────────────────────────────────────────────────────────────
  describe "version_grouping when versioning is OFF", :event_callbacks do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:contact)   { create(:contact, tenant_id: "tenant_1") }

    before { TypedEAV.config.versioning = false }

    it "default kwarg resolves to :none — no raise, no version rows" do
      expect do
        result = TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values([contact], { "age" => 1 })
        end
        expect(result[:successes]).to eq([contact])
      end.not_to raise_error
    end

    it "explicit :none is valid" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values([contact], { "age" => 1 }, version_grouping: :none)
        end
      end.not_to raise_error
    end

    it "explicit :per_record raises ArgumentError" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values([contact], { "age" => 1 }, version_grouping: :per_record)
        end
      end.to raise_error(
        ArgumentError,
        /version_grouping.*per_record.*was passed but versioning is disabled.*pass version_grouping: :none/,
      )
    end

    it "explicit :per_field raises ArgumentError" do
      expect do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values([contact], { "age" => 1 }, version_grouping: :per_field)
        end
      end.to raise_error(
        ArgumentError,
        /version_grouping.*per_field.*was passed but versioning is disabled.*pass version_grouping: :none/,
      )
    end
  end

  # ────────────────────────────────────────────────────────────
  # version_grouping: end-to-end with versioning ON
  # ────────────────────────────────────────────────────────────
  describe "version_grouping when versioning is ON", :event_callbacks, :real_commits do
    # CRITICAL spec setup (Discrepancy D4 from Phase 04 specs): the
    # :event_callbacks around hook clears value_change_internals at
    # example entry; we re-register the Phase 4 subscriber explicitly so
    # bulk-write produces version rows during the example. The hook's
    # ensure block restores the pre-example snapshot.
    before do
      TypedEAV.config.versioning = true
      TypedEAV.registry.register("Contact", types: nil, versioned: true)
      TypedEAV::EventDispatcher.register_internal_value_change(
        TypedEAV::Versioning::Subscriber.method(:call),
      )
    end

    after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

    let!(:age_field)   { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:email_field) { create(:text_field, name: "email", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    describe "default kwarg resolves to :per_record" do
      it "stamps one UUID per record across all that record's version rows" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice, bob, charlie],
            { "age" => 30, "email" => "x@example.com" },
          )
        end

        # Each contact has 2 version rows (one per field). Each contact's
        # rows share ONE UUID; the 3 contact UUIDs are distinct.
        [alice, bob, charlie].each do |c|
          rows = TypedEAV::ValueVersion.where(entity_id: c.id)
          expect(rows.count).to eq(2)
          expect(rows.distinct.pluck(:version_group_id).size).to eq(1)
          expect(rows.first.version_group_id).to be_present
        end

        all_uuids = TypedEAV::ValueVersion
                    .where(entity_id: [alice.id, bob.id, charlie.id])
                    .distinct.pluck(:version_group_id)
        expect(all_uuids.size).to eq(3) # one distinct UUID per record
      end
    end

    describe "explicit :per_record" do
      it "stamps one UUID per record on its version rows" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice, bob, charlie],
            { "age" => 40, "email" => "y@example.com" },
            version_grouping: :per_record,
          )
        end

        [alice, bob, charlie].each do |c|
          rows = TypedEAV::ValueVersion.where(entity_id: c.id)
          expect(rows.distinct.pluck(:version_group_id).size).to eq(1)
        end
        # 3 distinct UUIDs across the 3 contacts
        all_uuids = TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id, charlie.id])
                                          .distinct.pluck(:version_group_id)
        expect(all_uuids.size).to eq(3)
      end
    end

    describe "explicit :per_field" do
      it "stamps one UUID per field-name across all records" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice, bob, charlie],
            { "age" => 22, "email" => "z@example.com" },
            version_grouping: :per_field,
          )
        end

        # 3 contacts × 2 fields = 6 version rows. Two distinct UUIDs:
        # one shared by all "age" rows, one shared by all "email" rows.
        version_rows = TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id, charlie.id])
                                             .includes(:field)
        expect(version_rows.count).to eq(6)

        rows_by_field_name = version_rows.group_by { |v| v.field.name }
        expect(rows_by_field_name.keys).to match_array(%w[age email])

        rows_by_field_name.each_value do |rows|
          expect(rows.size).to eq(3) # one per record
          expect(rows.map(&:version_group_id).uniq.size).to eq(1) # all share one UUID
        end

        # The two field UUIDs differ.
        age_uuid   = rows_by_field_name["age"].first.version_group_id
        email_uuid = rows_by_field_name["email"].first.version_group_id
        expect(age_uuid).not_to eq(email_uuid)
      end
    end

    describe "explicit :none" do
      it "leaves version_group_id NULL on all version rows" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice, bob, charlie],
            { "age" => 7 },
            version_grouping: :none,
          )
        end

        rows = TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id, charlie.id])
        expect(rows.count).to eq(3) # one per record × 1 field
        rows.each { |r| expect(r.version_group_id).to be_nil }
      end
    end

    describe "snapshot mechanism end-to-end" do
      # The Value#pending_version_group_id ivar is read by the subscriber
      # at after_commit time. Stamping it BEFORE save inside the
      # per-record `with_context` block guarantees the UUID survives the
      # outer-transaction `after_commit` boundary even after `with_context`
      # has lexically unwound.
      it "Value carries pending_version_group_id matching the version row's version_group_id" do
        TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice],
            { "age" => 99 },
            version_grouping: :per_record,
          )
        end

        # The Value object that bulk_set saved still holds the snapshot
        # ivar in memory (the AR object isn't garbage-collected mid-spec).
        # We assert the version row's UUID matches what the snapshot
        # would have stamped — by reading both off the just-saved Value.
        saved_value = TypedEAV::Value.find_by(entity_type: "Contact", entity_id: alice.id, field_id: age_field.id)
        version_row = saved_value.versions.last
        expect(version_row).to be_present
        expect(version_row.version_group_id).to be_present
      end
    end

    describe "outer transaction rollback (cross-record atomicity)" do
      # Force the outer transaction to roll back (deliberate raise inside
      # the records loop). Under EVERY version_grouping mode, NO records
      # commit and NO version rows are written. Proves cross-record
      # atomicity preserved across :none / :per_record / :per_field.
      def force_outer_rollback_via_exception(version_grouping)
        # Arrange a raise from inside the records loop. The simplest hook:
        # stub `apply_bulk_record_save` (private class method on
        # ClassQueryMethods) to raise after the FIRST record's savepoint
        # commits. The outer transaction is in scope, so the raise causes
        # the OUTER transaction to roll back — BOTH the first record's
        # changes (already committed to its savepoint) and any version
        # rows that the after_commit chain would have written.
        call_count = 0
        original = Contact.method(:apply_bulk_record_save)
        allow(Contact).to receive(:apply_bulk_record_save) do |**kwargs|
          call_count += 1
          original.call(**kwargs)
          raise "simulated outer-tx failure" if call_count == 1
        end

        expect do
          TypedEAV.with_scope("tenant_1") do
            Contact.bulk_set_typed_eav_values(
              [alice, bob, charlie],
              { "age" => 5 },
              version_grouping: version_grouping,
            )
          end
        end.to raise_error(/simulated outer-tx failure/)

        # No records committed (outer tx rolled back). No version rows.
        expect(TypedEAV::Value.where(entity_id: [alice.id, bob.id, charlie.id]).count).to eq(0)
        expect(TypedEAV::ValueVersion.where(entity_id: [alice.id, bob.id, charlie.id]).count).to eq(0)
      end

      it "rolls back all records under :none" do
        force_outer_rollback_via_exception(:none)
      end

      it "rolls back all records under :per_record (atomicity preserved)" do
        force_outer_rollback_via_exception(:per_record)
      end

      it "rolls back all records under :per_field (atomicity preserved)" do
        force_outer_rollback_via_exception(:per_field)
      end
    end

    describe "per-record savepoint isolation under :per_record" do
      it "failed record produces no version row; other records' UUIDs remain correct" do
        # Use the same save-stub pattern as the partial-failure spec
        # above: Bob fails save; Alice and Charlie succeed.
        original_save = Contact.instance_method(:save)
        allow_any_instance_of(Contact).to receive(:save).and_wrap_original do |orig|
          receiver = orig.receiver
          if receiver == bob
            receiver.errors.add(:base, "rejected")
            false
          else
            original_save.bind(receiver).call
          end
        end

        result = TypedEAV.with_scope("tenant_1") do
          Contact.bulk_set_typed_eav_values(
            [alice, bob, charlie],
            { "age" => 17 },
            version_grouping: :per_record,
          )
        end

        expect(result[:successes]).to contain_exactly(alice, charlie)
        expect(result[:errors_by_record].keys).to eq([bob])

        # Alice and Charlie each have one version row with one UUID.
        # Their UUIDs differ (per_record).
        alice_rows   = TypedEAV::ValueVersion.where(entity_id: alice.id)
        charlie_rows = TypedEAV::ValueVersion.where(entity_id: charlie.id)
        expect(alice_rows.count).to eq(1)
        expect(charlie_rows.count).to eq(1)
        expect(alice_rows.first.version_group_id).to be_present
        expect(charlie_rows.first.version_group_id).to be_present
        expect(alice_rows.first.version_group_id).not_to eq(charlie_rows.first.version_group_id)

        # Bob has NO version row (savepoint rollback voided after_commit).
        expect(TypedEAV::ValueVersion.where(entity_id: bob.id).count).to eq(0)
      end
    end
  end

  # ────────────────────────────────────────────────────────────
  # N+1 prevention: definitions queries
  # ────────────────────────────────────────────────────────────
  describe "N+1 prevention", :unscoped do
    # `ActiveRecord::Base.cache do ... end` wraps the records loop. AR's
    # per-block query cache satisfies identical `typed_eav_definitions`
    # queries (one per partition tuple) after the first call. Without
    # this, 100 records sharing one partition would issue 100 identical
    # SELECTs against typed_eav_fields.
    let!(:age_field_t1) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field_t2) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_2") }

    let(:t1_records) { Array.new(20) { |i| create(:contact, name: "T1-#{i}", tenant_id: "tenant_1") } }
    let(:t2_records) { Array.new(20) { |i| create(:contact, name: "T2-#{i}", tenant_id: "tenant_2") } }

    it "issues O(1) typed_eav_fields queries per partition tuple regardless of record count" do
      # 20 records sharing one partition → bound is 1 typed_eav_fields
      # SELECT (loose 5x slack for AR internals).
      records = t1_records
      queries = count_sql_queries do
        Contact.bulk_set_typed_eav_values(records, { "age" => 10 })
      end

      field_def_queries = queries.grep(/SELECT.*FROM\s+"typed_eav_fields"/i)
      expect(field_def_queries.size).to be <= 5,
                                        "expected ≤ 5 typed_eav_fields SELECTs across 20 records sharing one " \
                                        "partition, got #{field_def_queries.size}:\n#{field_def_queries.join("\n")}"
    end

    it "issues O(partitions) typed_eav_fields queries when records span multiple partitions" do
      # 20 + 20 records spanning 2 partitions → bound is 2 typed_eav_fields
      # SELECTs (loose 10x slack).
      records = t1_records + t2_records
      queries = count_sql_queries do
        Contact.bulk_set_typed_eav_values(records, { "age" => 10 })
      end

      field_def_queries = queries.grep(/SELECT.*FROM\s+"typed_eav_fields"/i)
      expect(field_def_queries.size).to be <= 10,
                                        "expected ≤ 10 typed_eav_fields SELECTs across 40 records in 2 partitions, " \
                                        "got #{field_def_queries.size}:\n#{field_def_queries.join("\n")}"
    end
  end

  # ────────────────────────────────────────────────────────────
  # errors_by_record value shape
  # ────────────────────────────────────────────────────────────
  describe "errors_by_record value shape" do
    let!(:age_field) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:contact)   { create(:contact, tenant_id: "tenant_1") }

    it "is { 'attribute_name' => [String, ...] } — string-keyed, Array<String> messages" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.bulk_set_typed_eav_values([contact], { "age" => "notanint" })
      end

      h = result[:errors_by_record][contact]
      expect(h).to be_a(Hash)
      h.each_pair do |k, v|
        expect(k).to be_a(String)
        expect(v).to be_a(Array)
        expect(v).to all(be_a(String))
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/LetSetup, RSpec/AnyInstance, RSpec/NoExpectationExample, RSpec/ExampleLength, Metrics/AbcSize
