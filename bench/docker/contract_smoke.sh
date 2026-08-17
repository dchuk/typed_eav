#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$ROOT/bench/docker/lib/runner_contract.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/typed-eav-contract.XXXXXX"); trap 'case "$tmp" in */typed-eav-contract.*) rm -rf -- "$tmp";; esac' EXIT
export GB_TASK=T086 GB_RUN_ID=t086-local SECRET_KEY_BASE=fixed-test-secret
good_ruby=$(runner_contract_resolve_project_ruby)
[ "$(runner_contract_verify_project_ruby "$good_ruby")" = "$good_ruby" ]
mkdir -p "$tmp"/{output,tmp,log,cache,bundle,run}; printf '%s\n' 'BUNDLE_ALLOW_OFFLINE_INSTALL: "true"' > "$tmp/bundle/config"
runner_contract_require_identity
[ "$(runner_contract_pg_target 17)" = /var/lib/postgresql/data ]; [ "$(runner_contract_pg_target 18)" = /var/lib/postgresql ]
runner_contract_probe_writable "$tmp/output" "$tmp/tmp" "$tmp/log"; runner_contract_probe_secret; runner_contract_probe_rubocop_cache "$tmp/cache"; runner_contract_probe_offline_bundle "$tmp/bundle"
if (unset SECRET_KEY_BASE; runner_contract_probe_secret); then exit 1; fi
if runner_contract_probe_writable "$tmp/missing"; then exit 1; fi
if runner_contract_pg_target 99; then exit 1; fi
if runner_contract_probe_offline_bundle "$tmp/cache"; then exit 1; fi
"$good_ruby" -I"$ROOT/bench/docker/lib" - <<'RUBY' "$tmp/run"
require "artifact_envelope"
root = ARGV.fetch(0)
payload = {"rows" => [1, 2]}
accepted = TypedEAVBenchmark::ArtifactEnvelope.build(status: "accepted", task: "T086", run_id: "t086-local", payload: payload)
payload["rows"] << 3
raise unless accepted.dig("payload", "rows") == [1, 2]
TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: accepted)
begin
  TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: TypedEAVBenchmark::ArtifactEnvelope.build(status: "rejected", task: "T086", run_id: "t086-local", payload: {}))
  raise "exclusivity failed"
rescue RuntimeError => e
  raise unless e.message.include?("exclusive")
end
cyclic = []; cyclic << cyclic
begin
  TypedEAVBenchmark::ArtifactEnvelope.build(status: "rejected", task: "T086", run_id: "t086-local", payload: cyclic)
  raise "cycle accepted"
rescue ArgumentError => e
  raise unless e.message.include?("cyclic")
end
RUBY
runner_contract_atomic_stage "$tmp/run" 01_PREFLIGHT '{"state":"PREFLIGHT"}'
runner_contract_atomic_stage "$tmp/run" 02_QUIESCED '{"state":"QUIESCED"}'
runner_contract_atomic_stage "$tmp/run" 03_RUNNER_STOPPED '{"state":"RUNNER_STOPPED","injected":true}'
runner_contract_atomic_stage "$tmp/run" 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED"}'
runner_contract_atomic_stage "$tmp/run" 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT"}'
runner_contract_atomic_stage "$tmp/run" 06_SEALED '{"state":"SEALED"}'
tar -C "$tmp/run" -cf "$tmp/export.tar" .; sha256sum "$tmp/export.tar" > "$tmp/export.sha256"; runner_contract_assert_exported "$tmp/export.tar" "$tmp/export.sha256"
runner_contract_atomic_stage "$tmp/run" 07_AUDITED '{"state":"AUDITED","cleanup":true,"export_before_cleanup":true}'
[ "$(find "$tmp/run/stages" -name '*.json' | wc -l | tr -d ' ')" = 7 ]; [ -s "$tmp/run/accepted.json" ]; [ ! -e "$tmp/run/rejected.json" ]
runner_contract_forbid_unsafe_words "$ROOT/bench/docker/contract_smoke.sh"

mkdir "$tmp/fake-bin"
printf '#!/bin/sh\nprintf "2.6.10"\n' > "$tmp/fake-bin/ruby"
chmod +x "$tmp/fake-bin/ruby"
if runner_contract_verify_project_ruby "$tmp/fake-bin/ruby"; then exit 1; fi
if (export TYPED_EAV_PROJECT_RUBY="$tmp/fake-bin/ruby"; runner_contract_resolve_project_ruby); then exit 1; fi

printf 'sealed payload\n' > "$tmp/transfer.tar"
retention=$(runner_contract_retain_transfer "$tmp/transfer.tar" "$tmp/retained" t086-injected)
retained_path=${retention%%|*}; retained_sha=${retention##*|}
[ -s "$retained_path" ] && [ "$(sha256sum "$retained_path" | awk '{print $1}')" = "$retained_sha" ]
runner_contract_atomic_stage "$tmp/validator-failure" 07_AUDITED '{"state":"AUDITED","post_transfer_cleanup":true}'
if "$good_ruby" -e 'exit 23'; then exit 1; fi
[ -s "$retained_path" ] && [ "$(sha256sum "$retained_path" | awk '{print $1}')" = "$retained_sha" ]
[ ! -e "$tmp/validator-failure/accepted.json" ]
[ -s "$tmp/validator-failure/stages/07_AUDITED.json" ]
printf 'contract_smoke=pass accepted=1 rejected_exclusive=1 cycle_rejected=1 stages=7 ruby_mismatch_rejected=1 validator_failure_retained=%s retained_sha256=%s audited_cleanup=1\n' "$retained_path" "$retained_sha"
