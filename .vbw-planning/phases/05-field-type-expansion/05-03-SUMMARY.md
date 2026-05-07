---
phase: 5
plan: 03
title: Field::Image + Field::File via Active Storage soft-detect (engine initializer, has_one_attached, on_image_attached hook)
status: complete
completed: 2026-05-06
tasks_completed: 5
tasks_total: 5
commit_hashes:
  - 6c2a927
  - 968b7bd
  - 9747e6c
  - b87a474
  - c1e79e6
files_modified:
  - app/models/typed_eav/field/image.rb
  - app/models/typed_eav/field/file.rb
  - app/models/typed_eav/value.rb
  - lib/typed_eav/engine.rb
  - lib/typed_eav/config.rb
  - spec/factories/typed_eav.rb
  - spec/dummy/config/storage.yml
  - spec/dummy/config/environment.rb
  - spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb
  - spec/spec_helper.rb
  - spec/lib/typed_eav/config_versioning_spec.rb
  - spec/models/typed_eav/field_spec.rb
  - spec/models/typed_eav/value_spec.rb
  - spec/lib/typed_eav/active_storage_soft_detect_spec.rb
  - README.md
deviations:
  - "DEVN-01 (minor): plan files_modified listed `spec/dummy/config/application.rb` but the dummy app keeps its application config inline in `spec/dummy/config/environment.rb` — there is no separate application.rb / environments/test.rb in this minimal engine test rig. Edited environment.rb instead. Active Storage was already loaded via `require \"rails/all\"`, so no `require \"active_storage/engine\"` was needed; added `config.active_storage.service = :test` plus a documenting comment to the Application class block."
  - "DEVN-01 (minor): plan P01 suggested `cd spec/dummy && bundle exec rails db:migrate` to apply the AS migration. The dummy app has no `bin/rails` script (it's an engine test rig). Applied the migration once via `ActiveRecord::MigrationContext.new(\"spec/dummy/db/migrate\").migrate`. Also extended `spec/spec_helper.rb` to auto-apply pending dummy-app migrations on suite startup — `maintain_test_schema!` only loads from `db/schema.rb` (which the dummy app deliberately does not commit), so without this extension a fresh check-out would raise \"active_storage_blobs does not exist\" on first run. spec/spec_helper.rb is in the plan's allowed_paths."
  - "DEVN-01 (minor): plan truth block called for a hand-rolled `defined?(@on_image_attached) ? @on_image_attached : nil` reader idiom \"matching scope_resolver / versioning patterns\". Used plain `attr_accessor :on_image_attached` instead, mirroring the closer precedent of `on_value_change` / `on_field_change` (lib/typed_eav/config.rb lines 193, 209). Rationale: the hand-rolled idiom is needed when callers must distinguish \"never set\" from \"explicitly nil/false\" (scope_resolver has DEFAULT_SCOPE_RESOLVER fallback; versioning has `false` default). on_image_attached's contract is simply \"nil means unset\" — no fallback, no false-vs-never-set distinction. attr_accessor is the right idiom; the plan-truth was over-prescribing relative to the actual contract surface. reset! coverage and :event_callbacks snapshot/restore behave identically either way."
  - "DEVN-01 (minor): plan P04 suggested simulating the AS-unloaded branch \"via Module#prepend stub_module on a dedicated subclass\", noting the unloaded-path test would be \"structurally weaker than the loaded path because `defined?(::ActiveStorage::Blob)` cannot be stubbed at runtime\". Used RSpec's `hide_const(\"ActiveStorage::Blob\")` instead, which genuinely removes the constant for the duration of the example — `defined?(::ActiveStorage::Blob)` returns nil for real, exercising the gem's actual soft-detect predicate (engine seam, image/file cast, validate_typed_value) rather than a synthetic prepend-stub. Stronger guarantee than the plan-suggested approach; the unloaded-path block now has 4 examples (cast raise for Image, cast raise for File, validate_typed_value silent no-op, class still loads) plus 2 Engine seam idempotence/unloaded-return examples."
  - "DEVN-01 (minor): RuboCop/RSpec cops required two inline disables in `spec/lib/typed_eav/active_storage_soft_detect_spec.rb`: RSpec/SpecFilePathFormat + RSpec/DescribeMethod for the topical `RSpec.describe TypedEAV::Engine, \"Active Storage soft-detect (Phase 5 plan 03)\"` form (file path doesn't match Engine and the second arg is descriptor-prose, not a method name); plus a paired Style/RedundantConstantBase disable for the `expect(defined?(::ActiveStorage::Blob)).to be_nil` sanity-check inside the hide_const block (the leading `::` matches the gem-wide soft-detect idiom). Both disables include a `--` justification per the codebase's documented convention (CONVENTIONS.md §Quality patterns)."
