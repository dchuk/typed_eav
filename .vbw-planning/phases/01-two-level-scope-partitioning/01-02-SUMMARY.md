---
phase: 1
plan: "02"
title: "Tuple-returning resolver and thread-local stack"
status: complete
completed: 2026-04-29
tasks_completed: 4
tasks_total: 4
commit_hashes:
  - 52014a3
deviations:
  - "DEVN-05 (pre-existing / anticipated): 8 examples in spec/lib/typed_eav/scoping_spec.rb fail after this commit. The plan calls these out explicitly as expected — they are NOT regressions caused by gem-code bugs. 5 are assertion-shape mismatches (`expected \"t1\", got [\"t1\", nil]`) that plan 06 will rewrite to assert tuples; 3 are `ArgumentError` raises from `current_scope` because the spec stubs `Config.scope_resolver = -> { \"scalar\" }` (lines 67, 79, 140 / 142) — exactly the new strict contract surfacing as designed. The plan's verify gate explicitly required this pattern. No NoMethodError / TypeError raised from gem code paths."
pre_existing_issues:
  - '{"test":"TypedEAV scope enforcement .with_scope sets the ambient scope inside the block","file":"spec/lib/typed_eav/scoping_spec.rb:16","error":"assertion-shape mismatch: expected \"t1\", got [\"t1\", nil] — plan 06 owns rewriting assertions to expect tuples"}'
  - '{"test":"TypedEAV scope enforcement .with_scope restores the prior scope after the block exits","file":"spec/lib/typed_eav/scoping_spec.rb:22","error":"assertion-shape mismatch: expected \"inner\", got [\"inner\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement .with_scope accepts an AR-like object and normalizes to id.to_s","file":"spec/lib/typed_eav/scoping_spec.rb:38","error":"assertion-shape mismatch: expected \"42\", got [\"42\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement resolver chain uses the configured resolver when no block is active","file":"spec/lib/typed_eav/scoping_spec.rb:67","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar; the new Phase 1 strict contract requires a tuple — plan 06 owns updating resolver stubs"}'
  - '{"test":"TypedEAV scope enforcement resolver chain with_scope wins over the configured resolver","file":"spec/lib/typed_eav/scoping_spec.rb:72","error":"assertion-shape mismatch: expected \"from_block\", got [\"from_block\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement resolver chain normalizes AR-record return values from the resolver","file":"spec/lib/typed_eav/scoping_spec.rb:79","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare AR record (not a tuple); plan 06 owns updating resolver stubs"}'
  - '{"test":"TypedEAV scope enforcement acts_as_tenant bridge (default resolver) reads ActsAsTenant.current_tenant when ActsAsTenant is defined","file":"spec/lib/typed_eav/scoping_spec.rb:91","error":"assertion-shape mismatch: expected \"99\", got [\"99\", nil] — plan 06 owns rewriting assertions"}'
  - '{"test":"TypedEAV scope enforcement fail-closed enforcement on scoped models … does NOT raise when the resolver returns a value","file":"spec/lib/typed_eav/scoping_spec.rb:140","error":"ArgumentError raised by current_scope because the spec stubs the resolver with a bare scalar (line 142); plan 06 owns updating resolver stubs"}'
