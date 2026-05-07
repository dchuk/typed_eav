# frozen_string_literal: true

require "spec_helper"

# Phase 6 Plan 04: Bulk read API.
#
# `Entity.typed_eav_hash_for(records)` is the class-method bulk variant of
# `InstanceMethods#typed_eav_hash`. It returns
#   { record_id => { field_name => value } }
# for an Enumerable of host records, issuing exactly two SQL queries plus one
# `typed_eav_definitions` query per unique partition tuple — N+1-free
# regardless of record count or field count.
#
# Logic invariants (mirrored from the per-record instance method):
#   * Orphan-safe: values whose field row has been deleted (`tv.field` nil)
#     are silently skipped. Same as `typed_eav_hash` line 591.
#   * Winning-id precedence: when the partition has a global+scoped name
#     collision, the value attached to the scoped (winning) field_id wins.
#     Same as `typed_eav_hash` lines 600–605.
#   * Per-tuple field lookup: records are grouped by
#     `[typed_eav_scope, typed_eav_parent_scope]` BEFORE the per-tuple
#     `winning_ids_by_name` map is built — a single value preload spans
#     all records, but the field-collision map is computed once per tuple.
RSpec.describe "Entity.typed_eav_hash_for", type: :model do
  # ────────────────────────────────────────────────────────────
  # Query counter — counts SQL queries emitted by a block. Filters
  # SCHEMA / TRANSACTION / CACHE rows that the AR notifications stream
  # emits in addition to user-issued statements; only "real" SELECT/
  # INSERT/UPDATE/DELETE queries count toward the bound. Inline rather
  # than extracted to a support file because no other spec consumes it
  # yet (per plan §T2 notes).
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
  # Single-tenant scoped Contact records
  # ────────────────────────────────────────────────────────────
  describe "single-tenant scoped Contact records" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }

    let!(:alice)   { create(:contact, name: "Alice",   tenant_id: "tenant_1") }
    let!(:bob)     { create(:contact, name: "Bob",     tenant_id: "tenant_1") }
    let!(:charlie) { create(:contact, name: "Charlie", tenant_id: "tenant_1") }

    before do
      [[alice, "Alice", 30], [bob, "Bob", 25], [charlie, "Charlie", 40]].each do |c, n, a|
        TypedEAV::Value.create!(entity: c, field: name_field).tap do |v|
          v.value = n
          v.save!
        end
        TypedEAV::Value.create!(entity: c, field: age_field).tap do |v|
          v.value = a
          v.save!
        end
      end
    end

    it "returns { record_id => { name => value } } for each record" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.typed_eav_hash_for([alice, bob, charlie])
      end

      expect(result).to eq(
        alice.id => { "name" => "Alice",   "age" => 30 },
        bob.id => { "name" => "Bob", "age" => 25 },
        charlie.id => { "name" => "Charlie", "age" => 40 },
      )
    end
  end

  # ────────────────────────────────────────────────────────────
  # Unscoped Product records (no scope_method on the host)
  # ────────────────────────────────────────────────────────────
  describe "unscoped Product records", :unscoped do
    let!(:title_field) { create(:text_field, name: "title", entity_type: "Product") }
    let!(:qty_field)   { create(:integer_field, name: "qty", entity_type: "Product") }

    let!(:p1) { create(:product, title: "Widget A") }
    let!(:p2) { create(:product, title: "Widget B") }
    let!(:p3) { create(:product, title: "Widget C") }

    before do
      [[p1, "A", 1], [p2, "B", 2], [p3, "C", 3]].each do |p, t, q|
        TypedEAV::Value.create!(entity: p, field: title_field).tap do |v|
          v.value = t
          v.save!
        end
        TypedEAV::Value.create!(entity: p, field: qty_field).tap do |v|
          v.value = q
          v.save!
        end
      end
    end

    it "returns { record_id => { name => value } } across unscoped records" do
      result = Product.typed_eav_hash_for([p1, p2, p3])

      expect(result).to eq(
        p1.id => { "title" => "A", "qty" => 1 },
        p2.id => { "title" => "B", "qty" => 2 },
        p3.id => { "title" => "C", "qty" => 3 },
      )
    end
  end

  # ────────────────────────────────────────────────────────────
  # Two-axis Project records (scope + parent_scope)
  # ────────────────────────────────────────────────────────────
  describe "two-axis Project records (scope + parent_scope)" do
    let!(:scoped_field) do
      create(:text_field, name: "label", entity_type: "Project",
                          scope: "tenant_1", parent_scope: "ws_1")
    end

    let!(:project_a) { create(:project, name: "A", tenant_id: "tenant_1", workspace_id: "ws_1") }
    let!(:project_b) { create(:project, name: "B", tenant_id: "tenant_1", workspace_id: "ws_1") }

    before do
      # A field in the SAME tenant but a DIFFERENT parent_scope must NOT leak
      # into the (tenant_1, ws_1) result. Same name, same scope axis, different
      # parent — should not appear in the bulk-read output for project_a/_b.
      # Created here (not via `let!`) so RSpec/LetSetup doesn't flag the
      # un-referenced fixture; its existence is the load-bearing assertion.
      create(:text_field, name: "label", entity_type: "Project",
                          scope: "tenant_1", parent_scope: "ws_2")

      [[project_a, "Alpha"], [project_b, "Beta"]].each do |proj, label|
        TypedEAV::Value.create!(entity: proj, field: scoped_field).tap do |v|
          v.value = label
          v.save!
        end
      end
    end

    it "groups records by (scope, parent_scope) and resolves per-tuple definitions" do
      result = TypedEAV.with_scope(%w[tenant_1 ws_1]) do
        Project.typed_eav_hash_for([project_a, project_b])
      end

      expect(result).to eq(
        project_a.id => { "label" => "Alpha" },
        project_b.id => { "label" => "Beta" },
      )
    end
  end

  # ────────────────────────────────────────────────────────────
  # Records with no values
  # ────────────────────────────────────────────────────────────
  describe "records with no typed values", :unscoped do
    let!(:p1) { create(:product, title: "Empty One") }

    before { create(:text_field, name: "title", entity_type: "Product") }

    it "returns an empty inner hash for each record (still indexable by id)" do
      result = Product.typed_eav_hash_for([p1])
      expect(result).to eq(p1.id => {})
    end
  end

  # ────────────────────────────────────────────────────────────
  # Global+scoped name collision — scoped wins (winning-id precedence)
  # ────────────────────────────────────────────────────────────
  describe "global+scoped name collision" do
    let!(:global_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: nil) }
    let!(:scoped_age) { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:contact)    { create(:contact, tenant_id: "tenant_1") }

    before do
      # Both rows exist for the same contact — only the scoped one should
      # surface in the bulk result (winning-id precedence). Mirrors the
      # `#typed_eav_hash` instance-method invariant at lines 600–605.
      TypedEAV::Value.create!(entity: contact, field: scoped_age).tap do |v|
        v.value = 99
        v.save!
      end
      # Bypass `validates :field, uniqueness: { scope: ... }` to write a
      # duplicate row attached to the global field — simulates the rare
      # edge case where the scoped definition was added AFTER a global
      # value was already in place. Direct INSERT mirrors the pattern in
      # `#typed_eav_hash` collision specs in has_typed_eav_spec.rb.
      TypedEAV::Value.connection.execute(<<~SQL.squish)
        INSERT INTO typed_eav_values (entity_type, entity_id, field_id, integer_value, created_at, updated_at)
        VALUES ('Contact', #{contact.id}, #{global_age.id}, 11, NOW(), NOW())
      SQL
    end

    it "returns only the scoped (winning) value, not the shadowed global" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.typed_eav_hash_for([contact])
      end

      expect(result).to eq(contact.id => { "age" => 99 })
    end
  end

  # ────────────────────────────────────────────────────────────
  # Orphan values (field row deleted out from under the value)
  # ────────────────────────────────────────────────────────────
  describe "orphan values (field destroyed mid-test)", :unscoped do
    let!(:field)   { create(:text_field, name: "note", entity_type: "Contact") }
    let!(:contact) { create(:contact) }

    before do
      TypedEAV::Value.create!(entity: contact, field: field).tap do |v|
        v.value = "hello"
        v.save!
      end
      # Raw delete bypasses the FK cascade and leaves a Value row with
      # field_id pointing at a now-missing row. Phase 02's
      # `field_dependent: :nullify` makes this an expected outcome of a
      # configured choice — the FK is ON DELETE SET NULL.
      TypedEAV::Field::Base.connection.execute(
        "DELETE FROM typed_eav_fields WHERE id = #{field.id}",
      )
    end

    it "skips orphan values (returns empty inner hash)" do
      result = Contact.typed_eav_hash_for([contact])
      expect(result).to eq(contact.id => {})
    end
  end

  # ────────────────────────────────────────────────────────────
  # Empty input → {}
  # ────────────────────────────────────────────────────────────
  describe "empty input" do
    it "returns an empty hash" do
      expect(Contact.typed_eav_hash_for([])).to eq({})
    end
  end

  # ────────────────────────────────────────────────────────────
  # Nil input → ArgumentError
  # ────────────────────────────────────────────────────────────
  describe "nil input" do
    it "raises ArgumentError" do
      expect { Contact.typed_eav_hash_for(nil) }
        .to raise_error(ArgumentError, /requires an Enumerable.*got nil/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Wrong-class records → ArgumentError
  # ────────────────────────────────────────────────────────────
  describe "wrong-class records", :unscoped do
    let!(:product) { create(:product, title: "X") }

    it "raises ArgumentError when records are not instances of self" do
      expect { Contact.typed_eav_hash_for([product]) }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Mixed-class records → ArgumentError
  # ────────────────────────────────────────────────────────────
  describe "mixed-class records", :unscoped do
    let!(:contact) { create(:contact) }
    let!(:product) { create(:product, title: "X") }

    it "raises ArgumentError when records span multiple classes" do
      expect { Contact.typed_eav_hash_for([contact, product]) }
        .to raise_error(ArgumentError, /expects records of class Contact/)
    end
  end

  # ────────────────────────────────────────────────────────────
  # AR Relation input
  # ────────────────────────────────────────────────────────────
  describe "AR Relation input" do
    let!(:name_field) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:alice) { create(:contact, name: "Alice", tenant_id: "tenant_1") }
    let!(:bob)   { create(:contact, name: "Bob",   tenant_id: "tenant_1") }

    before do
      TypedEAV::Value.create!(entity: alice, field: name_field).tap do |v|
        v.value = "Alice"
        v.save!
      end
      TypedEAV::Value.create!(entity: bob, field: name_field).tap do |v|
        v.value = "Bob"
        v.save!
      end
    end

    it "accepts an ActiveRecord::Relation and returns the same shape as Array input" do
      result = TypedEAV.with_scope("tenant_1") do
        Contact.typed_eav_hash_for(Contact.where(tenant_id: "tenant_1").order(:id))
      end

      expect(result).to eq(
        alice.id => { "name" => "Alice" },
        bob.id => { "name" => "Bob" },
      )
    end
  end

  # ────────────────────────────────────────────────────────────
  # N+1 prevention: query-count bound
  #
  # Bound: 2 + (unique partition tuples) =
  #   1 value preload (with `includes(:field)` → that fires 2 queries:
  #   value SELECT and field SELECT, but Rails counts both via the
  #   includes batch) PLUS 1 typed_eav_definitions per unique tuple.
  #
  # In practice, with 2 partition tuples (tenant_1 and tenant_2):
  #   - 1 SELECT typed_eav_values WHERE entity_type=? AND entity_id IN (?)
  #   - 1 SELECT typed_eav_fields WHERE id IN (?)              (preload)
  #   - 1 SELECT typed_eav_fields WHERE entity_type=? AND scope=? (tuple 1)
  #   - 1 SELECT typed_eav_fields WHERE entity_type=? AND scope=? (tuple 2)
  # = 4 queries total, INDEPENDENT of how many records each tuple contains.
  # ────────────────────────────────────────────────────────────
  describe "N+1 prevention", :unscoped do
    let!(:name_field_t1) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_1") }
    let!(:name_field_t2) { create(:text_field, name: "name", entity_type: "Contact", scope: "tenant_2") }
    let!(:age_field_t1)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_1") }
    let!(:age_field_t2)  { create(:integer_field, name: "age", entity_type: "Contact", scope: "tenant_2") }

    let!(:t1_records) do
      Array.new(3) { |i| create(:contact, name: "T1-#{i}", tenant_id: "tenant_1") }
    end
    let!(:t2_records) do
      Array.new(2) { |i| create(:contact, name: "T2-#{i}", tenant_id: "tenant_2") }
    end

    before do
      t1_records.each_with_index do |c, i|
        TypedEAV::Value.create!(entity: c, field: name_field_t1).tap do |v|
          v.value = "Name#{i}"
          v.save!
        end
        TypedEAV::Value.create!(entity: c, field: age_field_t1).tap do |v|
          v.value = 20 + i
          v.save!
        end
      end
      t2_records.each_with_index do |c, i|
        TypedEAV::Value.create!(entity: c, field: name_field_t2).tap do |v|
          v.value = "T2-#{i}"
          v.save!
        end
        TypedEAV::Value.create!(entity: c, field: age_field_t2).tap do |v|
          v.value = 30 + i
          v.save!
        end
      end
    end

    it "issues at most (2 + unique_partition_tuples) SQL queries regardless of record count" do
      records = t1_records + t2_records
      partitions = 2 # (tenant_1, nil) and (tenant_2, nil)

      queries = count_sql_queries do
        result = Contact.typed_eav_hash_for(records)
        # Force iteration so any lazy work materializes inside the block.
        result.each_value(&:keys)
      end

      # Bound = 1 value preload + 1 field preload + 1 definitions per tuple.
      # Use `<=` to allow Rails query-cache or test-harness variance one query
      # of slack; the load-bearing assertion is "does not scale with record count".
      expect(queries.size).to be <= (2 + partitions),
                              "expected ≤ #{2 + partitions} queries, got #{queries.size}:\n" \
                              "#{queries.join("\n")}"
    end
  end
end