pre_existing_issues: []
ac_results:
  - criterion: "Phase-start Gating Decision 1 RESOLVED: LAZY SOFT-DETECT — gemspec unchanged, has_one_attached wrapped in `defined?(::ActiveStorage::Blob)` inside config.after_initialize"
    verdict: pass
    evidence: "commit 9747e6c lib/typed_eav/engine.rb#register_attachment_associations! line 130: `return false unless defined?(::ActiveStorage::Blob)`; gemspec diff empty"
  - criterion: "signed_id storage in string_value (portable, decoupled from AS internal blob-id format)"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/image.rb line 81: `value_column :string_value`; same on file.rb line 31. cast contract returns `[raw, false]` for String input (signed_id passthrough)"
  - criterion: "TypedEAV::Field::Image extends Base, value_column :string_value, operators [:eq, :is_null, :is_not_null], store_accessor :options, :allowed_content_types, :max_size_bytes"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/image.rb lines 81-85; spec coverage in spec/models/typed_eav/field_spec.rb 'Image has the explicit operator set' + cast describe block"
  - criterion: "TypedEAV::Field::File same shape with class identity Image/File-distinct (no shared parent beyond Base)"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/file.rb declares `class File < Base` (NOT `class File < Image`); identical declarations to image.rb except class name and NotImplementedError message"
  - criterion: "Engine config.after_initialize wraps `TypedEAV::Value.has_one_attached :attachment` in `if defined?(::ActiveStorage::Blob)`; single :attachment association covers both Image and File"
    verdict: pass
    evidence: "commit 9747e6c lib/typed_eav/engine.rb#register_attachment_associations! at line 130 is the testable seam; second config.after_initialize block invokes it. Single `:attachment` declaration on TypedEAV::Value (line 134)"
  - criterion: "on_image_attached hook contract: `(value, blob)` arity, hand-rolled accessor idiom, fires AFTER versioning AND on_value_change"
    verdict: pass
    evidence: "commit 6c2a927 lib/typed_eav/config.rb attr_accessor :on_image_attached (DEVN-01 explains attr_accessor vs hand-rolled choice). Hook ordering: commit 9747e6c app/models/typed_eav/value.rb declares `_dispatch_image_attached` AFTER the three `_dispatch_value_change_*` callbacks (lines 306-310). Spec coverage in field_spec.rb 'fires when an attachment is added' confirms after_commit ordering"
  - criterion: "on_image_attached fires ONLY for Field::Image (not Field::File); regression test asserts non-fire for File"
    verdict: pass
    evidence: "commit 9747e6c app/models/typed_eav/value.rb#_dispatch_image_attached line 562: `return unless field.is_a?(TypedEAV::Field::Image)`. spec/models/typed_eav/field_spec.rb 'does NOT fire for Field::File attachments' green"
  - criterion: "Field::Image#cast contract: nil/blank → [nil, false]; String → [raw, false]; Blob → [signed_id, false]; IO/File/Hash → [nil, true]; raise NotImplementedError when AS undefined"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/image.rb lines 86-101; spec/models/typed_eav/field_spec.rb describe TypedEAV::Field::Image — 6 examples cover all cases. spec/lib/typed_eav/active_storage_soft_detect_spec.rb unloaded-path block confirms NotImplementedError raise via hide_const"
  - criterion: "Field::File#cast: identical contract with class name swapped in error message"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/file.rb lines 42-58; same shape as image.rb; spec coverage in field_spec.rb describe TypedEAV::Field::File"
  - criterion: "Field::Image#read_value / apply_default_to inherit defaults — single-cell from dispatch perspective"
    verdict: pass
    evidence: "Image and File define neither method — inherit from Field::Base (read_value at base.rb line 275, apply_default_to at line 307). Confirmed by passing spec/models/typed_eav/value_spec.rb 'with an image field stores signed_id in string_value' (the single-cell read path)"
  - criterion: "Field::Image#validate_typed_value validates blob via find_signed; allowed_content_types + max_size_bytes options; skipped when AS unloaded"
    verdict: pass
    evidence: "commit 968b7bd app/models/typed_eav/field/image.rb lines 113-138 (find_signed, content_type_matches? helper, byte_size check). spec/lib/typed_eav/active_storage_soft_detect_spec.rb 'validate_typed_value silently no-ops when ActiveStorage::Blob is undefined' green"
  - criterion: "BUILTIN_FIELD_TYPES gains :image and :file entries"
    verdict: pass
    evidence: "commit 968b7bd lib/typed_eav/config.rb lines 74-75 (`file: \"TypedEAV::Field::File\"`, `image: \"TypedEAV::Field::Image\"`). zeitwerk_loading_spec passes — both constants resolve via Config.field_class_for"
  - criterion: "Config.on_image_attached accessor + reset! + spec_helper :event_callbacks snapshot extension"
    verdict: pass
    evidence: "commit 6c2a927 lib/typed_eav/config.rb attr_accessor :on_image_attached + reset! line 257. spec/spec_helper.rb :event_callbacks snapshots saved_on_image_attached. spec/lib/typed_eav/config_versioning_spec.rb '.on_image_attached' describe block — 5 examples covering defaults/settable/reset/leak-detection"
  - criterion: ":image_field and :file_field factories"
    verdict: pass
    evidence: "commit 968b7bd spec/factories/typed_eav.rb adds both factories matching the :currency_field / :percentage_field pattern"
  - criterion: "spec/dummy schema migrated for Active Storage; storage.yml configured for :test service"
    verdict: pass
    evidence: "commit 6c2a927 spec/dummy/config/storage.yml (Disk-backed :test/:local services); spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb (canonical Rails-generated migration); spec/dummy/config/environment.rb sets `config.active_storage.service = :test`"
  - criterion: "active_storage_soft_detect_spec.rb covers BOTH branches (loaded + unloaded via testable seam)"
    verdict: pass
    evidence: "commit b87a474 spec/lib/typed_eav/active_storage_soft_detect_spec.rb — 10 examples: 4 loaded-path (reflection, cast, validate against real Blob), 4 unloaded-path via hide_const (cast raise for Image, cast raise for File, validate no-op, class still loads), 2 Engine seam (idempotence, AS-unloaded return)"
  - criterion: "All RESEARCH §RQ-7 spec patterns covered (column mapping, supported operators, casting, nil-safety exhaustive, operators exhaustive, hook firing positive + negative)"
    verdict: pass
    evidence: "commit b87a474 extends every iteration block in spec/models/typed_eav/field_spec.rb: column-mapping (Image/File → :string_value), operator_column BC iteration, supported_operators assertions, cast describes, nil-safety exhaustive (image_field/file_field added), operators-exhaustive, on_image_attached dispatch describe (5 examples)"
  - criterion: "README documents Image, File, soft-detect contract, and on_image_attached hook"
    verdict: pass
    evidence: "commit c1e79e6 README.md: Field Types table gains Image/File rows; §'Built-in Phase-5 field types' gains 4 new bullets (Image contract, File contract, Active Storage dependency soft-detect, on_image_attached hook) with code examples"
  - criterion: "frozen_string_literal: true on every new .rb file"
    verdict: pass
    evidence: "head -1 of app/models/typed_eav/field/image.rb, file.rb, spec/lib/typed_eav/active_storage_soft_detect_spec.rb all show '# frozen_string_literal: true'. db/migrate and spec/dummy files excluded per CONVENTIONS.md (Rubocop config)"
  - criterion: "No hardcoded attribute references outside legitimate field-class implementation sites"
    verdict: pass
    evidence: "Image/File use `:string_value` literally inside their own field class declarations (legitimate column choice). Engine's `has_one_attached :attachment` is a model-level macro (not an attribute reference). Value's _dispatch_image_attached uses `field.is_a?(TypedEAV::Field::Image)` (class identity, not attribute name) and `attachment.attached?` (AS-native). No new grep hits for hardcoded :string_value/:integer_value/:decimal_value/:boolean_value in lib/typed_eav/query_builder.rb"
  - criterion: "Image/File classes still LOAD when Active Storage is unloaded (Zeitwerk autoloads them)"
    verdict: pass
    evidence: "spec/lib/typed_eav/active_storage_soft_detect_spec.rb 'Field::Image still LOADS as a Ruby class when ActiveStorage::Blob is undefined' green. Image.value_column and Image.supported_operators readable inside hide_const block"
  - criterion: "Idempotent registration: register_attachment_associations! safe to call multiple times"
    verdict: pass
    evidence: "commit 9747e6c lib/typed_eav/engine.rb @attachment_registered guard. spec/lib/typed_eav/active_storage_soft_detect_spec.rb 'is idempotent — second call returns false' confirms"
  - criterion: "Phase 1 (scope), Phase 3 (events), Phase 4 (versioning) regression-clean"
    verdict: pass
    evidence: "bundle exec rspec spec/lib/typed_eav/event_dispatcher_spec.rb spec/models/typed_eav/value_event_spec.rb spec/models/typed_eav/field_event_spec.rb spec/lib/typed_eav/versioning/ — 60 examples green; spec/lib/typed_eav/scoping_spec.rb green in full-suite run"
  - criterion: "Acceptance gate: bundle exec rspec → all green; rubocop clean"
    verdict: pass
    evidence: "bundle exec rspec → 789 passed (was 746 at phase start; +43 new examples for plan 05-03). bundle exec rubocop → 84 files, no offenses"
