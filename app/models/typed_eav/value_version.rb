# frozen_string_literal: true

module TypedEAV
  # Append-only audit log row for a TypedEAV::Value mutation. One row per
  # :create / :update / :destroy event when the host entity opted into
  # versioning AND the gem-level master switch is on. Written by
  # TypedEAV::Versioning::Subscriber (plan 04-02), read via
  # Value#history (plan 04-03) or directly via this model.
  #
  # ## Schema invariants (locked at 04-CONTEXT.md)
  #
  # - `before_value` and `after_value` are jsonb hashes keyed by typed-
  #   column name (e.g., {"integer_value": 42}). Empty {} means "no
  #   recorded value" (typical of a :create event's before, or a
  #   :destroy event's after). {"<col>": null} means "recorded nil"
  #   (a deliberate clear). The two are NOT semantically equivalent.
  # - `change_type` is one of "create" | "update" | "destroy" — string,
  #   not enum, for forward compat. Phase 04 ships these three; future
  #   phases may extend the validator.
  # - `value_id` and `field_id` are nullable: ON DELETE SET NULL on both
  #   FKs preserves the audit log when the live Value/Field is destroyed
  #   (matches Phase 02's cascade pattern for typed_eav_values.field_id).
  # - `(entity_type, entity_id)` is the durable identity. Even after the
  #   Value row is destroyed and value_id is NULLed, the entity tuple
  #   tells consumers which host record this version belonged to.
  # - `changed_by` is a plain string — Lead's plan-time decision (see
  #   04-01-PLAN §Plan-time decisions §1). Apps resolve to AR records
  #   on the read side: `User.find_by(id: version.changed_by)`.
  #
  # ## Why no default_scope
  #
  # Append-only logs benefit from explicit ordering at the call site
  # (`Value#history.order(changed_at: :desc)`) rather than a hidden
  # default_scope that consumers must learn to override. Mirrors the
  # gem's existing convention (no default_scope on Value, Field::Base,
  # Section, Option). The idx_te_vvs_value covering index serves the
  # `(value_id, changed_at DESC)` query path natively.
  class ValueVersion < ApplicationRecord
    self.table_name = "typed_eav_value_versions"

    # ── Associations ──

    # Source Value. optional: true because the FK is ON DELETE SET NULL
    # — destroying the live Value preserves the version row but NULLs
    # the FK column. Without optional: true, AR's belongs_to validator
    # would reject any version row whose source Value was destroyed.
    belongs_to :value,
               class_name: "TypedEAV::Value",
               inverse_of: :versions,
               optional: true

    # Source Field. Same rationale as :value above. Stored separately
    # from `value.field` because (a) the live Value's field_id may itself
    # be NULL post-Phase-02 cascade, (b) the version row may outlive
    # both Value and Field, and (c) callers asking "what field did this
    # version belong to" want a direct lookup, not a two-hop chain.
    # No `inverse_of:` — Field::Base does not declare a reverse
    # `has_many :versions` association (the audit log is queried by
    # value_id or by (entity_type, entity_id), not by field_id from
    # the field side).
    belongs_to :field,
               class_name: "TypedEAV::Field::Base",
               optional: true,
               inverse_of: false

    # Polymorphic entity. NOT optional — every version row is durably
    # tied to its host entity tuple even when value_id / field_id are
    # NULLed. Consumers query history by (entity_type, entity_id).
    belongs_to :entity, polymorphic: true

    # ── Validations ──

    # change_type closed set. Mirrors the Phase 02 field_dependent
    # validator pattern (field/base.rb:56-59) — string column +
    # inclusion validator narrows the set at the model layer while
    # keeping schema migrations additive.
    CHANGE_TYPES = %w[create update destroy].freeze

    validates :change_type, inclusion: {
      in: CHANGE_TYPES,
      message: "must be one of: #{CHANGE_TYPES.join(", ")}",
    }
    # Explicit entity_type / entity_id presence validators kept alongside the
    # `belongs_to :entity, polymorphic: true` declaration above (which would
    # implicitly enforce both already). Plan 04-01 must_haves list both as
    # named validators so a `validates :entity_type, presence: true` grep
    # locates them — readability over DRY here.
    validates :entity_type, presence: true
    validates :entity_id, presence: true # rubocop:disable Rails/RedundantPresenceValidationOnBelongsTo -- explicit per plan 04-01 must_haves; redundancy is intentional documentation
    validates :changed_at, presence: true
    # No validation on before_value / after_value shape — the subscriber
    # is the only writer and its contract is locked at plan 04-02. App
    # code that bypasses the subscriber and writes raw rows directly is
    # explicitly out of scope for Phase 04.
  end
end
