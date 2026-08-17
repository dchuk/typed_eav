#!/usr/bin/env bash
set -euo pipefail

# T091 representative runner. T086 owns the cancellation drill; this runner
# performs no live drill and records a rejected envelope on any gate failure.
ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t091-$(date -u +%Y%m%dt%H%M%sz)-$$"
NET="$RUN_ID-net"; PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"
EXPORTER="$RUN_ID-exporter"; IMAGE="$RUN_ID:runner"; PGVOL="$RUN_ID-pg"; OUTVOL="$RUN_ID-out"
RTMP="/tmp/$RUN_ID"; OUT="$ROOT/bench/results/phase-6-bulk-write-representative.json"; DB="typed_eav_t091_${RUN_ID//[^a-zA-Z0-9]/_}"
ADMISSION_ONLY="${T091_ADMISSION_ONLY:-0}"
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$ROOT/bench/docker/lib/runner_contract.sh"
runner_contract_forbid_unsafe_words "$ROOT/bench/docker/bulk-write/run_remote.sh"
PROJECT_RUBY=$(runner_contract_resolve_project_ruby)
[ "$($PROJECT_RUBY -e 'print RUBY_VERSION')" = 3.4.4 ]
RETAINED_ROOT="${TMPDIR:-/tmp}/typed-eav-t091-retained"
LTMP=$(mktemp -d "${TMPDIR:-/tmp}/typed-eav-t091.XXXXXX")
trap 'rm -rf -- "$LTMP"; ssh -o BatchMode=yes "$REMOTE" "rm -rf -- $RTMP $RTMP.tgz" >/dev/null 2>&1 || true' EXIT

die() { echo "T091: $*" >&2; exit 1; }
[ -z "$(git -C "$ROOT" status --short)" ] || die "dirty source tree"
mkdir -p "$LTMP/src"
git -C "$ROOT" archive HEAD | tar -x -C "$LTMP/src"
git -C "$ROOT" rev-parse HEAD > "$LTMP/src/source.commit"
(cd "$LTMP/src" && find . -type f ! -name source.sha256 -print0 | sort -z | xargs -0 shasum -a 256) > "$LTMP/src/source.sha256"
COPYFILE_DISABLE=1 tar -C "$LTMP/src" -czf "$LTMP/src.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$RTMP' && test ! -e '$RTMP.tgz'"
scp -q -o BatchMode=yes "$LTMP/src.tgz" "$REMOTE:$RTMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' PG='$PG' RUNNER='$RUNNER' EXPORTER='$EXPORTER' IMAGE='$IMAGE' PGVOL='$PGVOL' OUTVOL='$OUTVOL' RTMP='$RTMP' DB='$DB' ADMISSION_ONLY='$ADMISSION_ONLY' bash -s" <<'REMOTE'
set -u
cd /tmp
mkdir -p "$RTMP"
tar -xzf "$RTMP.tgz" -C "$RTMP"
cd "$RTMP"
if ! sha256sum -c source.sha256 >/dev/null 2>&1; then
  gate_status=40
fi
# shellcheck source=bench/docker/lib/runner_contract.sh
source bench/docker/lib/runner_contract.sh
export GB_TASK=T091 GB_RUN_ID="$RUN_ID"
: "${gate_status:=0}"
runner_contract_require_identity || gate_status=41

