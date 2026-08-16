#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t074-$(date -u +%Y%m%dt%H%M%sz)-$$"
NET="$RUN_ID-net"; PGVOL="$RUN_ID-pgdata"; OUTVOL="$RUN_ID-output"
PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; DRILL="$RUN_ID-drill"; MONITOR="$RUN_ID-monitor"; EXPORTER="$RUN_ID-exporter"; IMAGE="$RUN_ID:runner"
REMOTE_TMP="/tmp/$RUN_ID"; RESULT_REMOTE="$REMOTE_TMP.result.tar"; DRILL_REMOTE="$REMOTE_TMP.drill.tar"
IMAGE_LIFECYCLE_REMOTE="$REMOTE_TMP.image-lifecycle.json"
OUT="$ROOT_DIR/bench/results/phase-4-multi-filter-corrective-representative.json"
DRILL_ONLY=${TYPED_EAV_DRILL_ONLY:-0}; TMP_ROOT=/private/tmp; [ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp

die(){ echo "run_remote.sh: $*" >&2; exit 1; }
cleanup_local(){
  case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t074-*|/tmp/typed-eav-t074-*) rm -rf -- "$LOCAL_TMP";; esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "LIFECYCLE='$IMAGE_LIFECYCLE_REMOTE' bash -s" <<'IMAGE_CLEANUP' >/dev/null 2>&1 || true
set +e
[ -s "$LIFECYCLE" ] || exit 0
read -r preexisting introduced image_id < <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(str(d["initial_exact_tag_present"]).lower(),str(d["image_id_introduced"]).lower(),d["image_id"])' "$LIFECYCLE")
if [ "$preexisting" = false ]; then
  current=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null)
  [ -z "$current" ] || [ "$current" != "$image_id" ] || docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1
  if [ "$introduced" = true ] && docker image inspect "$image_id" >/dev/null 2>&1; then docker image rm "$image_id" >/dev/null 2>&1; fi
fi
rm -f -- "$LIFECYCLE"
IMAGE_CLEANUP
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "case '$RESULT_REMOTE' in /tmp/t074-*.result.tar) rm -f -- '$RESULT_REMOTE';; esac" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT
for command in ssh scp tar shasum; do command -v "$command" >/dev/null || die "$command required"; done
[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = a51e087635aa900252459b339fe22c63227b0907 ] || die "source must start at exact a51e087"
[ -z "$(git -C "$ROOT_DIR" status --short --untracked-files=no -- . ':(exclude)bench/README.md' ':(exclude)bench/multi_filter_benchmark.rb' ':(exclude)bench/validate_multi_filter_corrective_artifact.rb' ':(exclude)bench/docker/multi-filter-corrective/run_remote.sh' ':(exclude)bench/results/phase-4-multi-filter-corrective-representative.json' ':(exclude)docs/improvement-program.md')" ] || die "tracked file outside T074 allowlist changed"

ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "RUN_ID='$RUN_ID' LIFECYCLE='$IMAGE_LIFECYCLE_REMOTE' bash -s" <<'PREFLIGHT'
set -euo pipefail
docker image inspect postgres:17 >/dev/null
root=$(docker info --format '{{.DockerRootDir}}'); before=$(mktemp); now=""; trap 'rm -f -- "$before" "$now"' EXIT
snapshot(){ for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"
for sample in 1 2 3; do
  mem=$(free -b | awk '/^Mem:/{print $7}'); disk=$(df -Pk "$root" | tail -1 | awk '{print $4*1024}'); load=$(awk '{print $1}' /proc/loadavg)
  echo "T074_PREFLIGHT sample=$sample available=$mem docker_free=$disk load1=$load"
  awk -v m="$mem" -v d="$disk" 'BEGIN{exit !(m>=12884901888&&d>=21474836480)}' || exit 42
  now=$(mktemp); snapshot > "$now"; cmp -s "$before" "$now" || exit 43; rm -f "$now"; now=""; [ "$sample" = 3 ] || sleep 5
done
pre_ids=$(mktemp); docker image ls -aq --no-trunc | sort -u > "$pre_ids"
pre_ids_sha=$(sha256sum "$pre_ids" | awk '{print $1}')
initial_exact_tag_present=false; pull_count=0
if docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1; then initial_exact_tag_present=true; else docker pull --quiet ruby:3.4.4-bookworm >/dev/null; pull_count=1; fi
image_id=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm)
repo_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk '/^ruby@sha256:/{print;exit}')
ruby_version=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk -F= '$1=="RUBY_VERSION"{print $2;exit}')
[ -n "$repo_digest" ] && [ "${repo_digest#ruby@sha256:}" != "$repo_digest" ] || exit 44
[ "$ruby_version" = 3.4.4 ] || exit 44
image_id_introduced=true; grep -Fxq "$image_id" "$pre_ids" && image_id_introduced=false
python3 -c 'import json,sys;json.dump({"schema_version":1,"initial_exact_tag_present":sys.argv[1]=="true","pre_pull_image_ids_sha256":sys.argv[2],"pull_count":int(sys.argv[3]),"repo_digest":sys.argv[4],"image_id":sys.argv[5],"ruby_version":sys.argv[6],"image_id_introduced":sys.argv[7]=="true","build_pull":False,"prune_used":False},open(sys.argv[8],"w"),sort_keys=True)' "$initial_exact_tag_present" "$pre_ids_sha" "$pull_count" "$repo_digest" "$image_id" "$ruby_version" "$image_id_introduced" "$LIFECYCLE"
rm -f -- "$pre_ids"
echo "T076_IMAGE initial_exact_tag_present=$initial_exact_tag_present pull_count=$pull_count repo_digest=$repo_digest image_id=$image_id ruby_version=$ruby_version introduced=$image_id_introduced"
PREFLIGHT

