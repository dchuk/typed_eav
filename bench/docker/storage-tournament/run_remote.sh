#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$ROOT/bench/docker/lib/runner_contract.sh"

readonly TASK=T127
readonly BASE_COMMIT=858bd5931b3e1a601ba87ccb58ea95d7305f2e2f
readonly REMOTE_HOST=dchuk@100.81.180.103
readonly DB_PREFIX=typed_eav_t123_
readonly GIB=$((1024 * 1024 * 1024))
readonly SMOKE_PROJECTED_PEAK_BYTES=$((24 * GIB))
readonly PROJECTED_EXPORT_BYTES=$((1 * GIB))
readonly FACTOR_SMOKE_ARTIFACT_SHA=12401bc778a32d8aed985a65b11af12d61497e120d450fc20e5b4e4fde23f10c
readonly FACTOR_SMOKE_A1M_HOSTS=128
readonly FACTOR_SMOKE_A1M_RELATION_BYTES=2809856
readonly MIN_DOCKER_FREE_BYTES=$((100 * GIB))
readonly RUNTIME_RESERVE_BYTES=$((20 * GIB))
readonly MIN_AVAILABLE_MEMORY_BYTES=$((12 * GIB))
readonly WORK_DEADLINE_SECONDS=$((18 * 60 * 60))
readonly TOTAL_DEADLINE_SECONDS=$((24 * 60 * 60))
readonly IOWAIT_SAMPLE_SECONDS=15
readonly IOWAIT_THRESHOLD_PERCENT=25
readonly IOWAIT_CONSECUTIVE_LIMIT=4
readonly MIGRATION_RUBY='ActiveRecord::MigrationContext.new([File.expand_path("db/migrate"), File.expand_path("spec/dummy/db/migrate")]).migrate'
readonly ALLOWED_OVERLAYS='bench/storage_tournament_benchmark.rb bench/validate_storage_tournament_artifact.rb bench/docker/storage-tournament/run_remote.sh bench/README.md docs/improvement-program.md Gemfile .rubocop.yml bench/planner_statistics_benchmark.rb'
readonly REMOTE_LOCAL_HELPERS='stable_snapshot_projection exclude_owned_snapshot source_path_set_matches iowait_next_streak write_monitor_reason_to write_monitor_marker_to monitor_reason_value monitor_exit_status owned_container owned_image cleanup finish snapshot write_snapshot_hash stage monitor_loop monitor'

usage() {
  printf 'usage: %s --self-test | --representative\n' "$0" >&2
}

required_docker_free_bytes() {
  local projected
  projected=$((3 * SMOKE_PROJECTED_PEAK_BYTES + RUNTIME_RESERVE_BYTES + PROJECTED_EXPORT_BYTES))
  if ((projected > MIN_DOCKER_FREE_BYTES)); then
    printf '%s\n' "$projected"
  else
    printf '%s\n' "$MIN_DOCKER_FREE_BYTES"
  fi
}

capacity_admitted() {
  local available_memory=$1 docker_free=$2
  ((available_memory >= MIN_AVAILABLE_MEMORY_BYTES && docker_free >= $(required_docker_free_bytes)))
}

valid_database_name() {
  local database=$1
  case "$database" in
    typed_eav_test) return 1 ;;
    "$DB_PREFIX"[a-z0-9_]*) return 0 ;;
    *) return 1 ;;
  esac
}

stable_snapshot_projection() {
  awk -F'|' '
    BEGIN { invalid = 0 }
    NF < 2 || $1 == "" || $2 == "" { invalid = 1; next }
    { print $1 "|" $2 }
    END { exit invalid }
  ' | LC_ALL=C sort
}

exclude_owned_snapshot() {
  awk -F'|' 'FILENAME == ARGV[1] { owned[$1] = 1; next } !owned[$1]' "$1" "$2"
}

source_path_set_matches() {
  local root=$1 expected actual status=0
  expected=$(mktemp) || return 1
  actual=$(mktemp) || { rm -f -- "$expected"; return 1; }
  awk '{print $2}' "$root/source.sha256" | LC_ALL=C sort > "$expected" || status=1
  (cd "$root" && find . -type f ! -path './source.sha256' -print | LC_ALL=C sort) > "$actual" || status=1
  [ "$status" -eq 0 ] && cmp -s "$expected" "$actual" || status=1
  rm -f -- "$expected" "$actual"
  return "$status"
}

checkpoint_provenance_matches() {
  local head parents actual expected
  head=$(git -C "$ROOT" rev-parse HEAD) || return 1
  parents=$(git -C "$ROOT" rev-list --parents -n 1 "$head") || return 1
  [[ $parents == "$head $BASE_COMMIT" ]] || return 1
  [[ $(git -C "$ROOT" rev-list --count "$BASE_COMMIT..$head") -eq 1 ]] || return 1
  git -C "$ROOT" merge-base --is-ancestor "$BASE_COMMIT" "$head" || return 1
  expected=$(printf '%s\n' "$ALLOWED_OVERLAYS" | tr ' ' '\n' | LC_ALL=C sort)
  actual=$(git -C "$ROOT" diff --name-only "$BASE_COMMIT" "$head" | LC_ALL=C sort)
  [[ $actual == "$expected" ]] || return 1
  [[ -z $(git -C "$ROOT" status --porcelain) ]]
}

monitor_exit_status() {
  case "$1" in
    noimpact|pressure|iowait) printf '50\n' ;;
    snapshot_failure|unexpected_exit|"") printf '49\n' ;;
    completed) printf '0\n' ;;
    *) printf '49\n' ;;
  esac
}

iowait_next_streak() {
  local current=$1 percent=$2 delta_ready=$3
  if [[ $delta_ready == true ]] &&
     awk -v percent="$percent" -v threshold="$IOWAIT_THRESHOLD_PERCENT" \
       'BEGIN { exit !(percent > threshold) }'; then
    printf '%s\n' "$((current + 1))"
  else
    printf '0\n'
  fi
}

classified_rejection_reason() {
  local status=$1 iowait_breaches=$2 pressure_breaches=$3 monitor_lived=$4
  if [[ $status -eq 52 ]]; then
    if [[ $iowait_breaches -gt 0 ]]; then
      printf 'monitor iowait rejection\n'
    elif [[ $pressure_breaches -gt 0 ]]; then
      printf 'monitor pressure rejection\n'
    elif [[ $monitor_lived == false ]]; then
      printf 'monitor lifecycle rejection\n'
    else
      printf 'monitor rejection\n'
    fi
  else
    printf 'remote runner rejection\n'
  fi
}

