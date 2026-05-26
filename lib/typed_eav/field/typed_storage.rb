# frozen_string_literal: true

module TypedEAV
  module Field
    # One concern owns the entire native-typed-column storage seam.
    #
    # Field types declare WHICH typed column(s) hold their value via the
    # class-level DSL (`value_column`, `value_columns`, `operators`,
    # `operator_column`), and override three instance methods to compose
    # multi-cell value shapes (`read_value`, `write_value`, `apply_default`).
    # Snapshot/change-detection helpers (`value_changed?`, `before_snapshot`,
    # `after_snapshot`) are concrete and derive from `value_columns`; they
    # are NOT overridable — the snapshot shape is a versioning-coupled
    # invariant.
    #
    # ## Class-level DSL
    #
    #   value_column :integer_value           # single-cell sugar; primary cell
    #   value_columns :decimal_value, :string_value  # plural form
    #   operators :eq, :gt, :is_null          # restrict supported operators
    #   operator_column(:currency_eq)         # override to route ops to cells
    #
    # Both `value_column` and `value_columns` share the same `@value_columns`
    # class instance variable. `value_column` returns the first element of
    # `value_columns`, preserving the single-cell sugar shape.
    #
    # ## Override-point instance methods (the entire extension surface)
    #
    # - `read_value(record)` — compose the logical value from the cells.
    # - `write_value(record, casted)` — unpack the casted value across cells.
    # - `apply_default(record)` — populate cells from the field's default.
    #
    # The default implementations target `value_columns.first` (single-cell
    # behavior). Multi-cell types override ALL THREE — overriding just one
    # creates an asymmetry where reads see the multi-cell shape but writes
    # / defaults populate only one column (or vice versa).
    #
    # ## Concrete (non-overridable) snapshot helpers
    #
    # - `value_changed?(record)` — true iff ANY value_columns column has a
    #   saved_change_to_attribute? — used by the Value :update dispatch gate
    #   so multi-cell types fire the event when only the second cell changed.
    # - `before_snapshot(record, change_type)` — per-column hash keyed by
    #   string column names. `:create` returns `{}`.
    # - `after_snapshot(record, change_type)` — per-column hash keyed by
    #   string column names. `:destroy` returns `{}`.
    #
    # Snapshot keys are stringified so query patterns like
    # `WHERE before_value->>'integer_value' = '42'` work uniformly.
    module TypedStorage
      extend ActiveSupport::Concern

      DEFAULT_OPERATORS_BY_COLUMN = {
        boolean_value: %i[eq not_eq is_null is_not_null],
        string_value: %i[eq not_eq contains not_contains starts_with ends_with is_null is_not_null],
        text_value: %i[eq not_eq contains not_contains starts_with ends_with is_null is_not_null],
        integer_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
        decimal_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
        date_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
        datetime_value: %i[eq not_eq gt gteq lt lteq between is_null is_not_null],
        json_value: %i[contains is_null is_not_null],
      }.freeze
      FALLBACK_OPERATORS = %i[eq not_eq is_null is_not_null].freeze

      class_methods do
        # Declare the typed column(s) this field type stores its value in.
        #
        # `value_column :col` — single-cell sugar; equivalent to
        # `value_columns :col`. Returns `:col` when called without arguments.
        # Raises NotImplementedError when called without arguments AND no
        # column has been declared (the "subclass must declare" enforcement).
        #
        # Both `value_column` and `value_columns` write to the same
        # `@value_columns` class instance variable on the declaring class
        # (Ruby class ivars are NOT inherited, so each subclass that calls
        # the setter installs its own). `Field::Percentage` re-declares
        # `value_column :decimal_value` to work around this non-inheritance.
        def value_column(column_name = nil)
          if column_name
            @value_columns = [column_name.to_sym]
          else
            cols = value_columns
            cols.first
          end
        end

        # Declare the typed columns this field type stores across (multi-cell
        # form). Returns the configured Array when called without arguments.
        # Raises NotImplementedError when no column(s) have been declared
        # on this class — the same enforcement as `value_column`.
        #
        # The primary cell is `value_columns.first`; defaults for
        # `read_value` / `write_value` / `apply_default` target it.
        def value_columns(*cols)
          if cols.any?
            @value_columns = cols.map(&:to_sym)
          else
            @value_columns || raise(NotImplementedError,
                                    "#{name} must declare `value_column :column_name`")
          end
        end

        # The physical column this operator acts on. Defaults to
        # `value_columns.first` for single-cell field types. Multi-cell
        # types (Currency: `:currency_eq` → `:string_value`; everything
        # else → `:decimal_value`) override this to route operators to
        # different cells.
        #
        # Called by `QueryBuilder.filter` AFTER the
        # `supported_operators.include?(operator)` validation gate, so
        # `_operator` is always one the field explicitly supports.
        def operator_column(_operator)
          value_columns.first
        end

        # Operators this field type supports for querying. Defaults to the
        # column-aware default set. Override via `.operators(*ops)`.
        def supported_operators
          @supported_operators || default_operators_for(value_columns.first)
        end

        def operators(*ops)
          @supported_operators = ops.map(&:to_sym)
        end

        private

        def default_operators_for(col)
          DEFAULT_OPERATORS_BY_COLUMN.fetch(col, FALLBACK_OPERATORS)
        end
      end

      # ── Override-point instance methods (the entire multi-cell surface) ──

      # Returns the logical value for this field as stored on `value_record`.
      # Default reads the primary cell. Override in multi-cell types to
      # compose a hash (e.g., `Field::Currency` returns
      # `{amount: r[:decimal_value], currency: r[:string_value]}`).
      def read_value(value_record)
        value_record[self.class.value_columns.first]
      end

      # Writes a casted value to `value_record`. Default writes the primary
      # cell. Override in multi-cell types to unpack the casted value
      # across multiple cells.
      def write_value(value_record, casted)
        value_record[self.class.value_columns.first] = casted
      end

      # Writes this field's configured default to `value_record`. Default
      # writes `default_value` to the primary cell, bypassing Value#value=
      # to avoid re-casting an already-cast default. Override in multi-cell
      # types to populate multiple cells from a composite default.
      def apply_default(value_record)
        value_record[self.class.value_columns.first] = default_value
      end

      # ── Concrete snapshot helpers (NOT overridable) ──

      # True iff ANY of the field's value_columns had a saved change in the
      # just-committed save. Used by Value's :update dispatch gate so
      # multi-cell types correctly fire the event when only the second cell
      # changed (regression case Phase 5 D3).
      def value_changed?(value_record)
        self.class.value_columns.any? do |column|
          value_record.saved_change_to_attribute?(column)
        end
      end

      # Pre-change snapshot keyed by string column names.
      # - :create  → {} (no before state)
      # - :update  → {col => attribute_before_last_save(col)}
      # - :destroy → {col => value_record[col]} (in-memory on the destroyed
      #   AR record per Phase 03 P04 live-validation)
      def before_snapshot(value_record, change_type)
        case change_type.to_sym
        when :create
          {}
        when :update
          self.class.value_columns.to_h do |column|
            [column.to_s, value_record.attribute_before_last_save(column.to_s)]
          end
        when :destroy
          self.class.value_columns.to_h { |column| [column.to_s, value_record[column]] }
        else
          raise ArgumentError, "Unsupported change_type: #{change_type.inspect}"
        end
      end

      # Post-change snapshot keyed by string column names.
      # - :create / :update → {col => value_record[col]}
      # - :destroy          → {} (no after state)
      def after_snapshot(value_record, change_type)
        case change_type.to_sym
        when :create, :update
          self.class.value_columns.to_h { |column| [column.to_s, value_record[column]] }
        when :destroy
          {}
        else
          raise ArgumentError, "Unsupported change_type: #{change_type.inspect}"
        end
      end
    end
  end
end