snapshot() { runner_contract_snapshot; }
snapshot_hash() { snapshot | sha256sum | awk '{print $1}'; }
before=$(mktemp); snapshot > "$before"; before_hash=$(sha256sum "$before" | awk '{print $1}')
run_started=$(date +%s); runner_status=90
stage=preflight; failure_status=none
initial_tag=false; tag_introduced=false; image_id_introduced=false; base_id_preexisting=false; base_id=""; base_digest=""; base_version=""
postgres_image_id=""; postgres_repo_digest=""; postgres_server_version=""
mkdir -p "$RTMP/export"
monitor_pid=""; monitor_status="not_started"; monitor_pass=false; breach_reason=""
cleanup() {
  set +e
  if [ -n "$monitor_pid" ]; then kill "$monitor_pid" >/dev/null 2>&1 || true; wait "$monitor_pid" 2>/dev/null || true; fi
  runner_contract_owned container "$RUNNER" && docker rm -f "$RUNNER" >/dev/null
  runner_contract_owned container "$EXPORTER" && docker rm -f "$EXPORTER" >/dev/null
  runner_contract_owned container "$PG" && docker rm -f "$PG" >/dev/null
  runner_contract_owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null
  runner_contract_owned network "$NET" && docker network rm "$NET" >/dev/null
  runner_contract_owned volume "$PGVOL" && docker volume rm "$PGVOL" >/dev/null
  runner_contract_owned volume "$OUTVOL" && docker volume rm "$OUTVOL" >/dev/null
  if [ "$tag_introduced" = true ] && [ "$initial_tag" = false ]; then docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1 || true; fi
  if [ "$image_id_introduced" = true ] && [ "$base_id_preexisting" = false ] && [ -n "$base_id" ]; then docker image rm "$base_id" >/dev/null 2>&1 || true; fi
}
cleanup_exit() { cleanup; }
trap cleanup_exit EXIT

docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
for sample in 1 2 3; do
  available=$(free -b 2>/dev/null | awk '/^Mem:/{print $7}')
  docker_free=$(df -Pk "$docker_root" 2>/dev/null | tail -1 | awk '{print $4*1024}')
  if ! awk -v m="$available" -v d="$docker_free" 'BEGIN { exit !(m >= 12884901888 && d >= 21474836480) }'; then gate_status=42; fi
  sample_hash=$(snapshot_hash); printf '%s|%s|%s|%s\n' "$sample" "$available" "$docker_free" "$sample_hash" >> "$RTMP/preflight.log"
  [ "$sample_hash" = "$before_hash" ] || gate_status=43
  [ "$sample" = 3 ] || sleep 5
done

docker image inspect postgres:17 >/dev/null 2>&1 || gate_status=44
postgres_image_id=$(docker image inspect -f '{{.Id}}' postgres:17 2>/dev/null || true)
postgres_repo_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' postgres:17 2>/dev/null | awk '/^postgres@sha256:/{print;exit}')
[ -n "$postgres_image_id" ] && [ -n "$postgres_repo_digest" ] || gate_status=44
if [ "$ADMISSION_ONLY" != 1 ]; then
  pre_image_ids=$(mktemp); docker image ls -aq --no-trunc | sort -u > "$pre_image_ids"
  if [ "$gate_status" = 0 ] && docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1; then initial_tag=true; fi
  if [ "$gate_status" = 0 ] && [ "$initial_tag" = false ]; then docker pull --quiet ruby:3.4.4-bookworm >/dev/null 2>&1 || gate_status=45; tag_introduced=true; fi
  base_id=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null || true)
  grep -Fxq "$base_id" "$pre_image_ids" || image_id_introduced=true
  grep -Fxq "$base_id" "$pre_image_ids" && base_id_preexisting=true
  rm -f "$pre_image_ids"
  base_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' ruby:3.4.4-bookworm 2>/dev/null | awk '/^ruby@sha256:/{print;exit}')
  base_version=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ruby:3.4.4-bookworm 2>/dev/null | awk -F= '$1=="RUBY_VERSION"{print $2;exit}')
  [ "$base_version" = 3.4.4 ] && [ -n "$base_digest" ] || gate_status=46
fi

pg_target=$(runner_contract_pg_target 17 2>/dev/null) || gate_status=47
if [ "$gate_status" = 0 ]; then
  docker network create --internal --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$NET" >/dev/null || gate_status=46
  docker volume create --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$PGVOL" >/dev/null || gate_status=47
  docker volume create --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$OUTVOL" >/dev/null || gate_status=48
fi