write_rejected_envelope() {
  local project_ruby=$1 root=$2 run=$3 status=$4 retained=$5 reason=$6
  mkdir -p "$root"
  runner_contract_atomic_stage "$root" 07_AUDITED \
    "{\"state\":\"AUDITED\",\"accepted\":false,\"reason\":\"$reason\"}"
  "$project_ruby" -I"$ROOT/bench/docker/lib" -rartifact_envelope -e '
root,run,status,retained,reason=ARGV
env=TypedEAVBenchmark::ArtifactEnvelope.build(status:"rejected",task:"T127",run_id:run,payload:{},
 diagnostics:{"remote_status"=>status.to_i,"retained"=>retained,"reason"=>reason})
TypedEAVBenchmark::ArtifactEnvelope.write!(root:root,envelope:env)
' "$root" "$run" "$status" "$retained" "$reason" >/dev/null
}

write_monitor_reason_to() {
  local root=$1 reason=$2 temporary
  temporary="$root/monitor.reason.tmp"
  [ -d "$root" ] || return 0
  [ -s "$root/monitor.reason" ] && return 0
  if printf '%s\n' "$reason" > "$temporary" && mv -f -- "$temporary" "$root/monitor.reason"; then
    :
  else
    rm -f -- "$temporary"
  fi
}

write_monitor_marker_to() {
  local root=$1 marker=$2 temporary
  temporary="$root/$marker.tmp"
  [ -d "$root" ] || return 0
  if : > "$temporary" && mv -f -- "$temporary" "$root/$marker"; then
    :
  else
    rm -f -- "$temporary"
  fi
}

self_test() {
  local project_ruby temporary retained retained_path retained_sha temporary_ruby
  local stable_a stable_b stable_added stable_removed stable_transition fixture_dir filtered reason status
  local streak percent breaches
  project_ruby=$(runner_contract_resolve_project_ruby)
  runner_contract_verify_project_ruby "$project_ruby" >/dev/null
  export GB_TASK=$TASK GB_RUN_ID=t127-self-test
  runner_contract_require_identity

  [[ $BASE_COMMIT == 858bd5931b3e1a601ba87ccb58ea95d7305f2e2f ]]
  [[ $REMOTE_HOST == dchuk@100.81.180.103 ]]
  [[ $(required_docker_free_bytes) -eq $MIN_DOCKER_FREE_BYTES ]]
  [[ $FACTOR_SMOKE_ARTIFACT_SHA =~ ^[0-9a-f]{64}$ ]]
  ((FACTOR_SMOKE_A1M_RELATION_BYTES * 1000000 / FACTOR_SMOKE_A1M_HOSTS <= SMOKE_PROJECTED_PEAK_BYTES))
  capacity_admitted "$MIN_AVAILABLE_MEMORY_BYTES" "$(required_docker_free_bytes)"
  if capacity_admitted "$((MIN_AVAILABLE_MEMORY_BYTES - 1))" "$(required_docker_free_bytes)"; then return 1; fi
  if capacity_admitted "$MIN_AVAILABLE_MEMORY_BYTES" "$(( $(required_docker_free_bytes) - 1 ))"; then return 1; fi
  valid_database_name typed_eav_t123_t127_self_test
  if valid_database_name typed_eav_test; then return 1; fi
  if valid_database_name typed_eav_t121_self_test; then return 1; fi
  [[ $MIGRATION_RUBY == *'db/migrate'* ]]
  [[ $MIGRATION_RUBY == *'spec/dummy/db/migrate'* ]]
  [[ $ALLOWED_OVERLAYS == *'bench/storage_tournament_benchmark.rb'* ]]
  [[ $ALLOWED_OVERLAYS == *'bench/validate_storage_tournament_artifact.rb'* ]]
  [[ $ALLOWED_OVERLAYS == *'bench/README.md'* ]]
  [[ $ALLOWED_OVERLAYS == *'docs/improvement-program.md'* ]]
  [[ $ALLOWED_OVERLAYS == *'Gemfile'* ]]
  [[ $ALLOWED_OVERLAYS == *'bench/planner_statistics_benchmark.rb'* ]]
  [[ $(find "$ROOT/bench/docker/storage-tournament" -maxdepth 1 -type f -print | wc -l | tr -d ' ') -eq 1 ]]
  checkpoint_provenance_matches
  runner_contract_forbid_unsafe_words "$0"

  stable_a=$(printf '%s\n' \
    'id-a|running|Up 1 minute' 'id-b|exited|Exited (0) 2 minutes ago' |
    stable_snapshot_projection)
  stable_b=$(printf '%s\n' \
    'id-a|running|Up 2 minutes' 'id-b|exited|Exited (0) 3 minutes ago' |
    stable_snapshot_projection)
  stable_added=$(printf '%s\n' \
    'id-a|running|Up 2 minutes' 'id-b|exited|Exited (0) 3 minutes ago' \
    'id-c|created|Created less than a second ago' | stable_snapshot_projection)
  stable_removed=$(printf '%s\n' 'id-a|running|Up 2 minutes' | stable_snapshot_projection)
  stable_transition=$(printf '%s\n' \
    'id-a|paused|Up 2 minutes (Paused)' 'id-b|exited|Exited (0) 3 minutes ago' |
    stable_snapshot_projection)
  [[ $stable_a == "$stable_b" ]]
  [[ $stable_a != "$stable_added" ]]
  [[ $stable_a != "$stable_removed" ]]
  [[ $stable_a != "$stable_transition" ]]
  local samples=1
  ((samples < 2))
  samples=2
  ((samples >= 2))

  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/typed-eav-t127-monitor-fixture.XXXXXX")
  trap 'case ${fixture_dir:-} in */typed-eav-t127-monitor-fixture.*) rm -rf -- "$fixture_dir";; esac' RETURN
  : > "$fixture_dir/owned"
  printf '%s\n' 'id-a|running' 'id-b|exited' > "$fixture_dir/snapshot"
  filtered=$(exclude_owned_snapshot "$fixture_dir/owned" "$fixture_dir/snapshot")
  [[ $filtered == $'id-a|running\nid-b|exited' ]]
  printf '%s\n' id-a > "$fixture_dir/owned"
  filtered=$(exclude_owned_snapshot "$fixture_dir/owned" "$fixture_dir/snapshot")
  [[ $filtered == 'id-b|exited' ]]
  mkdir "$fixture_dir/source"
  printf 'source fixture\n' > "$fixture_dir/source/a"
  (cd "$fixture_dir/source" && shasum -a 256 ./a) > "$fixture_dir/source/source.sha256"
  source_path_set_matches "$fixture_dir/source"
  printf 'runtime diagnostic\n' > "$fixture_dir/source/snapshot-baseline.sha256"
  if source_path_set_matches "$fixture_dir/source"; then return 1; fi
  rm -f -- "$fixture_dir/source/snapshot-baseline.sha256"
  source_path_set_matches "$fixture_dir/source"
  awk '/<<'\''REMOTE'\''/{capture=1;next} capture && /^REMOTE$/{exit} capture{print}' "$0" > "$fixture_dir/remote.sh"
  local helper
  for helper in $REMOTE_LOCAL_HELPERS; do
    grep -Eq "^${helper}\\(\\)[[:space:]]*\\{" "$fixture_dir/remote.sh"
  done
  for reason in noimpact pressure iowait snapshot_failure unexpected_exit; do
    rm -f -- "$fixture_dir/monitor.reason"
    write_monitor_reason_to "$fixture_dir" "$reason"
    [[ $(<"$fixture_dir/monitor.reason") == "$reason" ]]
    status=$(monitor_exit_status "$reason")
    case "$reason" in
      noimpact|pressure|iowait) [[ $status == 50 ]] ;;
      snapshot_failure|unexpected_exit) [[ $status == 49 ]] ;;
    esac
  done
  [[ $(monitor_exit_status completed) == 0 ]]
  streak=0
  for percent in 26 27; do streak=$(iowait_next_streak "$streak" "$percent" true); done
  [[ $streak -eq 2 && $streak -lt $IOWAIT_CONSECUTIVE_LIMIT ]]
  streak=$(iowait_next_streak "$streak" 28 true)
  [[ $streak -eq 3 && $streak -lt $IOWAIT_CONSECUTIVE_LIMIT ]]
  breaches=0
  streak=$(iowait_next_streak "$streak" 29 true)
  if [[ $streak -ge $IOWAIT_CONSECUTIVE_LIMIT ]]; then breaches=$((breaches + 1)); fi
  [[ $streak -eq $IOWAIT_CONSECUTIVE_LIMIT && $breaches -eq 1 ]]
  streak=0
  for percent in 26 27 10 28 29; do streak=$(iowait_next_streak "$streak" "$percent" true); done
  [[ $streak -eq 2 ]]
  [[ $(iowait_next_streak 3 25 true) -eq 0 ]]
  [[ $(iowait_next_streak 3 99 false) -eq 0 ]]
  for marker in noimpact.breach pressure.breach iowait.breach snapshot-failure.breach; do
    write_monitor_marker_to "$fixture_dir" "$marker"
    [[ -e "$fixture_dir/$marker" ]]
    rm -f -- "$fixture_dir/$marker"
  done

  temporary=$(mktemp -d "${TMPDIR:-/tmp}/typed-eav-t127-self-test.XXXXXX")
  trap 'case ${temporary:-} in */typed-eav-t127-self-test.*) rm -rf -- "$temporary";; esac' RETURN
  printf 'retained payload\n' > "$temporary/result.tar"
  retained=$(runner_contract_retain_transfer "$temporary/result.tar" "$temporary/retained" t127-self-test)
  retained_path=${retained%%|*}
  retained_sha=${retained##*|}
  [[ -s $retained_path ]]
  [[ $(shasum -a 256 "$retained_path" | awk '{print $1}') == "$retained_sha" ]]

  "$project_ruby" -I"$ROOT/bench/docker/lib" - "$temporary/envelope" <<'RUBY'
require "artifact_envelope"
root = ARGV.fetch(0)
accepted = TypedEAVBenchmark::ArtifactEnvelope.build(
  status: "accepted", task: "T127", run_id: "t127-self-test", payload: {"retained" => true}
)
TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: accepted)
begin
  rejected = TypedEAVBenchmark::ArtifactEnvelope.build(
    status: "rejected", task: "T127", run_id: "t127-self-test", payload: {}
  )
  TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: rejected)
  raise "accepted/rejected exclusivity failed"
