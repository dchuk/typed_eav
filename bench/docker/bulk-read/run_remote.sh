#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t086-$(date -u +%Y%m%dt%H%M%sz)-$$"
NET="$RUN_ID-net"; PGVOL="$RUN_ID-pg"; OUTVOL="$RUN_ID-out"
PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; DRILL="$RUN_ID-drill"; MONITOR="$RUN_ID-monitor"; IMAGE="$RUN_ID:runner"
RTMP="/tmp/$RUN_ID"; TRANSFER="$RTMP.result.tar"
OUT="$ROOT/bench/results/phase-5-bulk-read-representative.json"
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$ROOT/bench/docker/lib/runner_contract.sh"
PROJECT_RUBY=$(runner_contract_resolve_project_ruby) || { echo "T086: project Ruby 3.4.4 unavailable" >&2; exit 1; }
[ "$("$PROJECT_RUBY" -e 'print RUBY_VERSION')" = 3.4.4 ] || exit 1
retained_base=/tmp; [ -d /private/tmp ] && retained_base=/private/tmp
RETAINED_ROOT="$retained_base/typed-eav-t086-retained"
RETAINED_PAYLOAD=""; PUBLISHED=false

die() { echo "T086: $*" >&2; exit 1; }
cleanup_local() {
  case "${LTMP:-}" in /private/tmp/typed-eav-t086-*|/tmp/typed-eav-t086-*) rm -rf -- "$LTMP";; esac
  if [ "$PUBLISHED" = true ] && [ -n "$RETAINED_PAYLOAD" ]; then rm -f -- "$RETAINED_PAYLOAD"; fi
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "rm -f -- '$TRANSFER'" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT

[ "$(git -C "$ROOT" rev-parse HEAD)" = 746331baac4f8355c7d165c54bc749d9272c0f38 ] || die "wrong HEAD"
[ -z "$(git -C "$ROOT" status --short --untracked-files=no -- . \
  ':(exclude)bench/docker/lib/runner_contract.sh' ':(exclude)bench/docker/lib/artifact_envelope.rb' \
  ':(exclude)bench/docker/contract_smoke.sh' ':(exclude)bench/docker/bulk-read/run_remote.sh' \
  ':(exclude)bench/validate_bulk_read_artifact.rb' ':(exclude)bench/bulk_read_benchmark.rb' \
  ':(exclude)bench/README.md' ':(exclude)docs/improvement-program.md' \
  ':(exclude)bench/results/phase-5-bulk-read-representative.json')" ] || die "tracked file outside allowlist changed"

tmp_base=/tmp; [ -d /private/tmp ] && tmp_base=/private/tmp
LTMP=$(mktemp -d "$tmp_base/typed-eav-t086-$RUN_ID.XXXXXX")
mkdir "$LTMP/src"
git -C "$ROOT" archive HEAD | tar -x -C "$LTMP/src"
for path in bench/README.md bench/bulk_read_benchmark.rb bench/validate_bulk_read_artifact.rb \
  bench/docker/lib/runner_contract.sh bench/docker/lib/artifact_envelope.rb \
  bench/docker/contract_smoke.sh bench/docker/bulk-read/run_remote.sh docs/improvement-program.md; do
  mkdir -p "$LTMP/src/$(dirname "$path")"; cp "$ROOT/$path" "$LTMP/src/$path"
done
(cd "$LTMP/src" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LTMP/source.sha256"
cp "$LTMP/source.sha256" "$LTMP/src/source.sha256"
COPYFILE_DISABLE=1 tar -C "$LTMP/src" -czf "$LTMP/src.tgz" .
ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "test ! -e '$RTMP' && test ! -e '$RTMP.tgz' && test ! -e '$TRANSFER'"
scp -q -o BatchMode=yes "$LTMP/src.tgz" "$REMOTE:$RTMP.tgz"

set +e
ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' PGVOL='$PGVOL' OUTVOL='$OUTVOL' PG='$PG' RUNNER='$RUNNER' DRILL='$DRILL' MONITOR='$MONITOR' IMAGE='$IMAGE' RTMP='$RTMP' TRANSFER='$TRANSFER' bash -s" <<'REMOTE'
set -euo pipefail
run_started=$(date +%s); monitor_pid=""; before=""; after=""
initial_exact_tag_present=false; image_id_introduced=false; pull_count=0; ruby_image_id=""
case "$RTMP" in /tmp/t086-*) ;; *) exit 40;; esac

