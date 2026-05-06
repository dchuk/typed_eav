# frozen_string_literal: true

require "spec_helper"

RSpec.describe TypedEAV::Versioned do
  # Throwaway host classes to exercise the included hook. We use unique
  # class names so Registry entries don't collide across examples.
  # rubocop:disable RSpec/InstanceVariable -- snapshot/restore across before/after needs cross-hook state; let blocks don't span hooks.
  before { @saved_entities = TypedEAV.registry.entities.dup }
  after  { TypedEAV.registry.instance_variable_set(:@entities, @saved_entities) }
  # rubocop:enable RSpec/InstanceVariable

  describe "post-has_typed_eav opt-in" do
    let(:host_class) do
      stub_class_name = "VersionedConcernTestHost1"
      # rubocop:disable Rails/ApplicationRecord -- gem-level spec uses AR::Base directly; no app-level base class side effects desired.
      Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        define_singleton_method(:name) { stub_class_name }
      end
    end

    it "sets versioned: true on the Registry entry when included after has_typed_eav" do
      host_class.has_typed_eav(types: %i[text integer])
      host_class.include(described_class)

      expect(TypedEAV.registry.versioned?("VersionedConcernTestHost1")).to be(true)
    end

    it "preserves the existing types: restriction" do
      host_class.has_typed_eav(types: %i[text integer])
      host_class.include(described_class)

      expect(TypedEAV.registry.allowed_types_for("VersionedConcernTestHost1")).to eq(%i[text integer])
    end

    it "preserves nil types: (no restriction)" do
      host_class.has_typed_eav(types: nil)
      host_class.include(described_class)

      expect(TypedEAV.registry.entities["VersionedConcernTestHost1"]).to eq(types: nil, versioned: true)
    end

    it "is equivalent to has_typed_eav versioned: true (state shape match)" do
      # rubocop:disable Rails/ApplicationRecord
      kwarg_class = Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "EquivKwargTest"
      end
      kwarg_class.has_typed_eav(types: %i[text], versioned: true)

      # rubocop:disable Rails/ApplicationRecord
      include_class = Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "EquivIncludeTest"
      end
      include_class.has_typed_eav(types: %i[text])
      include_class.include(described_class)

      expect(TypedEAV.registry.entities["EquivKwargTest"])
        .to eq(TypedEAV.registry.entities["EquivIncludeTest"])
    end
  end

  describe "precondition (has_typed_eav must run first)" do
    it "raises ArgumentError when included on a model that did not call has_typed_eav" do
      # rubocop:disable Rails/ApplicationRecord
      bad_class = Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "BadHostNoHasTypedEAV"
      end

      expect { bad_class.include(described_class) }
        .to raise_error(ArgumentError, /requires `has_typed_eav` to have run first/)
    end

    it "error message names the offending class" do
      # rubocop:disable Rails/ApplicationRecord
      bad_class = Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "BadHostNamedInError"
      end

      expect { bad_class.include(described_class) }
        .to raise_error(ArgumentError, /BadHostNamedInError/)
    end

    it "error message suggests the kwarg form alternative" do
      # rubocop:disable Rails/ApplicationRecord
      bad_class = Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "BadHostKwargSuggestion"
      end

      expect { bad_class.include(described_class) }
        .to raise_error(ArgumentError, /versioned: true/)
    end
  end

  describe "double-include (idempotent)" do
    let(:host_class) do
      # rubocop:disable Rails/ApplicationRecord
      Class.new(ActiveRecord::Base) do
        # rubocop:enable Rails/ApplicationRecord
        self.table_name = "contacts"
        def self.name = "DoubleIncludeTest"
      end
    end

    it "is safe to include twice (Registry overwrite is idempotent for this state)" do
      host_class.has_typed_eav(types: %i[text])
      host_class.include(described_class)

      # AR's include is idempotent — re-including a module is a no-op.
      # Even so, ensure the Registry stays consistent across re-includes.
      host_class.include(described_class)

      expect(TypedEAV.registry.entities["DoubleIncludeTest"]).to eq(types: %i[text], versioned: true)
    end
  end
end