rescue RuntimeError => error
  raise unless error.message.include?("exclusive")
end
RUBY
  [[ -s $temporary/envelope/accepted.json ]]
  [[ ! -e $temporary/envelope/rejected.json ]]

  write_rejected_envelope "$project_ruby" "$temporary/rejected-envelope" t127-self-test 52 \
    "$retained_path" "$(classified_rejection_reason 52 1 0 false)"
  "$project_ruby" -rjson -e '
data=JSON.parse(File.read(ARGV.fetch(0)))
raise "classified status lost" unless data.dig("diagnostics","remote_status") == 52
raise "classified reason lost" unless data.dig("diagnostics","reason") == "monitor iowait rejection"
' "$temporary/rejected-envelope/rejected.json"

  temporary_ruby="$temporary/ruby-2.6"
  printf '#!/bin/sh\nprintf "2.6.10"\n' > "$temporary_ruby"
  chmod +x "$temporary_ruby"
  if runner_contract_verify_project_ruby "$temporary_ruby"; then return 1; fi

  printf 't127_runner_self_test=pass ruby=3.4.4 required_docker_free_bytes=%s work_deadline=%s total_deadline=%s retained_sha256=%s\n' \
    "$(required_docker_free_bytes)" "$WORK_DEADLINE_SECONDS" "$TOTAL_DEADLINE_SECONDS" "$retained_sha"
}

die() {
  printf 'T127: %s\n' "$*" >&2
  exit 1
}

