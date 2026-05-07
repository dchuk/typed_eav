# frozen_string_literal: true

class TypedEAVController < ApplicationController
  include TypedEAVControllerConcern

  # Fail-closed authorization. The generated admin manages field DEFINITIONS
  # (schema-like data visible across entity types and tenants), so we pretend
  # these routes don't exist unless the host app explicitly grants access.
  # `head :not_found` is intentional — a 403 leaks that these routes exist.
  #
  # TO ENABLE ACCESS, edit the `authorize_typed_eav_admin!` method below
  # directly in this file (defining a same-named method in ApplicationController
  # does NOT override it — Ruby looks up methods on the subclass first).
  # Examples to paste into the private method:
  #
  #   # Pundit
  #   def authorize_typed_eav_admin!
  #     authorize :typed_eav, :manage?
  #   end
  #
  #   # CanCanCan
  #   def authorize_typed_eav_admin!
  #     authorize! :manage, TypedEAV::Field::Base
  #   end
  #
  #   # Host-app admin predicate
  #   def authorize_typed_eav_admin!
  #     head :not_found unless current_user&.admin?
  #   end
  before_action :authorize_typed_eav_admin!
  before_action :set_field, only: %i[show edit update destroy]

  def index
    @fields = scoped_fields.order(:entity_type, :scope, :parent_scope, :sort_order, :name)
  end

  def show; end

  def new
    type_class = resolve_type_class(params[:type])
    @field = type_class.new
  end

  def edit; end

  def create
    type_class = resolve_type_class(params.dig(:typed_eav_field, :field_type) || params[:type])
    partition = ensure_partition!
    attrs = field_params(type_class, creating: true)
    attrs[:scope] = partition[:scope]
    attrs[:parent_scope] = partition[:parent_scope]
    attrs[:section_id] = verified_section_id(
      params.dig(:typed_eav_field, :section_id),
      attrs[:entity_type],
      partition,
    )
    @field = type_class.new(attrs)

    if @field.save
      redirect_to edit_typed_eav_field_path(@field), status: :see_other,
                                                     notice: "Field created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    attrs = field_params(@field.class, creating: false)
    attrs[:section_id] = verified_section_id(
      params.dig(:typed_eav_field, :section_id),
      @field.entity_type,
      field_partition(@field),
    )

    if @field.update(attrs)
      redirect_to edit_typed_eav_field_path(@field), status: :see_other,
                                                     notice: "Field updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @field.destroy!
    redirect_to typed_eav_fields_path, status: :see_other, notice: "Field deleted."
  end

  # POST /typed_eav_fields/:typed_eav_field_id/field_options/add_option
  def add_option
    @field = scoped_fields.find(params[:typed_eav_field_id])
    # Lock the field row during option creation so two concurrent creates
    # can't observe the same `count` and assign the same sort_order.
    @field.with_lock do
      next_order = (@field.field_options.maximum(:sort_order) || 0) + 1
      @field.field_options.create!(
        label: params[:option_label],
        value: params[:option_value],
        sort_order: next_order,
      )
    end
    redirect_to edit_typed_eav_field_path(@field), status: :see_other
  end

  # DELETE /typed_eav_fields/:typed_eav_field_id/field_options/remove_option
  def remove_option
    @field = scoped_fields.find(params[:typed_eav_field_id])
    @field.field_options.find(params[:option_id]).destroy!
    redirect_to edit_typed_eav_field_path(@field), status: :see_other
  end

  private

  # Default: block all access. Host app must override to grant access.
  # `head :not_found` is intentional — a 403 leaks that these admin
  # routes exist.
  def authorize_typed_eav_admin!
    head :not_found
  end

  def set_field
    @field = scoped_fields.find(params[:id])
  end

  # Base relation filtered through TypedEAV's partition seam. Fields with the
  # global tuple `(scope=NULL, parent_scope=NULL)` are visible to every
  # partition. Fail-closed semantics:
  #   - unscoped?                    -> ALL fields across every partition
  #   - [scope, parent_scope] present -> global + scope + full-tuple fields
  #   - no tuple, require_scope=true  -> raise TypedEAV::ScopeRequired
  #   - no tuple, require_scope=false -> global fields only; never leaks
  #                                     other tenants' rows.
  # Use `TypedEAV.with_scope(value) { }` or configure
  # `TypedEAV.config.scope_resolver` to set the tuple.
  def scoped_fields
    partition = current_partition!
    return TypedEAV::Field::Base.all if partition[:mode] == :all_partitions

    TypedEAV::Field::Base.where(id: visible_field_ids(partition))
  end

  # Resolve the ambient tuple for writes. Mirrors `scoped_fields` semantics:
  #   - unscoped?                    -> returns the global tuple
  #   - [scope, parent_scope] present -> returns that tuple
  #   - no tuple, require_scope=true  -> raises TypedEAV::ScopeRequired
  #   - no tuple, require_scope=false -> returns the global tuple
  def ensure_partition!
    current_partition!.slice(:scope, :parent_scope)
  end

  # Server-side verification that the requested section exists within the same
  # partition tuple as the field being created or updated, including global
  # sections visible to that tuple.
  # Returns nil if `id` is blank. Raises ActiveRecord::RecordNotFound (Rails
  # renders 404) if the id does not belong to a section the caller can see,
  # blocking cross-tenant assignment via a forged section_id.
  def verified_section_id(id, entity_type, partition)
    return nil if id.blank?

    TypedEAV::Partition.find_visible_section!(
      id,
      entity_type: entity_type,
      **partition,
    ).id
  end

  def current_partition!
    return { scope: nil, parent_scope: nil, mode: :all_partitions } if TypedEAV.unscoped?

    tuple = TypedEAV.current_scope
    return { scope: tuple.first, parent_scope: tuple.last, mode: :partition } if tuple

    if TypedEAV.config.require_scope
      raise TypedEAV::ScopeRequired,
            "TypedEAV.current_scope is nil and require_scope is enabled; " \
            "wrap the request in TypedEAV.with_scope(value) { } or configure " \
            "TypedEAV.config.scope_resolver."
    end

    { scope: nil, parent_scope: nil, mode: :partition }
  end

  def field_partition(field)
    { scope: field.scope, parent_scope: field.parent_scope, mode: :partition }
  end

  def visible_field_ids(partition)
    TypedEAV::Field::Base.distinct.pluck(:entity_type).flat_map do |entity_type|
      TypedEAV::Partition.visible_fields(entity_type: entity_type, **partition).pluck(:id)
    end
  end

  def resolve_type_class(type_name)
    return TypedEAV::Field::Text if type_name.blank?

    TypedEAV.config.field_class_for(type_name)
  rescue ArgumentError
    TypedEAV::Field::Text
  end

  # Data-driven permitted params based on what the field type exposes via
  # store_accessor. Much cleaner than a massive case statement per type.
  #
  # NOTE: `scope`, `parent_scope`, and `section_id` are intentionally NOT in
  # the permit list. `scope` and `parent_scope` are derived server-side from
  # the ambient partition tuple in `create`; a
  # client-supplied value would let any authenticated user write into another
  # tenant's partition. `section_id` is verified against the partition seam via
  # `verified_section_id` on both create and update.
  def field_params(type_class, creating:)
    base = %i[name required sort_order]
    base += %i[entity_type] if creating

    # Collect store_accessor keys from options (min, max, min_length, etc.)
    option_keys = option_keys_for(type_class)

    # Default value is scalar for most types, array for array types
    permitted = if type_class.method_defined?(:array_field?) && type_class.allocate.array_field?
                  base + option_keys + [{ default_value: [] }]
                else
                  base + option_keys + %i[default_value]
                end

    params.require(:typed_eav_field).permit(*permitted).tap do |attrs|
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