if [ "$gate_status" = 0 ]; then
  stage=postgres_start
  docker run -d --name "$PG" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=192 --blkio-weight=100 --memory=8g --memory-swap=8g --pids-limit=512 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m --tmpfs /var/run/postgresql:rw,noexec,nosuid,size=16m -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:$pg_target" postgres:17 >/dev/null || gate_status=48
  ready=false
  for _ in $(seq 1 150); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && ready=true && break; sleep 2; done
  [ "$ready" = true ] || gate_status=49
  postgres_server_version=$(docker exec "$PG" psql -U postgres -Atqc 'SHOW server_version' 2>/dev/null || true)
  [ -n "$postgres_server_version" ] || gate_status=49
  docker exec "$PG" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB\"" >/dev/null || gate_status=49
  [ "$(docker exec "$PG" psql -U postgres -Atqc "SELECT current_database()" "$DB" 2>/dev/null || true)" = "$DB" ] || gate_status=49
fi
mkdir -p "$RTMP/export"
docker inspect "$PG" > "$RTMP/export/postgres.inspect.json" 2>/dev/null || :
docker ps -a --filter "name=^/${PG}$" > "$RTMP/export/postgres.status.txt" 2>/dev/null || :
docker logs "$PG" > "$RTMP/export/postgres.stdout" 2> "$RTMP/export/postgres.stderr" || :
[ -s "$RTMP/export/postgres.inspect.json" ] || printf '{}\n' > "$RTMP/export/postgres.inspect.json"
[ -s "$RTMP/export/postgres.status.txt" ] || printf 'unavailable\n' > "$RTMP/export/postgres.status.txt"
[ -s "$RTMP/export/postgres.stdout" ] || : > "$RTMP/export/postgres.stdout"
[ -s "$RTMP/export/postgres.stderr" ] || : > "$RTMP/export/postgres.stderr"
if [ "$ADMISSION_ONLY" = 1 ]; then
  stage=admission_only
  failure_status=admission_only
  runner_status=90
fi
if [ "$gate_status" = 0 ] && [ "$ADMISSION_ONLY" != 1 ]; then
  stage=build
  docker build --pull=false --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" -t "$IMAGE" -f - "$RTMP" <<'DOCKERFILE' || gate_status=50
FROM ruby:3.4.4-bookworm
WORKDIR /work
COPY . .
RUN bundle install --jobs=4 --retry=3
DOCKERFILE
fi