representative() {
  [[ ${TYPED_EAV_REPRESENTATIVE_RUN_OK:-} == 1 ]] || die "representative execution requires TYPED_EAV_REPRESENTATIVE_RUN_OK=1"
  local project_ruby run_id local_tmp remote_tmp transfer retained_root retention retained_path retained_sha
  local remote_status extract_root candidate candidate_sha envelope_root canonical classification
  local classified_status classified_iowait classified_pressure classified_monitor_lived rejection_reason
  project_ruby=$(runner_contract_resolve_project_ruby) || die "project Ruby 3.4.4 unavailable"
  runner_contract_verify_project_ruby "$project_ruby" >/dev/null || die "project Ruby mismatch"
  checkpoint_provenance_matches || die "checkpoint provenance mismatch or dirty worktree"

  run_id="t127-$(date -u +%Y%m%dt%H%M%sz)-$$"
  remote_tmp="/tmp/$run_id"
  transfer="$remote_tmp.result.tar"
  local_base=/tmp
  [[ -d /private/tmp ]] && local_base=/private/tmp
  local_tmp=$(mktemp -d "$local_base/typed-eav-$run_id.XXXXXX")
  retained_root="$local_base/typed-eav-t127-retained"
  cleanup_local() {
    case "${local_tmp:-}" in /tmp/typed-eav-t127-*|/private/tmp/typed-eav-t127-*) rm -rf -- "$local_tmp";; esac
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" "rm -f -- '$transfer'" >/dev/null 2>&1 || true
  }
  trap cleanup_local EXIT

  mkdir -p "$local_tmp/src"
  git -C "$ROOT" archive "$BASE_COMMIT" | tar -x -C "$local_tmp/src"
  local overlay
  for overlay in $ALLOWED_OVERLAYS; do
    mkdir -p "$local_tmp/src/$(dirname "$overlay")"
    cp "$ROOT/$overlay" "$local_tmp/src/$overlay"
  done
  (cd "$local_tmp/src" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$local_tmp/source.sha256"
  cp "$local_tmp/source.sha256" "$local_tmp/src/source.sha256"
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$local_tmp/src" -czf "$local_tmp/source.tgz" .
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
    "test ! -e '$remote_tmp' && test ! -e '$remote_tmp.tgz' && test ! -e '$transfer'" || die "remote run path exists"
  scp -q -o BatchMode=yes "$local_tmp/source.tgz" "$REMOTE_HOST:$remote_tmp.tgz"

  set +e
  timeout "$TOTAL_DEADLINE_SECONDS" ssh -o BatchMode=yes "$REMOTE_HOST" \
    "RUN_ID='$run_id' RTMP='$remote_tmp' TRANSFER='$transfer' REQUIRED_FREE='$(required_docker_free_bytes)' \
MIN_MEMORY='$MIN_AVAILABLE_MEMORY_BYTES' WORK_DEADLINE='$WORK_DEADLINE_SECONDS' TOTAL_DEADLINE='$TOTAL_DEADLINE_SECONDS' \
SMOKE_PEAK='$SMOKE_PROJECTED_PEAK_BYTES' EXPORT_BYTES='$PROJECTED_EXPORT_BYTES' DB_PREFIX='$DB_PREFIX' \
IOWAIT_SAMPLE_SECONDS='$IOWAIT_SAMPLE_SECONDS' IOWAIT_THRESHOLD_PERCENT='$IOWAIT_THRESHOLD_PERCENT' \
IOWAIT_CONSECUTIVE_LIMIT='$IOWAIT_CONSECUTIVE_LIMIT' bash -s" <<'REMOTE'
set -euo pipefail
TASK=T127
NET="$RUN_ID-net"; PGVOL="$RUN_ID-pg"; OUTVOL="$RUN_ID-out"
PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; FINALIZER="$RUN_ID-finalizer"; IMAGE="$RUN_ID:runner"
DB="${DB_PREFIX}t127_${RUN_ID//[^a-z0-9]/_}"
monitor_pid=""; before_file=""; after_file=""; initial_ruby_tag=false; ruby_image_id=""; ruby_image_introduced=false

stable_snapshot_projection() {
  awk -F'|' '
    BEGIN { invalid = 0 }
    NF < 2 || $1 == "" || $2 == "" { invalid = 1; next }
    { print $1 "|" $2 }
    END { exit invalid }
  ' | LC_ALL=C sort
}
exclude_owned_snapshot() {
  awk -F'|' 'FILENAME == ARGV[1] { owned[$1] = 1; next } !owned[$1]' "$1" "$2"
}
source_path_set_matches() {
  local root=$1 expected actual status=0
  expected=$(mktemp) || return 1
  actual=$(mktemp) || { rm -f -- "$expected"; return 1; }
  awk '{print $2}' "$root/source.sha256" | LC_ALL=C sort > "$expected" || status=1
  (cd "$root" && find . -type f ! -path './source.sha256' -print | LC_ALL=C sort) > "$actual" || status=1
  [ "$status" -eq 0 ] && cmp -s "$expected" "$actual" || status=1
  rm -f -- "$expected" "$actual"
  return "$status"
}
write_monitor_reason_to() {
  local root=$1 reason=$2 temporary
  temporary="$root/monitor.reason.tmp"
  [ -d "$root" ] || return 0
  [ -s "$root/monitor.reason" ] && return 0
  if printf '%s\n' "$reason" > "$temporary" && mv -f -- "$temporary" "$root/monitor.reason"; then
    :
  else
    rm -f -- "$temporary"
  fi
}
write_monitor_marker_to() {
  local root=$1 marker=$2 temporary
  temporary="$root/$marker.tmp"
  [ -d "$root" ] || return 0
  if : > "$temporary" && mv -f -- "$temporary" "$root/$marker"; then
    :
  else
    rm -f -- "$temporary"
  fi
}
monitor_reason_value() {
  local reason=""
  if [ -s "$RTMP/monitor.reason" ]; then
    IFS= read -r reason < "$RTMP/monitor.reason" || true
  fi
  printf '%s\n' "$reason"
}
monitor_exit_status() {
  case "$1" in
    noimpact|pressure|iowait) printf '50\n' ;;
    snapshot_failure|unexpected_exit|"") printf '49\n' ;;
    completed) printf '0\n' ;;
    *) printf '49\n' ;;
  esac
}

iowait_next_streak() {
  local current=$1 percent=$2 delta_ready=$3
  if [ "$delta_ready" = true ] &&
     awk -v percent="$percent" -v threshold="$IOWAIT_THRESHOLD_PERCENT" \
       'BEGIN { exit !(percent > threshold) }'; then
    printf '%s\n' "$((current + 1))"
  else
    printf '0\n'
  fi
}

owned_container() {
  [ "$(docker inspect -f '{{index .Config.Labels "goalbuddy.task"}}|{{index .Config.Labels "goalbuddy.run"}}' "$1" 2>/dev/null)" = "$TASK|$RUN_ID" ]
}
owned_image() {
  [ "$(docker inspect -f '{{index .Config.Labels "goalbuddy.task"}}|{{index .Config.Labels "goalbuddy.run"}}' "$1" 2>/dev/null)" = "$TASK|$RUN_ID" ]
}
cleanup() {
  set +e
  [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true
  for container in "$RUNNER" "$FINALIZER" "$PG"; do owned_container "$container" && docker rm -f "$container" >/dev/null 2>&1 || true; done
  owned_image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true
  docker network inspect "$NET" >/dev/null 2>&1 && \
    [ "$(docker network inspect -f '{{index .Labels "goalbuddy.task"}}|{{index .Labels "goalbuddy.run"}}' "$NET")" = "$TASK|$RUN_ID" ] && \
    docker network rm "$NET" >/dev/null 2>&1 || true
  for volume in "$OUTVOL" "$PGVOL"; do
    docker volume inspect "$volume" >/dev/null 2>&1 && \
      [ "$(docker volume inspect -f '{{index .Labels "goalbuddy.task"}}|{{index .Labels "goalbuddy.run"}}' "$volume")" = "$TASK|$RUN_ID" ] && \
      docker volume rm "$volume" >/dev/null 2>&1 || true
  done
  if [ "$initial_ruby_tag" = false ] && [ -n "$ruby_image_id" ]; then
    current=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null || true)
    [ "$current" != "$ruby_image_id" ] || docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1 || true
    if [ "$ruby_image_introduced" = true ] && docker image inspect "$ruby_image_id" >/dev/null 2>&1; then
      docker image rm "$ruby_image_id" >/dev/null 2>&1 || true
    fi
  fi
  rm -f -- "$before_file" "$after_file"
  case "$RTMP" in /tmp/t127-*) rm -rf -- "$RTMP" "$RTMP.tgz";; esac
}
finish() {
  status=$?
  trap - EXIT
  set +e
  if [ ! -s "$TRANSFER" ]; then
    reject=$(mktemp -d)
    printf '%s\n' "$status" > "$reject/remote-status"
    [ ! -s "$RTMP/stdout" ] || cp "$RTMP/stdout" "$reject/stdout"
    [ ! -s "$RTMP/stderr" ] || cp "$RTMP/stderr" "$reject/stderr"
    [ ! -s "$RTMP/pressure.log" ] || cp "$RTMP/pressure.log" "$reject/pressure.log"
    if owned_container "$PG"; then
      docker logs "$PG" > "$reject/postgres.log" 2>&1 || true
    fi
    if [ -s "$RTMP/monitor.reason" ]; then
      cp "$RTMP/monitor.reason" "$reject/monitor-terminal-reason"
    else
      printf 'unavailable\n' > "$reject/monitor-terminal-reason"
    fi
    : > "$reject/monitor-markers"
    for marker in noimpact.breach pressure.breach iowait.breach snapshot-failure.breach; do
      if [ -e "$RTMP/$marker" ]; then
        : > "$reject/$marker"
        printf '%s=present\n' "$marker" >> "$reject/monitor-markers"
      else
        printf '%s=absent\n' "$marker" >> "$reject/monitor-markers"
      fi
    done
    for snapshot_hash in snapshot-baseline.sha256 snapshot-current.sha256; do
      if [ -s "$RTMP/$snapshot_hash" ]; then
        cp "$RTMP/$snapshot_hash" "$reject/$snapshot_hash"
      else
        printf 'unavailable\n' > "$reject/$snapshot_hash"
      fi
    done
    printf '{"initial_ruby_tag_present":%s,"ruby_image_id":"%s","ruby_image_introduced":%s}\n' \
      "$initial_ruby_tag" "$ruby_image_id" "$ruby_image_introduced" > "$reject/lifecycle.json"
    tar -C "$reject" -cf "$TRANSFER" .
    case "$reject" in /tmp/tmp.*) rm -rf -- "$reject";; esac
  fi
  cleanup
  exit "$status"
}
trap finish EXIT
case "$RTMP" in /tmp/t127-*) ;; *) exit 40;; esac
case "$DB" in typed_eav_t123_*) ;; *) exit 41;; esac
[ "$DB" != typed_eav_test ] || exit 42