cleanup() {
  set +e
  [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true
  for container in "$DRILL" "$RUNNER" "$MONITOR" "$PG"; do runner_contract_owned container "$container" && docker rm -f "$container" >/dev/null 2>&1 || true; done
  runner_contract_owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true
  runner_contract_owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true
  for volume in "$OUTVOL" "$PGVOL"; do runner_contract_owned volume "$volume" && docker volume rm "$volume" >/dev/null 2>&1 || true; done
  if [ "$initial_exact_tag_present" = false ] && [ -n "$ruby_image_id" ]; then
    current=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null)
    [ -z "$current" ] || [ "$current" != "$ruby_image_id" ] || docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1 || true
    if [ "$image_id_introduced" = true ] && docker image inspect "$ruby_image_id" >/dev/null 2>&1; then docker image rm "$ruby_image_id" >/dev/null 2>&1 || true; fi
  fi
  rm -f -- "$before" "$after"
  case "$RTMP" in /tmp/t086-*) rm -rf -- "$RTMP" "$RTMP.tgz";; esac
}
trap cleanup EXIT

docker image inspect postgres:17 >/dev/null
docker_root=$(docker info --format '{{.DockerRootDir}}'); before=$(mktemp)
raw_snapshot() {
  for id in $(docker ps -aq); do
    docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'
  done | sort
}
raw_snapshot > "$before"
for sample in 1 2 3; do
  available=$(free -b | awk '/^Mem:/{print $7}'); docker_free=$(df -Pk "$docker_root" | tail -1 | awk '{print $4*1024}'); load1=$(awk '{print $1}' /proc/loadavg)
  echo "T086_PREFLIGHT sample=$sample available=$available docker_free=$docker_free load1=$load1"
  awk -v memory="$available" -v disk="$docker_free" 'BEGIN{exit !(memory>=12884901888 && disk>=21474836480)}' || exit 42
  current=$(mktemp); raw_snapshot > "$current"; cmp -s "$before" "$current" || exit 43; rm -f "$current"
  [ "$sample" = 3 ] || sleep 5
done

pre_ids=$(mktemp); docker image ls -aq --no-trunc | sort -u > "$pre_ids"; pre_ids_sha=$(sha256sum "$pre_ids" | awk '{print $1}')
if docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1; then initial_exact_tag_present=true; else docker pull --quiet ruby:3.4.4-bookworm >/dev/null; pull_count=1; fi
ruby_image_id=$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm)
repo_digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk '/^ruby@sha256:/{print;exit}')
ruby_version=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ruby:3.4.4-bookworm | awk -F= '$1=="RUBY_VERSION"{print $2;exit}')
[ "$ruby_version" = 3.4.4 ] && [ "${repo_digest#ruby@sha256:}" != "$repo_digest" ] || exit 44
grep -Fxq "$ruby_image_id" "$pre_ids" || image_id_introduced=true; rm -f "$pre_ids"

mkdir "$RTMP"; tar -xzf "$RTMP.tgz" -C "$RTMP"; (cd "$RTMP" && sha256sum -c source.sha256 >/dev/null)
# shellcheck source=bench/docker/lib/runner_contract.sh
source "$RTMP/bench/docker/lib/runner_contract.sh"
export GB_TASK=T086 GB_RUN_ID="$RUN_ID"; runner_contract_require_identity
pg_target=$(runner_contract_pg_target 17); [ "$pg_target" = /var/lib/postgresql/data ]
docker network create --internal --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
snapshot() { runner_contract_snapshot; }
snapshot > "$before"
docker volume create --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" "$PGVOL" >/dev/null
docker volume create --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" "$OUTVOL" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network "$NET" \
  --cpus=2 --cpu-shares=192 --memory=8g --memory-swap=8g --blkio-weight=100 --shm-size=1g --pids-limit=512 \
  -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:$pg_target" postgres:17 >/dev/null
ready=0
for _ in $(seq 1 150); do
  if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  [ "$(docker inspect -f '{{.State.Status}}' "$PG")" = running ] || break; sleep 2
done
[ "$ready" = 1 ] || exit 45

docker build --pull=false --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$RTMP" <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
WORKDIR /work
COPY . .
RUN bundle install --jobs=4 --retry=3 && bundle config set --global allow_offline_install true
DOCKERFILE
docker run -d --name "$MONITOR" --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network none \
  --cpus=.1 --memory=128m --memory-swap=128m --pids-limit=32 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=8m \
  --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output" --entrypoint sleep "$IMAGE" infinity >/dev/null
