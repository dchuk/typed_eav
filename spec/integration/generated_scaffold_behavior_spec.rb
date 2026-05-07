# frozen_string_literal: true

require "spec_helper"

RSpec.describe "generated scaffold behavior", type: :request do
  before do
    install_generated_scaffold
  end

  after do
    Rails.application.reload_routes!
  end

  it "renders the generated index with fields visible to the active parent-scope partition" do
    global = create(:text_field, name: "global_status", entity_type: "Project")
    tenant = create(:text_field, name: "tenant_status", entity_type: "Project", scope: "t1")
    workspace = create(:text_field, name: "workspace_status", entity_type: "Project", scope: "t1", parent_scope: "w1")
    other_tenant = create(:text_field, name: "other_tenant_status", entity_type: "Project", scope: "t2")
    other_workspace = create(
      :text_field,
      name: "other_workspace_status",
      entity_type: "Project",
      scope: "t1",
      parent_scope: "w2",
    )

    TypedEAV.with_scope(%w[t1 w1]) do
      get "/typed_eav_fields"
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(global.name, tenant.name, workspace.name)
    expect(response.body).not_to include(other_tenant.name, other_workspace.name)
  end

  it "adds and removes field options through the generated admin routes" do
    field = create(:select_field, name: "status", entity_type: "Contact", scope: "t1")

    TypedEAV.with_scope("t1") do
      post "/typed_eav_fields/#{field.id}/field_options/add_option",
           params: { option_label: "Archived", option_value: "archived" }
    end

    expect(response).to redirect_to("/typed_eav_fields/#{field.id}/edit")
    option = field.field_options.find_by!(value: "archived")
    expect(option.label).to eq("Archived")
    expect(option.sort_order).to eq(4)

    TypedEAV.with_scope("t1") do
      delete "/typed_eav_fields/#{field.id}/field_options/remove_option",
             params: { option_id: option.id }
    end

    expect(response).to redirect_to("/typed_eav_fields/#{field.id}/edit")
    expect(field.field_options.where(value: "archived")).not_to exist
  end

  it "renders and creates fields in the active scoped form partition" do
    TypedEAV.with_scope(%w[t1 w1]) do
      get "/typed_eav_fields/new", params: { type: "text" }
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("value=\"t1\"")
    expect(response.body).to include("value=\"w1\"")

    TypedEAV.with_scope(%w[t1 w1]) do
      post "/typed_eav_fields",
           params: {
             typed_eav_field: {
               field_type: "text",
               entity_type: "Project",
               name: "stage",
               scope: "forged",
               parent_scope: "forged_parent",
             },
           }
    end

    field = TypedEAV::Field::Base.find_by!(entity_type: "Project", name: "stage")
    expect(response).to redirect_to("/typed_eav_fields/#{field.id}/edit")
    expect(field.scope).to eq("t1")
    expect(field.parent_scope).to eq("w1")
  end

  it "renders global and single-scope field form partition states" do
    TypedEAV.unscoped do
      get "/typed_eav_fields/new", params: { type: "text" }
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Global (all scopes)")
    expect(response.body).to include("Global (all parent scopes)")

    TypedEAV.with_scope("t1") do
      get "/typed_eav_fields/new", params: { type: "text" }
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("value=\"t1\"")
    expect(response.body).to include("Global (all parent scopes)")
  end

  it "renders the generated search helper with scoped fields and existing filter params" do
    visible = create(:text_field, name: "customer_status", entity_type: "Contact", scope: "t1")
    hidden = create(:text_field, name: "internal_status", entity_type: "Contact", scope: "t2")

    TypedEAV.with_scope("t1") do
      get "/typed_eav_search_preview",
          params: { f: [{ n: visible.name, op: "contains", v: "vip" }] }
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Filter by Custom Fields")
    expect(response.body).to include("Customer status")
    expect(response.body).to include("value=\"vip\"")
    expect(response.body).not_to include(hidden.name.humanize)
  end

  def install_generated_scaffold
    stub_host_application_controller
    load_generated_scaffold_files
    configure_generated_controller
    install_search_preview_controller
    draw_generated_scaffold_routes
  end

  def template_root
    Rails.root.join("../../lib/generators/typed_eav/scaffold/templates").expand_path
  end

  def stub_host_application_controller
    # rubocop:disable Rails/ApplicationController -- this spec creates the dummy host's ApplicationController.
    stub_const("ApplicationController", Class.new(ActionController::Base))
    # rubocop:enable Rails/ApplicationController
    ApplicationController.allow_forgery_protection = false
    stub_const("TypedEAVControllerConcern", Module.new)
    stub_const("TypedEAVHelper", Module.new)
    stub_const("TypedEAVController", Class.new(ApplicationController))
  end

  def load_generated_scaffold_files
    load template_root.join("controllers/concerns/typed_eav_controller_concern.rb")
    load template_root.join("helpers/typed_eav_helper.rb")
    load template_root.join("controllers/typed_eav_controller.rb")
  end

  def configure_generated_controller
    TypedEAVController.prepend_view_path(template_root.join("views"))
    TypedEAVController.helper(TypedEAVHelper)
    TypedEAVController.class_eval do
      private

      def authorize_typed_eav_admin!
        true
      end
    end
  end

  def install_search_preview_controller
    stub_const("TypedEAVPreviewController", Class.new(ApplicationController))
    TypedEAVPreviewController.include(TypedEAVControllerConcern)
    TypedEAVPreviewController.helper(TypedEAVHelper)
    TypedEAVPreviewController.prepend_view_path(template_root.join("views"))
    TypedEAVPreviewController.class_eval do
      def search
        fields = Contact.typed_eav_definitions
        render html: view_context.render_typed_eav_search(fields: fields, url: "/contacts")
      end
    end
  end

  def draw_generated_scaffold_routes
    Rails.application.routes.draw do
      get "/typed_eav_search_preview", to: "typed_eav_preview#search"
      resources :typed_eav_fields, controller: "typed_eav" do
        resources :field_options, controller: "typed_eav", only: [] do
          collection do
            post :add_option
            delete :remove_option
          end
        end
      end
    end
  end
end