snapshot() {
  local owned ids
  owned=$(mktemp) || return 1
  ids=$(mktemp) || { rm -f -- "$owned"; return 1; }
  if ! docker ps -aq --no-trunc --filter "label=goalbuddy.task=$TASK" --filter "label=goalbuddy.run=$RUN_ID" |
       LC_ALL=C sort > "$owned"; then
    rm -f -- "$owned" "$ids"
    return 1
  fi
  if ! docker ps -a --no-trunc --format '{{.ID}}|{{.State}}' | stable_snapshot_projection > "$ids"; then
    rm -f -- "$owned" "$ids"
    return 1
  fi
  if ! exclude_owned_snapshot "$owned" "$ids" | LC_ALL=C sort; then
    rm -f -- "$owned" "$ids"
    return 1
  fi
  rm -f -- "$owned" "$ids" || return 1
}

docker image inspect postgres:17 >/dev/null 2>&1 || exit 43
postgres_image_id=$(docker image inspect -f '{{.Id}}' postgres:17)
postgres_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' postgres:17 | awk '/^postgres@sha256:/{print;exit}')
[ -n "$postgres_digest" ] || exit 44
docker_root=$(docker info --format '{{.DockerRootDir}}')
before_file=$(mktemp)
if ! snapshot > "$before_file"; then
  rm -f -- "$before_file"
  exit 46
fi
before_sha=$(sha256sum "$before_file" | awk '{print $1}')
memory_min=0; disk_min=0
for sample in 1 2 3; do
  memory=$(free -b | awk '/^Mem:/{print $7}'); disk=$(df -PB1 "$docker_root" | awk 'END{print $4}')
  [ "$memory" -ge "$MIN_MEMORY" ] && [ "$disk" -ge "$REQUIRED_FREE" ] || exit 45
  [ "$memory_min" -ne 0 ] && [ "$memory_min" -le "$memory" ] || memory_min=$memory
  [ "$disk_min" -ne 0 ] && [ "$disk_min" -le "$disk" ] || disk_min=$disk
  current=$(mktemp); snapshot > "$current"; cmp -s "$before_file" "$current" || exit 46; rm -f "$current"
  [ "$sample" = 3 ] || sleep 5
done
host_cpus=$(nproc); host_memory=$(free -b | awk '/^Mem:/{print $2}')

mkdir "$RTMP"; tar -xzf "$RTMP.tgz" -C "$RTMP"; (cd "$RTMP" && sha256sum -c source.sha256 >/dev/null)
write_snapshot_hash() {
  local kind=$1 value=$2 temporary
  temporary="$RTMP/snapshot-$kind.sha256.tmp"
  if printf '%s\n' "$value" > "$temporary" && mv -f -- "$temporary" "$RTMP/snapshot-$kind.sha256"; then
    :
  else
    rm -f -- "$temporary"
  fi
}
source_path_set_matches "$RTMP" || exit 55
write_snapshot_hash baseline "$before_sha"
source_sha=$(sha256sum "$RTMP/source.sha256" | awk '{print $1}')
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$RTMP/bench/docker/lib/runner_contract.sh"
export GB_TASK=$TASK GB_RUN_ID=$RUN_ID; runner_contract_require_identity

pre_images=$(mktemp); docker image ls -aq --no-trunc | sort -u > "$pre_images"
if docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1; then initial_ruby_tag=true; else docker pull --quiet ruby:3.4.4-bookworm >/dev/null; fi
ruby_image_id=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm)
ruby_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk '/^ruby@sha256:/{print;exit}')
ruby_version=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk -F= '$1=="RUBY_VERSION"{print $2;exit}')
[ "$ruby_version" = 3.4.4 ] && [ -n "$ruby_digest" ] || exit 47
grep -Fxq "$ruby_image_id" "$pre_images" || ruby_image_introduced=true; rm -f "$pre_images"

docker build --pull=false --memory=3g --cpu-shares=128 --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$RTMP" <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
WORKDIR /work
COPY . .
RUN bundle install --jobs=4 --retry=3 && bundle config set --global allow_offline_install true
DOCKERFILE
docker network create --internal --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
docker volume create --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" "$PGVOL" >/dev/null
docker volume create --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" "$OUTVOL" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" --network "$NET" \
  --user postgres \
  --cpus=2 --cpu-shares=192 --memory=8g --memory-swap=8g --blkio-weight=100 --shm-size=1g --pids-limit=512 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m --tmpfs /var/run/postgresql:rw,nosuid,size=16m,mode=1777 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:/var/lib/postgresql/data" postgres:17 >/dev/null
ready=0
for _ in $(seq 1 150); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && { ready=1; break; }; sleep 2; done
[ "$ready" = 1 ] || exit 48
postgres_version=$(docker exec "$PG" psql -U postgres -Atqc 'show server_version')
docker run -d --name "$FINALIZER" --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" --network none \
  --cpus=.1 --memory=128m --memory-swap=128m --pids-limit=32 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=8m \
  --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output" --entrypoint sleep "$IMAGE" infinity >/dev/null
