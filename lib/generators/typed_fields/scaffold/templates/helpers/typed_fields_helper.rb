# frozen_string_literal: true

module TypedFieldsHelper
  # ─── Value Input Rendering ───────────────────────────────────

  # Render all typed field inputs for a record's form. Owns the
  # `fields_for :typed_values` builder so the submitted params are
  # shaped correctly for `accepts_nested_attributes_for :typed_values`.
  #
  #   <%= render_typed_value_inputs(form: f, record: @contact) %>
  #
  # The controller's strong params must permit:
  #
  #   typed_values_attributes: [:id, :field_id, :value, :_destroy,
  #                             { value: [] }]
  #
  def render_typed_value_inputs(form:, record:)
    # Index the in-scope definitions by id. Used both to look up sort_order
    # without touching `v.field` (avoids per-value field load when typed_values
    # was preloaded but `:field` was not) AND to thread the resolved field
    # into `render_typed_value_input` so it doesn't re-trigger that lookup.
    fields_by_id = record.typed_field_definitions.index_by(&:id)

    typed_values = record.initialize_typed_values.sort_by do |v|
      # Newly-built values may have field_id=nil but carry an in-memory
      # `field` object; fall back to that to avoid sorting them all to 0.
      field = fields_by_id[v.field_id] || v.field
      field&.sort_order || 0
    end

    parts = typed_values.map do |typed_value|
      form.fields_for(:typed_values, typed_value, child_index: nested_child_index(typed_value)) do |vf|
        render_typed_value_input(form: vf, typed_value: typed_value, fields_by_id: fields_by_id)
      end
    end
    safe_join(parts)
  end

  # Render a single typed value input. Expects `form` to be a typed-value
  # builder (from `fields_for :typed_values`) — it emits the hidden `id` /
  # `field_id` inputs nested attributes need to resolve the row, then
  # delegates to the type-specific partial for the value input itself.
  #
  # Advanced callers that own their own `fields_for` block can invoke this
  # directly:
  #
  #   <%= form.fields_for :typed_values, typed_value do |vf| %>
  #     <%= render_typed_value_input(form: vf, typed_value: vf.object) %>
  #   <% end %>
  #
  # Pass `fields_by_id:` (a {field_id => Field} map) when iterating many
  # values to avoid triggering a per-value `typed_value.field` query in the
  # association-loaded-but-`:field`-not-preloaded case.
  def render_typed_value_input(form:, typed_value:, fields_by_id: nil)
    field = (fields_by_id && fields_by_id[typed_value.field_id]) || typed_value.field
    partial_name = value_input_partial(field)

    hidden = "".html_safe
    hidden << form.hidden_field(:id) if typed_value.persisted?
    hidden << form.hidden_field(:field_id, value: field.id)

    hidden + render(partial: partial_name, locals: {
      form: form,
      typed_value: typed_value,
      field: field,
    })
  end

  # Render an array field with add/remove buttons (Stimulus-powered).
  #
  #   <%= render_array_field(form: f, name: :value, value: [1,2,3],
  #         field_method: :number_field, field_opts: { min: 0 }) %>
  #
  def render_array_field(form:, name:, value:, field_method:, field_opts: {})
    render partial: "shared/array_field", locals: {
      form: form,
      name: name,
      value: value,
      field_method: field_method,
      field_opts: field_opts,
    }
  end

  # ─── Field Management Form Rendering ─────────────────────────

  # Render the field definition form (for creating/editing field definitions).
  def render_typed_field_form(field:)
    partial = field_form_partial(field)
    render partial: partial, locals: { field: field }
  end

  # ─── Search/Filter Form Rendering ───────────────────────────

  # Render a search form for filtering entities by typed fields.
  #
  #   <%= render_typed_fields_search(fields: Contact.typed_field_definitions, url: contacts_path) %>
  #
  def render_typed_fields_search(fields:, url:)
    render partial: "typed_fields/finders/form", locals: {
      fields: fields,
      url: url,
    }
  end

  # ─── Operator Labels ────────────────────────────────────────

  def typed_field_operator_label(operator)
    {
      eq: "equals",
      not_eq: "does not equal",
      gt: "greater than",
      gteq: "greater than or equal",
      lt: "less than",
      lteq: "less than or equal",
      between: "between",
      contains: "contains",
      not_contains: "does not contain",
      starts_with: "starts with",
      ends_with: "ends with",
      any_eq: "includes",
      all_eq: "includes all",
      is_null: "is empty",
      is_not_null: "is not empty",
    }[operator.to_sym] || operator.to_s.humanize
  end

  private

  # Distinct `child_index` for each nested value so Rails generates unique
  # param names. Use the object id for new records (stable within a request),
  # the record id for persisted rows.
  def nested_child_index(typed_value)
    typed_value.persisted? ? typed_value.id : "new_#{typed_value.object_id}"
  end

  # Resolve the value input partial for a field type.
  # Falls back to a generic text input if no specific partial exists.
  def value_input_partial(field)
    type_key = field.field_type_name
    partial = "typed_fields/values/inputs/#{type_key}"
    lookup_context.exists?(partial, [], true) ? partial : "typed_fields/values/inputs/text"
  end

  # Resolve the field definition form partial.
  def field_form_partial(field)
    type_key = field.field_type_name
    partial = "typed_fields/forms/#{type_key}"
    lookup_context.exists?(partial, [], true) ? partial : "typed_fields/forms/base"
  end
end