stage() {
  docker exec "$MONITOR" bash -c 'root=$1; name=$2; value=$3; mkdir -p "/output/$root"; temporary="/output/$root/$name.tmp"; printf "%s\n" "$value" > "$temporary"; mv "$temporary" "/output/$root/$name.json"' _ "$1" "$2" "$3"
}

drill_db="typed_eav_t086_drill_${RUN_ID##*-}"
stage drill 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'
docker exec "$PG" createdb -U postgres "$drill_db"
docker run -d --name "$DRILL" --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network "$NET" \
  --cpus=.25 --memory=256m --memory-swap=256m --pids-limit=64 --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -e PGHOST="$PG" -e PGUSER=postgres -e PGDATABASE="$drill_db" --entrypoint ruby "$IMAGE" -rpg -e 'PG.connect.exec("select pg_sleep(300)")' >/dev/null
active=0
for _ in $(seq 1 30); do
  sessions=$(docker exec "$PG" psql -U postgres -d postgres -Atc "select count(*) from pg_stat_activity where datname='$drill_db' and state='active'")
  if [ "$sessions" = 1 ]; then active=1; break; fi; sleep 1
done
[ "$active" = 1 ] || exit 46
stage drill 02_QUIESCED '{"state":"QUIESCED","new_admissions":false,"active_sessions_before_stop":1}'
docker stop -t 5 "$DRILL" >/dev/null; stage drill 03_RUNNER_STOPPED '{"state":"RUNNER_STOPPED","owned":true}'
docker exec "$PG" psql -U postgres -d postgres -Atc "select pg_terminate_backend(pid) from pg_stat_activity where datname='$drill_db'" >/dev/null
remaining=$(docker exec "$PG" psql -U postgres -d postgres -Atc "select count(*) from pg_stat_activity where datname='$drill_db'")
[ "$remaining" = 0 ] || exit 47
stage drill 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
drill_after=$(mktemp); snapshot > "$drill_after"; cmp -s "$before" "$drill_after" || exit 48; rm -f "$drill_after"
stage drill 05_AFTER_INVARIANT '{"state":"AFTER_INVARIANT","passed":true}'
drill_sha=$(docker exec "$MONITOR" ruby -rdigest -e 'files=Dir["/output/drill/*.json"].sort; material=files.map{|file|"#{File.basename(file)}\0#{Digest::SHA256.file(file).hexdigest}"}.join;print Digest::SHA256.hexdigest(material)')
stage drill 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$drill_sha\"}"
docker run --rm --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$RTMP/drill-sealed.tar"
[ -s "$RTMP/drill-sealed.tar" ] && tar -tf "$RTMP/drill-sealed.tar" | grep -q 'drill/06_SEALED.json' || exit 49
docker exec "$PG" dropdb -U postgres "$drill_db"; runner_contract_owned container "$DRILL" && docker rm "$DRILL" >/dev/null
[ "$(docker exec "$PG" psql -U postgres -d postgres -Atc "select count(*) from pg_database where datname='$drill_db'")" = 0 ] || exit 50
stage drill 07_AUDITED '{"state":"AUDITED","export_before_drop":true,"database_dropped":true,"cleanup_audited":true}'
docker run --rm --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - drill > "$RTMP/drill-final.tar"
docker cp "$RTMP/drill-sealed.tar" "$MONITOR:/output/drill-sealed.tar"; docker cp "$RTMP/drill-final.tar" "$MONITOR:/output/drill-final.tar"

(
  while :; do
    timestamp=$(date -u +%FT%TZ); available=$(free -b | awk '/^Mem:/{print $7}'); load1=$(awk '{print $1}' /proc/loadavg)
    stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' | sort); count=$(printf '%s\n' "$stats" | awk 'NF{n++}END{print n+0}')
    stats_sha=$(printf '%s' "$stats" | sha256sum | awk '{print $1}')
    printf '%s|%s|%s|%s|%s\n' "$timestamp" "$available" "$load1" "$count" "$stats_sha" >> "$RTMP/anonymous-pressure.log"
    sleep 15
  done
) & monitor_pid=$!