LOCAL_TMP=$(mktemp -d "$TMP_ROOT/typed-eav-t074-$RUN_ID.XXXXXX"); STAGE="$LOCAL_TMP/source"; mkdir "$STAGE"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE"
for path in bench/README.md bench/multi_filter_benchmark.rb bench/validate_multi_filter_corrective_artifact.rb bench/docker/multi-filter-corrective/run_remote.sh docs/improvement-program.md; do
  mkdir -p "$STAGE/$(dirname "$path")"; cp "$ROOT_DIR/$path" "$STAGE/$path"
done
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LOCAL_TMP/source-manifest.sha256"
cp "$LOCAL_TMP/source-manifest.sha256" "$STAGE/source-manifest.sha256"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$LOCAL_TMP/source.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$REMOTE_TMP' && test ! -e '$REMOTE_TMP.tgz' && test ! -e '$RESULT_REMOTE'"
scp -q -o BatchMode=yes "$LOCAL_TMP/source.tgz" "$REMOTE:$REMOTE_TMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' PGVOL='$PGVOL' OUTVOL='$OUTVOL' PG='$PG' RUNNER='$RUNNER' DRILL='$DRILL' MONITOR='$MONITOR' EXPORTER='$EXPORTER' IMAGE='$IMAGE' REMOTE_TMP='$REMOTE_TMP' RESULT_REMOTE='$RESULT_REMOTE' DRILL_REMOTE='$DRILL_REMOTE' DRILL_ONLY='$DRILL_ONLY' IMAGE_LIFECYCLE_REMOTE='$IMAGE_LIFECYCLE_REMOTE' bash -s" <<'REMOTE'
# shellcheck shell=bash
set -euo pipefail
run_started=$(date +%s); monitor_pid=""; before=""; after=""
case "$REMOTE_TMP" in /tmp/t074-*) ;; *) exit 45;; esac
[ -s "$IMAGE_LIFECYCLE_REMOTE" ] || exit 44
read -r ruby_tag_preexisting ruby_image_introduced ruby_image_id < <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(str(d["initial_exact_tag_present"]).lower(),str(d["image_id_introduced"]).lower(),d["image_id"])' "$IMAGE_LIFECYCLE_REMOTE")
[ "$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm)" = "$ruby_image_id" ] || exit 44
owned(){
  case "$1" in container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);; network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);; esac
  python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T074" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"
}
cleanup(){
  set +e; [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true
  for c in "$EXPORTER" "$MONITOR" "$DRILL" "$RUNNER" "$PG"; do owned container "$c" && docker rm -f "$c" >/dev/null 2>&1 || true; done
  owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true
  owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true
  for v in "$OUTVOL" "$PGVOL"; do owned volume "$v" && docker volume rm "$v" >/dev/null 2>&1 || true; done
  if [ "$ruby_tag_preexisting" = false ]; then
    current=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null)
    [ -z "$current" ] || [ "$current" != "$ruby_image_id" ] || docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1 || true
    if [ "$ruby_image_introduced" = true ] && docker image inspect "$ruby_image_id" >/dev/null 2>&1; then docker image rm "$ruby_image_id" >/dev/null 2>&1 || true; fi
  fi
  rm -f -- "$before" "$after"
  case "$REMOTE_TMP" in /tmp/t074-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz" "$DRILL_REMOTE";; esac
}
trap cleanup EXIT
mkdir "$REMOTE_TMP"; tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"; (cd "$REMOTE_TMP" && shasum -a 256 -c source-manifest.sha256 >/dev/null)
docker network create --internal --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
before=$(mktemp)
snapshot(){
  for id in $(docker ps -aq); do
    labels=$(docker inspect -f '{{json .Config.Labels}}' "$id")
    if python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T074" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; then continue; fi
    docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'
  done | sort
}
snapshot > "$before"
docker volume create --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" "$PGVOL" >/dev/null
docker volume create --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" "$OUTVOL" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=192 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=1g --pids-limit=512 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:/var/lib/postgresql/data" postgres:17 >/dev/null
ready=0; for _ in $(seq 1 150); do if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi; [ "$(docker inspect -f '{{.State.Status}}' "$PG")" = running ] || break; sleep 2; done
[ "$ready" = 1 ] || exit 46
docker build --pull=false --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$REMOTE_TMP" <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
RUN gem install pg -v 1.6.3 --no-document
WORKDIR /work
COPY . .
DOCKERFILE
docker run -d --name "$MONITOR" --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network none --cpus=.1 --cpu-shares=64 --memory=128m --memory-swap=128m --pids-limit=32 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=8m --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output" --entrypoint sleep "$IMAGE" infinity >/dev/null
docker exec -i "$MONITOR" bash -c 'cat > /output/image-lifecycle.json' < "$IMAGE_LIFECYCLE_REMOTE"
stage(){ docker exec "$MONITOR" bash -c 'dir=$1;name=$2;value=$3;mkdir -p "/output/$dir";tmp="/output/$dir/$name.tmp";printf "%s\n" "$value" > "$tmp";mv "$tmp" "/output/$dir/$name.json"' _ "$1" "$2" "$3"; }

