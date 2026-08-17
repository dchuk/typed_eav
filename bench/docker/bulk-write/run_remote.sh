#!/usr/bin/env bash
set -euo pipefail

# T091 representative runner. T086 owns the cancellation drill; this runner
# performs no live drill and records a rejected envelope on any gate failure.
ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t091-$(date -u +%Y%m%dt%H%M%sz)-$$"
NET="$RUN_ID-net"; PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"
EXPORTER="$RUN_ID-exporter"; IMAGE="$RUN_ID:runner"; PGVOL="$RUN_ID-pg"; OUTVOL="$RUN_ID-out"
RTMP="/tmp/$RUN_ID"; OUT="$ROOT/bench/results/phase-6-bulk-write-representative.json"
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
(cd "$LTMP/src" && find . -type f ! -name source.sha256 -print0 | sort -z | xargs -0 shasum -a 256) > "$LTMP/src/source.sha256"
COPYFILE_DISABLE=1 tar -C "$LTMP/src" -czf "$LTMP/src.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$RTMP' && test ! -e '$RTMP.tgz'"
scp -q -o BatchMode=yes "$LTMP/src.tgz" "$REMOTE:$RTMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' PG='$PG' RUNNER='$RUNNER' EXPORTER='$EXPORTER' IMAGE='$IMAGE' PGVOL='$PGVOL' OUTVOL='$OUTVOL' RTMP='$RTMP' bash -s" <<'REMOTE'
set -u
cd /tmp
mkdir -p "$RTMP"
tar -xzf "$RTMP.tgz" -C "$RTMP"
cd "$RTMP"
# shellcheck source=bench/docker/lib/runner_contract.sh
source bench/docker/lib/runner_contract.sh
export GB_TASK=T091 GB_RUN_ID="$RUN_ID"
gate_status=0
runner_contract_require_identity || gate_status=41

snapshot() { runner_contract_snapshot; }
snapshot_hash() { snapshot | sha256sum | awk '{print $1}'; }
before=$(mktemp); snapshot > "$before"; before_hash=$(sha256sum "$before" | awk '{print $1}')
run_started=$(date +%s); runner_status=90
initial_tag=false; tag_introduced=false; image_id_introduced=false; base_id_preexisting=false; base_id=""; base_digest=""; base_version=""
mkdir -p "$RTMP/export"

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

pg_target=$(runner_contract_pg_target 17 2>/dev/null) || gate_status=47
if [ "$gate_status" = 0 ]; then
  docker network create --internal --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$NET" >/dev/null || gate_status=46
  docker volume create --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$PGVOL" >/dev/null || gate_status=47
  docker volume create --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" "$OUTVOL" >/dev/null || gate_status=48
fi

cleanup() {
  set +e
  runner_contract_owned container "$RUNNER" && docker rm -f "$RUNNER" >/dev/null
  runner_contract_owned container "$EXPORTER" && docker rm -f "$EXPORTER" >/dev/null
  runner_contract_owned container "$PG" && docker rm -f "$PG" >/dev/null
  runner_contract_owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null
  runner_contract_owned network "$NET" && docker network rm "$NET" >/dev/null
  runner_contract_owned volume "$PGVOL" && docker volume rm "$PGVOL" >/dev/null
  runner_contract_owned volume "$OUTVOL" && docker volume rm "$OUTVOL" >/dev/null
  if [ "$tag_introduced" = true ] && [ "$initial_tag" = false ]; then docker image rm ruby:3.4.4-bookworm >/dev/null 2>&1 || true; fi
}

if [ "$gate_status" = 0 ]; then
  docker run -d --name "$PG" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network "$NET" --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PGVOL:$pg_target" postgres:17 >/dev/null || gate_status=48
  ready=false
  for _ in $(seq 1 150); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && ready=true && break; sleep 2; done
  [ "$ready" = true ] || gate_status=49
fi
if [ "$gate_status" = 0 ]; then
  docker build --pull=false --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" -t "$IMAGE" -f - "$RTMP" <<'DOCKERFILE' || gate_status=50
FROM ruby:3.4.4-bookworm
WORKDIR /work
COPY . .
RUN bundle install --jobs=4 --retry=3
DOCKERFILE
fi

if [ "$gate_status" = 0 ]; then
  set +e
  docker run --name "$RUNNER" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network "$NET" --cpus=1.5 --memory=3g --memory-swap=3g --pids-limit=256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /work/spec/dummy/tmp:rw,noexec,nosuid,size=32m --tmpfs /work/spec/dummy/log:rw,noexec,nosuid,size=32m --cap-drop=ALL --security-opt=no-new-privileges -e PGHOST="$PG" -e PGUSER=postgres -e SECRET_KEY_BASE=t091-secret -v "$OUTVOL:/output" "$IMAGE" timeout --signal=TERM --kill-after=120s 5400s bash -lc 'bundle exec ruby bench/bulk_write_benchmark.rb --tier representative --output /output/result.json && bundle exec ruby bench/validate_bulk_write_artifact.rb /output/result.json' > "$RTMP/stdout" 2> "$RTMP/stderr"
  runner_status=$?; set -u
fi