---

Phase 5 plan 03 ships TWO new field types — `Field::Image` and `Field::File` — via lazy Active Storage soft-detect (Gating Decision 1: gem does NOT add `activestorage` as a hard dependency; runtime guards via `defined?(::ActiveStorage::Blob)`). Five tasks, five atomic commits, 789 examples green (+43 new), RuboCop clean across 84 files.

## What Was Built

- `TypedEAV::Field::Image` and `TypedEAV::Field::File` — Active Storage-backed field types extending `Field::Base`. Both declare `value_column :string_value` (storing the attached blob's `signed_id`), narrow operators to `[:eq, :is_null, :is_not_null]`, and expose `allowed_content_types` + `max_size_bytes` options via `store_accessor :options`. Image and File share identical bodies — the distinction is class identity, used by the `on_image_attached` dispatcher and consumer code via `value.field.is_a?(Field::Image)`.
- **Lazy soft-detect contract:** Both classes still LOAD via Zeitwerk when AS is absent (constants are inspectable; `Image.value_column` returns `:string_value` even without AS). Only `#cast` and `#validate_typed_value` short-circuit / raise on invocation: `cast` raises `NotImplementedError` with an actionable install message; `validate_typed_value` silently no-ops (defensive belt-and-suspenders — the cast layer is the fail-fast surface).
- **`TypedEAV::Engine.register_attachment_associations!` testable seam.** Mirrors Phase 04's `Versioning.register_if_enabled` pattern: extracted from the second `config.after_initialize` block so specs can exercise both branches (loaded / AS-unloaded) without rebooting Rails. Conditional `defined?(::ActiveStorage::Blob)` guard + idempotency guard via `@attachment_registered` (returns `false` when already registered or when AS is unloaded). Single `:attachment` `has_one_attached` association on TypedEAV::Value covers BOTH Image and File typed Values — RESEARCH §Risk 3 documents the rationale against per-class associations (would double AR overhead on every Value row in the monolithic `typed_eav_values` table).
- **`Config.on_image_attached` accessor** with `(value, blob)` signature, plain `attr_accessor` idiom (matches `on_value_change` / `on_field_change` precedent — see DEVN-01). Default nil; reset! coverage; spec_helper `:event_callbacks` snapshot/restore extended.
- **`TypedEAV::Value#_dispatch_image_attached`** — after_commit dispatcher (declared AFTER the three `_dispatch_value_change_*` callbacks so it runs LAST in the chain — versioning and on_value_change both fire before this informational hook). Six guard clauses (AS loaded, field present, field is_a? Image, attachment association exists, `attachment.attached?`, `saved_change_to_string_value?`) before the hook firing. Error policy: rescue StandardError + Rails.logger.error — the after_commit chain MUST NOT crash on hook failures.
- **File-no-fire by design:** `_dispatch_image_attached` checks `is_a?(TypedEAV::Field::Image)`, never fires for `Field::File`. ROADMAP wording is image-specific; the regression test in field_spec.rb explicitly asserts non-fire for File, Text, and unset hook cases.
- **`BUILTIN_FIELD_TYPES`** gains `:image` and `:file` entries (positioned after `:email`, alphabetic intent within the existing logical grouping). `:image_field` and `:file_field` factories follow the bare-bones single-cell pattern of `:currency_field` / `:percentage_field`.
- **spec/dummy Active Storage scaffolding:** `spec/dummy/config/storage.yml` declares Disk-backed `:test` and `:local` services; `environment.rb` sets `config.active_storage.service = :test` (Active Storage was already loaded via `require "rails/all"`); the canonical Rails-generated migration creates `active_storage_blobs` / `active_storage_attachments` / `active_storage_variant_records`. `spec/spec_helper.rb` auto-applies pending dummy-app migrations on suite startup so fresh check-outs / CI just work.
- **`spec/lib/typed_eav/active_storage_soft_detect_spec.rb` (NEW)** — 10 examples covering both branches via RSpec's `hide_const` (genuine constant removal — `defined?(::ActiveStorage::Blob)` returns nil for real, exercising the gem's actual soft-detect predicate rather than a synthetic prepend-stub). Loaded path: reflection registered, cast accepts signed_ids, validate_typed_value runs against real Blob. Unloaded path: cast raise for Image, cast raise for File, validate silent no-op, class still loads. Engine seam: idempotence + AS-unloaded return value contract.
- **Spec coverage extensions in field_spec.rb (236 examples, +24)** — column-mapping iteration, operator_column BC iteration, supported_operators assertions, cast describes, nil-safety exhaustive list, operators-exhaustive list, on_image_attached dispatch describe (5 examples; positive + 3 negative regressions + raise-isolation).
- **Spec coverage extensions in value_spec.rb (95 examples, +6)** — "with an image field" and "with a file field" contexts cover the full attach + signed_id assignment + reload + read-back round-trip; value-nil-when-no-attachment regression.
- **README** §"Field Types" table gains Image/File rows; §"Built-in Phase-5 field types" gains four new bullets (Image contract, File contract, Active Storage dependency soft-detect, on_image_attached hook) with canonical code examples for the attach flow and async-processing pattern.

