# frozen_string_literal: true

module TypedEAV
  module HasTypedEAV
    # Read-only, on-demand dirty tracking for typed Value rows that are part
    # of a host association's in-memory target.
    #
    # Pending comparisons follow Active Record's own dirty state; saved
    # snapshots use the host lifecycle, not a separate Value mutation registry.
    # A typed Value
    # retains its database snapshot through `attribute_in_database`, while
    # autosave clears its ordinary dirty state after a successful host save.
    # Consequently failed saves and outer transaction rollbacks retain the
    # same correction-friendly state that Active Record exposes on the child.
    #
    # The association target is inspected without loading it. Named and
    # nested assignment paths already place their touched Values in that
    # target; callers using direct Value assignment should use a loaded
    # `typed_values` association. A Value loaded independently from the host
    # is intentionally outside this API because observing it would require an
    # eager query of every Value row or a new global mutation registry.
    module DirtyTracking
      extend ActiveSupport::Concern

      included do
        # Register before has_typed_eav declares the autosave association.
        # Active Model prepends after_* callbacks, so the later autosave
        # callback executes after this capture. The public save wrappers
        # restore prior state when a later save callback raises.
        after_create :_typed_eav_capture_saved_changes
        after_update :_typed_eav_capture_saved_changes
        after_destroy :_typed_eav_clear_saved_changes
      end

      # Pending typed-value changes keyed by effective Field name.
      #
      # The returned hash and pairs are fresh objects. Before-values are
      # reconstructed from the stored physical cells through the Field's
      # public logical reader, so multi-cell fields retain the same shape as
      # `typed_eav_value` rather than exposing storage-column details.
      def typed_eav_changes
        values = typed_eav_pending_values
        return {} if values.empty?

        names_by_field_id = typed_eav_effective_field_names
        changes_by_field_id = typed_eav_change_pairs(values, names_by_field_id)

        changes_by_field_id.each_with_object({}) do |(field_id, pair), changes|
          name = names_by_field_id[field_id]
          next unless name
          next if pair[0] == pair[1]

          changes[name] = pair.map(&:deep_dup)
        end
      end

      # Logical changes from the most recent successful host save. The value
      # is intentionally available in host `after_save` callbacks, where the
      # child autosave has already consumed ordinary dirty state. This is
      # successful-save state, not evidence that an outer transaction later
      # committed and not a replacement for ValueVersion history.
      def saved_typed_eav_changes
        (@typed_eav_saved_changes || {}).deep_dup
      end

      # Bracket the complete public save call, including callbacks that run
      # after the model's create/update callbacks. An around_save callback
      # cannot rescue an after_save callback that is compiled outside its
      # around sequence, but these wrappers can restore the previous snapshot
      # for both false returns and raised errors.
      def save(...)
        _typed_eav_track_save { super }
      end

      def save!(...)
        _typed_eav_track_save { super }
      end

      private

      # Capture from the host lifecycle before autosave runs. Because this
      # callback was registered before the association's autosave callback,
      # before_save mutations and marked-for-destruction Values are still
      # observable here.
      def _typed_eav_capture_saved_changes
        # A record-level rollback callback can be skipped after a later
        # failed validation; use Rails' transaction-level callback instead.
        self.class.current_transaction.after_rollback { _typed_eav_clear_saved_changes }
        @typed_eav_saved_changes = typed_eav_changes.deep_dup
      end

      # Keep failed saves from replacing the last successful result. A normal
      # return of false is handled here as well as exceptions raised by save
      # callbacks or autosave. If the failed save opened a transaction that
      # rolled back, Active Record may have cleared the snapshot before this
      # wrapper resumes; restoring `previous` here preserves the failed-save
      # contract. A successful save leaves the new snapshot in place until a
      # later outer rollback callback clears it.
      def _typed_eav_track_save
        previous = @typed_eav_saved_changes
        result = yield

        @typed_eav_saved_changes = previous unless result
        result
      rescue StandardError
        @typed_eav_saved_changes = previous
        raise
      end

      def _typed_eav_clear_saved_changes
        @typed_eav_saved_changes = {}
      end

      public

      # Reload replaces the host's association target. Clear the separate
      # saved snapshot at the same boundary so it cannot outlive the state it
      # describes.
      def reload(...)
        super.tap { _typed_eav_clear_saved_changes }
      end

      private

      # Reading `target` is the important lazy boundary: calling the public
      # dirty API on an untouched host never issues a typed_values SELECT.
      # `build` adds to target without marking the association loaded, so the
      # direct-association path is covered as well.
      def typed_eav_pending_values
        typed_values.target.select do |value|
          next false if value.destroyed?
          next false if value.new_record? && value.marked_for_destruction?

          typed_eav_value_pending?(value)
        end
      end

      def typed_eav_value_pending?(value)
        return true if value.marked_for_destruction? && value.persisted?
        return false unless value.changed?

        field = value.field
        return false unless field

        field.class.value_columns.any? do |column|
          value.will_save_change_to_attribute?(column)
        end
      end

      # Resolve names only after finding a changed Value. This keeps ordinary
      # reads and saves free of definition queries while preserving the same
      # collision precedence used by `typed_eav_value` and `typed_eav_hash`.
      def typed_eav_effective_field_names
        typed_eav_defs_by_name.each_with_object({}) do |(name, field), names|
          names[field.id] = name
        end
      end

      def typed_eav_change_pairs(values, names_by_field_id)
        values.each_with_object({}) do |value, changes|
          change = typed_eav_change_for(value, names_by_field_id)
          next unless change

          field_id, pair = change
          merge_typed_eav_change(changes, field_id, pair)
        end
      end

      def typed_eav_change_for(value, names_by_field_id)
        field = value.field
        field_id = value.field_id || field&.id
        return unless field && field_id && names_by_field_id.key?(field_id)

        before = typed_eav_before_value(value, field)
        after = value.marked_for_destruction? ? nil : field.read_value(value)
        return if before == after

        [field_id, [before, after]]
      end

      # One Value row per field is the normal shape. Keep the first non-nil
      # before-state when a target temporarily contains both an old marked row
      # and a replacement build; this preserves the original persisted
      # baseline while the final target row supplies the after-state.
      def merge_typed_eav_change(changes, field_id, pair)
        return changes[field_id] = pair unless changes.key?(field_id)

        changes[field_id][0] = pair[0] if changes[field_id][0].nil? && !pair[0].nil?
        changes[field_id][1] = pair[1]
      end

      # Use the original stored cells as a lightweight Value snapshot and
      # invoke the Field's logical reader. This is intentionally not a second
      # representation of multi-cell values; Field#read_value remains the
      # single source of truth for both current and prior values.
      def typed_eav_before_value(value, field)
        return nil if value.new_record?

        snapshot = value.dup
        field.class.value_columns.each do |column|
          snapshot[column] = value.attribute_in_database(column)
        end
        field.read_value(snapshot)
      end
    end
  end
end