if [ "$gate_status" = 0 ] && [ "$ADMISSION_ONLY" != 1 ]; then
  stage=runner
  : > "$RTMP/pressure.log"
  rm -f "$RTMP/monitor.ready" "$RTMP/monitor.stop" "$RTMP/pressure.breach"
  monitor_status="running"
  (
    monitor_exit() {
      if [ ! -e "$RTMP/monitor.stop" ] && [ ! -e "$RTMP/pressure.breach" ]; then
        printf '%s\n' monitor_died > "$RTMP/monitor.breach.tmp"
        mv -f "$RTMP/monitor.breach.tmp" "$RTMP/pressure.breach"
        runner_contract_owned container "$RUNNER" && docker stop -t 20 "$RUNNER" >/dev/null 2>&1 || true
      fi
    }
    trap monitor_exit EXIT
    previous_total=0; previous_iowait=0; consecutive_high=0
    while [ ! -e "$RTMP/monitor.stop" ]; do
      docker_free=$(df -Pk "$docker_root" 2>/dev/null | tail -1 | awk '{print $4*1024}')
      available=$(free -b 2>/dev/null | awk '/^Mem:/{print $7}')
      load1=$(awk '{print $1}' /proc/loadavg)
      total=$(awk '/^cpu /{sum=0;for(i=2;i<=NF;i++)sum+=$i;print sum}' /proc/stat)
      iowait=$(awk '/^cpu /{print $6}' /proc/stat)
      iowait_pct=0
      if [ "$previous_total" -gt 0 ] && [ "$total" -gt "$previous_total" ]; then
        iowait_pct=$(awk -v d="$((iowait - previous_iowait))" -v t="$((total - previous_total))" 'BEGIN{printf "%.2f",100*d/t}')
      fi
      count=$(docker ps -q | wc -l | tr -d ' ')
      stats_hash=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null | sha256sum | awk '{print $1}')
      printf '%s|%s|%s|%s|%s|%s|%s\n' "$(date -u +%FT%TZ)" "$available" "$docker_free" "$load1" "$iowait_pct" "$count" "$stats_hash" >> "$RTMP/pressure.log"
      if awk -v m="$available" -v d="$docker_free" 'BEGIN { exit !(m < 12884901888 || d < 21474836480) }'; then
        breach_reason="headroom_floor"; printf '%s\n' "$breach_reason" > "$RTMP/pressure.breach.tmp"; mv -f "$RTMP/pressure.breach.tmp" "$RTMP/pressure.breach"
        runner_contract_owned container "$RUNNER" && docker stop -t 20 "$RUNNER" >/dev/null 2>&1 || true
        break
      fi
      if awk -v w="$iowait_pct" 'BEGIN { exit !(w > 50) }'; then consecutive_high=$((consecutive_high+1)); else consecutive_high=0; fi
      if [ "$consecutive_high" -ge 2 ]; then
        breach_reason="iowait_over_50_percent"; printf '%s\n' "$breach_reason" > "$RTMP/pressure.breach.tmp"; mv -f "$RTMP/pressure.breach.tmp" "$RTMP/pressure.breach"
        runner_contract_owned container "$RUNNER" && docker stop -t 20 "$RUNNER" >/dev/null 2>&1 || true
        break
      fi
      previous_total=$total; previous_iowait=$iowait
      if [ ! -e "$RTMP/monitor.ready" ]; then printf '%s\n' ready > "$RTMP/monitor.ready.tmp"; mv -f "$RTMP/monitor.ready.tmp" "$RTMP/monitor.ready"; fi
      sleep 15
    done
  ) & monitor_pid=$!
  ready=false
  for _ in $(seq 1 30); do
    [ -e "$RTMP/pressure.breach" ] && break
    if [ -e "$RTMP/monitor.ready" ] && kill -0 "$monitor_pid" 2>/dev/null; then ready=true; break; fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    gate_status=51
  fi
fi
if [ "$gate_status" = 0 ] && [ "$ADMISSION_ONLY" != 1 ]; then
  set +e
  docker run --name "$RUNNER" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network "$NET" --cpus=1.5 --cpu-shares=128 --blkio-weight=100 --memory=3g --memory-swap=3g --pids-limit=256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /work/spec/dummy/tmp:rw,noexec,nosuid,size=32m --tmpfs /work/spec/dummy/log:rw,noexec,nosuid,size=32m --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e DATABASE_URL="postgresql://postgres@$PG/$DB" -e SECRET_KEY_BASE=t091-secret -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=120s 5400s bash -lc 'bundle exec ruby bench/bulk_write_benchmark.rb --tier representative --output /output/result.json && bundle exec ruby bench/validate_bulk_write_artifact.rb /output/result.json' > "$RTMP/stdout" 2> "$RTMP/stderr"
  runner_status=$?; set -u
  : > "$RTMP/monitor.stop"
  wait "$monitor_pid"; monitor_wait=$?; monitor_pid=""
  if [ "$monitor_wait" = 0 ] && [ ! -e "$RTMP/pressure.breach" ]; then monitor_status="stopped"; else monitor_status="failed"; fi
fi

# Export every available result/diagnostic before deleting any owned volume.
set +e
export_status=92
if runner_contract_owned image "$IMAGE" && runner_contract_owned volume "$OUTVOL"; then
  docker run --name "$EXPORTER" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - . > "$RTMP/export/output.tar"
  export_status=$?
