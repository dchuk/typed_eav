#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t062-$(date -u +%Y%m%dt%H%M%sz)-$$"
NET="$RUN_ID-net"; PGVOL="$RUN_ID-pgdata"; OUTVOL="$RUN_ID-output"
PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; DRILL="$RUN_ID-drill"; MONITOR="$RUN_ID-monitor"; EXPORTER="$RUN_ID-exporter"; IMAGE="$RUN_ID:runner"
REMOTE_TMP="/tmp/$RUN_ID"; RESULT_REMOTE="$REMOTE_TMP.result.tar"; DRILL_REMOTE="$REMOTE_TMP.drill.tar"
OUT="$ROOT_DIR/bench/results/phase-4-multi-filter-representative.json"
TMP_ROOT=/private/tmp; [ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp
DRILL_ONLY=${TYPED_EAV_DRILL_ONLY:-0}

die(){ echo "run_remote.sh: $*" >&2; exit 1; }
cleanup_local(){
  case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t062-*|/tmp/typed-eav-t062-*) rm -rf -- "$LOCAL_TMP";; esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "case '$RESULT_REMOTE' in /tmp/t062-*.result.tar) rm -f -- '$RESULT_REMOTE';; esac" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT
for command in ssh scp tar shasum; do command -v "$command" >/dev/null || die "$command required"; done
[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = d0b32934ef6c84462d7cfa3c8acb167714e4639b ] || die "source must start at exact d0b3293"
[ -z "$(git -C "$ROOT_DIR" status --short --untracked-files=no -- . ':(exclude)bench/README.md' ':(exclude)bench/multi_filter_benchmark.rb' ':(exclude)bench/docker/multi-filter/run_remote.sh' ':(exclude)bench/results/phase-4-multi-filter-representative.json' ':(exclude)docs/improvement-program.md')" ] || die "tracked file outside T062 allowlist changed"

ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' <<'PREFLIGHT'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}'); before=$(mktemp); now=""; trap 'rm -f -- "$before" "$now"' EXIT
snapshot(){ for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"
for sample in 1 2 3; do
  mem=$(free -b | awk '/^Mem:/{print $7}'); disk=$(df -Pk "$root" | tail -1 | awk '{print $4*1024}'); load=$(awk '{print $1}' /proc/loadavg)
  echo "T062_PREFLIGHT sample=$sample available=$mem docker_free=$disk load1=$load"
  awk -v m="$mem" -v d="$disk" 'BEGIN{exit !(m>=12884901888&&d>=21474836480)}' || exit 42
  now=$(mktemp); snapshot > "$now"; cmp -s "$before" "$now" || exit 43; rm -f "$now"; now=""; [ "$sample" = 3 ] || sleep 5
done
PREFLIGHT

LOCAL_TMP=$(mktemp -d "$TMP_ROOT/typed-eav-t062-$RUN_ID.XXXXXX"); STAGE="$LOCAL_TMP/source"; mkdir "$STAGE"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE"
for path in bench/README.md bench/multi_filter_benchmark.rb bench/docker/multi-filter/run_remote.sh docs/improvement-program.md; do
  mkdir -p "$STAGE/$(dirname "$path")"; cp "$ROOT_DIR/$path" "$STAGE/$path"
done
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LOCAL_TMP/source-manifest.sha256"
cp "$LOCAL_TMP/source-manifest.sha256" "$STAGE/source-manifest.sha256"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$LOCAL_TMP/source.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$REMOTE_TMP' && test ! -e '$REMOTE_TMP.tgz' && test ! -e '$RESULT_REMOTE'"
scp -q -o BatchMode=yes "$LOCAL_TMP/source.tgz" "$REMOTE:$REMOTE_TMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' PGVOL='$PGVOL' OUTVOL='$OUTVOL' PG='$PG' RUNNER='$RUNNER' DRILL='$DRILL' MONITOR='$MONITOR' EXPORTER='$EXPORTER' IMAGE='$IMAGE' REMOTE_TMP='$REMOTE_TMP' RESULT_REMOTE='$RESULT_REMOTE' DRILL_REMOTE='$DRILL_REMOTE' DRILL_ONLY='$DRILL_ONLY' bash -s" <<'REMOTE'
# shellcheck shell=bash
set -euo pipefail
run_started=$(date +%s)
case "$REMOTE_TMP" in /tmp/t062-*) ;; *) exit 45;; esac
monitor_pid=""; before=""; after=""
owned(){
  case "$1" in container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);; network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);; esac
  python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T062" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"
}
cleanup(){
  set +e
  [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true
  for c in "$EXPORTER" "$MONITOR" "$DRILL" "$RUNNER" "$PG"; do owned container "$c" && docker rm -f "$c" >/dev/null 2>&1 || true; done
  owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true
  owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true
  for v in "$OUTVOL" "$PGVOL"; do owned volume "$v" && docker volume rm "$v" >/dev/null 2>&1 || true; done
  rm -f -- "$before" "$after"
  case "$REMOTE_TMP" in /tmp/t062-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz" "$DRILL_REMOTE";; esac
}
trap cleanup EXIT
mkdir "$REMOTE_TMP"; tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"; (cd "$REMOTE_TMP" && shasum -a 256 -c source-manifest.sha256 >/dev/null)
docker network create --internal --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
before=$(mktemp)
snapshot(){
  for id in $(docker ps -aq); do
    labels=$(docker inspect -f '{{json .Config.Labels}}' "$id")
    if python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T062" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; then continue; fi
    docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'
  done | sort
}
snapshot > "$before"
docker volume create --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" "$PGVOL" >/dev/null
docker volume create --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" "$OUTVOL" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=192 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=1g --pids-limit=512 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:/var/lib/postgresql/data" postgres:17 >/dev/null
ready=0; for _ in $(seq 1 150); do if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi; [ "$(docker inspect -f '{{.State.Status}}' "$PG")" = running ] || break; sleep 2; done
[ "$ready" = 1 ] || { docker logs "$PG" >&2; exit 46; }
docker build --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$REMOTE_TMP" <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
RUN gem install pg -v 1.6.3 --no-document
WORKDIR /work
COPY . .
DOCKERFILE

docker run -d --name "$MONITOR" --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network none --cpus=.1 --cpu-shares=64 --memory=128m --memory-swap=128m --pids-limit=32 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=8m --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output" --entrypoint sleep "$IMAGE" infinity >/dev/null

stage(){
  docker exec "$MONITOR" bash -c 'dir=$1; name=$2; value=$3; mkdir -p "/output/$dir"; tmp="/output/$dir/$name.tmp"; printf "%s\n" "$value" > "$tmp"; mv "$tmp" "/output/$dir/$name.json"' _ "$1" "$2" "$3"
}

# Cancellation-injection drill: export sealed diagnostics before dropping its
# database, then audit the export and remove only exact T062-owned state.
drill_db="typed_eav_phase4_multi_drill_${RUN_ID##*-}"
stage drill 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'
docker exec "$PG" createdb -U postgres "$drill_db"
docker run -d --name "$DRILL" --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=.25 --memory=256m --memory-swap=256m --pids-limit=64 --read-only --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e PGDATABASE="$drill_db" -v "$OUTVOL:/output" --entrypoint ruby "$IMAGE" -rpg -e 'File.write("/output/drill/admitted.tmp","admitted\n");File.rename("/output/drill/admitted.tmp","/output/drill/admitted");PG.connect.exec("SELECT pg_sleep(300)")' >/dev/null
active=0; for _ in $(seq 1 30); do sessions=$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$drill_db' AND state='active'"); if [ "$sessions" = 1 ]; then active=1; break; fi; sleep 1; done
[ "$active" = 1 ] || exit 49
stage drill 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
docker stop -t 5 "$DRILL" >/dev/null
stage drill 03_RUNNER_STOPPED '{"state":"RUNNER_STOPPED","owned":true}'
docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$drill_db'" >/dev/null
[ "$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$drill_db'")" = 0 ] || exit 50
stage drill 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
drill_after=$(mktemp); snapshot > "$drill_after"; drill_invariant=false; cmp -s "$before" "$drill_after" && drill_invariant=true; rm -f "$drill_after"
[ "$drill_invariant" = true ] || exit 51
stage drill 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT","passed":true}'
drill_payload_sha=$(docker exec "$MONITOR" bash -c 'find /output/drill -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum' | sha256sum | awk '{print $1}')
stage drill 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$drill_payload_sha\"}"
docker run --rm --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$DRILL_REMOTE"
[ -s "$DRILL_REMOTE" ] || exit 52
docker exec "$PG" dropdb -U postgres "$drill_db"
owned container "$DRILL" && docker rm "$DRILL" >/dev/null
drill_export_sha=$(sha256sum "$DRILL_REMOTE" | awk '{print $1}')
tar -tf "$DRILL_REMOTE" | grep -q 'drill/06_SEALED.json' || exit 53
stage drill 07_AUDITED "{\"state\":\"AUDITED\",\"export_before_drop\":true,\"export_sha256\":\"$drill_export_sha\",\"database_dropped\":true,\"cleanup_audited\":true}"
if [ "$DRILL_ONLY" = 1 ]; then
  docker run --rm --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$RESULT_REMOTE"
  exit 0
fi

# Record anonymous co-tenant pressure only; never inspect names, mounts, logs, or workload data.
(
  while :; do
    ts=$(date -u +%FT%TZ); mem=$(free -b | awk '/^Mem:/{print $7}'); load=$(awk '{print $1}' /proc/loadavg); iowait=$(awk '/^cpu /{print $6}' /proc/stat)
    stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' | sort); count=$(printf '%s\n' "$stats" | awk 'NF{n++}END{print n+0}'); stats_sha=$(printf '%s' "$stats" | sha256sum | awk '{print $1}')
    printf '%s|%s|%s|%s|%s|%s\n' "$ts" "$mem" "$load" "$iowait" "$count" "$stats_sha" | docker exec -i "$MONITOR" bash -c 'cat >> /output/anonymous-pressure.log'
    sleep 15
  done
) & monitor_pid=$!

set +e
docker run --name "$RUNNER" --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1.5 --cpu-shares=128 --blkio-weight=100 --memory=3g --memory-swap=3g --pids-limit=256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_REPRESENTATIVE_OK=1 -e TYPED_EAV_PROGRESS_DIR=/output/progress -e TYPED_EAV_SEMANTIC_SMOKE_PATH=/output/semantic-smoke.json -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=60s 6300s bash -lc 'ruby bench/multi_filter_benchmark.rb --tier smoke --seed 4502 --output /output/semantic-smoke.json && ruby bench/multi_filter_benchmark.rb --tier representative --seed 4502 --output /output/result.json'
runner_status=$?
set -e
# Atomic finalizer: no new runner admissions; terminate any owned benchmark
# sessions before snapshotting, sealing, and exporting. Resource cleanup is later.
stage finalizer 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'
stage finalizer 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
if owned container "$RUNNER" && [ "$(docker inspect -f '{{.State.Running}}' "$RUNNER")" = true ]; then docker stop -t 30 "$RUNNER" >/dev/null; fi
stage finalizer 03_RUNNER_STOPPED "{\"state\":\"RUNNER_STOPPED\",\"runner_status\":$runner_status}"
docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname LIKE 'typed_eav_phase4_multi_%'" >/dev/null
remaining_sessions=$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname LIKE 'typed_eav_phase4_multi_%'")
[ "$remaining_sessions" = 0 ] || exit 54
stage finalizer 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
kill "$monitor_pid" >/dev/null 2>&1 || true; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""
docker exec "$MONITOR" test -s /output/anonymous-pressure.log || exit 47
after=$(mktemp)
snapshot > "$after"
invariant_passed=false; cmp -s "$before" "$after" && invariant_passed=true
[ "$invariant_passed" = true ] || exit 48
stage finalizer 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT","passed":true}'
before_sha=$(sha256sum "$before" | awk '{print $1}'); after_sha=$(sha256sum "$after" | awk '{print $1}')
pressure_samples=$(docker exec "$MONITOR" wc -l /output/anonymous-pressure.log | awk '{print $1}')
pressure_sha=$(docker exec "$MONITOR" sha256sum /output/anonymous-pressure.log | awk '{print $1}')
progress_count=$(docker exec "$MONITOR" find /output/progress -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
progress_sha=$(docker exec "$MONITOR" bash -c 'find /output/progress -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum' | sha256sum | awk '{print $1}')
finalizer_payload_sha=$(docker exec "$MONITOR" bash -c 'find /output -type f ! -name "06_SEALED.json" ! -name "07_AUDITED.json" -print0 | sort -z | xargs -0 sha256sum' | sha256sum | awk '{print $1}')
stage finalizer 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$finalizer_payload_sha\"}"
elapsed_seconds=$(( $(date +%s) - run_started )); [ "$elapsed_seconds" -lt 7200 ] || exit 55

docker run --name "$EXPORTER" --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network none --cpus=.25 --memory=256m --memory-swap=256m --pids-limit=64 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --cap-drop=ALL --security-opt=no-new-privileges -e RUNNER_STATUS="$runner_status" -e INVARIANT_PASSED="$invariant_passed" -e BEFORE_SHA="$before_sha" -e AFTER_SHA="$after_sha" -e PRESSURE_SAMPLES="$pressure_samples" -e PRESSURE_SHA="$pressure_sha" -e PROGRESS_COUNT="$progress_count" -e PROGRESS_SHA="$progress_sha" -v "$OUTVOL:/output" --entrypoint ruby "$IMAGE" -rjson -e '
safety={"task_label"=>"T062","run_label_present"=>true,"work_deadline_seconds"=>6300,"hard_timeout_seconds"=>7200,"runner_status"=>ENV.fetch("RUNNER_STATUS").to_i,"internal_network"=>true,"published_ports"=>[],"host_network"=>false,"docker_socket_mounted"=>false,"privileged"=>false,"media_binds"=>false,"compose_used"=>false,"restart_policy"=>"no","postgres_caps"=>{"cpus"=>2,"memory_bytes"=>8589934592,"memory_swap_bytes"=>8589934592,"cpu_shares"=>192,"blkio_weight"=>100},"runner_caps"=>{"cpus"=>1.5,"memory_bytes"=>3221225472,"memory_swap_bytes"=>3221225472,"cpu_shares"=>128,"blkio_weight"=>100,"cap_drop"=>["ALL"],"no_new_privileges"=>true,"read_only"=>true},"existing_container_invariant"=>{"passed"=>ENV.fetch("INVARIANT_PASSED")=="true","before_sha256"=>ENV.fetch("BEFORE_SHA"),"after_sha256"=>ENV.fetch("AFTER_SHA")},"anonymous_pressure"=>{"samples"=>ENV.fetch("PRESSURE_SAMPLES").to_i,"sha256"=>ENV.fetch("PRESSURE_SHA"),"raw_identifiers_retained"=>false},"progress_checkpoints"=>{"count"=>ENV.fetch("PROGRESS_COUNT").to_i,"sha256"=>ENV.fetch("PROGRESS_SHA"),"diagnostic_only"=>true},"cancellation_drill"=>{"passed"=>true,"export_before_drop"=>true},"finalizer"=>{"states"=>%w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED],"export_before_cleanup"=>true},"cleanup_contract"=>"exact T062/run labels plus exact names; verified after transfer"}
File.write("/output/run-safety.json", "#{JSON.pretty_generate(safety)}\n")
path="/output/result.json"; if File.exist?(path); d=JSON.parse(File.read(path),max_nesting:false); d["remote_safety"]=safety; tmp="#{path}.tmp"; File.write(tmp,"#{JSON.pretty_generate(d,max_nesting:false)}\n"); File.rename(tmp,path); end
'
docker run --rm --label goalbuddy.task=T062 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - . > "$RESULT_REMOTE"
REMOTE

scp -q -o BatchMode=yes "$REMOTE:$RESULT_REMOTE" "$LOCAL_TMP/result.tar"
mkdir "$LOCAL_TMP/output"; tar -xf "$LOCAL_TMP/result.tar" -C "$LOCAL_TMP/output"
if [ "$DRILL_ONLY" = 1 ]; then
  PATH="${HOME}/.rbenv/versions/3.4.4/bin:$PATH" ruby -rjson -e 'dir=ARGV.fetch(0); expected=%w[01_PREFLIGHT 02_QUIESCED 03_RUNNER_STOPPED 04_SESSIONS_TERMINATED 05_AFTER_INVARIANT 06_SEALED 07_AUDITED]; files=Dir[File.join(dir,"*.json")].map{|path|File.basename(path,".json")}.sort; abort "drill stages mismatch" unless files==expected; audit=JSON.parse(File.read(File.join(dir,"07_AUDITED.json"))); abort "drill export ordering failed" unless audit["export_before_drop"] && audit["database_dropped"] && audit["cleanup_audited"]; puts "T062_DRILL stages=#{files.length} export_before_drop=true"' "$LOCAL_TMP/output/drill"
  ssh -o BatchMode=yes "$REMOTE" "sleep 2; test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test ! -e '$REMOTE_TMP'; test ! -e '$REMOTE_TMP.tgz'"
  echo "T062 cancellation drill accepted"
  exit 0
fi
PATH="${HOME}/.rbenv/versions/3.4.4/bin:$PATH" ruby -rjson -e 's=JSON.parse(File.read(ARGV[0])); puts "T062_TRANSFER runner_status=#{s.fetch("runner_status")} checkpoints=#{s.dig("progress_checkpoints","count")}"' "$LOCAL_TMP/output/run-safety.json"
# The remote trap has now removed only exact T062-owned resources. Prove zero leftovers.
ssh -o BatchMode=yes "$REMOTE" "sleep 2; test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T062 --filter label=goalbuddy.run='$RUN_ID')\"; test ! -e '$REMOTE_TMP'; test ! -e '$REMOTE_TMP.tgz'"
PATH="${HOME}/.rbenv/versions/3.4.4/bin:$PATH" ruby -rjson -e 'path=ARGV.fetch(0);d={"state"=>"AUDITED","exact_cleanup"=>true,"post_cleanup_verified"=>true};File.write(path,"#{JSON.generate(d)}\n")' "$LOCAL_TMP/output/finalizer/07_AUDITED.json"
PATH="${HOME}/.rbenv/versions/3.4.4/bin:$PATH" ruby -rjson -e 's=JSON.parse(File.read(ARGV[0])); abort "representative runner failed status=#{s.fetch("runner_status")}, checkpoints=#{s.dig("progress_checkpoints","count")}" unless s.fetch("runner_status").zero?; d=JSON.parse(File.read(ARGV[1]),max_nesting:false); abort "artifact rejected" unless d.dig("validation","accepted") && d.dig("remote_safety","existing_container_invariant","passed"); abort "checkpoint set incomplete" unless s.dig("progress_checkpoints","count")==300; abort "attempt count mismatch" unless d.dig("validation","attempt_count")==2940; abort "oracle count mismatch" unless d.dig("validation","semantic_oracle_count")==294; abort "summary count mismatch" unless d.dig("validation","semantic_scenario_summary_count")==75; abort "smoke incomplete" unless d.dig("semantic_smoke","fully_equal") && d.dig("semantic_smoke","oracle_count")==98; puts "T062_ARTIFACT accepted scenarios=#{d.fetch("scenario_catalog").size} trials=#{d.fetch("trials").size} checkpoints=300"' "$LOCAL_TMP/output/run-safety.json" "$LOCAL_TMP/output/result.json"
PATH="${HOME}/.rbenv/versions/3.4.4/bin:$PATH" ruby -rjson -e 'path=ARGV.fetch(0);d=JSON.parse(File.read(path),max_nesting:false);d.fetch("remote_safety")["post_cleanup_verified"]=true;tmp="#{path}.tmp";File.write(tmp,"#{JSON.pretty_generate(d,max_nesting:false)}\n");File.rename(tmp,path)' "$LOCAL_TMP/output/result.json"
mkdir -p "$(dirname "$OUT")"; cp "$LOCAL_TMP/output/result.json" "$OUT"
echo "T062 representative artifact: $OUT"
