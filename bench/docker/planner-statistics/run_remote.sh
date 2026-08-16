#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t051-$(date -u +%Y%m%dt%H%M%Sz)-$$"
NET="$RUN_ID-net"; VOL="$RUN_ID-pgdata"; OUTVOL="$RUN_ID-output"; PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; DIAG="$RUN_ID-diagnostic"; IMAGE="$RUN_ID:runner"
REMOTE_TMP="/tmp/$RUN_ID"; RESULT_REMOTE="$REMOTE_TMP.result.json"
OUT="$ROOT_DIR/bench/results/phase-4-planner-statistics-representative.json"
TMP_ROOT=/private/tmp; [ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp

die(){ echo "run_remote.sh: $*" >&2; exit 1; }
cleanup_local(){ case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t051-*|/tmp/typed-eav-t051-*) rm -rf -- "$LOCAL_TMP";; esac; ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "case '$RESULT_REMOTE' in /tmp/t051-*.result.json) rm -f -- '$RESULT_REMOTE';; esac" >/dev/null 2>&1 || true; }
trap cleanup_local EXIT
for command in ssh scp tar shasum; do command -v "$command" >/dev/null || die "$command required"; done
[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = 14c1e122b24e78e5c08dad2338021822b4c5d299 ] || die "source must start at exact 14c1e12"

ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' <<'PREFLIGHT'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}'); before=$(mktemp); now=""; trap 'rm -f -- "$before" "$now"' EXIT
snapshot(){ for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"
for sample in 1 2 3; do
  mem=$(free -b | awk '/^Mem:/{print $7}'); disk=$(df -Pk "$root" | tail -1 | awk '{print $4*1024}'); echo "T051_PREFLIGHT sample=$sample available=$mem docker_free=$disk"
  awk -v m="$mem" -v d="$disk" 'BEGIN{exit !(m>=17179869184&&d>=32212254720)}' || exit 42
  now=$(mktemp); snapshot > "$now"; cmp -s "$before" "$now" || exit 43; rm -f "$now"; now=""; [ "$sample" = 3 ] || sleep 5
done
PREFLIGHT

LOCAL_TMP=$(mktemp -d "$TMP_ROOT/typed-eav-t051-$RUN_ID.XXXXXX"); STAGE="$LOCAL_TMP/source"; mkdir "$STAGE"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE"
for path in bench/README.md bench/planner_statistics_benchmark.rb bench/docker/planner-statistics/run_remote.sh docs/improvement-program.md; do mkdir -p "$STAGE/$(dirname "$path")"; cp "$ROOT_DIR/$path" "$STAGE/$path"; done
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LOCAL_TMP/source-manifest.sha256"; cp "$LOCAL_TMP/source-manifest.sha256" "$STAGE/source-manifest.sha256"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$LOCAL_TMP/source.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$REMOTE_TMP' && test ! -e '$REMOTE_TMP.tgz' && test ! -e '$RESULT_REMOTE'"
scp -q -o BatchMode=yes "$LOCAL_TMP/source.tgz" "$REMOTE:$REMOTE_TMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' VOL='$VOL' OUTVOL='$OUTVOL' PG='$PG' RUNNER='$RUNNER' DIAG='$DIAG' IMAGE='$IMAGE' REMOTE_TMP='$REMOTE_TMP' RESULT_REMOTE='$RESULT_REMOTE' bash -s" <<'REMOTE'
set -euo pipefail
case "$REMOTE_TMP" in /tmp/t051-*) ;; *) exit 45;; esac
monitor_pid=""; before=""; after=""
owned(){ case "$1" in container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);; network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);; esac; python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T051" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; }
cleanup(){ set +e; [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true; for c in "$DIAG" "$RUNNER" "$PG"; do owned container "$c" && docker rm -f "$c" >/dev/null 2>&1 || true; done; owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true; owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true; for v in "$OUTVOL" "$VOL"; do owned volume "$v" && docker volume rm "$v" >/dev/null 2>&1 || true; done; rm -f -- "$before" "$after"; case "$REMOTE_TMP" in /tmp/t051-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz";; esac; }
trap cleanup EXIT
mkdir "$REMOTE_TMP"; tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"; (cd "$REMOTE_TMP" && shasum -a 256 -c source-manifest.sha256 >/dev/null)
docker network create --internal --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
before=$(mktemp)
snapshot(){ for id in $(docker ps -aq); do labels=$(docker inspect -f '{{json .Config.Labels}}' "$id"); if python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T051" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; then continue; fi; docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"
docker volume create --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" "$VOL" >/dev/null
docker volume create --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" "$OUTVOL" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=256 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=1g -e POSTGRES_HOST_AUTH_METHOD=trust -v "$VOL:/var/lib/postgresql/data" postgres:17 >/dev/null
ready=0; for wait in $(seq 1 150); do if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi; [ "$(docker inspect -f '{{.State.Status}}' "$PG")" = running ] || break; sleep 2; done
[ "$ready" = 1 ] || { docker logs "$PG" >&2; exit 46; }
docker build --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$REMOTE_TMP" <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
RUN gem install pg -v 1.6.3 --no-document
WORKDIR /work
COPY . .
DOCKERFILE

# Minimal T051-owned output diagnostic. Files are closed via atomic rename, hashed,
# then the done marker is written last. Transfer is an explicit tar stream, not
# docker cp, and the diagnostic stays in the owned output volume until cleanup.
docker run -d --name "$DIAG" --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=.25 --memory=256m --memory-swap=256m --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=64 -v "$OUTVOL:/output" --entrypoint bash "$IMAGE" -lc 'set -e; mkdir -p /output/diagnostic; printf "t051-output-transfer\n" > /output/diagnostic/payload.tmp; mv /output/diagnostic/payload.tmp /output/diagnostic/payload.txt; (cd /output && sha256sum diagnostic/payload.txt > diagnostic/sha256.tmp); mv /output/diagnostic/sha256.tmp /output/diagnostic/sha256; find /output/diagnostic -maxdepth 1 -type f -printf "%f|%s\n" | sort > /output/diagnostic/listing.tmp; mv /output/diagnostic/listing.tmp /output/diagnostic/listing; date -u +%FT%TZ > /output/diagnostic/done-order.tmp; mv /output/diagnostic/done-order.tmp /output/diagnostic/done; while [ ! -e /output/diagnostic/stop ]; do sleep 1; done'
for wait in $(seq 1 60); do docker exec "$DIAG" test -e /output/diagnostic/done && break; sleep 1; done
docker exec "$DIAG" test -s /output/diagnostic/payload.txt
docker exec "$DIAG" test -s /output/diagnostic/sha256
docker exec "$DIAG" tar -C /output -cf - diagnostic > "$REMOTE_TMP/diagnostic.tar"
mkdir "$REMOTE_TMP/diagnostic-transfer"; tar -xf "$REMOTE_TMP/diagnostic.tar" -C "$REMOTE_TMP/diagnostic-transfer"
(cd "$REMOTE_TMP/diagnostic-transfer" && sha256sum -c diagnostic/sha256)
cp "$REMOTE_TMP/diagnostic-transfer/diagnostic/listing" "$REMOTE_TMP/diagnostic-listing"
cp "$REMOTE_TMP/diagnostic-transfer/diagnostic/sha256" "$REMOTE_TMP/diagnostic-sha256"
cp "$REMOTE_TMP/diagnostic-transfer/diagnostic/done" "$REMOTE_TMP/diagnostic-done-order"
docker exec "$DIAG" touch /output/diagnostic/stop; docker rm -f "$DIAG" >/dev/null

docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}' > "$REMOTE_TMP/contention-before"
(while :; do printf '%s|' "$(date -u +%FT%TZ)" >> "$REMOTE_TMP/telemetry"; awk '/^cpu /{print}' /proc/stat | head -1 >> "$REMOTE_TMP/telemetry"; sleep 10; done) & monitor_pid=$!
docker run -d --name "$RUNNER" --label goalbuddy.task=T051 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1 --cpu-shares=128 --blkio-weight=100 --memory=2g --memory-swap=2g --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --tmpfs /tmp:rw,noexec,nosuid,size=1g -v "$VOL:/var/lib/postgresql/data:ro" -v "$OUTVOL:/run/t051-output" -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_REPRESENTATIVE_OK=1 -e TYPED_EAV_REPRESENTATIVE_ENTITIES=300000 --entrypoint bash "$IMAGE" -lc 'set -e; for trial in $(seq 1 10); do case "$trial" in 1) order=baseline,dependencies,dependencies_mcv_ndistinct,mcv,ndistinct;; 2) order=dependencies,mcv,baseline,ndistinct,dependencies_mcv_ndistinct;; 3) order=mcv,ndistinct,dependencies,dependencies_mcv_ndistinct,baseline;; 4) order=ndistinct,dependencies_mcv_ndistinct,mcv,baseline,dependencies;; 5) order=dependencies_mcv_ndistinct,baseline,ndistinct,dependencies,mcv;; 6) order=ndistinct,mcv,dependencies_mcv_ndistinct,dependencies,baseline;; 7) order=dependencies_mcv_ndistinct,ndistinct,baseline,mcv,dependencies;; 8) order=baseline,dependencies_mcv_ndistinct,dependencies,ndistinct,mcv;; 9) order=dependencies,baseline,mcv,dependencies_mcv_ndistinct,ndistinct;; 10) order=mcv,dependencies,ndistinct,baseline,dependencies_mcv_ndistinct;; esac; temp="/run/t051-output/trial-$trial.json.tmp"; final="/run/t051-output/trial-$trial.json"; TYPED_EAV_TRIAL="$trial" TYPED_EAV_CANDIDATE_ORDER="$order" ruby bench/planner_statistics_benchmark.rb --tier representative --seed 4601 --output "$temp"; test -s "$temp"; mv "$temp" "$final"; done; ruby bench/planner_statistics_benchmark.rb aggregate /run/t051-output/combined.json.tmp /run/t051-output/trial-{1..10}.json; test -s /run/t051-output/combined.json.tmp; mv /run/t051-output/combined.json.tmp /run/t051-output/combined.json; (cd /run/t051-output && sha256sum trial-*.json combined.json > trials.sha256.tmp); mv /run/t051-output/trials.sha256.tmp /run/t051-output/trials.sha256; find /run/t051-output -maxdepth 1 -name "trial-*.json" -type f -printf "%f|%s\n" | sort > /run/t051-output/trials.listing.tmp; mv /run/t051-output/trials.listing.tmp /run/t051-output/trials.listing; date -u +%FT%TZ > /run/t051-output/done-order.tmp; mv /run/t051-output/done-order.tmp /run/t051-output/done; while [ ! -e /run/t051-output/stop ]; do sleep 2; done'
started=$(date +%s)
for wait in $(seq 1 14400); do docker exec "$RUNNER" test -e /run/t051-output/done && break; [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" = running ] || { docker logs "$RUNNER" >&2; exit 47; }; [ $(($(date +%s)-started)) -lt 28800 ] || exit 51; sleep 2; done
docker exec "$RUNNER" test -s /run/t051-output/done || exit 48
docker exec "$RUNNER" test -s /run/t051-output/trials.sha256
docker exec "$RUNNER" test -s /run/t051-output/combined.json
docker exec "$RUNNER" sh -c 'test "$(find /run/t051-output -maxdepth 1 -name "trial-*.json" -type f | wc -l)" -eq 10'
docker exec "$RUNNER" tar -C /run/t051-output -cf - trial-1.json trial-2.json trial-3.json trial-4.json trial-5.json trial-6.json trial-7.json trial-8.json trial-9.json trial-10.json combined.json trials.sha256 trials.listing done > "$REMOTE_TMP/trials.tar"
mkdir "$REMOTE_TMP/trial-transfer"; tar -xf "$REMOTE_TMP/trials.tar" -C "$REMOTE_TMP/trial-transfer"
(cd "$REMOTE_TMP/trial-transfer" && sha256sum -c trials.sha256)
docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}' > "$REMOTE_TMP/contention-after"
cp "$REMOTE_TMP/trial-transfer/combined.json" "$REMOTE_TMP/combined.json"
python3 - "$REMOTE_TMP" "$RUN_ID" <<'PY'
import json,sys,hashlib
d,run=sys.argv[1:]; path=f'{d}/combined.json'; result=json.load(open(path))
result['task']='T051'; result['run_id']=run
result['remote_execution']={'postgres_performance_major':17,'performance_generalization':'PostgreSQL 17 only','co_tenant_timing':'absolute timing diagnostic','resource_caps':{'postgres':'2 CPU, 8 GiB','runner':'1 CPU, 2 GiB'},'output_transfer':{'mechanism':'closed files on owned output volume, explicit tar stream, SHA-256 verification','diagnostic_listing':open(f'{d}/diagnostic-listing').read().strip(),'diagnostic_sha256':open(f'{d}/diagnostic-sha256').read().strip(),'diagnostic_done_order':open(f'{d}/diagnostic-done-order').read().strip(),'trial_listing':open(f'{d}/trial-transfer/trials.listing').read().strip(),'trial_sha256':open(f'{d}/trial-transfer/trials.sha256').read().strip(),'trial_done_order':open(f'{d}/trial-transfer/done').read().strip()},'contention_before':open(f'{d}/contention-before').read().strip(),'contention_after':open(f'{d}/contention-after').read().strip(),'telemetry_samples':sum(1 for _ in open(f'{d}/telemetry')),'existing_container_invariant':'pending','source_manifest_sha256':hashlib.sha256(open(f'{d}/source-manifest.sha256','rb').read()).hexdigest(),'cleanup_pending_transfer':True}
json.dump(result,open(path,'w'),indent=2); open(path,'a').write('\n')
PY
docker exec "$RUNNER" touch /run/t051-output/stop
docker rm -f "$RUNNER" >/dev/null; docker rm -f "$PG" >/dev/null; docker image rm "$IMAGE" >/dev/null; docker network rm "$NET" >/dev/null; docker volume rm "$OUTVOL" >/dev/null; docker volume rm "$VOL" >/dev/null
after=$(mktemp); snapshot > "$after"; cmp -s "$before" "$after" || exit 49
left=$(docker ps -aq --filter label=goalbuddy.task=T051 --filter "label=goalbuddy.run=$RUN_ID"; docker network ls -q --filter label=goalbuddy.task=T051 --filter "label=goalbuddy.run=$RUN_ID"; docker volume ls -q --filter label=goalbuddy.task=T051 --filter "label=goalbuddy.run=$RUN_ID")
[ -z "$left" ] || exit 50
python3 - "$REMOTE_TMP/combined.json" "$RESULT_REMOTE" <<'PY'
import json,sys
p,o=sys.argv[1:]; d=json.load(open(p)); d['remote_execution']['existing_container_invariant']='pass'; d['remote_execution']['cleanup_pending_transfer']=False; d['remote_execution']['post_cleanup_verified']=True
json.dump(d,open(o,'w'),indent=2); open(o,'a').write('\n')
PY
REMOTE

scp -q -o BatchMode=yes "$REMOTE:$RESULT_REMOTE" "$OUT"
ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); m=d.fetch("mechanical_validation"); abort unless m.fetch("accepted") && m.fetch("eleven_hundred_raw_plans") && d.dig("remote_execution","post_cleanup_verified") && d.fetch("trials").size==10' "$OUT"
echo "T051 representative artifact: $OUT"