fi
set -u
if [ "$gate_status" != 0 ] && [ "$failure_status" = none ]; then failure_status="gate_$gate_status"; fi
printf '%s\n' "$stage" > "$RTMP/export/stage"
printf '%s\n' "$failure_status" > "$RTMP/export/failure_status"
cp "$RTMP/source.sha256" "$RTMP/export/source.sha256"
cp "$RTMP/source.commit" "$RTMP/export/source.commit" 2>/dev/null || :
cp "$RTMP/stdout" "$RTMP/export/stdout" 2>/dev/null || : > "$RTMP/export/stdout"; cp "$RTMP/stderr" "$RTMP/export/stderr" 2>/dev/null || : > "$RTMP/export/stderr"
cp "$RTMP/pressure.log" "$RTMP/export/pressure.log" 2>/dev/null || : > "$RTMP/export/pressure.log"
[ -e "$RTMP/pressure.log" ] || : > "$RTMP/pressure.log"
cp "$RTMP/pressure.breach" "$RTMP/export/pressure.breach" 2>/dev/null || : > "$RTMP/export/pressure.breach"
[ -e "$RTMP/pressure.breach" ] || : > "$RTMP/pressure.breach"
printf '%s\n' "$runner_status" > "$RTMP/export/runner_status"
cleanup
sleep 2
after=$(mktemp); snapshot > "$after"; after_hash=$(sha256sum "$after" | awk '{print $1}')
zero_labels=true
[ -z "$(docker ps -aq --filter label=goalbuddy.task=T091 --filter label=goalbuddy.run="$RUN_ID")" ] || zero_labels=false
[ -z "$(docker network ls -q --filter label=goalbuddy.task=T091 --filter label=goalbuddy.run="$RUN_ID")" ] || zero_labels=false
[ -z "$(docker volume ls -q --filter label=goalbuddy.task=T091 --filter label=goalbuddy.run="$RUN_ID")" ] || zero_labels=false
[ -z "$(docker image ls -q --filter label=goalbuddy.task=T091 --filter label=goalbuddy.run="$RUN_ID")" ] || zero_labels=false
zero_names=true
for exact_name in "$RUNNER" "$EXPORTER" "$PG"; do
  [ -z "$(docker ps -aq --filter "name=^/${exact_name}$")" ] || zero_names=false
done
base_restored=false
tag_maps_to_base=false
tag_present=false
docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1 && tag_present=true
[ "$tag_present" = true ] && [ "$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null || true)" = "$base_id" ] && tag_maps_to_base=true
if [ "$initial_tag" = true ]; then
  [ "$tag_maps_to_base" = true ] && [ "$base_id_preexisting" = true ] && base_restored=true
elif [ "$base_id_preexisting" = true ]; then
  [ "$tag_present" = false ] && docker image inspect "$base_id" >/dev/null 2>&1 && base_restored=true
else
  [ "$tag_present" = false ] && ! docker image inspect "$base_id" >/dev/null 2>&1 && base_restored=true
fi
elapsed=$(( $(date +%s) - run_started )); deadline_ok=false; [ "$elapsed" -le 6300 ] && deadline_ok=true
pressure_samples=$(wc -l < "$RTMP/pressure.log" 2>/dev/null | tr -d ' ')
pressure_hash=$(sha256sum "$RTMP/pressure.log" 2>/dev/null | awk '{print $1}')
pressure_breach=$(cat "$RTMP/pressure.breach" 2>/dev/null || true)
monitor_pass=false; [ -s "$RTMP/pressure.log" ] && [ -z "$pressure_breach" ] && monitor_pass=true
zero_exact_names=true
for exact_name in "$NET" "$PGVOL" "$OUTVOL" "$IMAGE"; do
  [ -z "$(docker network ls -q --filter "name=^${exact_name}$"; docker volume ls -q --filter "name=^${exact_name}$"; docker image ls -q --filter "reference=${exact_name}")" ] || zero_exact_names=false
