#!/usr/bin/env bash

runner_contract_require_identity() {
  case "${GB_TASK:-}" in T[0-9][0-9][0-9]) ;; *) return 90;; esac
  case "${GB_RUN_ID:-}" in "${GB_TASK,,}"-*) ;; *) return 91;; esac
}

runner_contract_pg_target() {
  case "$1" in 18|19) printf '/var/lib/postgresql\n';; 12|13|14|15|16|17) printf '/var/lib/postgresql/data\n';; *) return 92;; esac
}

runner_contract_atomic_stage() {
  local root=$1 name=$2 json=$3 tmp
  mkdir -p "$root/stages" || return
  tmp="$root/stages/$name.json.tmp-$$"; printf '%s\n' "$json" > "$tmp" && mv "$tmp" "$root/stages/$name.json"
}

runner_contract_probe_writable() {
  local path probe
  for path in "$@"; do
    [ -d "$path" ] && probe="$path/.runner-contract-$$" && : > "$probe" && rm -f "$probe" || return 93
  done
}

runner_contract_probe_secret() { [ -n "${SECRET_KEY_BASE:-}" ] || return 94; }
runner_contract_probe_rubocop_cache() { [ -d "$1" ] && [ -w "$1" ] || return 95; }
runner_contract_probe_offline_bundle() { [ -f "$1/config" ] && grep -q 'BUNDLE_ALLOW_OFFLINE_INSTALL' "$1/config" || return 96; }

runner_contract_verify_project_ruby() {
  local ruby_bin=$1
  [ -x "$ruby_bin" ] || return 98
  [ "$("$ruby_bin" -e 'print RUBY_VERSION' 2>/dev/null)" = 3.4.4 ] || return 98
  printf '%s\n' "$ruby_bin"
}

runner_contract_resolve_project_ruby() {
  local candidate
  if [ -n "${TYPED_EAV_PROJECT_RUBY:-}" ]; then
    runner_contract_verify_project_ruby "$TYPED_EAV_PROJECT_RUBY"
    return
  fi
  if command -v rbenv >/dev/null 2>&1; then
    candidate=$(RBENV_VERSION=3.4.4 rbenv which ruby 2>/dev/null) || candidate=""
    if [ -n "$candidate" ] && runner_contract_verify_project_ruby "$candidate"; then return; fi
  fi
  candidate=$(command -v ruby 2>/dev/null) || candidate=""
  [ -n "$candidate" ] && runner_contract_verify_project_ruby "$candidate"
}

runner_contract_retain_transfer() {
  local source=$1 retained_root=$2 run_id=$3 destination temporary checksum
  [ -s "$source" ] || return 99
  case "$run_id" in t[0-9][0-9][0-9]-*) ;; *) return 99;; esac
  mkdir -p "$retained_root" || return
  destination="$retained_root/$run_id-result.tar"
  temporary="$destination.tmp-$$"
  cp "$source" "$temporary" && mv "$temporary" "$destination" || return
  checksum=$(sha256sum "$destination" | awk '{print $1}') || return
  [ "$(sha256sum "$destination" | awk '{print $1}')" = "$checksum" ] || return 99
  printf '%s|%s\n' "$destination" "$checksum"
}

runner_contract_snapshot() {
  local id labels
  for id in $(docker ps -aq); do
    labels=$(docker inspect -f '{{json .Config.Labels}}' "$id")
    if python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")==sys.argv[2] and d.get("goalbuddy.run")==sys.argv[3] else 1)' "$labels" "$GB_TASK" "$GB_RUN_ID"; then continue; fi
    docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'
  done | sort
}

runner_contract_owned() {
  local kind=$1 name=$2 labels
  case "$kind" in container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$name" 2>/dev/null);; network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$name" 2>/dev/null);; *) return 97;; esac
  python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")==sys.argv[2] and d.get("goalbuddy.run")==sys.argv[3] else 1)' "$labels" "$GB_TASK" "$GB_RUN_ID"
}

runner_contract_assert_exported() { [ -s "$1" ] && [ -s "$2" ] && (cd "$(dirname "$1")" && sha256sum -c "$(basename "$2")"); }
runner_contract_forbid_unsafe_words() { ! grep -Eq -- '--privileged|--network[= ]host|docker[.]sock|docker compose|docker-compose|--restart|--publish|-p[[:space:]][0-9]|docker (system|image|container|volume) prune' "$1"; }
