# frozen_string_literal: true

module TypedEAV
  module SchemaPortability
    class ImportIndex
      attr_reader :fields, :sections

      def initialize(field_entries, section_entries)
        @fields = preload_fields(field_entries)
        @sections = preload_sections(section_entries)
      end

      def field_identity(field_or_entry)
        identity(field_or_entry, :name)
      end

      def section_identity(section_or_entry)
        identity(section_or_entry, :code)
      end

      private

      def preload_fields(entries)
        return {} if entries.empty?

        identity_relation(TypedEAV::Field::Base, entries, :name)
          .includes(:field_options)
          .index_by { |field| field_identity(field) }
      end

      def preload_sections(entries)
        return {} if entries.empty?

        identity_relation(TypedEAV::Section, entries, :code)
          .index_by { |section| section_identity(section) }
      end

      def identity_relation(model, entries, key)
        relations = entries.uniq { |entry| identity(entry, key) }.map do |entry|
          model.where(
            key => entry[key.to_s],
            entity_type: entry["entity_type"],
            scope: entry["scope"],
            parent_scope: entry["parent_scope"],
          )
        end
        relations.reduce { |union, relation| union.or(relation) }
      end

      def identity(record_or_entry, key)
        attributes = [key, :entity_type, :scope, :parent_scope]
        return attributes.map { |attribute| record_or_entry[attribute.to_s] } if record_or_entry.is_a?(Hash)

        attributes.map { |attribute| record_or_entry.public_send(attribute) }
      end
    end
  end
end