stage() {
  docker exec "$FINALIZER" bash -c 'root=$1;name=$2;value=$3;mkdir -p "/output/$root";tmp="/output/$root/$name.tmp";printf "%s\n" "$value" > "$tmp";mv "$tmp" "/output/$root/$name.json"' _ finalizer "$1" "$2"
}

monitor_loop() {
  local previous_total=0 previous_wait=0 consecutive=0 samples=0 delta_ready=false current current_sha
  local user nice system idle wait irq softirq steal total pct memory disk load
  while :; do
    if ! read -r _ user nice system idle wait irq softirq steal _ < /proc/stat; then
      write_monitor_reason_to "$RTMP" unexpected_exit
      return 1
    fi
    total=$((user+nice+system+idle+wait+irq+softirq+steal))
    pct=0
    if [ "$previous_total" -gt 0 ] && [ "$total" -gt "$previous_total" ]; then
      if ! pct=$(awk -v dw="$((wait-previous_wait))" -v dt="$((total-previous_total))" 'BEGIN{printf "%.3f",100*dw/dt}'); then
        write_monitor_reason_to "$RTMP" unexpected_exit
        return 1
      fi
      delta_ready=true
    fi
    previous_total=$total; previous_wait=$wait; samples=$((samples+1))
    if ! memory=$(free -b | awk '/^Mem:/{print $7}') ||
       ! disk=$(df -PB1 "$docker_root" | awk 'END{print $4}') ||
       ! load=$(awk '{print $1}' /proc/loadavg) ||
       ! printf '%s|%s|%s|%s|%s\n' "$(date -u +%FT%TZ)" "$memory" "$disk" "$load" "$pct" >> "$RTMP/pressure.log"; then
      write_monitor_reason_to "$RTMP" unexpected_exit
      return 1
    fi
    if ! current=$(mktemp) || ! snapshot > "$current"; then
      rm -f -- "${current:-}"
      write_monitor_marker_to "$RTMP" snapshot-failure.breach
      write_monitor_reason_to "$RTMP" snapshot_failure
      return 1
    fi
    if ! current_sha=$(sha256sum "$current" | awk '{print $1}'); then
      rm -f -- "$current"
      write_monitor_marker_to "$RTMP" snapshot-failure.breach
      write_monitor_reason_to "$RTMP" snapshot_failure
      return 1
    fi
    write_snapshot_hash current "$current_sha"
    if ! cmp -s "$before_file" "$current"; then
      rm -f "$current"
      write_monitor_marker_to "$RTMP" noimpact.breach
      write_monitor_reason_to "$RTMP" noimpact
      return 0
    fi
    rm -f "$current"
    if [ "$memory" -lt "$MIN_MEMORY" ] || [ "$disk" -lt $((20*1024*1024*1024+EXPORT_BYTES)) ]; then
      write_monitor_marker_to "$RTMP" pressure.breach
      write_monitor_reason_to "$RTMP" pressure
      return 0
    fi
    consecutive=$(iowait_next_streak "$consecutive" "$pct" "$delta_ready")
    if [ "$consecutive" -ge "$IOWAIT_CONSECUTIVE_LIMIT" ]; then
      write_monitor_marker_to "$RTMP" iowait.breach
      write_monitor_reason_to "$RTMP" iowait
      return 0
    fi
    if [ "$delta_ready" = true ] && [ "$samples" -ge 2 ] && [ ! -e "$RTMP/monitor.ready" ]; then
      write_monitor_marker_to "$RTMP" monitor.ready
    fi
    sleep "$IOWAIT_SAMPLE_SECONDS"
  done
}
monitor() {
  local monitor_status
  set +e
  monitor_loop
  monitor_status=$?
  if [ ! -s "$RTMP/monitor.reason" ]; then
    write_monitor_reason_to "$RTMP" unexpected_exit
  fi
  docker stop -t 20 "$RUNNER" >/dev/null 2>&1 || true
  return "$monitor_status"
}
monitor & monitor_pid=$!
for _ in $(seq 1 30); do
  [ -e "$RTMP/monitor.ready" ] && break
  if ! kill -0 "$monitor_pid" 2>/dev/null; then
    exit "$(monitor_exit_status "$(monitor_reason_value)")"
  fi
  sleep 1
done
if [ ! -e "$RTMP/monitor.ready" ] || [ -e "$RTMP/pressure.breach" ] || [ -e "$RTMP/iowait.breach" ] ||
   [ -e "$RTMP/noimpact.breach" ] || [ -e "$RTMP/snapshot-failure.breach" ]; then
  exit "$(monitor_exit_status "$(monitor_reason_value)")"
fi
docker exec "$PG" createdb -U postgres "$DB"
[ "$(docker exec "$PG" psql -U postgres -d "$DB" -Atqc 'select current_database()')" = "$DB" ] || exit 56

stage 01_PREFLIGHT '{"state":"PREFLIGHT"}'
set +e
docker run --name "$RUNNER" --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" --network "$NET" \
  --cpus=1 --cpu-shares=128 --memory=3g --memory-swap=3g --blkio-weight=100 --pids-limit=256 --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /work/spec/dummy/tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /work/spec/dummy/log:rw,noexec,nosuid,size=64m --cap-drop=ALL --security-opt=no-new-privileges \
  -e PGHOST="$PG" -e PGUSER=postgres -e PGDATABASE="$DB" -e DATABASE_URL="postgresql://postgres@$PG:5432/$DB" \
  -e SECRET_KEY_BASE=fixed-t127-representative-secret -e RAILS_ENV=test -e TYPED_EAV_REPRESENTATIVE_OK=1 \
  -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=60s "$WORK_DEADLINE" bash -lc '
    source bench/docker/lib/runner_contract.sh
    export GB_TASK=T127 GB_RUN_ID='"$RUN_ID"'
    runner_contract_require_identity
    runner_contract_probe_writable /output /tmp /work/spec/dummy/tmp /work/spec/dummy/log
    runner_contract_probe_secret
    bundle check
    test "$PGDATABASE" != typed_eav_test
    bundle exec ruby -r ./spec/dummy/config/environment -e '\''
      connection = ActiveRecord::Base.connection
      abort "database mismatch" unless connection.select_value("select current_database()") == ENV.fetch("PGDATABASE")
      ActiveRecord::MigrationContext.new([File.expand_path("db/migrate")]).migrate
      ActiveRecord::MigrationContext.new([File.expand_path("spec/dummy/db/migrate")]).migrate
      expected = %w[projects typed_eav_fields typed_eav_values]
      actual = expected.select { |table| connection.select_value("select to_regclass(#{connection.quote(table)})") }
      abort "required tables missing" unless actual == expected
    '\''
    bundle exec ruby bench/storage_tournament_benchmark.rb --mode representative --output /output/result.json
  ' > "$RTMP/stdout" 2> "$RTMP/stderr"
runner_status=$?
set -e

