# frozen_string_literal: true

require "spec_helper"

# Unit specs for TypedEAV::EventDispatcher. Exercises the in-process
# dispatch contract via doubles + lambdas — no AR records needed. The
# integration side (real after_commit firing on Value / Field) lives in
# spec/models/typed_eav/{value,field}_event_spec.rb.
#
# All examples opt into `:event_callbacks` so Config user procs and the
# internal-subscriber lists are snapshot/restored around each example.
# Live validation of value.id readability post-destroy lives in
# spec/models/typed_eav/value_event_spec.rb (requires a real AR record).
RSpec.describe TypedEAV::EventDispatcher, :event_callbacks do
  let(:value_double) { instance_double(TypedEAV::Value, id: 1, field_id: 2) }
  let(:field_double) { instance_double(TypedEAV::Field::Base, id: 3, name: "test_field") }

  describe "internal-subscriber registration" do
    it "value_change_internals returns an Array that persists registrations across calls" do
      cb = ->(_v, _t, _c) {}
      described_class.register_internal_value_change(cb)
      expect(described_class.value_change_internals).to be_a(Array)
      expect(described_class.value_change_internals).to include(cb)
    end

    it "field_change_internals returns an Array that persists registrations across calls" do
      cb = ->(_f, _t) {}
      described_class.register_internal_field_change(cb)
      expect(described_class.field_change_internals).to be_a(Array)
      expect(described_class.field_change_internals).to include(cb)
    end

    it "preserves registration order across multiple registrations on value_change_internals" do
      cb1 = ->(_v, _t, _c) {}
      cb2 = ->(_v, _t, _c) {}
      cb3 = ->(_v, _t, _c) {}
      described_class.register_internal_value_change(cb1)
      described_class.register_internal_value_change(cb2)
      described_class.register_internal_value_change(cb3)
      expect(described_class.value_change_internals).to eq([cb1, cb2, cb3])
    end

    it "preserves registration order across multiple registrations on field_change_internals" do
      cb1 = ->(_f, _t) {}
      cb2 = ->(_f, _t) {}
      described_class.register_internal_field_change(cb1)
      described_class.register_internal_field_change(cb2)
      expect(described_class.field_change_internals).to eq([cb1, cb2])
    end
  end

  describe "dispatch_value_change" do
    it "fires internals first (in registration order), then user proc last" do
      sequence = []
      described_class.register_internal_value_change(
        ->(_v, _t, _c) { sequence << :internal_first },
      )
      described_class.register_internal_value_change(
        ->(_v, _t, _c) { sequence << :internal_second },
      )
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { sequence << :user }

      described_class.dispatch_value_change(value_double, :create)

      expect(sequence).to eq(%i[internal_first internal_second user])
    end

    it "passes (value, change_type, current_context) to internals AND user proc" do
      seen_internal = nil
      seen_user = nil
      described_class.register_internal_value_change(
        ->(v, t, c) { seen_internal = [v, t, c] },
      )
      TypedEAV::Config.on_value_change = ->(v, t, c) { seen_user = [v, t, c] }

      TypedEAV.with_context(actor_id: 42) do
        described_class.dispatch_value_change(value_double, :update)
      end

      expect(seen_internal).to eq([value_double, :update, { actor_id: 42 }])
      expect(seen_user).to eq([value_double, :update, { actor_id: 42 }])
    end

    it "captures context once per dispatch — internals and user proc see the same Hash instance" do
      captures = []
      described_class.register_internal_value_change(
        ->(_v, _t, c) { captures << c.object_id },
      )
      TypedEAV::Config.on_value_change = ->(_v, _t, c) { captures << c.object_id }

      TypedEAV.with_context(request_id: "abc") do
        described_class.dispatch_value_change(value_double, :create)
      end

      expect(captures.uniq.size).to eq(1) # both saw the same frozen Hash
    end

    it "internal raise propagates (fail-closed)" do
      described_class.register_internal_value_change(
        ->(_v, _t, _c) { raise "internal-boom" },
      )

      expect do
        described_class.dispatch_value_change(value_double, :create)
      end.to raise_error(RuntimeError, "internal-boom")
    end

    it "internal raise prevents user proc from firing (short-circuits the chain)" do
      user_fired = false
      described_class.register_internal_value_change(
        ->(_v, _t, _c) { raise "boom" },
      )
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { user_fired = true }

      expect do
        described_class.dispatch_value_change(value_double, :create)
      end.to raise_error(RuntimeError, "boom")
      expect(user_fired).to be(false)
    end

    it "user-proc raise is rescued + logged via Rails.logger.error + swallowed" do
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { raise "user-boom" }
      allow(Rails.logger).to receive(:error)

      expect do
        described_class.dispatch_value_change(value_double, :create)
      end.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/on_value_change raised/)
    end

    it "logs the value_id, field_id, and change_type in the error message" do
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { raise "boom" }
      allow(Rails.logger).to receive(:error)

      described_class.dispatch_value_change(value_double, :destroy)

      expect(Rails.logger).to have_received(:error)
        .with(a_string_matching(/value_id=1.*field_id=2.*change_type=destroy/))
    end

    it "is a no-op when no internals registered and on_value_change is nil" do
      expect do
        described_class.dispatch_value_change(value_double, :create)
      end.not_to raise_error
    end
  end

  describe "dispatch_field_change" do
    it "passes (field, change_type) — TWO args, no context" do
      seen_internal = nil
      seen_user = nil
      described_class.register_internal_field_change(
        ->(*args) { seen_internal = args },
      )
      TypedEAV::Config.on_field_change = ->(*args) { seen_user = args }

      described_class.dispatch_field_change(field_double, :rename)

      expect(seen_internal).to eq([field_double, :rename])
      expect(seen_internal.size).to eq(2)
      expect(seen_user).to eq([field_double, :rename])
      expect(seen_user.size).to eq(2)
    end

    it "fires internals first then user proc last" do
      sequence = []
      described_class.register_internal_field_change(
        ->(_f, _t) { sequence << :internal },
      )
      TypedEAV::Config.on_field_change = ->(_f, _t) { sequence << :user }

      described_class.dispatch_field_change(field_double, :create)

      expect(sequence).to eq(%i[internal user])
    end

    it "internal raise propagates (fail-closed)" do
      described_class.register_internal_field_change(
        ->(_f, _t) { raise "field-internal-boom" },
      )
      expect do
        described_class.dispatch_field_change(field_double, :update)
      end.to raise_error(RuntimeError, "field-internal-boom")
    end

    it "user-proc raise is rescued + logged via Rails.logger.error + swallowed" do
      TypedEAV::Config.on_field_change = ->(_f, _t) { raise "user-boom" }
      allow(Rails.logger).to receive(:error)

      expect do
        described_class.dispatch_field_change(field_double, :rename)
      end.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/on_field_change raised/)
    end

    it "logs the field_id, field_name, and change_type in the error message" do
      TypedEAV::Config.on_field_change = ->(_f, _t) { raise "boom" }
      allow(Rails.logger).to receive(:error)

      described_class.dispatch_field_change(field_double, :rename)

      expect(Rails.logger).to have_received(:error)
        .with(a_string_matching(/field_id=3.*field_name=test_field.*change_type=rename/))
    end
  end

  describe "user-proc reassignment safety" do
    it "reassigning Config.on_value_change does NOT disable internal subscribers" do
      internal_calls = 0
      described_class.register_internal_value_change(
        ->(_v, _t, _c) { internal_calls += 1 },
      )

      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { :first }
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) { :second }

      described_class.dispatch_value_change(value_double, :create)

      expect(internal_calls).to eq(1)
    end
  end

  describe "reset semantics" do
    it "EventDispatcher.reset! clears value_change_internals AND field_change_internals" do
      described_class.register_internal_value_change(->(_v, _t, _c) {})
      described_class.register_internal_field_change(->(_f, _t) {})

      described_class.reset!

      expect(described_class.value_change_internals).to eq([])
      expect(described_class.field_change_internals).to eq([])
    end

    it "EventDispatcher.reset! does NOT touch Config.on_value_change / on_field_change" do
      v_proc = ->(_v, _t, _c) {}
      f_proc = ->(_f, _t) {}
      TypedEAV::Config.on_value_change = v_proc
      TypedEAV::Config.on_field_change = f_proc
      described_class.register_internal_value_change(->(_v, _t, _c) {})

      described_class.reset!

      expect(TypedEAV::Config.on_value_change).to equal(v_proc)
      expect(TypedEAV::Config.on_field_change).to equal(f_proc)
    end

    # Amendment 4 — automated coverage of plan 03-01 P03's reset! extension.
    # Pairs with the EventDispatcher.reset! tests above to give complete
    # coverage of the locked split-reset contract from 03-CONTEXT.md.
    it "Config.reset! resets both user procs back to nil" do
      TypedEAV::Config.on_value_change = ->(_v, _t, _c) {}
      TypedEAV::Config.on_field_change = ->(_f, _t) {}

      TypedEAV::Config.reset!

      expect(TypedEAV::Config.on_value_change).to be_nil
      expect(TypedEAV::Config.on_field_change).to be_nil
    end

    it "Config.reset! does NOT clear EventDispatcher internal-subscribers arrays" do
      v_internal = ->(_v, _t, _c) {}
      f_internal = ->(_f, _t) {}
      described_class.register_internal_value_change(v_internal)
      described_class.register_internal_field_change(f_internal)

      TypedEAV::Config.reset!

      expect(described_class.value_change_internals).to include(v_internal)
      expect(described_class.field_change_internals).to include(f_internal)
    end
  end
end