drill_db="typed_eav_phase4_multi_drill_${RUN_ID##*-}"
stage drill 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'
docker exec "$PG" createdb -U postgres "$drill_db"
docker run -d --name "$DRILL" --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=.25 --memory=256m --memory-swap=256m --pids-limit=64 --read-only --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e PGDATABASE="$drill_db" -v "$OUTVOL:/output" --entrypoint ruby "$IMAGE" -rpg -e 'File.write("/output/drill/admitted.tmp","admitted\n");File.rename("/output/drill/admitted.tmp","/output/drill/admitted");PG.connect.exec("SELECT pg_sleep(300)")' >/dev/null
active=0; for _ in $(seq 1 30); do sessions=$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$drill_db' AND state='active'"); if [ "$sessions" = 1 ]; then active=1; break; fi; sleep 1; done
[ "$active" = 1 ] || exit 49
stage drill 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
docker stop -t 5 "$DRILL" >/dev/null; stage drill 03_RUNNER_STOPPED '{"state":"RUNNER_STOPPED","owned":true}'
docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$drill_db'" >/dev/null
[ "$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$drill_db'")" = 0 ] || exit 50
stage drill 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
drill_after=$(mktemp); snapshot > "$drill_after"; cmp -s "$before" "$drill_after" || exit 51; rm -f "$drill_after"
stage drill 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT","passed":true}'
drill_sha=$(docker exec "$MONITOR" bash -c 'find /output/drill -maxdepth 1 -type f -print0|sort -z|xargs -0 sha256sum' | sha256sum | awk '{print $1}')
stage drill 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$drill_sha\"}"
docker run --rm --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$DRILL_REMOTE"
[ -s "$DRILL_REMOTE" ] || exit 52; docker exec "$PG" dropdb -U postgres "$drill_db"; owned container "$DRILL" && docker rm "$DRILL" >/dev/null
tar -tf "$DRILL_REMOTE" | grep -q 'drill/06_SEALED.json' || exit 53
stage drill 07_AUDITED '{"state":"AUDITED","export_before_drop":true,"database_dropped":true,"cleanup_audited":true}'
if [ "$DRILL_ONLY" = 1 ]; then docker run --rm --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$RESULT_REMOTE"; exit 0; fi