done
python3 - "$RTMP/export/safety.json" "$runner_status" "$export_status" "$gate_status" "$elapsed" "$before_hash" "$after_hash" "$zero_labels" "$zero_names" "$zero_exact_names" "$base_restored" "$base_id_preexisting" "$deadline_ok" "$initial_tag" "$tag_introduced" "$image_id_introduced" "$base_id" "$base_digest" "$base_version" "$monitor_status" "$pressure_samples" "$pressure_hash" "$monitor_pass" "$pressure_breach" "$RTMP/source.commit" "$RTMP/source.sha256" "$postgres_image_id" "$postgres_repo_digest" "$postgres_server_version" <<'PY'
import json
import sys
def b(value): return value == "true"
_, path, runner, export, gate, elapsed, before, after, labels, names, exact, restored, preexisting, deadline, initial, tag, image, image_id, digest, version, monitor, samples, pressure, monitor_pass, breach, commit_path, manifest_path, postgres_id, postgres_digest, postgres_server = sys.argv
source_commit=open(commit_path).read().strip(); manifest_sha=__import__("hashlib").sha256(open(manifest_path,"rb").read()).hexdigest()
json.dump({"task":"T091","runner_status":int(runner),"export_status":int(export),"gate_status":int(gate),"work_deadline_seconds":5400,"total_deadline_seconds":6300,"elapsed_seconds":int(elapsed),"pre_snapshot_sha256":before,"post_snapshot_sha256":after,"zero_owned_resources":b(labels),"zero_owned_names":b(names),"zero_exact_names":b(exact),"base_restored":b(restored),"base_id_preexisting":b(preexisting),"deadline_ok":b(deadline),"post_cleanup_verified":b(labels) and b(names) and b(exact) and b(restored) and b(deadline) and monitor == "stopped" and b(monitor_pass) and not breach and before == after,"source_commit":source_commit,"source_manifest_sha256":manifest_sha,"base_image":{"initial_exact_tag_present":b(initial),"tag_introduced":b(tag),"image_id":"%s"%image_id,"repo_digest":"%s"%digest,"ruby_version":"%s"%version,"image_id_introduced":b(image),"prune_used":False},"postgres_image":{"image_id":postgres_id,"repo_digest":postgres_digest},"postgres_server_version":postgres_server,"preflight_samples":3,"pressure_monitor":{"status":monitor,"samples":int(samples or 0),"sha256":pressure,"monitor_pass":b(monitor_pass),"breach_reason":breach},"caps":{"postgres_cpus":2,"postgres_memory_bytes":8589934592,"runner_cpus":1.5,"runner_memory_bytes":3221225472},"internal_network":True,"published_ports":[],"host_network":False,"privileged":False,"restart_policy":"no","media_mounts":False},open(path,"w"),sort_keys=True)
PY
tar -C "$RTMP/export" -cf "$RTMP/result.tar" .
REMOTE