stage 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
owned_container "$RUNNER" && [ "$(docker inspect -f '{{.State.Running}}' "$RUNNER")" = true ] && docker stop -t 20 "$RUNNER" >/dev/null || true
stage 03_RUNNER_STOPPED "{\"state\":\"RUNNER_STOPPED\",\"runner_status\":$runner_status}"
docker exec "$PG" psql -U postgres -d postgres -Atqc "select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB'" >/dev/null
remaining=$(docker exec "$PG" psql -U postgres -d postgres -Atqc "select count(*) from pg_stat_activity where datname='$DB'")
[ "$remaining" = 0 ] || exit 51
stage 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
monitor_lived=false
if kill -0 "$monitor_pid" 2>/dev/null; then monitor_lived=true; kill "$monitor_pid"; wait "$monitor_pid" 2>/dev/null || true; fi
monitor_pid=""
[ "$monitor_lived" = true ] && [ ! -e "$RTMP/pressure.breach" ] && [ ! -e "$RTMP/iowait.breach" ] && \
  [ ! -e "$RTMP/noimpact.breach" ] || runner_status=52
after_file=$(mktemp); snapshot > "$after_file"; after_sha=$(sha256sum "$after_file" | awk '{print $1}')
invariant=false; cmp -s "$before_file" "$after_file" && invariant=true
stage 05_AFTER_INVARIANT "{\"state\":\"AFTER_INVARIANT\",\"passed\":$invariant}"
[ -s "$RTMP/pressure.log" ] || exit 53
pressure_samples=$(wc -l < "$RTMP/pressure.log" | tr -d ' '); pressure_sha=$(sha256sum "$RTMP/pressure.log" | awk '{print $1}')
for file in stdout stderr pressure.log source.sha256; do docker cp "$RTMP/$file" "$FINALIZER:/output/$file"; done
python3 - <<PY > "$RTMP/remote-evidence.json"
import json
json.dump({
 "runner_status":$runner_status,"database":"$DB","postgresql":"$postgres_version","ruby":"$ruby_version",
 "source_manifest_sha256":"$source_sha","postgres_image_id":"$postgres_image_id","postgres_digest":"$postgres_digest",
 "ruby_image_id":"$ruby_image_id","ruby_digest":"$ruby_digest","ruby_image_introduced":json.loads("$ruby_image_introduced"),
 "initial_ruby_tag_present":json.loads("$initial_ruby_tag"),"admission":{"samples":3,"memory_available_bytes":$memory_min,
 "docker_free_bytes":$disk_min,"required_docker_free_bytes":$REQUIRED_FREE,"smoke_projected_peak_bytes":$SMOKE_PEAK,
 "projected_export_bytes":$EXPORT_BYTES},
 "resource_limits":{"host_capacity":{"cpus":$host_cpus,"memory_bytes":$host_memory},"headroom":{"cpus":$host_cpus,"memory_bytes":$memory_min},
 "postgres":{"cpus":2,"memory_bytes":8589934592},"runner":{"cpus":1,"memory_bytes":3221225472},
 "work_deadline_seconds":$WORK_DEADLINE,"total_deadline_seconds":$TOTAL_DEADLINE},
 "telemetry":{"samples":$pressure_samples,"sha256":"$pressure_sha","monitor_lived":json.loads("$monitor_lived"),
 "pressure_breaches":$(test -e "$RTMP/pressure.breach" && echo 1 || echo 0),"iowait_breaches":$(test -e "$RTMP/iowait.breach" && echo 1 || echo 0)},
 "invariant":{"passed":json.loads("$invariant"),"before_sha256":"$before_sha","after_sha256":"$after_sha"}
},open("$RTMP/remote-evidence.json","w"),sort_keys=True)
PY
docker cp "$RTMP/remote-evidence.json" "$FINALIZER:/output/remote-evidence.json"
payload_sha=$(docker exec "$FINALIZER" bash -c 'find /output -type f ! -path "*/06_SEALED.json" -print0|sort -z|xargs -0 sha256sum' | sha256sum | awk '{print $1}')
stage 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$payload_sha\"}"
docker run --rm --label goalbuddy.task=$TASK --label "goalbuddy.run=$RUN_ID" --network none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - . > "$TRANSFER"
[ -s "$TRANSFER" ] || exit 54
if [ "$runner_status" -ne 0 ]; then
  exit "$runner_status"
