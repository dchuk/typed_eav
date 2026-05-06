# frozen_string_literal: true

class CreateTypedEAVValueVersions < ActiveRecord::Migration[7.1]
  def change
    # Append-only audit log of TypedEAV::Value mutations. Phase 04 versioning
    # writes one row per :create / :update / :destroy event when the host
    # entity opted in (via `has_typed_eav versioned: true` — landing in plan
    # 04-02) AND the gem-level master switch is on (`config.versioning = true`).
    #
    # Storage shape decisions:
    #   - before_value / after_value are jsonb keyed by typed-column name
    #     (e.g., {"integer_value": 42}). Single-cell field types produce
    #     one-key hashes; Phase 05 Currency will produce two-key hashes
    #     ({"decimal_value": 99.99, "string_value": "USD"}). The {} default
    #     means "no recorded value" (e.g., the before snapshot of a :create
    #     event); {"<column>": null} means "recorded nil" (e.g., user
    #     cleared the cell). Distinct semantics on purpose.
    #   - changed_by is a plain string. Per Lead's plan-time decision (see
    #     Plan §Plan-time decisions §1), the gem coerces actor_resolver
    #     returns via the same `normalize_one`-style coercion that Phase 1
    #     uses for scope (lib/typed_eav.rb:239-243). Apps that need
    #     polymorphic actor querying resolve `changed_by` to a model on the
    #     read side — `User.find_by(id: version.changed_by)`.
    #   - context is jsonb so apps can store arbitrary `with_context`
    #     payloads (request_id, source, anything the caller passed).
    #     Default {} matches `TypedEAV.current_context`'s frozen-empty
    #     return shape when no with_context block is active.
    #   - changed_at is a separate column from created_at because callers
    #     may want to record event-time vs persistence-time distinctly
    #     (e.g., backfilling a historical version row from an external
    #     audit log). Default to `Time.current` at write time in the
    #     subscriber (plan 04-02); migration just declares NOT NULL.
    create_table :typed_eav_value_versions do |t|
      # Source row references. Both nullable + ON DELETE SET NULL so the
      # audit log survives Value/Field destruction. Phase 02 made
      # typed_eav_values.field_id ON DELETE SET NULL using exactly this
      # pattern (db/migrate/20260501000000 lines 22-24). Same rationale:
      # losing audit history because the live row was destroyed defeats
      # the "append-only audit log" contract from 04-CONTEXT.md.
      t.references :value,
                   null: true,
                   foreign_key: { to_table: :typed_eav_values, on_delete: :nullify }
      t.references :field,
                   null: true,
                   foreign_key: { to_table: :typed_eav_fields, on_delete: :nullify }

      # Polymorphic entity reference. Mirrors the typed_eav_values.entity
      # pair exactly (Value belongs_to :entity polymorphic). NOT NULL
      # because the entity tuple is the durable identity of a version
      # row even after the Value (live cell) is destroyed — Phase 04
      # consumers query history by `(entity_type, entity_id)`, not by
      # value_id (which may be NULL). The polymorphic _type/_id columns
      # default to NOT NULL via the t.references helper when null: false.
      t.references :entity, polymorphic: true, null: false

      # Actor identifier. Nullable per 04-CONTEXT.md §"actor_resolver
      # returning nil" — system writes, migrations, console-without-actor,
      # background jobs without `with_context(actor: ...)` all produce
      # nil. Apps that need strict enforcement do it in their own
      # actor_resolver lambda (`-> { Current.user || raise }`).
      t.string :changed_by

      # Snapshot columns. Default {} (NOT null) so the subscriber never
      # writes nil — distinguishes "no recorded value" ({}) from "recorded
      # nil" ({"<col>": null}). The change_type semantic is:
      #   :create  → before_value: {},                after_value: {"<col>": <new>}
      #   :update  → before_value: {"<col>": <old>},  after_value: {"<col>": <new>}
      #   :destroy → before_value: {"<col>": <old>},  after_value: {}
      # Phase 05 Currency emits two-key snapshots automatically when its
      # `value_columns` override returns [:decimal_value, :string_value]
      # (subscriber loops over value_columns).
      t.jsonb :before_value, null: false, default: {}
      t.jsonb :after_value,  null: false, default: {}

      # `with_context` payload at write time (TypedEAV.current_context).
      # Frozen Hash captured by EventDispatcher.dispatch_value_change
      # (event_dispatcher.rb:89). Default {} matches the empty-context
      # return shape; subscriber stores the captured Hash verbatim.
      t.jsonb :context, null: false, default: {}

      # Lifecycle metadata. change_type is a string (not enum) for forward
      # compat — same rationale as Phase 02's field_dependent column
      # (string-not-enum keeps schema migrations additive). Validator on
      # the AR model narrows to the locked closed set.
      t.string :change_type, null: false

      # Event-time. Distinct from created_at to allow backfill scenarios
      # where the subscriber writes a historical event-time. The :create
      # / :update / :destroy normal path sets changed_at = Time.current
      # in the subscriber (plan 04-02).
      t.datetime :changed_at, null: false

      t.timestamps
    end

    # Indexes — ship three at initial migration per Lead's plan-time
    # decision (see Plan §Plan-time decisions §2). All use idx_te_vvs_*
    # naming convention (matches CHANGELOG.md / Phase 1-2 idx_te_*
    # precedent). DESC on changed_at because Value#history (plan 04-03)
    # returns most-recent-first by default.
    #
    # No GIN index on before_value/after_value — deferred per CONTEXT.
    # No partial unique indexes — multiple version rows per value_id are
    # the whole point of the audit log.
    add_index :typed_eav_value_versions,
              %i[value_id changed_at],
              order: { changed_at: :desc },
              name: "idx_te_vvs_value"

    add_index :typed_eav_value_versions,
              %i[entity_type entity_id changed_at],
              order: { changed_at: :desc },
              name: "idx_te_vvs_entity"

    add_index :typed_eav_value_versions,
              %i[field_id changed_at],
              order: { changed_at: :desc },
              name: "idx_te_vvs_field"
  end
end