(
  while :; do
    ts=$(date -u +%FT%TZ); mem=$(free -b | awk '/^Mem:/{print $7}'); load=$(awk '{print $1}' /proc/loadavg); iowait=$(awk '/^cpu /{print $6}' /proc/stat)
    stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' | sort); count=$(printf '%s\n' "$stats" | awk 'NF{n++}END{print n+0}'); stats_sha=$(printf '%s' "$stats" | sha256sum | awk '{print $1}')
    printf '%s|%s|%s|%s|%s|%s\n' "$ts" "$mem" "$load" "$iowait" "$count" "$stats_sha" | docker exec -i "$MONITOR" bash -c 'cat >> /output/anonymous-pressure.log'; sleep 15
  done
) & monitor_pid=$!
set +e
docker run --name "$RUNNER" --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1.5 --cpu-shares=128 --blkio-weight=100 --memory=3g --memory-swap=3g --pids-limit=256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_REPRESENTATIVE_OK=1 -e TYPED_EAV_SEMANTIC_SMOKE_PATH=/output/historical-smoke.json -e TYPED_EAV_CORRECTIVE_SMOKE_PATH=/output/corrective-smoke.json -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=60s 3600s bash -lc '
TYPED_EAV_PROGRESS_DIR=/output/progress-historical ruby bench/multi_filter_benchmark.rb --tier smoke --matrix historical --seed 4502 --output /output/historical-smoke.json &&
TYPED_EAV_PROGRESS_DIR=/output/progress-corrective-smoke ruby bench/multi_filter_benchmark.rb --tier smoke --matrix corrective --seed 4502 --output /output/corrective-smoke.json &&
TYPED_EAV_PROGRESS_DIR=/output/progress ruby bench/multi_filter_benchmark.rb --tier representative --matrix corrective --seed 4502 --output /output/result.json &&
ruby bench/validate_multi_filter_corrective_artifact.rb /output/result.json'
runner_status=$?; set -e
stage finalizer 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'; stage finalizer 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
if owned container "$RUNNER" && [ "$(docker inspect -f '{{.State.Running}}' "$RUNNER")" = true ]; then docker stop -t 30 "$RUNNER" >/dev/null; fi
stage finalizer 03_RUNNER_STOPPED "{\"state\":\"RUNNER_STOPPED\",\"runner_status\":$runner_status}"
docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname LIKE 'typed_eav_phase4_multi_%'" >/dev/null
[ "$(docker exec "$PG" psql -U postgres -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname LIKE 'typed_eav_phase4_multi_%'")" = 0 ] || exit 54
stage finalizer 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
kill "$monitor_pid" >/dev/null 2>&1 || true; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; docker exec "$MONITOR" test -s /output/anonymous-pressure.log || exit 47
after=$(mktemp); snapshot > "$after"; cmp -s "$before" "$after" || exit 48
stage finalizer 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT","passed":true}'
before_sha=$(sha256sum "$before"|awk '{print $1}'); after_sha=$(sha256sum "$after"|awk '{print $1}'); pressure_samples=$(docker exec "$MONITOR" wc -l /output/anonymous-pressure.log|awk '{print $1}'); progress_count=$(docker exec "$MONITOR" find /output/progress -maxdepth 1 -name '*.json' -type f|wc -l)
payload_sha=$(docker exec "$MONITOR" bash -c 'find /output -type f ! -name "06_SEALED.json" ! -name "07_AUDITED.json" -print0|sort -z|xargs -0 sha256sum'|sha256sum|awk '{print $1}')
stage finalizer 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$payload_sha\"}"
[ $(( $(date +%s) - run_started )) -lt 4200 ] || exit 55
docker run --name "$EXPORTER" --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network none --cpus=.25 --memory=256m --memory-swap=256m --pids-limit=64 --read-only --cap-drop=ALL --security-opt=no-new-privileges -e RUNNER_STATUS="$runner_status" -e BEFORE_SHA="$before_sha" -e AFTER_SHA="$after_sha" -e PRESSURE_SAMPLES="$pressure_samples" -e PROGRESS_COUNT="$progress_count" -v "$OUTVOL:/output" --entrypoint ruby "$IMAGE" -rjson -e '
safety={"task_label"=>"T074","work_deadline_seconds"=>3600,"hard_timeout_seconds"=>4200,"runner_status"=>ENV.fetch("RUNNER_STATUS").to_i,"internal_network"=>true,"published_ports"=>[],"host_network"=>false,"docker_socket_mounted"=>false,"privileged"=>false,"media_binds"=>false,"compose_used"=>false,"restart_policy"=>"no","postgres_caps"=>{"cpus"=>2,"memory_bytes"=>8589934592},"runner_caps"=>{"cpus"=>1.5,"memory_bytes"=>3221225472},"existing_container_invariant"=>{"passed"=>ENV.fetch("BEFORE_SHA")==ENV.fetch("AFTER_SHA"),"before_sha256"=>ENV.fetch("BEFORE_SHA"),"after_sha256"=>ENV.fetch("AFTER_SHA")},"anonymous_pressure"=>{"samples"=>ENV.fetch("PRESSURE_SAMPLES").to_i,"raw_identifiers_retained"=>false},"progress_checkpoints"=>{"count"=>ENV.fetch("PROGRESS_COUNT").to_i,"diagnostic_only"=>true},"cancellation_drill"=>{"passed"=>true,"export_before_drop"=>true},"finalizer"=>{"states"=>%w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED],"export_before_cleanup"=>true},"image_lifecycle"=>JSON.parse(File.read("/output/image-lifecycle.json")),"cleanup_contract"=>"exact T074/run labels plus exact names; verified after transfer"};File.write("/output/run-safety.json",JSON.pretty_generate(safety));path="/output/result.json";if File.exist?(path);d=JSON.parse(File.read(path),max_nesting:false);d["remote_safety"]=safety;File.write(path,JSON.pretty_generate(d,max_nesting:false));end'
docker run --rm --label goalbuddy.task=T074 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - . > "$RESULT_REMOTE"
REMOTE