set +e
docker run --name "$RUNNER" --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network "$NET" \
  --cpus=1.5 --cpu-shares=128 --memory=3g --memory-swap=3g --blkio-weight=100 --pids-limit=256 --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /work/spec/dummy/tmp:rw,noexec,nosuid,size=32m \
  --tmpfs /work/spec/dummy/log:rw,noexec,nosuid,size=32m --cap-drop=ALL --security-opt=no-new-privileges \
  -e PGHOST="$PG" -e PGUSER=postgres -e SECRET_KEY_BASE=fixed-t086-test-secret -e TYPED_EAV_REPRESENTATIVE_OK=1 \
  -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=60s 3600s bash -lc \
  'source bench/docker/lib/runner_contract.sh; export GB_TASK=T086 GB_RUN_ID='"$RUN_ID"'; runner_contract_require_identity; runner_contract_probe_writable /output /work/spec/dummy/tmp /work/spec/dummy/log /tmp; runner_contract_probe_secret; runner_contract_probe_offline_bundle /usr/local/bundle; bundle check; bundle exec ruby bench/bulk_read_benchmark.rb --tier representative --output /output/result.json' \
  > "$RTMP/stdout" 2> "$RTMP/stderr"
runner_status=$?
set -e

stage finalizer 01_PREFLIGHT '{"state":"PREFLIGHT","atomic":true}'; stage finalizer 02_QUIESCED '{"state":"QUIESCED","new_admissions":false}'
if runner_contract_owned container "$RUNNER" && [ "$(docker inspect -f '{{.State.Running}}' "$RUNNER")" = true ]; then docker stop -t 20 "$RUNNER" >/dev/null; fi
stage finalizer 03_RUNNER_STOPPED "{\"state\":\"RUNNER_STOPPED\",\"runner_status\":$runner_status}"
docker exec "$PG" psql -U postgres -d postgres -Atc "select pg_terminate_backend(pid) from pg_stat_activity where datname like 'typed_eav_phase5_bulk_read_%'" >/dev/null
remaining=$(docker exec "$PG" psql -U postgres -d postgres -Atc "select count(*) from pg_stat_activity where datname like 'typed_eav_phase5_bulk_read_%'")
[ "$remaining" = 0 ] || exit 51
stage finalizer 04_SESSIONS_TERMINATED '{"state":"SESSIONS_TERMINATED","remaining":0}'
kill "$monitor_pid" >/dev/null 2>&1 || true; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; [ -s "$RTMP/anonymous-pressure.log" ] || exit 52
after=$(mktemp); snapshot > "$after"; invariant=false; cmp -s "$before" "$after" && invariant=true
stage finalizer 05_AFTER_INVARIANT "{\"state\":\"AFTER_INVARIANT\",\"passed\":$invariant}"
before_sha=$(sha256sum "$before" | awk '{print $1}'); after_sha=$(sha256sum "$after" | awk '{print $1}')
pressure_samples=$(wc -l < "$RTMP/anonymous-pressure.log" | tr -d ' '); pressure_sha=$(sha256sum "$RTMP/anonymous-pressure.log" | awk '{print $1}')
payload_sha=$(docker exec "$MONITOR" bash -c 'find /output -type f ! -path "*/finalizer/06_SEALED.json" -print0 | sort -z | xargs -0 sha256sum' | sha256sum | awk '{print $1}')
stage finalizer 06_SEALED "{\"state\":\"SEALED\",\"payload_sha256\":\"$payload_sha\"}"
elapsed=$(( $(date +%s) - run_started )); deadline_ok=false; [ "$elapsed" -lt 4200 ] && deadline_ok=true
accepted=false; [ "$runner_status" = 0 ] && [ "$invariant" = true ] && [ "$deadline_ok" = true ] && accepted=true
python3 -c 'import json,sys;json.dump({"schema_version":1,"initial_exact_tag_present":sys.argv[1]=="true","pre_pull_image_ids_sha256":sys.argv[2],"pull_count":int(sys.argv[3]),"repo_digest":sys.argv[4],"image_id":sys.argv[5],"ruby_version":sys.argv[6],"image_id_introduced":sys.argv[7]=="true","build_pull":False,"prune_used":False,"post_cleanup_verified":False},open(sys.argv[8],"w"),sort_keys=True)' \
  "$initial_exact_tag_present" "$pre_ids_sha" "$pull_count" "$repo_digest" "$ruby_image_id" "$ruby_version" "$image_id_introduced" "$RTMP/image-lifecycle.json"

