# frozen_string_literal: true

require "spec_helper"

# Phase 5 plan 03 Gating Decision 1: lazy soft-detect.
#
# The gem does NOT add `add_dependency "activestorage"` to its gemspec.
# Apps that don't use Image/File field types pay zero overhead AND don't
# need to pull Active Storage into their bundle. Mirrors the
# `acts_as_tenant` precedent (Config::DEFAULT_SCOPE_RESOLVER, lib/typed_eav/
# config.rb lines 49-53).
#
# This file covers BOTH branches of the soft-detect:
#   1. Loaded path: the dummy app loads Active Storage via
#      `require "rails/all"` (spec/dummy/config/environment.rb), so the
#      engine's after_initialize block ran register_attachment_associations!
#      and TypedEAV::Value#attachment is registered. Field::Image#cast
#      and Field::File#cast accept signed_id strings without raising.
#   2. Unloaded path: simulated via RSpec's `hide_const` (genuine
#      constant removal — `defined?(::ActiveStorage::Blob)` returns nil
#      while hidden). Field::Image#cast and Field::File#cast raise
#      NotImplementedError with an actionable message.
#
# `hide_const` is the right tool here. `stub_const("ActiveStorage::Blob", nil)`
# would replace the constant with nil, but `defined?(::ActiveStorage::Blob)`
# would still return "constant" (the constant exists, its value is just
# nil). Only `hide_const` makes `defined?` return nil — exactly the
# state the gem's runtime guard expects when AS is genuinely absent.
# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod -- describe
# target is a topical soft-detect surface (spans Engine seam + Field::Image
# + Field::File + TypedEAV::Value); the second argument is a phase-prose
# descriptor, not a method name.
RSpec.describe TypedEAV::Engine, "Active Storage soft-detect (Phase 5 plan 03)" do
  # rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
  describe "loaded path (dummy app loads Active Storage)" do
    it "registers has_one_attached :attachment on TypedEAV::Value" do
      reflection = TypedEAV::Value.reflect_on_attachment(:attachment)
      expect(reflection).not_to be_nil
      expect(reflection.macro).to eq(:has_one_attached)
    end

    it "Field::Image#cast accepts a signed_id String without raising" do
      field = TypedEAV::Field::Image.new(name: "as_loaded_img", entity_type: "Contact")
      expect(field.cast("some_signed_id_str")).to eq(["some_signed_id_str", false])
    end

    it "Field::File#cast accepts a signed_id String without raising" do
      field = TypedEAV::Field::File.new(name: "as_loaded_file", entity_type: "Contact")
      expect(field.cast("some_signed_id_str")).to eq(["some_signed_id_str", false])
    end

    it "Field::Image#validate_typed_value validates against the loaded Blob class" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("img"),
        filename: "i.png",
        content_type: "image/png",
      )
      field = TypedEAV::Field::Image.new(name: "loaded_img_validate", entity_type: "Contact")
      record = TypedEAV::Value.new
      field.validate_typed_value(record, blob.signed_id)
      expect(record.errors[:value]).to be_empty
    end
  end

  describe "unloaded path (simulated via hide_const)" do
    it "Field::Image#cast raises NotImplementedError when ActiveStorage::Blob is undefined" do
      hide_const("ActiveStorage::Blob")
      # Sanity check: the gem-wide soft-detect uses `defined?(::ConstantName)`
      # idiom — pinning to top-level namespace is intentional. The cop's
      # redundant-base flag is a false positive in this `defined?` context.
      expect(defined?(::ActiveStorage::Blob)).to be_nil # rubocop:disable Style/RedundantConstantBase -- pinning to top-level namespace inside `defined?` matches the gem's soft-detect idiom
      field = TypedEAV::Field::Image.new(name: "unloaded_img", entity_type: "Contact")
      expect { field.cast("anything") }.to raise_error(
        NotImplementedError,
        /TypedEAV::Field::Image requires Active Storage/,
      )
    end

    it "Field::File#cast raises NotImplementedError when ActiveStorage::Blob is undefined" do
      hide_const("ActiveStorage::Blob")
      field = TypedEAV::Field::File.new(name: "unloaded_file", entity_type: "Contact")
      expect { field.cast("anything") }.to raise_error(
        NotImplementedError,
        /TypedEAV::Field::File requires Active Storage/,
      )
    end

    it "Field::Image#validate_typed_value silently no-ops when ActiveStorage::Blob is undefined" do
      hide_const("ActiveStorage::Blob")
      field = TypedEAV::Field::Image.new(name: "unloaded_img_validate", entity_type: "Contact")
      record = TypedEAV::Value.new
      # validate_typed_value's own `defined?` guard prevents NameError on
      # the find_signed call. Errors stay empty — the cast layer is the
      # fail-fast surface; validate_typed_value is defensive.
      expect { field.validate_typed_value(record, "some_signed_id") }.not_to raise_error
      expect(record.errors[:value]).to be_empty
    end

    it "Field::Image still LOADS as a Ruby class when ActiveStorage::Blob is undefined" do
      # The class itself must remain inspectable — apps that never
      # touch Image/File should be able to query Field type metadata
      # without forcing AS into their bundle. The raise-on-call
      # contract ensures invocation fails, not class-load.
      hide_const("ActiveStorage::Blob")
      expect(TypedEAV::Field::Image.value_column).to eq(:string_value)
      expect(TypedEAV::Field::Image.supported_operators).to eq(%i[eq is_null is_not_null])
    end
  end

  describe ".register_attachment_associations! (testable seam)" do
    it "is idempotent — second call returns false (already registered)" do
      # First boot already ran the seam; calling again should short-
      # circuit on the @attachment_registered guard. The return value
      # is `false` whether the early-out reason is "AS unloaded" or
      # "already registered" — the contract is "safe to call multiple
      # times, no observable side effects after the first success."
      result = described_class.register_attachment_associations!
      expect(result).to be(false)
    end

    it "returns false when ActiveStorage::Blob is undefined (regardless of registration state)" do
      hide_const("ActiveStorage::Blob")
      result = described_class.register_attachment_associations!
      expect(result).to be(false)
    end
  end
end
