# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::FieldDeletion, :event_callbacks, :real_commits do
  before do
    TypedEAV.registry.register("Contact", types: nil, versioned: true)
    TypedEAV.config.versioning = true
    TypedEAV::Versioning.register_if_enabled
  end

  after { TypedEAV.registry.register("Contact", types: nil, versioned: false) }

  def build_field(name: "batched_delete", policy: "destroy")
    create(:text_field, name: name, entity_type: "Contact", field_dependent: policy)
  end

  it "deletes exact-field values in committed keyset batches and preserves versions" do
    contact = create(:contact)
    sibling_contact = create(:contact)
    field = build_field
    sibling = build_field(name: "sibling_delete")
    TypedEAV::Value.create!(entity: contact, field: field, value: "target")
    TypedEAV::Value.create!(entity: sibling_contact, field: sibling, value: "sibling")

    expect { field.destroy_with_values_in_batches!(batch_size: 1) }
      .to change(TypedEAV::Field::Base, :count).by(-1)

    expect(TypedEAV::Value.where(field_id: field.id)).to be_empty
    expect(TypedEAV::Value.where(field_id: sibling.id)).to exist
    expect(TypedEAV::ValueVersion.where(entity_id: contact.id, change_type: "destroy")).to exist
    expect(TypedEAV::ValueVersion.where(entity_id: sibling_contact.id, change_type: "destroy")).to be_empty
  end

  # rubocop:disable RSpec/ExampleLength -- the assertions cover committed-batch and retry invariants together.
  it "retains the Field and rolls back a failed batch, then resumes remaining rows" do
    contacts = 3.times.map { |index| create(:contact, name: "retry-#{index}") }
    field = build_field(name: "retry_delete")
    values = contacts.each_with_index.map do |contact, index|
      TypedEAV::Value.create!(entity: contact, field: field, value: index.to_s)
    end
    failure_pending = true
    failing_id = values.last.id

    allow(TypedEAV::Value).to receive(:find).and_wrap_original do |original, value_id|
      value = original.call(value_id)
      if value_id == failing_id && failure_pending
        failure_pending = false
        allow(value).to receive(:destroy!).and_raise(RuntimeError, "forced batch failure")
      end
      value
    end

    expect { field.destroy_with_values_in_batches!(batch_size: 2) }
      .to raise_error(RuntimeError, "forced batch failure")
    expect(TypedEAV::Field::Base.where(id: field.id)).to exist
    expect(TypedEAV::Value.where(field_id: field.id).pluck(:id)).to eq([values.last.id])
    expect(TypedEAV::ValueVersion.where(entity_id: contacts.map(&:id), change_type: "destroy").count).to eq(2)
    expect(
      TypedEAV::ValueVersion
        .where(entity_id: contacts.first(2).map(&:id), change_type: "destroy")
        .group(:entity_id).count,
    )
      .to eq(contacts.first(2).to_h { |contact| [contact.id, 1] })

    allow(TypedEAV::Value).to receive(:find).and_call_original
    expect { field.reload.destroy_with_values_in_batches!(batch_size: 2) }.not_to raise_error
    expect(TypedEAV::Field::Base.where(id: field.id)).to be_empty
    expect(TypedEAV::Value.where(field_id: field.id)).to be_empty
    expect(TypedEAV::ValueVersion.where(entity_id: contacts.map(&:id), change_type: "destroy").count).to eq(3)
    expect(TypedEAV::ValueVersion.where(entity_id: contacts.map(&:id), change_type: "destroy").group(:entity_id).count)
      .to eq(contacts.to_h { |contact| [contact.id, 1] })
  end

  it "rejects invalid policy, transaction, and batch inputs before mutation" do
    field = build_field(policy: "nullify")

    expect { field.destroy_with_values_in_batches! }.to raise_error(ArgumentError, /field_dependent/)
    expect(TypedEAV::Field::Base.where(id: field.id)).to exist

    field.update!(field_dependent: "destroy")
    expect { field.destroy_with_values_in_batches!(batch_size: 0) }
      .to raise_error(ArgumentError, /batch_size/)
    expect { TypedEAV::Field::Base.transaction { field.destroy_with_values_in_batches! } }
      .to raise_error(ArgumentError, /open transaction/)
    expect(TypedEAV::Field::Base.where(id: field.id)).to exist
  end

  it "fails closed when the participating models use different pools" do
    field = build_field
    foreign_pool = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
    allow(TypedEAV::Value).to receive(:connection_pool).and_return(foreign_pool)

    expect { field.destroy_with_values_in_batches! }
      .to raise_error(ArgumentError, /share a connection pool/)
    expect(TypedEAV::Field::Base.where(id: field.id)).to exist
  end

  it "bounds final residual draining and retains the Field when it exceeds the batch" do
    contacts = 2.times.map { |index| create(:contact, name: "late-#{index}") }
    field = build_field(name: "bounded_finalization")
    allow(field).to receive(:lock!).and_wrap_original do |original|
      original.call.tap do
        contacts.each_with_index do |contact, index|
          TypedEAV::Value.create!(entity: contact, field: field, value: "late-#{index}")
        end
      end
    end

    expect { field.destroy_with_values_in_batches!(batch_size: 1) }
      .to raise_error(RuntimeError, /residual drain/)
    expect(TypedEAV::Field::Base.where(id: field.id)).to exist
  end

  it "holds the Field lock against a concurrent foreign-key insertion" do
    contact = create(:contact)
    field = build_field(name: "locked_finalization")
    result = Queue.new
    ready = Queue.new

    allow(field).to receive(:lock!).and_wrap_original do |original|
      original.call
      thread = Thread.new do
        TypedEAV::Value.connection_pool.with_connection do
          connection = TypedEAV::Value.connection
          connection.execute("SET lock_timeout = '250ms'")
          ready << :attempting
          begin
            TypedEAV::Value.create!(entity: contact, field: field, value: "blocked")
            result << :inserted
          rescue ActiveRecord::LockWaitTimeout
            result << :blocked
          ensure
            connection.execute("SET lock_timeout = '0'")
          end
        end
      end

      expect(ready.pop).to eq(:attempting)
      thread.join
      expect(result.pop).to eq(:blocked)
    end

    expect { field.destroy_with_values_in_batches!(batch_size: 1) }.not_to raise_error
    expect(TypedEAV::Value.where(field_id: field.id)).to be_empty
  end
  # rubocop:enable RSpec/ExampleLength
end