docker run --rm --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$OUTVOL:/output" -v "$RTMP:/diag:ro" --entrypoint ruby "$IMAGE" -rjson -I/work/bench/docker/lib -rartifact_envelope -e '
path = "/output/result.json"; payload = File.exist?(path) ? JSON.parse(File.read(path), max_nesting: false) : {}
expected_drill = %w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED AUDITED]
drill_records = Dir["/output/drill/*.json"].sort.map { |file| JSON.parse(File.read(file)) }
drill_passed = drill_records.map { |record| record["state"] } == expected_drill &&
  drill_records[1]["active_sessions_before_stop"] == 1 && drill_records[3]["remaining"] == 0 &&
  drill_records[4]["passed"] == true && drill_records[5]["payload_sha256"] == ARGV[7] &&
  drill_records[6].values_at("export_before_drop", "database_dropped", "cleanup_audited").all?
safety = {"task_label"=>"T086", "work_deadline_seconds"=>3600, "hard_timeout_seconds"=>4200, "elapsed_seconds"=>ARGV[0].to_i,
  "runner_status"=>ARGV[1].to_i, "internal_network"=>true, "published_ports"=>[], "host_network"=>false, "privileged"=>false,
  "compose_used"=>false, "docker_socket_mounted"=>false, "media_binds"=>false, "restart_policy"=>"no",
  "postgres_caps"=>{"cpus"=>2, "memory_bytes"=>8589934592}, "runner_caps"=>{"cpus"=>1.5, "memory_bytes"=>3221225472},
  "writable_paths"=>{"root_read_only"=>true, "paths"=>%w[/output /work/spec/dummy/tmp /work/spec/dummy/log /tmp]},
  "existing_container_invariant"=>{"passed"=>ARGV[2]=="true", "before_sha256"=>ARGV[3], "after_sha256"=>ARGV[4]},
  "anonymous_pressure"=>{"samples"=>ARGV[5].to_i, "sha256"=>ARGV[6], "raw_identifiers_retained"=>false},
  "drill"=>{"passed"=>drill_passed, "export_before_cleanup"=>drill_records[6]["export_before_drop"] == true,
    "live_session"=>drill_records[1]["active_sessions_before_stop"] == 1, "sessions_terminated"=>drill_records[3]["remaining"] == 0,
    "stage_count"=>drill_records.length, "sealed_sha256"=>ARGV[7]},
  "finalizer"=>{"states"=>%w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED], "export_before_cleanup"=>true},
  "contract"=>{"seven_states"=>false, "accepted_rejected_exclusive"=>true, "cycle_detection"=>true}, "source_manifest_sha256"=>ARGV[8],
  "image_lifecycle"=>JSON.parse(File.read("/diag/image-lifecycle.json")), "cleanup_contract"=>"exact T086/run labels plus exact names; verified after transfer",
  "post_cleanup_verified"=>false}
payload["remote_safety"] = safety; File.write(path, JSON.pretty_generate(payload) + "\n") if ARGV[9] == "true"
envelope = TypedEAVBenchmark::ArtifactEnvelope.build(status: ARGV[9] == "true" ? "accepted" : "rejected", task: "T086", run_id: ARGV[10], payload: payload,
  diagnostics: {"stdout"=>File.read("/diag/stdout"), "stderr"=>File.read("/diag/stderr")})
TypedEAVBenchmark::ArtifactEnvelope.write!(root: "/output", envelope: envelope)
' "$elapsed" "$runner_status" "$invariant" "$before_sha" "$after_sha" "$pressure_samples" "$pressure_sha" "$drill_sha" \
  "$(sha256sum "$RTMP/source.sha256" | awk '{print $1}')" "$accepted" "$RUN_ID"
docker run --rm --label goalbuddy.task=T086 --label "goalbuddy.run=$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$OUTVOL:/output:ro" --entrypoint tar "$IMAGE" -C /output -cf - . > "$TRANSFER"
[ -s "$TRANSFER" ] || exit 53
REMOTE
remote_status=$?
set -e

