#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t043-$(date -u +%Y%m%dt%H%M%Sz)-$$"
NET="$RUN_ID-net"; VOL="$RUN_ID-pgdata"; PG="$RUN_ID-postgres"; RUNNER="$RUN_ID-runner"; IMAGE="$RUN_ID:runner"
REMOTE_TMP="/tmp/$RUN_ID"; RESULT_REMOTE="$REMOTE_TMP.result.json"
OUT="$ROOT_DIR/bench/results/phase-3-string-search-representative.json"
TMP_ROOT=/private/tmp; [ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp

die(){ echo "run_remote.sh: $*" >&2; exit 1; }
cleanup_local(){ case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t043-*|/tmp/typed-eav-t043-*) rm -rf -- "$LOCAL_TMP";; esac; ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "case '$RESULT_REMOTE' in /tmp/t043-*.result.json) rm -f -- '$RESULT_REMOTE';; esac" >/dev/null 2>&1 || true; }
trap cleanup_local EXIT
for command in ssh scp tar shasum; do command -v "$command" >/dev/null || die "$command required"; done
[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = da4cd1cfcc2ac5520653bd7c9f42bb01e3566d0e ] || die "source must start at exact da4cd1c"

ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' <<'PREFLIGHT'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}'); before=$(mktemp); now=""; trap 'rm -f -- "$before" "$now"' EXIT
snapshot(){ for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"
for sample in 1 2 3; do
  mem=$(free -b | awk '/^Mem:/{print $7}'); disk=$(df -Pk "$root" | tail -1 | awk '{print $4*1024}'); echo "T043_PREFLIGHT sample=$sample available=$mem docker_free=$disk"
  awk -v m="$mem" -v d="$disk" 'BEGIN{exit !(m>=17179869184&&d>=32212254720)}' || exit 42
  now=$(mktemp); snapshot > "$now"; cmp -s "$before" "$now" || exit 43; rm -f "$now"; now=""; [ "$sample" = 3 ] || sleep 5
done
PREFLIGHT

LOCAL_TMP=$(mktemp -d "$TMP_ROOT/typed-eav-t043-$RUN_ID.XXXXXX"); STAGE="$LOCAL_TMP/source"; mkdir "$STAGE"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE"
for path in bench/README.md bench/string_search_benchmark.rb bench/docker/string-search/run_remote.sh docs/improvement-program.md; do mkdir -p "$STAGE/$(dirname "$path")"; cp "$ROOT_DIR/$path" "$STAGE/$path"; done
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LOCAL_TMP/source-manifest.sha256"; cp "$LOCAL_TMP/source-manifest.sha256" "$STAGE/source-manifest.sha256"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$LOCAL_TMP/source.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '$REMOTE_TMP' && test ! -e '$REMOTE_TMP.tgz' && test ! -e '$RESULT_REMOTE'"
scp -q -o BatchMode=yes "$LOCAL_TMP/source.tgz" "$REMOTE:$REMOTE_TMP.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='$RUN_ID' NET='$NET' VOL='$VOL' PG='$PG' RUNNER='$RUNNER' IMAGE='$IMAGE' REMOTE_TMP='$REMOTE_TMP' RESULT_REMOTE='$RESULT_REMOTE' bash -s" <<'REMOTE'
set -euo pipefail
case "$REMOTE_TMP" in /tmp/t043-*) ;; *) exit 45;; esac
root=$(docker info --format '{{.DockerRootDir}}'); COMPAT=""; COMPAT_VOLS=""; monitor_pid=""
owned(){ case "$1" in container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);; network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);; esac; python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T043" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; }
cleanup(){ set +e; [ -z "$monitor_pid" ] || kill "$monitor_pid" >/dev/null 2>&1 || true; for c in "$RUNNER" "$PG" $COMPAT; do owned container "$c" && docker rm -f "$c" >/dev/null 2>&1 || true; done; owned image "$IMAGE" && docker image rm "$IMAGE" >/dev/null 2>&1 || true; owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true; for v in "$VOL" $COMPAT_VOLS; do owned volume "$v" && docker volume rm "$v" >/dev/null 2>&1 || true; done; rm -f -- "${before:-}" "${after:-}"; case "$REMOTE_TMP" in /tmp/t043-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz";; esac; }
trap cleanup EXIT
mkdir "$REMOTE_TMP"; tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"; (cd "$REMOTE_TMP" && shasum -a 256 -c source-manifest.sha256 >/dev/null)
docker network create --internal --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
before=$(mktemp)
snapshot(){ for id in $(docker ps -aq); do labels=$(docker inspect -f '{{json .Config.Labels}}' "$id"); if python3 -c 'import json,sys;d=json.loads(sys.argv[1] or "{}");raise SystemExit(0 if d.get("goalbuddy.task")=="T043" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"; then continue; fi; docker inspect "$id" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0];s=d["State"];print("%s|%s|%s|%s"%(d["Id"],s["Status"],s.get("Health",{}).get("Status","none"),d.get("RestartCount",0)))'; done | sort; }
snapshot > "$before"; : > "$REMOTE_TMP/compatibility.ndjson"

# Compatibility gates run first. Logs survive in the owned temp directory until
# final success/failure and are embedded in the accepted artifact.
for version in 15 16 18; do
  name="$RUN_ID-pg$version"; volume="$RUN_ID-pg$version-data"; COMPAT="$COMPAT $name"; COMPAT_VOLS="$COMPAT_VOLS $volume"
  target=/var/lib/postgresql/data; [ "$version" = 18 ] && target=/var/lib/postgresql
  docker volume create --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" "$volume" >/dev/null
  docker run -d --name "$name" --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1 --cpu-shares=128 --blkio-weight=100 --memory=2g --memory-swap=2g --shm-size=128m -e POSTGRES_HOST_AUTH_METHOD=trust -v "$volume:$target" "postgres:$version" >/dev/null
  ready=0
  for wait in $(seq 1 150); do if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi; [ "$(docker inspect -f '{{.State.Status}}' "$name")" = running ] || break; sleep 2; done
  docker logs "$name" > "$REMOTE_TMP/postgres-$version-startup.log" 2>&1 || true
  if [ "$ready" != 1 ]; then echo "T043 lifecycle timeout PostgreSQL $version" >&2; tail -n 50 "$REMOTE_TMP/postgres-$version-startup.log" >&2; exit 46; fi
  docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE t043_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" -c "CREATE DATABASE t043_extension OWNER t043_owner" >/dev/null
  flags=$(docker exec "$name" psql -U postgres -Atqc "SELECT rolsuper||','||rolcreatedb||','||rolcreaterole||','||rolreplication FROM pg_roles WHERE rolname='t043_owner'")
  available=$(docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -Atqc "SELECT default_version FROM pg_available_extensions WHERE name='pg_trgm'")
  docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trgm' -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm' -c 'ALTER EXTENSION pg_trgm UPDATE' >/dev/null
  installed=$(docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_trgm'")
  docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -v ON_ERROR_STOP=1 -c 'DROP EXTENSION pg_trgm' >/dev/null
  dropped=$(docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -Atqc "SELECT count(*) FROM pg_extension WHERE extname='pg_trgm'")
  docker exec "$name" psql -h 127.0.0.1 -U t043_owner -d t043_extension -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trgm' -c 'DROP EXTENSION pg_trgm' >/dev/null
  logsum=$(sha256sum "$REMOTE_TMP/postgres-$version-startup.log" | awk '{print $1}')
  python3 -c 'import json,sys;print(json.dumps({"postgres_major":int(sys.argv[1]),"role_flags":sys.argv[2],"available_version":sys.argv[3],"installed_version":sys.argv[4],"idempotent_create":True,"update_succeeded":True,"drop_count":int(sys.argv[5]),"recreate_drop_succeeded":True,"startup_log_sha256":sys.argv[6],"startup_log":open(sys.argv[7]).read()}))' "$version" "$flags" "$available" "$installed" "$dropped" "$logsum" "$REMOTE_TMP/postgres-$version-startup.log" >> "$REMOTE_TMP/compatibility.ndjson"
  docker rm -f "$name" >/dev/null; docker volume rm "$volume" >/dev/null
done
COMPAT=""; COMPAT_VOLS=""

docker volume create --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" "$VOL" >/dev/null
docker buildx build --load --resource memory=2g --resource cpu-quota=100000 --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" -t "$IMAGE" -f - "$REMOTE_TMP" >/dev/null <<'DOCKERFILE'
FROM ruby:3.4.4-bookworm
RUN apt-get update && apt-get install --no-install-recommends -y build-essential libpq-dev && rm -rf /var/lib/apt/lists/* && gem install pg -v 1.6.3 --no-document
WORKDIR /workspace
COPY . /workspace
ENTRYPOINT ["ruby","bench/string_search_benchmark.rb"]
DOCKERFILE
docker run -d --name "$PG" --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=256 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=256m --health-cmd='pg_isready -U postgres' --health-interval=2s --health-timeout=2s --health-retries=60 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$VOL:/var/lib/postgresql/data" postgres:17 >/dev/null
for wait in $(seq 1 120); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$PG")" = healthy ] && break; [ "$wait" = 120 ] && exit 46; sleep 2; done
stats(){ docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' | awk -v pg="$PG" -v runner="$RUNNER" '$1!=pg&&$1!=runner{gsub(/%/,"",$2);gsub(/%/,"",$3);cpu+=$2;mem+=$3}END{printf "cpu_percent=%.3f mem_percent=%.3f",cpu,mem}'; }
stats > "$REMOTE_TMP/contention-before"; abort_file="$REMOTE_TMP/abort"
monitor(){ high=0; while [ ! -e "$REMOTE_TMP/runner_done" ]; do mem=$(free -b|awk '/^Mem:/{print $7}'); disk=$(df -Pk "$root"|tail -1|awk '{print $4*1024}'); io=$(vmstat 1 2|tail -1|awk '{print $16+0}'); echo "$(date -u +%FT%TZ) iowait=$io available=$mem docker_free=$disk $(stats)" >> "$REMOTE_TMP/telemetry"; current=$(mktemp); snapshot > "$current"; cmp -s "$before" "$current" || { rm -f "$current"; echo invariant > "$abort_file"; return; }; rm -f "$current"; if awk -v x="$io" 'BEGIN{exit !(x<=25)}';then high=0;else high=$((high+1));fi; awk -v m="$mem" -v d="$disk" 'BEGIN{exit !(m>=12884901888&&d>=21474836480)}' || { echo headroom > "$abort_file";return;}; [ "$high" -lt 2 ] || { echo iowait > "$abort_file";return;}; sleep 15; done; }
monitor & monitor_pid=$!
docker run -d --name "$RUNNER" --label goalbuddy.task=T043 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1 --cpu-shares=128 --blkio-weight=100 --memory=2g --memory-swap=2g --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /run/t043-output:rw,noexec,nosuid,size=2g -v "$VOL:/var/lib/postgresql/data:ro" -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_REPRESENTATIVE_OK=1 -e TYPED_EAV_REPRESENTATIVE_ENTITIES=250000 --entrypoint bash "$IMAGE" -lc '
set -e
runset(){ offset=$1; for slot in 1 2 3; do trial=$((offset+slot)); case "$slot" in 1) order=current_btree,lower_btree,trgm_gin;;2) order=lower_btree,trgm_gin,current_btree;;3) order=trgm_gin,current_btree,lower_btree;;esac; TYPED_EAV_TRIAL="$trial" TYPED_EAV_CANDIDATE_ORDER="$order" ruby bench/string_search_benchmark.rb --tier representative --seed 4401 --output "/run/t043-output/trial-$trial.json"; done; }
runset 0
ruby -rjson -e '\''d=ARGV.map{|f|JSON.parse(File.read(f))};v=[];d[0]["candidates"].each_key{|c|[%w[index_build_wal_bytes],%w[write_metrics insert_rows_per_second],%w[write_metrics insert_wal_bytes],%w[write_metrics update_rows_per_second],%w[write_metrics update_wal_bytes]].each{|p|a=d.map{|x|p.reduce(x["candidates"][c]){|z,k|z[k]}}.map(&:to_f);m=a.sum/a.size;v<<(m==0?0:Math.sqrt(a.sum{|x|(x-m)**2}/a.size)/m)}};exit(v.max<=0.25?0:1)'\'' /run/t043-output/trial-{1,2,3}.json || runset 3
: > /run/t043-output/done; while [ ! -e /run/t043-output/stop ];do sleep 2;done'
for wait in $(seq 1 1200); do [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" = running ] || { docker logs "$RUNNER" >&2; exit 44; }; docker exec "$RUNNER" test -e /run/t043-output/done && break; [ "$wait" = 1200 ] && exit 44; sleep 5; done
: > "$REMOTE_TMP/runner_done"; kill "$monitor_pid" >/dev/null 2>&1 || true; monitor_pid=""; [ ! -e "$abort_file" ] || { echo "runtime gate: $(cat "$abort_file")" >&2; exit 44; }
for trial in 1 2 3 4 5 6; do docker exec "$RUNNER" test -e "/run/t043-output/trial-$trial.json" || continue; docker exec "$RUNNER" cat "/run/t043-output/trial-$trial.json" > "$REMOTE_TMP/trial-$trial.json"; done
docker exec "$RUNNER" touch /run/t043-output/stop; for wait in $(seq 1 60);do [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" != running ]&&break;sleep 1;done
stats > "$REMOTE_TMP/contention-after"; docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}}' "$PG" > "$REMOTE_TMP/limits.pg"; docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}}' "$RUNNER" > "$REMOTE_TMP/limits.runner"
docker rm "$RUNNER" >/dev/null; after=$(mktemp); snapshot > "$after"; cmp -s "$before" "$after" || exit 43
python3 - "$REMOTE_TMP" "$RESULT_REMOTE" "$RUN_ID" <<'PY'
import glob,json,statistics,sys
d,out,run=sys.argv[1:];trials=[json.load(open(p)) for p in sorted(glob.glob(d+'/trial-*.json'))]
def dispersion(group):
 r=[]
 for c in group[0]['candidates']:
  for p in [('index_build_wal_bytes',),('write_metrics','insert_rows_per_second'),('write_metrics','insert_wal_bytes'),('write_metrics','update_rows_per_second'),('write_metrics','update_wal_bytes')]:
   a=[]
   for t in group:
    x=t['candidates'][c]
    for k in p:x=x[k]
    a.append(float(x))
   m=statistics.fmean(a);r.append({'candidate':c,'metric':'.'.join(p),'values':a,'relative_population_stddev':0 if m==0 else statistics.pstdev(a)/m})
 return r
selected=trials[:3];first=dispersion(selected)
if max(x['relative_population_stddev'] for x in first)>0.25:selected=trials[3:6]
metrics=dispersion(selected);maximum=max(x['relative_population_stddev'] for x in metrics)
if maximum>0.25:raise SystemExit('dispersion gate')
base=selected[0]
for c in base['candidates']:
 base['candidates'][c]['trial_medians']={k:statistics.median((t['candidates'][c][k] if k.startswith('index_') else t['candidates'][c]['write_metrics'][k]) for t in selected) for k in ['index_build_elapsed_ms','index_build_wal_bytes','insert_rows_per_second','insert_wal_bytes','update_rows_per_second','update_wal_bytes']}
 base['candidates'][c]['trial_medians']['index_bytes']=statistics.median(t['candidates'][c]['relation_bytes']['index_bytes'] for t in selected)
checks={t['dataset']['candidate_checksums'][c] for t in trials for c in t['dataset']['candidate_checksums']};query={op:{t['candidates'][c]['public_queries'][op]['entity_id_checksum'] for t in trials for c in t['candidates']} for op in base['public_sql_contract']}
if len(checks)!=1 or any(len(v)!=1 for v in query.values()):raise SystemExit('checksum gate')
base['trials']=[{'trial':t['trial'],'candidate_order':t['candidate_order'],'generated_at_utc':t['generated_at_utc']} for t in trials];base['dispersion']={'accepted_trial_numbers':[t['trial'] for t in selected],'bounded_rerun_used':len(trials)==6,'max_primary_relative_population_stddev':maximum,'threshold':0.25,'metrics':metrics};base['extension_lifecycle']=[json.loads(x) for x in open(d+'/compatibility.ndjson')]
base['remote_execution']={'task':'T043','run_id':run,'postgres_performance_major':17,'performance_generalization':'PG17 only; PG15/16/18 are lifecycle compatibility, not planner evidence.','co_tenant_timing':'absolute timing is diagnostic','limits':{'postgres':open(d+'/limits.pg').read().strip(),'runner':open(d+'/limits.runner').read().strip()},'contention':{'before':open(d+'/contention-before').read().strip(),'after':open(d+'/contention-after').read().strip()},'telemetry_samples':sum(1 for _ in open(d+'/telemetry')),'existing_container_invariant':'pass','source_manifest_verified':True,'cleanup_pending_transfer':True}
json.dump(base,open(out,'w'),indent=2);open(out,'a').write('\n')
PY
REMOTE

scp -q -o BatchMode=yes "$REMOTE:$RESULT_REMOTE" "$OUT"
ssh -o BatchMode=yes "$REMOTE" "set -e; test -z \"\$(docker ps -aq --filter label=goalbuddy.task=T043)\"; test -z \"\$(docker network ls -q --filter label=goalbuddy.task=T043)\"; test -z \"\$(docker volume ls -q --filter label=goalbuddy.task=T043)\"; test -z \"\$(docker image ls -q --filter label=goalbuddy.task=T043)\"; test ! -e '$REMOTE_TMP'; rm -f -- '$RESULT_REMOTE'"
ruby -rjson -e 'p=ARGV[0];d=JSON.parse(File.read(p));d["remote_execution"]["cleanup_pending_transfer"]=false;d["remote_execution"]["post_cleanup_verified"]=true;File.write(p,JSON.pretty_generate(d)+"\n")' "$OUT"
ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0]));abort unless d.dig("dataset","checksum_equal_across_candidates")&&d.dig("dispersion","max_primary_relative_population_stddev")<=0.25&&d.dig("remote_execution","post_cleanup_verified")&&d["extension_lifecycle"].map{|x|x["postgres_major"]}==[15,16,18]' "$OUT"
echo "T043 representative artifact: $OUT"
