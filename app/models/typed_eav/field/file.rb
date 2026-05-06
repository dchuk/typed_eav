# frozen_string_literal: true

module TypedEAV
  module Field
    # Active Storage-backed field type for non-image file attachments.
    # Stores the attached blob's `signed_id` (a String) in `string_value`.
    # Same shape as Field::Image — see image.rb for the full soft-detect
    # rationale, signed_id storage choice, and option semantics.
    #
    # ## Image vs File
    #
    # Both classes share the same shared `:attachment` has_one_attached
    # association on TypedEAV::Value (declared once in engine.rb's
    # config.after_initialize block; see RESEARCH §Risk 3 for the rationale
    # against per-class associations). The semantic distinction at runtime
    # is `value.field.is_a?(TypedEAV::Field::Image)` vs `is_a?(File)`. The
    # blob's content_type is the source of truth for image-vs-other-file.
    #
    # The on_image_attached hook (Phase 05) fires ONLY for Field::Image —
    # File has no parallel hook by ROADMAP design. Apps that need a
    # generic file-attached signal use on_value_change (Phase 03) or
    # subscribe to ActiveSupport::Notifications directly.
    #
    # ## Namespace shadowing note
    #
    # `TypedEAV::Field::File` shadows Ruby's top-level `::File` constant
    # inside the TypedEAV::Field namespace. Internal code that needs the
    # Ruby File class (none in this file) must reference it as `::File`
    # to avoid ambiguity. This is intentional and matches the gem's
    # one-class-per-file STI convention; renaming to FileAttachment
    # would diverge from Image (also a single-word noun).
    class File < Base
      value_column :string_value

      operators(*%i[eq is_null is_not_null])

      store_accessor :options, :allowed_content_types, :max_size_bytes

      # See TypedEAV::Field::Image#cast for the full contract — File's
      # cast is identical except for the NotImplementedError message.
      def cast(raw)
        unless defined?(::ActiveStorage::Blob)
          raise NotImplementedError,
                "TypedEAV::Field::File requires Active Storage. " \
                "Add `gem 'activestorage'` to your Gemfile (already " \
                "included via the `rails` meta-gem in Rails 7.1+) and " \
                "run `bin/rails active_storage:install`."
        end

        return [nil, false] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
        return [raw.signed_id, false] if raw.is_a?(::ActiveStorage::Blob)
        return [raw, false] if raw.is_a?(String)

        [nil, true]
      end

      # See TypedEAV::Field::Image#validate_typed_value for the full
      # contract — File's validation is identical (it accepts the same
      # allowed_content_types / max_size_bytes options). Apps that want
      # image-only mime restrictions configure
      # `allowed_content_types: ["image/*"]`; otherwise the field is a
      # general-purpose attachment slot.
      def validate_typed_value(record, val)
        return if val.nil?
        return unless defined?(::ActiveStorage::Blob)

        blob = ::ActiveStorage::Blob.find_signed(val)
        if blob.nil?
          record.errors.add(:value, :invalid)
          return
        end

        if allowed_content_types.present? && !content_type_matches?(blob.content_type)
          record.errors.add(
            :value,
            "must be one of #{Array(allowed_content_types).join(", ")}",
          )
        end

        return unless max_size_bytes.present? && blob.byte_size > max_size_bytes.to_i

        record.errors.add(:value, "exceeds max size #{max_size_bytes} bytes")
      end

      private

      def content_type_matches?(blob_content_type)
        Array(allowed_content_types).any? do |pattern|
          if pattern.end_with?("/*")
            blob_content_type&.start_with?(pattern.sub("/*", "/"))
          else
            blob_content_type == pattern
          end
        end
      end
    end
  end
end
