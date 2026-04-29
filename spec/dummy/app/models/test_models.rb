# frozen_string_literal: true

class Contact < ActiveRecord::Base
  has_typed_eav scope_method: :tenant_id
end

class Product < ActiveRecord::Base
  has_typed_eav types: %i[text integer decimal boolean]
end

# Two-level partitioned host: exercises both `scope_method:` and
# `parent_scope_method:`. Used by phase-1 specs to verify the full
# (entity_type, scope, parent_scope) triple wires through the resolver
# chain, the query path, and the Value-level cross-axis validator.
class Project < ActiveRecord::Base
  has_typed_eav scope_method: :tenant_id, parent_scope_method: :workspace_id
end