# Export every available result/diagnostic before deleting any owned volume.
set +e
docker run --name "$EXPORTER" --label goalbuddy.task=T091 --label goalbuddy.run="$RUN_ID" --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges -v "$OUTVOL:/output:ro" -v "$RTMP/export:/export" --entrypoint tar "$IMAGE" -C /output -cf /export/output.tar .
export_status=$?
set -u
cp "$RTMP/source.sha256" "$RTMP/export/source.sha256"
cp "$RTMP/stdout" "$RTMP/export/stdout" 2>/dev/null || :; cp "$RTMP/stderr" "$RTMP/export/stderr" 2>/dev/null || :
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
if [ "$initial_tag" = true ] && [ "$base_id_preexisting" = true ]; then
  [ "$(docker image inspect -f '{{.Id}}' ruby:3.4.4-bookworm 2>/dev/null || true)" = "$base_id" ] && base_restored=true
else
  ! docker image inspect "$base_id" >/dev/null 2>&1 && base_restored=true
fi
elapsed=$(( $(date +%s) - run_started )); deadline_ok=false; [ "$elapsed" -le 6300 ] && deadline_ok=true
zero_exact_names=true
for exact_name in "$NET" "$PGVOL" "$OUTVOL" "$IMAGE"; do
  [ -z "$(docker network ls -q --filter "name=^${exact_name}$"; docker volume ls -q --filter "name=^${exact_name}$"; docker image ls -q --filter "reference=${exact_name}")" ] || zero_exact_names=false
done
python3 - "$RTMP/export/safety.json" "$runner_status" "$export_status" "$gate_status" "$elapsed" "$before_hash" "$after_hash" "$zero_labels" "$zero_names" "$zero_exact_names" "$base_restored" "$base_id_preexisting" "$deadline_ok" "$initial_tag" "$tag_introduced" "$image_id_introduced" "$base_id" "$base_digest" "$base_version" <<'PY'
import json
import sys
def b(value): return value == "true"
_, path, runner, export, gate, elapsed, before, after, labels, names, exact, restored, preexisting, deadline, initial, tag, image, image_id, digest, version = sys.argv
json.dump({"task":"T091","runner_status":int(runner),"export_status":int(export),"gate_status":int(gate),"work_deadline_seconds":5400,"total_deadline_seconds":6300,"elapsed_seconds":int(elapsed),"pre_snapshot_sha256":before,"post_snapshot_sha256":after,"zero_owned_resources":b(labels),"zero_owned_names":b(names),"zero_exact_names":b(exact),"base_restored":b(restored),"base_id_preexisting":b(preexisting),"deadline_ok":b(deadline),"post_cleanup_verified":b(labels) and b(names) and b(exact) and b(restored) and b(deadline) and before == after,"base_image":{"initial_exact_tag_present":b(initial),"tag_introduced":b(tag),"image_id":"%s"%image_id,"repo_digest":"%s"%digest,"ruby_version":"%s"%version,"image_id_introduced":b(image),"prune_used":False},"preflight_samples":3,"caps":{"postgres_cpus":2,"postgres_memory_bytes":8589934592,"runner_cpus":1.5,"runner_memory_bytes":3221225472},"internal_network":True,"published_ports":[],"host_network":False,"privileged":False,"restart_policy":"no","media_mounts":False},open(path,"w"),sort_keys=True)
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
"$PROJECT_RUBY" -rjson -rdigest -I"$ROOT/bench/docker/lib" -rartifact_envelope -e 'root,run,sha,ok=ARGV; raw=File.exist?(ARGV[0]+"/../raw.json") ? JSON.parse(File.read(ARGV[0]+"/../raw.json")) : {}; safety=JSON.parse(File.read(root+"/safety.json")); accepted=(ok=="true") && safety["runner_status"]==0 && safety["gate_status"]==0 && safety["export_status"]==0 && safety["post_cleanup_verified"] && safety["remote_temp_removed"]; payload=raw.merge("remote_safety"=>safety); diag={"retained_sha256"=>sha,"remote_temp_removed"=>safety["remote_temp_removed"],"stdout"=>File.read(root+"/stdout"),"stderr"=>File.read(root+"/stderr"),"validator_stdout"=>(File.exist?(root+"/../validator.stdout") ? File.read(root+"/../validator.stdout") : ""),"validator_stderr"=>(File.exist?(root+"/../validator.stderr") ? File.read(root+"/../validator.stderr") : "")}; TypedEAVBenchmark::ArtifactEnvelope.write!(root: root, envelope: TypedEAVBenchmark::ArtifactEnvelope.build(status: accepted ? "accepted" : "rejected", task: "T091", run_id: run, payload: payload, diagnostics: diag))' "$LTMP/out" "$RUN_ID" "$retained_sha" "$validator_ok"
if [ -f "$LTMP/out/accepted.json" ]; then
  final_tmp="$RETAINED_ROOT/$RUN_ID-final.tar.tmp-$$"; final_tar="$RETAINED_ROOT/$RUN_ID-final.tar"; mkdir -p "$RETAINED_ROOT"; tar -C "$LTMP" -cf "$final_tmp" raw.json out; mv "$final_tmp" "$final_tar"; sha256sum "$final_tar" > "$final_tar.sha256"
  cp "$LTMP/raw.json" "$OUT"
else
  final_tmp="$RETAINED_ROOT/$RUN_ID-final.tar.tmp-$$"; final_tar="$RETAINED_ROOT/$RUN_ID-final.tar"; mkdir -p "$RETAINED_ROOT"; tar -C "$LTMP" -cf "$final_tmp" raw.json out; mv "$final_tmp" "$final_tar"; sha256sum "$final_tar" > "$final_tar.sha256"
  echo "T091: representative rejected; retained diagnostics: $final_tar" >&2
  exit 1
fi