scp -q -o BatchMode=yes "$REMOTE:$RESULT_REMOTE" "$LOCAL_TMP/result.tar"; mkdir "$LOCAL_TMP/output"; tar -xf "$LOCAL_TMP/result.tar" -C "$LOCAL_TMP/output"
if [ "$DRILL_ONLY" = 1 ]; then
  ruby -rjson -e 'd=ARGV[0];e=%w[01_PREFLIGHT 02_QUIESCED 03_RUNNER_STOPPED 04_SESSIONS_TERMINATED 05_AFTER_INVARIANT 06_SEALED 07_AUDITED];f=Dir[File.join(d,"*.json")].map{|p|File.basename(p,".json")}.sort;abort unless f==e;a=JSON.parse(File.read(File.join(d,"07_AUDITED.json")));abort unless a["export_before_drop"]&&a["database_dropped"]&&a["cleanup_audited"];puts "T074_DRILL stages=7 export_before_drop=true"' "$LOCAL_TMP/output/drill"
else
  ruby -rjson -e 's=JSON.parse(File.read(ARGV[0]));abort "runner failed" unless s["runner_status"]==0&&s.dig("existing_container_invariant","passed")&&s.dig("progress_checkpoints","count")==96' "$LOCAL_TMP/output/run-safety.json"
fi
ssh -o BatchMode=yes "$REMOTE" "sleep 2; test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T074 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T074 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T074 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T074 --filter label=goalbuddy.run='$RUN_ID')\"; test ! -e '$REMOTE_TMP'; test ! -e '$REMOTE_TMP.tgz'"
if [ "$DRILL_ONLY" = 1 ]; then echo "T074 cancellation drill accepted"; exit 0; fi
ruby bench/validate_multi_filter_corrective_artifact.rb "$LOCAL_TMP/output/result.json"
ruby -rjson -e 'p=ARGV[0];d=JSON.parse(File.read(p),max_nesting:false);l=d.dig("remote_safety","image_lifecycle");pre=l.fetch("initial_exact_tag_present");introduced=l.fetch("image_id_introduced");id=l.fetch("image_id");tag=system("ssh","-o","BatchMode=yes",ARGV[1],"docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1");id_present=system("ssh","-o","BatchMode=yes",ARGV[1],"docker image inspect #{id} >/dev/null 2>&1");ok=pre ? tag&&id_present : !tag&&(!introduced||!id_present);abort "image cleanup audit failed" unless ok;l["post_cleanup_exact_tag_present"]=tag;l["post_cleanup_image_id_present"]=id_present;l["post_cleanup_verified"]=true;d.fetch("remote_safety")["post_cleanup_verified"]=true;File.write(p,JSON.pretty_generate(d,max_nesting:false))' "$LOCAL_TMP/output/result.json" "$REMOTE"
mkdir -p "$(dirname "$OUT")"; cp "$LOCAL_TMP/output/result.json" "$OUT"; echo "T074 representative artifact: $OUT"