ac_results:
  - criterion: "TypedEAV.current_scope returns a [scope, parent_scope] two-element Array (both elements String or nil) — never a bare scalar"
    verdict: pass
    evidence: "Verified via dummy-app runner: with_scope(\"t1\") { current_scope } => [\"t1\", nil]; with_scope([\"t1\", \"ps1\"]) { current_scope } => [\"t1\", \"ps1\"]; resolver-tuple => [\"t1\", \"ps1\"]; nil resolver => nil"
  - criterion: "TypedEAV.with_scope accepts either a scalar (parent_scope coerced to nil) or a two-element Array; the previous one-arg signature with_scope(value) keeps its meaning: scope=value, parent_scope=nil"
    verdict: pass
    evidence: "Verified via dummy-app runner: with_scope(\"t1\") { current_scope } == [\"t1\", nil]; with_scope([\"t1\", \"ps1\"]) { current_scope } == [\"t1\", \"ps1\"]; with_scope(Struct.new(:id).new(42)) { current_scope } == [\"42\", nil]"
  - criterion: "Thread-local stack stores tuples (Arrays of length 2), not scalars; with_scope pushes a tuple; current_scope reads the last tuple"
    verdict: pass
    evidence: "lib/typed_eav.rb:126 pushes normalize_scope(value); lib/typed_eav.rb:76 returns stack.last directly — no further coercion. Nested blocks return inner tuple verbatim: with_scope(\"outer\") { with_scope([\"i\", \"ip\"]) { current_scope } } == [\"i\", \"ip\"]"
  - criterion: "Config::DEFAULT_SCOPE_RESOLVER returns [ActsAsTenant.current_tenant, nil] (auto-detect path) — tuple, not scalar"
    verdict: pass
    evidence: "lib/typed_eav/config.rb:38-42: returns nil unless defined?(::ActsAsTenant); else [::ActsAsTenant.current_tenant, nil]. Verified DEFAULT_SCOPE_RESOLVER.call == nil in the dummy app (no AAT loaded)."
  - criterion: "TypedEAV.normalize_scope is the permissive helper — accepts scalar/AR-record/tuple/nil, returns [String|nil, String|nil] or nil. It is used on the with_scope INPUT side (where scalar is BC) and is NOT the contract chokepoint for resolver-callable returns"
    verdict: pass
    evidence: "lib/typed_eav.rb:174-179 implements the permissive 3-branch dispatch (nil → nil; 2-elem Array → per-slot normalize; else → [normalize_one(v), nil]). Called from with_scope on push (line 126) but NOT called on the raw resolver return — current_scope:86 validates shape strictly first."
  - criterion: "Config.scope_resolver contract is enforced strictly inside TypedEAV.current_scope: the resolver's RAW return value (before any normalization) must be nil or a 2-element Array; any other shape (including a bare scalar) raises ArgumentError. No silent coercion."
    verdict: pass
    evidence: "lib/typed_eav.rb:83-92: raw = Config.scope_resolver&.call; return nil if raw.nil?; raise ArgumentError unless raw.is_a?(Array) && raw.size == 2. Verified: bare scalar 'scalar' raises; ['a'] raises; ['a','b','c'] raises; ['t1','ps1'] OK; nil OK."
  - criterion: "ArgumentError message names the offending return value via .inspect and points to the migration path (CHANGELOG / README)"
    verdict: pass
    evidence: "lib/typed_eav.rb:87-92 message text: 'TypedEAV.config.scope_resolver must return a 2-element [scope, parent_scope] Array (or nil). Got: #{raw.inspect}. v0.1.x resolvers returning a bare scalar must be updated — see CHANGELOG and the README migration note.' Verified: ArgumentError on { \"scalar\" } shows 'Got: \"scalar\"'."
  - criterion: "Resolver chain semantics for TypedEAV.unscoped block unchanged: returns nil and stops further resolution"
    verdict: pass
    evidence: "lib/typed_eav.rb:71 — `return nil if Thread.current[THREAD_UNSCOPED]` is the first branch in current_scope; unmodified from v0.1.x. Verified: existing scoping_spec tests for unscoped semantics still pass (none of the 8 failures touch unscoped)."
  - criterion: "Inline yard/comment docs explain the breaking change and migration path for custom resolvers, and explicitly distinguish the with_scope BC path (scalar OK) from the resolver-callable contract (scalar raises)"
    verdict: pass
    evidence: "lib/typed_eav.rb:43-69 (current_scope contract block); lib/typed_eav.rb:104-123 (with_scope BC-permissive surface); lib/typed_eav.rb:147-173 (normalize_scope NOT-a-contract-chokepoint disclaimer); lib/typed_eav/config.rb:18-44 (DEFAULT_SCOPE_RESOLVER migration note); lib/typed_eav/config.rb:65-83 (scope_resolver strict contract block). All five doc blocks call out the split surface explicitly."
  - criterion: "Single commit: refactor(scope): extend ambient resolver to return [scope, parent_scope] tuple"
    verdict: pass
    evidence: "Commit 52014a3, message subject 'refactor(scope): extend ambient resolver to return [scope, parent_scope] tuple'. git diff HEAD~1 --stat shows 2 files changed: lib/typed_eav.rb (+114/-10), lib/typed_eav/config.rb (+42/-0)."
---

Phase 1 / wave 1 / plan 02: convert the ambient scope resolver chain from scalar-returning to tuple-returning. After this commit `TypedEAV.current_scope` returns `[scope, parent_scope]` (or nil), `TypedEAV.with_scope` keeps single-arg BC, and `Config::DEFAULT_SCOPE_RESOLVER` returns a tuple. The strict-contract raise lives in `current_scope` at the resolver-fallback branch so a bare-scalar return from a custom `Config.scope_resolver` cannot be silently coerced.

## What Was Built

- `TypedEAV.current_scope` (`lib/typed_eav.rb:70-100`): now returns `nil` or a 2-element tuple. Stack reads bypass `normalize_scope` entirely (the stack stores normalized tuples). The resolver-callable path validates raw shape BEFORE normalization — non-nil non-2-Array returns raise `ArgumentError` naming the offending value via `.inspect`.
- `TypedEAV.with_scope(value)` (`lib/typed_eav.rb:124-130`): single-arg signature unchanged. Internally pushes `normalize_scope(value)` so the stack stores tuples (or nil). Accepts scalar (BC), tuple, AR record, or nil.
- `TypedEAV.normalize_scope(value)` (`lib/typed_eav.rb:174-179`): rewritten to always return nil or a 2-tuple. 3-branch dispatch: nil → nil; 2-Array → per-slot normalize; else → `[normalize_one(v), nil]`. Private `normalize_one` helper extracts the per-slot scalar/AR coercion.
- `Config::DEFAULT_SCOPE_RESOLVER` (`lib/typed_eav/config.rb:45-49`): returns nil when AAT is not loaded; `[::ActsAsTenant.current_tenant, nil]` when AAT is loaded. `[nil, nil]` is preserved (not auto-collapsed to nil) to distinguish "AAT consulted, no tenant" from "no resolver".
- Doc comments at five sites explicitly distinguish the BC-permissive `with_scope` block surface from the strict-contract `Config.scope_resolver` callable surface, with pointers to the CHANGELOG / README migration note (which lands in plan 07).

## Files Modified

- `lib/typed_eav.rb` -- modified: tuple-aware `current_scope`, `with_scope`, `normalize_scope`; private `normalize_one` helper; expanded doc comments distinguishing BC surface (with_scope) from strict surface (resolver-callable).
- `lib/typed_eav/config.rb` -- modified: `DEFAULT_SCOPE_RESOLVER` returns a tuple; expanded doc comment on `scope_resolver` config_accessor with the strict-contract migration note.
