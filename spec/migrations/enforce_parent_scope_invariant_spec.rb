# frozen_string_literal: true

require "spec_helper"
require TypedEAV::Engine.root.join("db/migrate/20260712000000_enforce_parent_scope_invariant")

RSpec.describe EnforceParentScopeInvariant, type: :model do
  subject(:migration) { described_class.new }

  it "rejects validation-bypassing orphan-parent fields and accepts valid tuple shapes" do
    expect do
      in_savepoint do
        TypedEAV::Field::Base.insert_all!([field_attributes(name: "db_orphan_field", scope: nil, parent_scope: "w1")])
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /parent_scope_requires_scope/)

    rows = [
      field_attributes(name: "db_global_field", scope: nil, parent_scope: nil),
      field_attributes(name: "db_scoped_field", scope: "t1", parent_scope: nil),
      field_attributes(name: "db_full_field", scope: "t1", parent_scope: "w1"),
    ]
    TypedEAV::Field::Base.insert_all!(rows)

    expect(TypedEAV::Field::Base.where(name: %w[db_global_field db_scoped_field db_full_field]).count).to eq(3)
  end

  it "rejects validation-bypassing orphan-parent sections and accepts valid tuple shapes" do
    expect do
      in_savepoint do
        TypedEAV::Section.insert_all!([section_attributes(code: "db_orphan_section", scope: nil, parent_scope: "w1")])
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /parent_scope_requires_scope/)

    rows = [
      section_attributes(code: "db_global_section", scope: nil, parent_scope: nil),
      section_attributes(code: "db_scoped_section", scope: "t1", parent_scope: nil),
      section_attributes(code: "db_full_section", scope: "t1", parent_scope: "w1"),
    ]
    TypedEAV::Section.insert_all!(rows)

    expect(TypedEAV::Section.where(code: %w[db_global_section db_scoped_section db_full_section]).count).to eq(3)
  end

  it "stops with actionable evidence when an installation already contains malformed rows" do
    migration.migrate(:down)
    TypedEAV::Field::Base.insert_all!([field_attributes(name: "db_existing_orphan", scope: nil, parent_scope: "w1")])

    expect { migration.migrate(:up) }
      .to raise_error(ActiveRecord::MigrationError, /1 typed_eav_fields row.*parent_scope.*scope/i)

    TypedEAV::Field::Base.where(name: "db_existing_orphan").delete_all
    migration.migrate(:up)
  end

  def field_attributes(name:, scope:, parent_scope:)
    {
      name: name,
      type: "TypedEAV::Field::Text",
      entity_type: "Project",
      scope: scope,
      parent_scope: parent_scope,
      created_at: Time.current,
      updated_at: Time.current,
    }
  end

  def section_attributes(code:, scope:, parent_scope:)
    {
      name: code.humanize,
      code: code,
      entity_type: "Project",
      scope: scope,
      parent_scope: parent_scope,
      created_at: Time.current,
      updated_at: Time.current,
    }
  end

  def in_savepoint(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
  end
end