scp -q -o BatchMode=yes "$REMOTE:$RTMP/result.tar" "$LTMP/remote.tar"
retention=$(runner_contract_retain_transfer "$LTMP/remote.tar" "$RETAINED_ROOT" "$RUN_ID")
retained=${retention%%|*}; retained_sha=${retention##*|}; mkdir "$LTMP/out"; tar -xf "$retained" -C "$LTMP/out"
[ -f "$LTMP/out/output.tar" ] && tar -xf "$LTMP/out/output.tar" -C "$LTMP/out"
remote_temp_removed=false
ssh -o BatchMode=yes "$REMOTE" "case '$RTMP' in /tmp/t091-*) rm -rf -- '$RTMP';; *) exit 90;; esac; rm -f -- '$RTMP.tgz'; test ! -e '$RTMP' && test ! -e '$RTMP.tgz'"
remote_temp_removed=true
"$PROJECT_RUBY" -rjson -e 'p=ARGV[0]; d=JSON.parse(File.read(p)); d["remote_temp_removed"]=ARGV[1]=="true"; File.write(p, JSON.pretty_generate(d)+"\n")' "$LTMP/out/safety.json" "$remote_temp_removed"
"$PROJECT_RUBY" -rjson -e 'd=JSON.parse(File.read(ARGV[0])); s=JSON.parse(File.read(ARGV[1])); d["remote_safety"]=s; File.write(ARGV[2], JSON.pretty_generate(d)+"\n")' "$LTMP/out/result.json" "$LTMP/out/safety.json" "$LTMP/raw.json" 2>/dev/null || :
validator_ok=false
if [ -s "$LTMP/raw.json" ]; then
  "$PROJECT_RUBY" bench/validate_bulk_write_artifact.rb "$LTMP/raw.json" >"$LTMP/validator.stdout" 2>"$LTMP/validator.stderr" && validator_ok=true
fi
if [ ! -s "$LTMP/raw.json" ]; then printf '{}\n' > "$LTMP/raw.json"; fi
"$PROJECT_RUBY" -rjson -e 'd=JSON.parse(File.read(ARGV[0])); s=JSON.parse(File.read(ARGV[1])); s["remote_temp_removed"]=ARGV[3]=="true"; d["remote_safety"]=s; File.write(ARGV[2], JSON.pretty_generate(d)+"\n")' "$LTMP/raw.json" "$LTMP/out/safety.json" "$LTMP/raw.json.tmp" "$remote_temp_removed" && mv "$LTMP/raw.json.tmp" "$LTMP/raw.json"
"$PROJECT_RUBY" -rjson -rdigest -I"$ROOT/bench/docker/lib" -rartifact_envelope -e 'root,run,sha,ok=ARGV; raw=File.exist?(ARGV[0]+"/../raw.json") ? JSON.parse(File.read(ARGV[0]+"/../raw.json")) : {}; safety=JSON.parse(File.read(root+"/safety.json")); accepted=(ok=="true") && safety["runner_status"]==0 && safety["gate_status"]==0 && safety["export_status"]==0 && safety["post_cleanup_verified"] && safety["remote_temp_removed"] && safety.dig("pressure_monitor","status")=="stopped" && safety.dig("pressure_monitor","samples").to_i>0 && safety.dig("pressure_monitor","monitor_pass") && !safety["source_commit"].to_s.empty? && !safety.dig("base_image","repo_digest").to_s.empty? && !safety.dig("postgres_image","image_id").to_s.empty? && !safety.dig("postgres_image","repo_digest").to_s.empty? && !safety["postgres_server_version"].to_s.empty?; payload=raw.merge("remote_safety"=>safety); diag={"retained_sha256"=>sha,"remote_temp_removed"=>safety["remote_temp_removed"],"stdout"=>File.read(root+"/stdout"),"stderr"=>File.read(root+"/stderr"),"validator_stdout"=>(File.exist?(root+"/../validator.stdout") ? File.read(root+"/../validator.stdout") : ""),"validator_stderr"=>(File.exist?(root+"/../validator.stderr") ? File.read(root+"/../validator.stderr") : "")}; TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: TypedEAVBenchmark::ArtifactEnvelope.build(status: accepted ? "accepted" : "rejected", task: "T091", run_id: run, payload: payload, diagnostics: diag))' "$LTMP/out" "$RUN_ID" "$retained_sha" "$validator_ok"
if [ -f "$LTMP/out/accepted.json" ]; then
  final_tmp="$RETAINED_ROOT/$RUN_ID-final.tar.tmp-$$"; final_tar="$RETAINED_ROOT/$RUN_ID-final.tar"; mkdir -p "$RETAINED_ROOT"; tar -C "$LTMP" -cf "$final_tmp" raw.json out; mv "$final_tmp" "$final_tar"; sha256sum "$final_tar" > "$final_tar.sha256"
  cp "$LTMP/raw.json" "$OUT"
else
  final_tmp="$RETAINED_ROOT/$RUN_ID-final.tar.tmp-$$"; final_tar="$RETAINED_ROOT/$RUN_ID-final.tar"; mkdir -p "$RETAINED_ROOT"; tar -C "$LTMP" -cf "$final_tmp" raw.json out; mv "$final_tmp" "$final_tar"; sha256sum "$final_tar" > "$final_tar.sha256"
  echo "T091: representative rejected; retained diagnostics: $final_tar" >&2
  exit 1
fi
