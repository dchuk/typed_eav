# frozen_string_literal: true

module TypedEAV
  module Field
    # Active Storage-backed field type for image attachments. Stores the
    # attached blob's `signed_id` (a String) in `string_value`. The
    # actual `:attachment` has_one_attached association lives on
    # TypedEAV::Value (registered in lib/typed_eav/engine.rb's
    # config.after_initialize block when ActiveStorage::Blob is defined).
    #
    # ## Phase 05 Gating Decision 1: lazy soft-detect
    #
    # The gem does NOT add `add_dependency 'activestorage'` to its gemspec.
    # When Active Storage is absent at runtime, this class still LOADS
    # (Zeitwerk autoloads it; constants are inspectable without forcing
    # AS load). #cast and #validate_typed_value short-circuit / raise on
    # invocation:
    #
    #   - #cast raises NotImplementedError with an actionable install
    #     message (the only cast contract that can fail-fast — every
    #     write path goes through cast).
    #   - #validate_typed_value silently no-ops when AS is unloaded
    #     (validation runs against blob lookup, which can't happen).
    #
    # Mirrors the acts_as_tenant precedent (Config::DEFAULT_SCOPE_RESOLVER
    # in lib/typed_eav/config.rb lines 49-53) — `defined?(::ConstantName)`
    # is the gem-wide soft-detect idiom.
    #
    # ## signed_id storage choice
    #
    # signed_id is a stable, portable, message-verified handle that
    # survives blob replacement and decouples the gem's data shape from
    # ActiveStorage's internal blob-id format. Storing the bare integer
    # blob_id would couple the gem's persisted data to AS's primary-key
    # type and prevent migrations like UUID-typed blobs. signed_id is
    # always a String → string_value is the natural typed column.
    #
    # ## Operators
    #
    # Explicit narrowing to [:eq, :is_null, :is_not_null]. Numeric and
    # string-pattern operators (:contains, :starts_with) don't apply to
    # signed_id strings (they're message-signed opaque tokens). Presence
    # checks via :is_null / :is_not_null are the canonical "does this
    # entity have an attachment?" query.
    #
    # ## Options
    #
    # - allowed_content_types: Array<String> — content-type allowlist
    #   for validate_typed_value. Supports exact matches ("image/png")
    #   and wildcard families ("image/*").
    # - max_size_bytes: Integer — maximum blob byte_size accepted by
    #   validate_typed_value. Pass as Integer or numeric String; nil
    #   disables the size cap.
    #
    # ## Attachment access
    #
    # Read-side: `value.attachment.attached?`, `value.attachment.blob`,
    # `value.attachment.url` (Rails standard helpers — typed_eav doesn't
    # wrap them).
    # Write-side: `value.attachment.attach(io: ..., filename: ...,
    # content_type: ...)`, then `value.update!(string_value: value
    # .attachment.blob.signed_id)`. The signed_id assignment is what
    # the typed_eav read path serves; the attachment association is the
    # AS-native handle.
    class Image < Base
      value_column :string_value

      operators(*%i[eq is_null is_not_null])

      store_accessor :options, :allowed_content_types, :max_size_bytes

      # Cast contract:
      # - nil / blank → [nil, false]
      # - String → treated as a signed_id; passthrough as [raw, false]
      # - ActiveStorage::Blob → [blob.signed_id, false]
      # - any other shape (File, Tempfile, IO, Hash) → [nil, true]
      #   (apps must call value.attachment.attach(io: ...) directly,
      #   then assign the blob's signed_id back through value=)
      #
      # Raises NotImplementedError when ::ActiveStorage::Blob is undefined.
      # The raise lives in cast (not in the class body) so the constant
      # itself loads cleanly under Zeitwerk even when AS is absent —
      # consumers inspecting `TypedEAV::Field::Image.value_column` are
      # not forced to install AS.
      def cast(raw)
        unless defined?(::ActiveStorage::Blob)
          raise NotImplementedError,
                "TypedEAV::Field::Image requires Active Storage. " \
                "Add `gem 'activestorage'` to your Gemfile (already " \
                "included via the `rails` meta-gem in Rails 7.1+) and " \
                "run `bin/rails active_storage:install`."
        end

        return [nil, false] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
        return [raw.signed_id, false] if raw.is_a?(::ActiveStorage::Blob)
        return [raw, false] if raw.is_a?(String)

        [nil, true]
      end

      # Validates a casted signed_id String. Looks up the blob via
      # `ActiveStorage::Blob.find_signed` (returns nil for tampered/
      # expired tokens — flagged as :invalid). When allowed_content_types
      # is set, asserts blob.content_type matches one entry (exact or
      # `image/*` wildcard). When max_size_bytes is set, asserts
      # blob.byte_size <= the limit.
      #
      # Silently no-ops when Active Storage is unloaded — the raise
      # happens in cast (the only path that reaches save) so this is
      # defensive belt-and-suspenders. Without this guard, a soft-
      # detect-aware host could call validate_typed_value directly via
      # introspection and trigger NameError at runtime; the no-op
      # preserves the lazy contract.
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

      # Match against allowed_content_types entries. An entry ending in
      # `/*` (e.g., "image/*") matches any content type with the same
      # family prefix; otherwise an exact string match is required.
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