fi
[ "$invariant" = true ] || exit 50
exit 0
REMOTE
  remote_status=$?
  set -e

  envelope_root="$retained_root/$run_id-envelope"
  reject_run() {
    local reason=$1 status=${2:-$remote_status} retained=${3:-}
    write_rejected_envelope "$project_ruby" "$envelope_root" "$run_id" "$status" "$retained" "$reason" \
      >/dev/null 2>&1 || true
    die "$reason; retained=${retained:-none} envelope=$envelope_root/rejected.json"
  }
  scp -q -o BatchMode=yes "$REMOTE_HOST:$transfer" "$local_tmp/result.tar" || reject_run "result transfer failed" "$remote_status"
  retention=$(runner_contract_retain_transfer "$local_tmp/result.tar" "$retained_root" "$run_id") || reject_run "retention failed" "$remote_status"
  retained_path=${retention%%|*}; retained_sha=${retention##*|}
  extract_root="$local_tmp/extracted"; mkdir "$extract_root"; tar -xf "$retained_path" -C "$extract_root" || \
    reject_run "retained transfer extraction failed" "$remote_status" "$retained_path"
  if ! ssh -o BatchMode=yes "$REMOTE_HOST" \
    "test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T127 --filter label=goalbuddy.run='$run_id')\" && \
test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T127 --filter label=goalbuddy.run='$run_id')\" && \
test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T127 --filter label=goalbuddy.run='$run_id')\" && \
test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T127 --filter label=goalbuddy.run='$run_id')\" && \
test -z \"\$(docker ps -aq --filter name='^/$run_id-postgres$')\" && test -z \"\$(docker ps -aq --filter name='^/$run_id-runner$')\" && \
test -z \"\$(docker ps -aq --filter name='^/$run_id-finalizer$')\" && ! docker network inspect '$run_id-net' >/dev/null 2>&1 && \
! docker volume inspect '$run_id-pg' >/dev/null 2>&1 && ! docker volume inspect '$run_id-out' >/dev/null 2>&1 && \
! docker image inspect '$run_id:runner' >/dev/null 2>&1 && test ! -e '$remote_tmp' && test ! -e '$remote_tmp.tgz'"; then
    reject_run "remote exact cleanup audit failed" "$remote_status" "$retained_path"
  fi

  if [[ -s $extract_root/lifecycle.json ]]; then
    "$project_ruby" -rjson -ropen3 -e '
path,remote=ARGV; data=JSON.parse(File.read(path)); image=data.fetch("ruby_image_id")
unless image.empty?
  tag, = Open3.capture3("ssh","-o","BatchMode=yes",remote,"docker image inspect -f {{.Id}} ruby:3.4.4-bookworm 2>/dev/null")
  present = system("ssh","-o","BatchMode=yes",remote,"docker image inspect #{image} >/dev/null 2>&1")
  ok = data.fetch("initial_ruby_tag_present") ? tag.strip == image : tag.strip.empty? && (!data.fetch("ruby_image_introduced") || !present)
  raise "Ruby base-image lifecycle mismatch" unless ok
end
' "$extract_root/lifecycle.json" "$REMOTE_HOST" || reject_run "early base-image lifecycle audit failed" "$remote_status" "$retained_path"
  fi

  if [[ -s $extract_root/remote-evidence.json ]]; then
    classification=$("$project_ruby" -rjson -e '
data=JSON.parse(File.read(ARGV.fetch(0)))
puts [data.fetch("runner_status"), data.dig("telemetry","iowait_breaches"),
      data.dig("telemetry","pressure_breaches"), data.dig("telemetry","monitor_lived")].join("|")
' "$extract_root/remote-evidence.json") || reject_run "remote evidence classification failed" "$remote_status" "$retained_path"
    IFS='|' read -r classified_status classified_iowait classified_pressure classified_monitor_lived <<< "$classification"
    if [[ $classified_status -ne 0 ]]; then
      rejection_reason=$(classified_rejection_reason "$classified_status" "$classified_iowait" \
        "$classified_pressure" "$classified_monitor_lived")
      reject_run "$rejection_reason" "$classified_status" "$retained_path"
    fi
  fi

  if [[ ! -s $extract_root/result.json || ! -s $extract_root/remote-evidence.json ]]; then
    reject_run "measurement or remote evidence missing" "$remote_status" "$retained_path"
  fi

  "$project_ruby" -rjson -ropen3 -e '
evidence, remote = ARGV
data = JSON.parse(File.read(evidence))
initial = data.fetch("initial_ruby_tag_present")
introduced = data.fetch("ruby_image_introduced")
image_id = data.fetch("ruby_image_id")
postgres_id = data.fetch("postgres_image_id")
tag_output, = Open3.capture3("ssh", "-o", "BatchMode=yes", remote, "docker image inspect -f {{.Id}} ruby:3.4.4-bookworm 2>/dev/null")
tag_id = tag_output.strip
id_present = system("ssh", "-o", "BatchMode=yes", remote, "docker image inspect #{image_id} >/dev/null 2>&1")
postgres_output, = Open3.capture3("ssh", "-o", "BatchMode=yes", remote, "docker image inspect -f {{.Id}} postgres:17 2>/dev/null")
postgres_now = postgres_output.strip
raise "Ruby base-image lifecycle mismatch" unless initial ? (tag_id == image_id && id_present) : (tag_id.empty? && (!introduced || !id_present))
raise "PostgreSQL base image changed" unless postgres_now == postgres_id
' "$extract_root/remote-evidence.json" "$REMOTE_HOST" || reject_run "base-image lifecycle audit failed" "$remote_status" "$retained_path"

  candidate="$local_tmp/candidate.json"
  "$project_ruby" -rjson -rdigest -e '
raw, evidence_path, transfer, output = ARGV
artifact = JSON.parse(File.read(raw), max_nesting: false)
evidence = JSON.parse(File.read(evidence_path))
transfer_sha = Digest::SHA256.file(transfer).hexdigest
measurement_sha = Digest::SHA256.file(raw).hexdigest
invariant = evidence.fetch("invariant")
artifact["accepted"] = true
artifact["environment"] = {
  "mode"=>"representative","database"=>evidence.fetch("database"),"postgresql"=>evidence.fetch("postgresql"),"ruby"=>evidence.fetch("ruby"),
  "artifact_sha256"=>measurement_sha,
  "admission"=>evidence.fetch("admission").merge("status"=>"passed","existing_container_invariant"=>invariant),
  "resource_limits"=>evidence.fetch("resource_limits"),
  "telemetry"=>{"explain_analyze_buffers_wal_settings"=>true,"samples"=>evidence.dig("telemetry","samples"),
    "pressure_breaches"=>evidence.dig("telemetry","pressure_breaches"),"iowait_breaches"=>evidence.dig("telemetry","iowait_breaches"),
    "live_through_finish"=>evidence.dig("telemetry","monitor_lived"),"monitor_started_before_work"=>true,"monitor_stopped_after_finish"=>true,
    "pressure_monitor"=>{"status"=>"stopped","monitor_pass"=>evidence.dig("telemetry","monitor_lived"),
      "samples"=>evidence.dig("telemetry","samples"),"sha256"=>evidence.dig("telemetry","sha256")}},
  "no_impact"=>{"existing_container_invariant"=>invariant,"media_stack_untouched"=>invariant.fetch("passed"),"passed"=>invariant.fetch("passed")},
  "export"=>{"before_cleanup"=>true,"bytes"=>File.size(transfer),"sha256"=>transfer_sha,"verified"=>true}
}
artifact["cleanup"] = {"exact"=>true,"export_before_cleanup"=>true,"owned_resources_zero"=>true,
  "post_cleanup_verified"=>true,"remaining_task_relations"=>artifact.dig("cleanup","remaining_task_relations") || []}
File.write(output, JSON.pretty_generate(artifact, max_nesting: false)+"\n")
' "$extract_root/result.json" "$extract_root/remote-evidence.json" "$retained_path" "$candidate" || \
    reject_run "candidate construction failed" "$remote_status" "$retained_path"
  candidate_sha=$(shasum -a 256 "$candidate" | awk '{print $1}')
  canonical="$ROOT/bench/results/phase-10-storage-tournament-representative.json"
  if [[ $remote_status -eq 0 ]] && "$project_ruby" "$ROOT/bench/validate_storage_tournament_artifact.rb" \
       --expected-sha "$candidate_sha" "$candidate"; then
    "$project_ruby" -I"$ROOT/bench/docker/lib" -rartifact_envelope -rjson -e '
root,path,run=ARGV; payload=JSON.parse(File.read(path),max_nesting:false)
env=TypedEAVBenchmark::ArtifactEnvelope.build(status:"accepted",task:"T127",run_id:run,payload:payload)
TypedEAVBenchmark::ArtifactEnvelope.write!(root:root,envelope:env)
' "$envelope_root" "$candidate" "$run_id"
    runner_contract_atomic_stage "$envelope_root" 07_AUDITED \
      '{"state":"AUDITED","accepted":true,"cleanup":true,"export_before_cleanup":true}'
    mkdir -p "$(dirname "$canonical")"; cp "$candidate" "$canonical"
    printf 'T127 representative artifact: %s retained=%s sha256=%s\n' "$canonical" "$retained_path" "$candidate_sha"
  else
    reject_run "representative validation rejected" "$remote_status" "$retained_path"
  fi
}

mode=${1:-}
case "$mode" in
  --self-test)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    self_test
    ;;
  --representative)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    representative
    ;;
  *)
    usage
    exit 2
    ;;
esac