scp -q -o BatchMode=yes "$REMOTE:$TRANSFER" "$LTMP/result.tar" || die "sealed result transfer failed (remote status $remote_status)"
retention=$(runner_contract_retain_transfer "$LTMP/result.tar" "$RETAINED_ROOT" "$RUN_ID") || die "transferred payload retention failed"
RETAINED_PAYLOAD=${retention%%|*}; RETAINED_SHA256=${retention##*|}
echo "T086_RETAINED path=$RETAINED_PAYLOAD sha256=$RETAINED_SHA256"
mkdir "$LTMP/out"; tar -xf "$RETAINED_PAYLOAD" -C "$LTMP/out"
ssh -o BatchMode=yes "$REMOTE" "sleep 2; test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T086 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T086 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T086 --filter label=goalbuddy.run='$RUN_ID')\"; test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T086 --filter label=goalbuddy.run='$RUN_ID')\"; test ! -e '$RTMP'; test ! -e '$RTMP.tgz'"
"$PROJECT_RUBY" -rjson -e '
root, remote = ARGV; accepted = File.join(root, "accepted.json"); rejected = File.join(root, "rejected.json")
abort "accepted/rejected exclusivity failed" unless File.exist?(accepted) ^ File.exist?(rejected)
if File.exist?(rejected); envelope = JSON.parse(File.read(rejected), max_nesting: false); warn JSON.pretty_generate(envelope.fetch("diagnostics")); abort "remote workflow rejected"; end
result = File.join(root, "result.json"); data = JSON.parse(File.read(result), max_nesting: false); lifecycle = data.dig("remote_safety", "image_lifecycle")
preexisting = lifecycle.fetch("initial_exact_tag_present"); introduced = lifecycle.fetch("image_id_introduced"); image_id = lifecycle.fetch("image_id")
tag = system("ssh", "-o", "BatchMode=yes", remote, "docker image inspect ruby:3.4.4-bookworm >/dev/null 2>&1")
id_present = system("ssh", "-o", "BatchMode=yes", remote, "docker image inspect #{image_id} >/dev/null 2>&1")
abort "image cleanup audit failed" unless preexisting ? tag && id_present : !tag && (!introduced || !id_present)
lifecycle["post_cleanup_exact_tag_present"] = tag; lifecycle["post_cleanup_image_id_present"] = id_present; lifecycle["post_cleanup_verified"] = true
safety = data.fetch("remote_safety"); safety["post_cleanup_verified"] = true
safety.fetch("finalizer").fetch("states") << "AUDITED"; safety.fetch("finalizer")["audited_after_transfer"] = true
safety.fetch("contract")["seven_states"] = safety.dig("finalizer", "states") == %w[PREFLIGHT QUIESCED RUNNER_STOPPED SESSIONS_TERMINATED AFTER_INVARIANT SEALED AUDITED]
File.write(result, JSON.pretty_generate(data) + "\n")
' "$LTMP/out" "$REMOTE"
"$PROJECT_RUBY" -rjson -rdigest -rtmpdir -e '
root = ARGV.fetch(0); expected = %w[01_PREFLIGHT 02_QUIESCED 03_RUNNER_STOPPED 04_SESSIONS_TERMINATED 05_AFTER_INVARIANT 06_SEALED 07_AUDITED]
Dir.mktmpdir("t086-drill-") do |tmp|
  system("tar", "-xf", File.join(root, "drill-final.tar"), "-C", tmp) or abort "drill extraction failed"
  files = Dir[File.join(tmp, "drill", "*.json")].sort; abort "drill stages missing" unless files.map { |path| File.basename(path, ".json") } == expected
  states = files.map { |path| JSON.parse(File.read(path)).fetch("state") }; abort "drill state order" unless states == expected.map { |name| name.sub(/^\d+_/, "") }
  material = files.first(5).map { |file| "#{File.basename(file)}\0#{Digest::SHA256.file(file).hexdigest}" }.join
  sealed = JSON.parse(File.read(files.fetch(5))); abort "drill seal mismatch" unless sealed["payload_sha256"] == Digest::SHA256.hexdigest(material)
  audit = JSON.parse(File.read(files.last)); abort "drill cleanup proof" unless audit.values_at("export_before_drop", "database_dropped", "cleanup_audited").all?
end
Dir.mktmpdir("t086-sealed-") do |tmp|
  system("tar", "-xf", File.join(root, "drill-sealed.tar"), "-C", tmp) or abort "sealed drill extraction failed"
  sealed_files = Dir[File.join(tmp, "drill", "*.json")].sort
  abort "sealed drill stage count" unless sealed_files.map { |path| File.basename(path, ".json") } == expected.first(6)
end
puts "T086_DRILL transferred_stages=7 export_before_drop=true"
' "$LTMP/out"
[ "$remote_status" = 0 ] || die "remote shell failed after exporting diagnostics"
"$PROJECT_RUBY" "$ROOT/bench/validate_bulk_read_artifact.rb" "$LTMP/out/result.json"
mkdir -p "$(dirname "$OUT")"; cp "$LTMP/out/result.json" "$OUT"
PUBLISHED=true
echo "T086 representative artifact: $OUT"