## Files Modified

- `app/models/typed_eav/field/image.rb` -- create: TypedEAV::Field::Image with signed_id contract, soft-detect cast guard, content-type/size validation
- `app/models/typed_eav/field/file.rb` -- create: TypedEAV::Field::File parallel to Image (class identity is the only distinction)
- `app/models/typed_eav/value.rb` -- modify: after_commit `_dispatch_image_attached` declared AFTER value-change callbacks; six-guard-clause dispatcher with StandardError rescue
- `lib/typed_eav/engine.rb` -- modify: second `config.after_initialize` block + `register_attachment_associations!` testable seam (mirrors Phase 04's `Versioning.register_if_enabled` pattern)
- `lib/typed_eav/config.rb` -- modify: BUILTIN_FIELD_TYPES gains :file and :image; Config.on_image_attached attr_accessor + reset! coverage
- `spec/factories/typed_eav.rb` -- modify: :image_field and :file_field factories
- `spec/dummy/config/storage.yml` -- create: :test and :local Disk-backed services
- `spec/dummy/config/environment.rb` -- modify (DEVN-01 — plan referenced application.rb but this dummy app keeps app config inline in environment.rb): sets `config.active_storage.service = :test`
- `spec/dummy/db/migrate/20260506000000_create_active_storage_tables.active_storage.rb` -- create: canonical Rails-generated AS migration
- `spec/spec_helper.rb` -- modify: auto-apply pending dummy-app migrations on startup; extend :event_callbacks snapshot/restore to cover Config.on_image_attached
- `spec/lib/typed_eav/config_versioning_spec.rb` -- modify: 5 examples covering Config.on_image_attached defaults / setter / reset! / event_callbacks isolation
- `spec/models/typed_eav/field_spec.rb` -- modify: column-mapping, operator_column BC, supported_operators, cast describes, nil-safety exhaustive, operators-exhaustive iterations all extended; on_image_attached hook dispatch describe block (5 examples)
- `spec/models/typed_eav/value_spec.rb` -- modify: "with an image field" and "with a file field" contexts (round-trip + value-nil regression)
- `spec/lib/typed_eav/active_storage_soft_detect_spec.rb` -- create: 10 examples covering loaded path / unloaded path (via hide_const) / Engine seam idempotence
- `README.md` -- modify: Field Types table + §"Built-in Phase-5 field types" gain Image/File/soft-detect/on_image_attached bullets with examples

## Deviations

See frontmatter `deviations:` for the canonical list. All five deviations are DEVN-01 (minor): three are documentation/path adjustments to match this dummy app's actual layout (no `application.rb`, no `bin/rails`, plan-truth wording on `defined?(@var)` idiom did not match the closer on_value_change/on_field_change precedent), and two are RuboCop / RSpec polish (rspec-rails cops required inline disables for the topical-describe form on the new soft-detect spec, and rspec-mocks `hide_const` was used instead of the plan-suggested prepend-stub for a stronger soft-detect guarantee). No scope changes; no DEVN-02/-03/-04/-05.
