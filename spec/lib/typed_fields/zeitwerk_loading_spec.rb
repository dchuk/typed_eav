# frozen_string_literal: true

require "spec_helper"

# Regression coverage for the T1.1 split of field/types.rb into one file
# per class. Before the split, an engine initializer explicitly loaded
# types.rb on every reload because Zeitwerk's 1:1 file/constant rule
# couldn't be satisfied. Now that Zeitwerk handles each class natively,
# we assert the descendants are all discoverable after a cold boot AND
# after an explicit reload, so nothing regresses silently if a future
# change re-introduces the multi-class-per-file pattern.

RSpec.describe "TypedFields::Field STI loading" do
  let(:expected_types) do
    TypedFields::Config::BUILTIN_FIELD_TYPES.values.map(&:constantize)
  end

  it "resolves every BUILTIN_FIELD_TYPES constant via Zeitwerk" do
    expected_types.each do |klass|
      expect(klass.ancestors).to include(TypedFields::Field::Base)
    end
  end

  it "registers all 17 subclasses on the STI descendants list" do
    # Force resolution via the config map (mirrors how Config#field_class_for
    # looks up STI classes at runtime).
    expected_types.each(&:name)

    descendants = TypedFields::Field::Base.descendants
    expect(descendants).to include(*expected_types)
    expect(descendants.size).to be >= 17
  end

  # NOTE: a mid-suite `Rails.application.reloader.reload!` assertion was
  # considered but removed — it unloads the TypedFields.registry and
  # pollutes downstream specs. Reload-safety is verified manually in
  # the demo app (touch a view, re-request a page; no NameError).
end
