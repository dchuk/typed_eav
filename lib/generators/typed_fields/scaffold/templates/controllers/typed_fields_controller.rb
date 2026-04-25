# frozen_string_literal: true

class TypedFieldsController < ApplicationController
  include TypedFieldsControllerConcern

  # Fail-closed authorization. The generated admin manages field DEFINITIONS
  # (schema-like data visible across entity types and tenants), so we pretend
  # these routes don't exist unless the host app explicitly grants access.
  # `head :not_found` is intentional — a 403 leaks that these routes exist.
  #
  # TO ENABLE ACCESS, edit the `authorize_typed_fields_admin!` method below
  # directly in this file (defining a same-named method in ApplicationController
  # does NOT override it — Ruby looks up methods on the subclass first).
  # Examples to paste into the private method:
  #
  #   # Pundit
  #   def authorize_typed_fields_admin!
  #     authorize :typed_field, :manage?
  #   end
  #
  #   # CanCanCan
  #   def authorize_typed_fields_admin!
  #     authorize! :manage, TypedFields::Field::Base
  #   end
  #
  #   # Host-app admin predicate
  #   def authorize_typed_fields_admin!
  #     head :not_found unless current_user&.admin?
  #   end
  before_action :authorize_typed_fields_admin!
  before_action :set_field, only: %i[show edit update destroy]

  def index
    @fields = scoped_fields.order(:entity_type, :scope, :sort_order, :name)
  end

  def show; end

  def new
    type_class = resolve_type_class(params[:type])
    @field = type_class.new
  end

  def edit; end

  def create
    type_class = resolve_type_class(params.dig(:typed_field, :field_type) || params[:type])
    ambient = ensure_scope!
    attrs = field_params(type_class, creating: true)
    attrs[:scope] = ambient
    attrs[:section_id] = verified_section_id(
      params.dig(:typed_field, :section_id),
      attrs[:entity_type],
      ambient
    )
    @field = type_class.new(attrs)

    if @field.save
      redirect_to edit_typed_field_path(@field), status: :see_other,
        notice: "Field created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    attrs = field_params(@field.class, creating: false)
    attrs[:section_id] = verified_section_id(
      params.dig(:typed_field, :section_id),
      @field.entity_type,
      @field.scope
    )

    if @field.update(attrs)
      redirect_to edit_typed_field_path(@field), status: :see_other,
        notice: "Field updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @field.destroy!
    redirect_to typed_fields_path, status: :see_other, notice: "Field deleted."
  end

  # POST /typed_fields/:typed_field_id/field_options/add_option
  def add_option
    @field = scoped_fields.find(params[:typed_field_id])
    # Lock the field row during option creation so two concurrent creates
    # can't observe the same `count` and assign the same sort_order.
    @field.with_lock do
      next_order = (@field.field_options.maximum(:sort_order) || 0) + 1
      @field.field_options.create!(
        label: params[:option_label],
        value: params[:option_value],
        sort_order: next_order
      )
    end
    redirect_to edit_typed_field_path(@field), status: :see_other
  end

  # DELETE /typed_fields/:typed_field_id/field_options/remove_option
  def remove_option
    @field = scoped_fields.find(params[:typed_field_id])
    @field.field_options.find(params[:option_id]).destroy!
    redirect_to edit_typed_field_path(@field), status: :see_other
  end

  private

  # Default: block all access. Host app must override to grant access.
  # `head :not_found` is intentional — a 403 leaks that these admin
  # routes exist.
  def authorize_typed_fields_admin!
    head :not_found
  end

  def set_field
    @field = scoped_fields.find(params[:id])
  end

  # Base relation filtered to the current ambient scope. Fields with
  # scope=NULL (global fields visible to all partitions) are always
  # included. Fail-closed semantics:
  #   - unscoped?               -> ALL fields across every scope (admin override)
  #   - scope present           -> fields for that scope UNION globals
  #   - scope nil, require_scope=true  -> raise TypedFields::ScopeRequired
  #   - scope nil, require_scope=false -> globals only (scope=NULL); never
  #                                       leaks other tenants' rows.
  # Use `TypedFields.with_scope(value) { }` or configure
  # `TypedFields.config.scope_resolver` to set the scope.
  def scoped_fields
    # Inside `TypedFields.unscoped { }` the caller has explicitly opted into
    # cross-scope visibility (admin/migration paths). Skip the scope filter
    # entirely so the scaffold remains usable instead of raising under
    # require_scope=true.
    return TypedFields::Field::Base.all if TypedFields.unscoped?

    scope = TypedFields.current_scope
    return TypedFields::Field::Base.where(scope: [scope, nil]) if scope

    if TypedFields.config.require_scope
      raise TypedFields::ScopeRequired,
        "TypedFields.current_scope is nil and require_scope is enabled; " \
        "wrap the request in TypedFields.with_scope(value) { } or configure " \
        "TypedFields.config.scope_resolver."
    end

    TypedFields::Field::Base.where(scope: nil)
  end

  # Resolve the ambient scope for writes. Mirrors `scoped_fields` semantics:
  #   - unscoped?               -> returns nil (admin override; new field is global)
  #   - scope present           -> returns the scope value
  #   - scope nil, require_scope=true  -> raises TypedFields::ScopeRequired
  #   - scope nil, require_scope=false -> returns nil (global-field creation)
  def ensure_scope!
    # Inside `TypedFields.unscoped { }` we deliberately bypass the require_scope
    # guard so admin tools can create global fields without first declaring an
    # ambient scope. Wrap in `with_scope` to write into a specific tenant.
    return nil if TypedFields.unscoped?

    scope = TypedFields.current_scope
    return scope if scope

    if TypedFields.config.require_scope
      raise TypedFields::ScopeRequired,
        "TypedFields.current_scope is nil and require_scope is enabled; " \
        "wrap the request in TypedFields.with_scope(value) { } or configure " \
        "TypedFields.config.scope_resolver."
    end

    nil
  end

  # Server-side verification that the requested section exists within the
  # caller's entity_type + scope (or globals). `Section.for_entity` unions
  # scope=NULL globals with the scoped rows, matching field visibility.
  # Returns nil if `id` is blank. Raises ActiveRecord::RecordNotFound (Rails
  # renders 404) if the id does not belong to a section the caller can see,
  # blocking cross-tenant assignment via a forged section_id.
  def verified_section_id(id, entity_type, scope)
    return nil if id.blank?
    TypedFields::Section.for_entity(entity_type, scope: scope).find(id).id
  end

  def resolve_type_class(type_name)
    return TypedFields::Field::Text if type_name.blank?
    TypedFields.config.field_class_for(type_name)
  rescue ArgumentError
    TypedFields::Field::Text
  end

  # Data-driven permitted params based on what the field type exposes via
  # store_accessor. Much cleaner than a massive case statement per type.
  #
  # NOTE: `scope` and `section_id` are intentionally NOT in the permit list.
  # `scope` is derived server-side from the ambient scope in `create`; a
  # client-supplied value would let any authenticated user write into another
  # tenant's partition. `section_id` is verified against a scoped Section
  # lookup via `verified_section_id` on both create and update.
  def field_params(type_class, creating:)
    base = %i[name required sort_order]
    base += %i[entity_type] if creating

    # Collect store_accessor keys from options (min, max, min_length, etc.)
    option_keys = option_keys_for(type_class)

    # Default value is scalar for most types, array for array types
    if type_class.method_defined?(:array_field?) && type_class.allocate.array_field?
      permitted = base + option_keys + [default_value: []]
    else
      permitted = base + option_keys + %i[default_value]
    end

    params.require(:typed_field).permit(*permitted).tap do |attrs|
      attrs.transform_values! do |value|
        value.is_a?(Array) ? compact_array_param(value) : value
      end
    end
  end

  # Introspect which option keys the field type exposes
  def option_keys_for(type_class)
    return [] unless type_class.respond_to?(:stored_attributes)
    (type_class.stored_attributes[:options] || []).map(&:to_sym)
  rescue StandardError
    []
  end
end
