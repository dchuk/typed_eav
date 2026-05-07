# frozen_string_literal: true

require "spec_helper"

# Phase 06 plan 02 spec coverage for `TypedEAV::Field::Base.export_schema` /
# `import_schema`. Covers: round-trip on empty target, two-axis partition
# round-trip with no leakage, equality-no-op short-circuit under each
# `on_conflict:` policy, divergent-row dispatch (`:error` raises, `:skip`
# leaves unchanged, `:overwrite` updates fields + replaces options), STI
# type-swap unconditional raise, schema_version validation, and section
# round-trip / equality-no-op symmetry.
#
# `:unscoped` is applied to specs that exercise cross-scope class-level
# queries on the scoped Contact / Project hosts — without it, the
# fail-closed default would raise ScopeRequired before the test could run.
# rubocop:disable RSpec/SpecFilePathFormat -- file path locked by Plan 06-02 (files_modified).
RSpec.describe TypedEAV::Field::Base, ".export_schema / .import_schema", :unscoped do
  # rubocop:enable RSpec/SpecFilePathFormat
  describe ".export_schema" do
    it "returns a hash with the schema_version envelope and partition keys" do
      hash = described_class.export_schema(entity_type: "Contact", scope: "tenant_x")

      expect(hash["schema_version"]).to eq(1)
      expect(hash["entity_type"]).to eq("Contact")
      expect(hash["scope"]).to eq("tenant_x")
      expect(hash["parent_scope"]).to be_nil
      expect(hash["fields"]).to eq([])
      expect(hash["sections"]).to eq([])
    end

    it "exposes exactly the documented top-level keys" do
      hash = described_class.export_schema(entity_type: "Contact")

      expect(hash.keys.sort).to eq(%w[entity_type fields parent_scope schema_version scope sections])
    end

    it "is JSON-serializable round-trippable" do
      create(:text_field, entity_type: "Contact", scope: "tenant_y", name: "json_text")

      hash = described_class.export_schema(entity_type: "Contact", scope: "tenant_y")
      decoded = JSON.parse(JSON.generate(hash))

      expect(decoded).to eq(hash)
    end

    it "scopes the query to the exact partition tuple — no leakage" do
      create(:text_field, entity_type: "Contact", scope: "t1", name: "isolated_one")
      create(:text_field, entity_type: "Contact", scope: "t2", name: "isolated_two")
      create(:text_field, entity_type: "Contact", scope: nil, name: "isolated_global")

      t1 = described_class.export_schema(entity_type: "Contact", scope: "t1")
      names = t1["fields"].pluck("name")

      expect(names).to eq(["isolated_one"])
    end

    it "emits options_data for select fields, ordered by sort_order" do
      field = create(:select_field, entity_type: "Contact", scope: "t_sel", name: "status_sel")
      # Factory creates 3 options. Reorder to confirm export sorts.
      field.field_options.find_by(value: "lead")&.update!(sort_order: 1)
      field.field_options.find_by(value: "active")&.update!(sort_order: 2)
      field.field_options.find_by(value: "inactive")&.update!(sort_order: 3)

      hash = described_class.export_schema(entity_type: "Contact", scope: "t_sel")
      entry = hash["fields"].first
      values = entry["options_data"].pluck("value")

      expect(values).to eq(%w[lead active inactive])
    end

    it "does not emit options_data for non-optionable fields" do
      create(:text_field, entity_type: "Contact", scope: "t_no_opts", name: "plain_text")

      entry = described_class.export_schema(entity_type: "Contact", scope: "t_no_opts")["fields"].first

      expect(entry).not_to have_key("options_data")
    end

    it "emits the literal STI type column string (not a symbol form)" do
      create(:integer_field, entity_type: "Contact", scope: "t_type", name: "age")

      entry = described_class.export_schema(entity_type: "Contact", scope: "t_type")["fields"].first

      expect(entry["type"]).to eq("TypedEAV::Field::Integer")
    end

    it "emits default_value_meta as the WHOLE jsonb hash, not just the inner value" do
      field = create(:integer_field, entity_type: "Contact", scope: "t_dvm", name: "level")
      field.update!(default_value_meta: { "v" => 42, "future_key" => "preserved" })

      entry = described_class.export_schema(entity_type: "Contact", scope: "t_dvm")["fields"].first

      expect(entry["default_value_meta"]).to eq("v" => 42, "future_key" => "preserved")
    end

    it "exports sections with all the documented keys" do
      create(
        :typed_section,
        entity_type: "Contact",
        scope: "t_sec",
        name: "Personal",
        code: "personal",
        sort_order: 1,
        active: true,
      )

      hash = described_class.export_schema(entity_type: "Contact", scope: "t_sec")
      section_entry = hash["sections"].first

      expect(section_entry.keys.sort).to eq(%w[active code entity_type name parent_scope scope sort_order])
      expect(section_entry["code"]).to eq("personal")
      expect(section_entry["active"]).to be(true)
    end

    it "orders fields by sort_order" do
      create(:text_field, entity_type: "Contact", scope: "t_ord", name: "alpha", sort_order: 3)
      create(:text_field, entity_type: "Contact", scope: "t_ord", name: "beta", sort_order: 1)
      create(:text_field, entity_type: "Contact", scope: "t_ord", name: "gamma", sort_order: 2)

      names = described_class.export_schema(entity_type: "Contact", scope: "t_ord")["fields"].pluck("name")

      expect(names).to eq(%w[beta gamma alpha])
    end
  end

  describe ".import_schema" do
    describe "schema_version validation" do
      it "raises ArgumentError when schema_version is not 1" do
        expect do
          described_class.import_schema({
                                          "schema_version" => 2,
                                          "entity_type" => "Contact",
                                          "scope" => nil,
                                          "parent_scope" => nil,
                                          "fields" => [],
                                          "sections" => [],
                                        })
        end.to raise_error(ArgumentError, /Unsupported schema_version: 2/)
      end

      it "raises ArgumentError when schema_version key is absent" do
        expect do
          described_class.import_schema({
                                          "entity_type" => "Contact",
                                          "scope" => nil,
                                          "parent_scope" => nil,
                                          "fields" => [],
                                          "sections" => [],
                                        })
        end.to raise_error(ArgumentError, /Unsupported schema_version: nil/)
      end

      it "includes a remediation hint pointing to a re-export" do
        expect do
          described_class.import_schema({ "schema_version" => 99 })
        end.to raise_error(ArgumentError, /Re-export from a current typed_eav version/)
      end
    end

    describe "on_conflict validation" do
      it "raises ArgumentError on an unsupported policy" do
        expect do
          described_class.import_schema(
            { "schema_version" => 1, "fields" => [], "sections" => [] },
            on_conflict: :bogus,
          )
        end.to raise_error(ArgumentError, /Unsupported on_conflict.*Supported.*:error.*:skip.*:overwrite/m)
      end
    end

    describe "round-trip on empty target" do
      it "recreates fields, sections, and select options identically" do
        create(:text_field, entity_type: "Contact", scope: "src_a", name: "first_name", sort_order: 1)
        create(:integer_field, entity_type: "Contact", scope: "src_a", name: "age", sort_order: 2)
        select_field = create(:select_field, entity_type: "Contact", scope: "src_a", name: "status_sel", sort_order: 3)
        create(
          :typed_section,
          entity_type: "Contact",
          scope: "src_a",
          name: "Personal",
          code: "personal",
          sort_order: 1,
        )

        hash = described_class.export_schema(entity_type: "Contact", scope: "src_a")

        # Clear the source partition to simulate import-into-empty.
        select_field.field_options.destroy_all
        described_class.where(entity_type: "Contact", scope: "src_a").destroy_all
        TypedEAV::Section.where(entity_type: "Contact", scope: "src_a").destroy_all

        result = described_class.import_schema(hash)

        expect(result["created"]).to eq(4) # 3 fields + 1 section
        expect(result["unchanged"]).to eq(0)

        re_exported = described_class.export_schema(entity_type: "Contact", scope: "src_a")
        expect(re_exported).to eq(hash)
      end
    end

    describe "two-axis partition round-trip (Project)" do
      it "creates fields in a different parent_scope partition with NO leakage into source" do
        create(:text_field, entity_type: "Project", scope: "tenant_1", parent_scope: "ws_1", name: "p_a", sort_order: 1)
        create(:text_field, entity_type: "Project", scope: "tenant_1", parent_scope: "ws_1", name: "p_b", sort_order: 2)

        hash = described_class.export_schema(entity_type: "Project", scope: "tenant_1", parent_scope: "ws_1")

        # Mutate every entry's parent_scope to point at ws_2, simulating a
        # cross-workspace clone. The export hash's top-level partition
        # values are informational; the per-entry partition is the
        # idempotence key.
        hash["fields"].each { |entry| entry["parent_scope"] = "ws_2" }

        described_class.import_schema(hash)

        ws_1_names = described_class
                     .where(entity_type: "Project", scope: "tenant_1", parent_scope: "ws_1")
                     .pluck(:name)
        ws_2_names = described_class
                     .where(entity_type: "Project", scope: "tenant_1", parent_scope: "ws_2")
                     .pluck(:name)

        expect(ws_1_names.sort).to eq(%w[p_a p_b])
        expect(ws_2_names.sort).to eq(%w[p_a p_b])

        # Two distinct sets — names duplicate but field_ids are disjoint.
        ws_1_ids = described_class
                   .where(entity_type: "Project", scope: "tenant_1", parent_scope: "ws_1")
                   .pluck(:id)
        ws_2_ids = described_class
                   .where(entity_type: "Project", scope: "tenant_1", parent_scope: "ws_2")
                   .pluck(:id)
        expect(ws_1_ids & ws_2_ids).to be_empty
      end
    end

    describe "equality-no-op short-circuit" do
      # Subscribes to sql.active_record and filters for INSERT/UPDATE/DELETE
      # against typed_eav_fields, typed_eav_options, typed_eav_sections.
      # Returns the captured statements so callers can assert ZERO writes.
      def capture_writes
        captured = []
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          payload = args.last
          sql = payload[:sql].to_s
          next if payload[:name] == "SCHEMA"
          next unless sql.match?(/\A\s*(INSERT|UPDATE|DELETE)\s/i)
          next unless sql.match?(/typed_eav_(fields|options|sections)/)

          captured << sql
        end
        yield
        captured
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end

      %i[error skip overwrite].each do |policy|
        # rubocop:disable RSpec/ExampleLength -- the equality short-circuit is an integration assertion: it requires populating fields + options + sections, exporting, re-importing under a policy, then asserting on counts AND zero writes. Splitting hides the round-trip.
        it "issues ZERO writes against fields/options/sections under on_conflict: :#{policy}" do
          create(:text_field, entity_type: "Contact", scope: "noop_#{policy}", name: "stable_text", sort_order: 1)
          create(
            :select_field,
            entity_type: "Contact",
            scope: "noop_#{policy}",
            name: "stable_sel",
            sort_order: 2,
          )
          create(
            :typed_section,
            entity_type: "Contact",
            scope: "noop_#{policy}",
            name: "Stable",
            code: "stable",
            sort_order: 1,
          )

          hash = described_class.export_schema(entity_type: "Contact", scope: "noop_#{policy}")
          fields_count = hash["fields"].size
          sections_count = hash["sections"].size

          result = nil
          writes = capture_writes do
            result = described_class.import_schema(hash, on_conflict: policy)
          end

          expect(result["unchanged"]).to eq(fields_count + sections_count)
          expect(result["created"]).to eq(0)
          expect(result["updated"]).to eq(0)
          expect(result["skipped"]).to eq(0)
          expect(writes).to be_empty,
                            "expected zero INSERT/UPDATE/DELETE against typed_eav_* under :#{policy}, " \
                            "got: #{writes.inspect}"
        end
        # rubocop:enable RSpec/ExampleLength
      end
    end

    describe "on_conflict: :error on a divergent row" do
      it "raises ArgumentError mentioning the field name, partition, and 'diverge'" do
        create(:text_field, entity_type: "Contact", scope: "div_e", name: "first_name", required: false)
        hash = described_class.export_schema(entity_type: "Contact", scope: "div_e")
        hash["fields"].first["required"] = true

        expect do
          described_class.import_schema(hash, on_conflict: :error)
        end.to raise_error(ArgumentError, /first_name.*div_e.*diverge/m)
      end

      # rubocop:disable RSpec/ExampleLength -- inline hash literal makes the test self-contained and grep-able; extracting via `let` would scatter the precise hash shape across the describe block and obscure what's being tested (transaction rollback over a 2-entry import).
      it "rolls back any prior writes from the same import call" do
        # Pre-populate a divergent existing row in the same partition.
        create(:text_field, entity_type: "Contact", scope: "div_rb", name: "stable_one", required: false)
        # Build a hash with: a NEW field that would create cleanly + the
        # divergent existing field. The import processes fields in order;
        # the first creates, then the second raises. Transaction rollback
        # must undo the create.
        hash = {
          "schema_version" => 1,
          "entity_type" => "Contact",
          "scope" => "div_rb",
          "parent_scope" => nil,
          "fields" => [
            {
              "name" => "would_be_created",
              "type" => "TypedEAV::Field::Text",
              "entity_type" => "Contact",
              "scope" => "div_rb",
              "parent_scope" => nil,
              "required" => false,
              "sort_order" => 1,
              "field_dependent" => "destroy",
              "options" => {},
              "default_value_meta" => {},
            },
            {
              "name" => "stable_one",
              "type" => "TypedEAV::Field::Text",
              "entity_type" => "Contact",
              "scope" => "div_rb",
              "parent_scope" => nil,
              "required" => true, # divergent
              "sort_order" => 2,
              "field_dependent" => "destroy",
              "options" => {},
              "default_value_meta" => {},
            },
          ],
          "sections" => [],
        }

        expect do
          described_class.import_schema(hash, on_conflict: :error)
        end.to raise_error(ArgumentError, /diverge/)

        # The "would_be_created" field must NOT exist — transaction rolled back.
        expect(described_class.where(entity_type: "Contact", scope: "div_rb", name: "would_be_created"))
          .to be_empty
      end
      # rubocop:enable RSpec/ExampleLength
    end

    describe "on_conflict: :skip on a divergent row" do
      # rubocop:disable RSpec/ExampleLength -- inline hash literal makes the test self-contained; the divergent + new combo exercises both the skip branch AND the create branch in one round-trip.
      it "leaves the existing field unchanged and creates the others" do
        existing = create(
          :integer_field,
          entity_type: "Contact",
          scope: "div_s",
          name: "skipped_field",
          sort_order: 1,
        )
        existing.update!(default_value_meta: { "v" => 7 })

        hash = {
          "schema_version" => 1,
          "entity_type" => "Contact",
          "scope" => "div_s",
          "parent_scope" => nil,
          "fields" => [
            {
              "name" => "skipped_field",
              "type" => "TypedEAV::Field::Integer",
              "entity_type" => "Contact",
              "scope" => "div_s",
              "parent_scope" => nil,
              "required" => false,
              "sort_order" => 1,
              "field_dependent" => "destroy",
              "options" => {},
              "default_value_meta" => { "v" => 999 }, # divergent
            },
            {
              "name" => "new_field",
              "type" => "TypedEAV::Field::Text",
              "entity_type" => "Contact",
              "scope" => "div_s",
              "parent_scope" => nil,
              "required" => false,
              "sort_order" => 2,
              "field_dependent" => "destroy",
              "options" => {},
              "default_value_meta" => {},
            },
          ],
          "sections" => [],
        }

        result = described_class.import_schema(hash, on_conflict: :skip)

        expect(result["created"]).to eq(1)
        expect(result["skipped"]).to eq(1)
        expect(result["unchanged"]).to eq(0)

        expect(existing.reload.default_value_meta).to eq("v" => 7)
        expect(described_class.where(entity_type: "Contact", scope: "div_s", name: "new_field")).to exist
      end
      # rubocop:enable RSpec/ExampleLength
    end

    describe "on_conflict: :overwrite on a divergent row" do
      # rubocop:disable RSpec/ExampleLength -- inline hash literal documents exactly which non-key attributes overwrite touches; extracting would scatter the field-shape contract.
      it "updates the field's non-key attributes" do
        existing = create(
          :integer_field,
          entity_type: "Contact",
          scope: "div_o",
          name: "ow_int",
          required: false,
          sort_order: 1,
        )
        existing.update!(default_value_meta: { "v" => 1 })

        hash = {
          "schema_version" => 1,
          "entity_type" => "Contact",
          "scope" => "div_o",
          "parent_scope" => nil,
          "fields" => [
            {
              "name" => "ow_int",
              "type" => "TypedEAV::Field::Integer",
              "entity_type" => "Contact",
              "scope" => "div_o",
              "parent_scope" => nil,
              "required" => true,
              "sort_order" => 9,
              "field_dependent" => "nullify",
              "options" => { "min" => 0, "max" => 100 },
              "default_value_meta" => { "v" => 50 },
            },
          ],
          "sections" => [],
        }

        result = described_class.import_schema(hash, on_conflict: :overwrite)

        expect(result["updated"]).to eq(1)
        existing.reload
        expect(existing.required).to be(true)
        expect(existing.sort_order).to eq(9)
        expect(existing.field_dependent).to eq("nullify")
        expect(existing.options).to eq("min" => 0, "max" => 100)
        expect(existing.default_value_meta).to eq("v" => 50)
      end
      # rubocop:enable RSpec/ExampleLength

      # rubocop:disable RSpec/ExampleLength -- the option-delete-and-recreate behavior requires asserting on BOTH the original (now-deleted) option ids AND the new option set; splitting hides the data-loss-vs-replacement contract this test exists to prove.
      it "deletes and recreates field_options for select fields under :overwrite" do
        existing = create(:select_field, entity_type: "Contact", scope: "div_oo", name: "ow_sel", sort_order: 1)
        original_option_ids = existing.field_options.pluck(:id).sort

        hash = {
          "schema_version" => 1,
          "entity_type" => "Contact",
          "scope" => "div_oo",
          "parent_scope" => nil,
          "fields" => [
            {
              "name" => "ow_sel",
              "type" => "TypedEAV::Field::Select",
              "entity_type" => "Contact",
              "scope" => "div_oo",
              "parent_scope" => nil,
              "required" => true, # divergent
              "sort_order" => 1,
              "field_dependent" => "destroy",
              "options" => {},
              "default_value_meta" => {},
              "options_data" => [
                { "label" => "New A", "value" => "new_a", "sort_order" => 1 },
                { "label" => "New B", "value" => "new_b", "sort_order" => 2 },
              ],
            },
          ],
          "sections" => [],
        }

        described_class.import_schema(hash, on_conflict: :overwrite)

        new_options = existing.reload.field_options.sorted
        new_ids = new_options.pluck(:id).sort
        expect(new_ids & original_option_ids).to be_empty, "old option rows should have been deleted"
        expect(new_options.map(&:value)).to eq(%w[new_a new_b])
      end
      # rubocop:enable RSpec/ExampleLength
    end

    describe "STI type-swap raise" do
      it "raises ArgumentError under EVERY on_conflict policy" do
        create(:integer_field, entity_type: "Contact", scope: "swap_t", name: "age", sort_order: 1)
        hash = described_class.export_schema(entity_type: "Contact", scope: "swap_t")
        hash["fields"].first["type"] = "TypedEAV::Field::Decimal"

        %i[error skip overwrite].each do |policy|
          expect do
            described_class.import_schema(hash, on_conflict: policy)
          end.to raise_error(
            ArgumentError,
            /Cannot change field 'age' from TypedEAV::Field::Integer to TypedEAV::Field::Decimal.*data-loss guard/m,
          ), "expected type-swap raise under on_conflict: :#{policy}"
        end
      end

      it "type-swap takes priority over the equality short-circuit" do
        # This is the same idea but for an entry whose other attributes
        # are unchanged — only the type column differs. The type-swap
        # check fires before equality, so the no-op rule does NOT save us.
        create(:integer_field, entity_type: "Contact", scope: "swap_pri", name: "x", sort_order: 1)
        hash = described_class.export_schema(entity_type: "Contact", scope: "swap_pri")
        hash["fields"].first["type"] = "TypedEAV::Field::Decimal"

        expect do
          described_class.import_schema(hash, on_conflict: :skip)
        end.to raise_error(ArgumentError, /data-loss guard/)
      end
    end

    describe "section round-trip + equality" do
      it "recreates active and inactive sections with active boolean preserved" do
        create(
          :typed_section,
          entity_type: "Contact",
          scope: "sec_rt",
          name: "Active Section",
          code: "active_sec",
          sort_order: 1,
          active: true,
        )
        create(
          :typed_section,
          entity_type: "Contact",
          scope: "sec_rt",
          name: "Inactive Section",
          code: "inactive_sec",
          sort_order: 2,
          active: false,
        )

        hash = described_class.export_schema(entity_type: "Contact", scope: "sec_rt")
        TypedEAV::Section.where(entity_type: "Contact", scope: "sec_rt").destroy_all

        described_class.import_schema(hash)

        sections = TypedEAV::Section.where(entity_type: "Contact", scope: "sec_rt").order(:sort_order)
        expect(sections.map(&:code)).to eq(%w[active_sec inactive_sec])
        expect(sections.map(&:active)).to eq([true, false])
      end

      it "section equality short-circuit applies under :error policy" do
        create(
          :typed_section,
          entity_type: "Contact",
          scope: "sec_eq",
          name: "Stable",
          code: "stable_sec",
          sort_order: 1,
        )
        hash = described_class.export_schema(entity_type: "Contact", scope: "sec_eq")

        result = nil
        expect { result = described_class.import_schema(hash, on_conflict: :error) }.not_to raise_error
        expect(result["unchanged"]).to eq(1)
        expect(result["skipped"]).to eq(0)
        expect(result["updated"]).to eq(0)
      end

      it "raises on a divergent section under :error" do
        create(
          :typed_section,
          entity_type: "Contact",
          scope: "sec_div",
          name: "Original Name",
          code: "div_sec",
          sort_order: 1,
        )
        hash = described_class.export_schema(entity_type: "Contact", scope: "sec_div")
        hash["sections"].first["name"] = "Renamed in hash"

        expect do
          described_class.import_schema(hash, on_conflict: :error)
        end.to raise_error(ArgumentError, /div_sec.*diverge/m)
      end

      it "updates a divergent section under :overwrite" do
        existing = create(
          :typed_section,
          entity_type: "Contact",
          scope: "sec_ow",
          name: "Old",
          code: "ow_sec",
          sort_order: 1,
          active: true,
        )
        hash = described_class.export_schema(entity_type: "Contact", scope: "sec_ow")
        hash["sections"].first["name"] = "New Name"
        hash["sections"].first["active"] = false

        result = described_class.import_schema(hash, on_conflict: :overwrite)

        expect(result["updated"]).to eq(1)
        existing.reload
        expect(existing.name).to eq("New Name")
        expect(existing.active).to be(false)
      end
    end
  end
end
