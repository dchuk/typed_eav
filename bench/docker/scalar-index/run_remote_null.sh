#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t034-$(date -u +%Y%m%dt%H%M%Sz)-$$"
NET="${RUN_ID}-net"
VOL="${RUN_ID}-pgdata"
PG="${RUN_ID}-postgres"
RUNNER="${RUN_ID}-runner"
REMOTE_TMP="/tmp/${RUN_ID}"
RESULT_REMOTE="${REMOTE_TMP}.result.json"
OUT="${ROOT_DIR}/bench/results/phase-2-null-distributions.json"
TMP_ROOT=/private/tmp
[ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp

die() { echo "run_remote_null.sh: $*" >&2; exit 1; }
cleanup_local() {
  case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t034-*|/tmp/typed-eav-t034-*) rm -rf -- "$LOCAL_TMP";; esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "case '${RESULT_REMOTE}' in /tmp/t034-*.result.json) rm -f -- '${RESULT_REMOTE}';; esac" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT
for command in ssh scp tar; do command -v "$command" >/dev/null || die "$command is required"; done

ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' <<'REMOTE_PREFLIGHT'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}')
snapshot=$(mktemp)
current=""
trap 'rm -f -- "$snapshot" "$current"' EXIT
snapshot_existing() { docker ps -a --no-trunc --format '{{.ID}}|{{.State}}|{{.Status}}' | awk -F'|' '{ health="none"; if ($3 ~ /\(healthy\)/) health="healthy"; else if ($3 ~ /\(unhealthy\)/) health="unhealthy"; else if ($3 ~ /health: starting/) health="starting"; print $1 "|" $2 "|" health }' | sort; }
snapshot_existing > "$snapshot"
for sample in 1 2 3; do
  available=$(free -b | awk '/^Mem:/ {print $7}')
  free_bytes=$(df -Pk "$root" | tail -1 | awk '{print $4 * 1024}')
  printf 'T034_PREFLIGHT sample=%s available=%s docker_free=%s\n' "$sample" "$available" "$free_bytes"
  awk -v m="$available" -v d="$free_bytes" 'BEGIN { exit !(m >= 17179869184 && d >= 33997254720) }' || exit 42
  current=$(mktemp)
  snapshot_existing > "$current"
  cmp -s "$snapshot" "$current" || exit 43
  rm -f "$current"
  [ "$sample" -lt 3 ] && sleep 20
done
rm -f "$snapshot"
REMOTE_PREFLIGHT

LOCAL_TMP=$(mktemp -d "${TMP_ROOT}/typed-eav-${RUN_ID}.XXXXXX")
STAGE="${LOCAL_TMP}/source"
mkdir -p "$STAGE/bench/docker/scalar-index"
cp "$ROOT_DIR/bench/null_index_benchmark.rb" "$STAGE/bench/null_index_benchmark.rb"
cp "$ROOT_DIR/bench/docker/scalar-index/Dockerfile" "$STAGE/bench/docker/scalar-index/Dockerfile"
cp "$ROOT_DIR/bench/docker/scalar-index/run_remote_null.sh" "$STAGE/bench/docker/scalar-index/run_remote_null.sh"
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$STAGE/source-manifest.sha256"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$STAGE" -czf "${LOCAL_TMP}/source.tgz" .
ssh -o BatchMode=yes "$REMOTE" "test ! -e '${REMOTE_TMP}' && test ! -e '${REMOTE_TMP}.tgz' && test ! -e '${RESULT_REMOTE}'"
scp -q -o BatchMode=yes "${LOCAL_TMP}/source.tgz" "${REMOTE}:${REMOTE_TMP}.tgz"

ssh -o BatchMode=yes "$REMOTE" "RUN_ID='${RUN_ID}' NET='${NET}' VOL='${VOL}' PG='${PG}' RUNNER='${RUNNER}' REMOTE_TMP='${REMOTE_TMP}' RESULT_REMOTE='${RESULT_REMOTE}' bash -s" <<'REMOTE_RUN'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}')
case "$REMOTE_TMP" in /tmp/t034-*) ;; *) exit 45;; esac
case "$RESULT_REMOTE" in /tmp/t034-*.result.json) ;; *) exit 45;; esac

owned() {
  case "$1" in
    container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);;
    network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);;
  esac
  python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); raise SystemExit(0 if d.get("goalbuddy.task")=="T034" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"
}
cleanup() {
  set +e
  owned container "$RUNNER" && docker rm -f "$RUNNER" >/dev/null 2>&1 || true
  owned container "$PG" && docker rm -f "$PG" >/dev/null 2>&1 || true
  owned image "$RUN_ID:runner" && docker image rm "$RUN_ID:runner" >/dev/null 2>&1 || true
  owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true
  owned volume "$VOL" && docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -f -- "${before:-}" "${after:-}"
  case "$REMOTE_TMP" in /tmp/t034-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz";; esac
}
trap cleanup EXIT

before=$(mktemp)
snapshot() { owned_ids=$(docker ps -aq --no-trunc --filter "label=goalbuddy.run=$RUN_ID" | paste -sd, -); docker ps -a --no-trunc --format '{{.ID}}|{{.State}}|{{.Status}}' | awk -F'|' -v owned=",$owned_ids," 'index(owned, "," $1 ",") == 0 { health="none"; if ($3 ~ /\(healthy\)/) health="healthy"; else if ($3 ~ /\(unhealthy\)/) health="unhealthy"; else if ($3 ~ /health: starting/) health="starting"; print $1 "|" $2 "|" health }' | sort; }
snapshot > "$before"
mkdir -- "$REMOTE_TMP"
tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"
aggregate_existing_stats() { docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' | awk -v pg="$PG" -v runner="$RUNNER" '$1 != pg && $1 != runner {gsub(/%/, "", $2); gsub(/%/, "", $3); cpu += $2; mem += $3} END {printf "existing_cpu_percent=%.3f existing_mem_percent=%.3f\n", cpu, mem}'; }
aggregate_existing_stats > "$REMOTE_TMP/contention-before"
docker system df --format '{{.Type}} {{.Size}} {{.Reclaimable}}' | sort > "$REMOTE_TMP/docker-df-before"

docker network create --internal --label goalbuddy.task=T034 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
docker volume create --label goalbuddy.task=T034 --label "goalbuddy.run=$RUN_ID" "$VOL" >/dev/null
docker buildx build --quiet --load --resource memory=2g --resource cpu-quota=100000 --label goalbuddy.task=T034 --label "goalbuddy.run=$RUN_ID" -f "$REMOTE_TMP/bench/docker/scalar-index/Dockerfile" -t "$RUN_ID:runner" "$REMOTE_TMP" >/dev/null
docker run -d --name "$PG" --label goalbuddy.task=T034 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=256 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=256m --health-cmd='pg_isready -U postgres' --health-interval=2s --health-timeout=2s --health-retries=30 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$VOL:/var/lib/postgresql/data" postgres:17 >/dev/null
for wait in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$PG")" = healthy ] && break
  [ "$wait" -lt 60 ] || { echo 'postgres health timeout' >&2; exit 46; }
  sleep 2
done

abort_file="$REMOTE_TMP/abort"
monitor() {
  high_iowait=0
  while [ ! -f "$REMOTE_TMP/runner_done" ]; do
    available=$(free -b | awk '/^Mem:/ {print $7}')
    free_bytes=$(df -Pk "$root" | tail -1 | awk '{print $4 * 1024}')
    iowait=$(vmstat 1 2 | tail -1 | awk '{print $16 + 0}')
    load1=$(awk '{print $1}' /proc/loadavg)
    aggregate=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' | awk -v pg="$PG" -v runner="$RUNNER" '$1 != pg && $1 != runner {gsub(/%/, "", $2); gsub(/%/, "", $3); cpu += $2; mem += $3} END {printf "existing_cpu_percent=%.3f existing_mem_percent=%.3f", cpu, mem}')
    printf '%s load1=%s iowait=%s available=%s docker_free=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$load1" "$iowait" "$available" "$free_bytes" "$aggregate" >> "$REMOTE_TMP/telemetry"
    snapshot > "$REMOTE_TMP/current-containers"
    cmp -s "$before" "$REMOTE_TMP/current-containers" || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    if awk -v w="$iowait" 'BEGIN { exit !(w <= 25) }'; then high_iowait=0; else high_iowait=$((high_iowait + 1)); fi
    awk -v m="$available" -v d="$free_bytes" 'BEGIN { exit !(m >= 12884901888 && d >= 21474836480) }' || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    [ "$high_iowait" -lt 2 ] || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    sleep 15
  done
}
monitor & monitor_pid=$!

docker run -d --name "$RUNNER" --label goalbuddy.task=T034 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1 --cpu-shares=128 --blkio-weight=100 --memory=2g --memory-swap=2g --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /run/t034-output:rw,noexec,nosuid,size=1g -v "$VOL:/var/lib/postgresql/data:ro" -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_NULL_REPRESENTATIVE_OK=1 --entrypoint bash "$RUN_ID:runner" -lc 'set -e; : > /run/t034-output/trial-times; for trial in 1 2 3; do case "$trial" in 1|3) order=partial_covering,partial_covering_with_integer_null;; 2) order=partial_covering_with_integer_null,partial_covering;; esac; start=$(date -u +%Y-%m-%dT%H:%M:%SZ); TYPED_EAV_TRIAL="$trial" TYPED_EAV_NULL_CANDIDATE_ORDER="$order" ruby bench/null_index_benchmark.rb --seed 3301 --output "/run/t034-output/trial-$trial.json"; test -s "/run/t034-output/trial-$trial.json"; end=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf "%s|%s|%s|%s\n" "$trial" "$order" "$start" "$end" >> /run/t034-output/trial-times; done; : > /run/t034-output/done; while [ ! -e /run/t034-output/stop ]; do sleep 2; done'
for wait in $(seq 1 900); do
  [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" = running ] || { docker logs "$RUNNER" >&2; echo 'runner exited before done sentinel' >&2; exit 44; }
  docker exec "$RUNNER" test -e /run/t034-output/done && break
  [ "$wait" -lt 900 ] || { echo 'runner done timeout' >&2; exit 44; }
  sleep 5
done
: > "$REMOTE_TMP/runner_done"
kill "$monitor_pid" >/dev/null 2>&1 || true
wait "$monitor_pid" >/dev/null 2>&1 || true
[ ! -f "$abort_file" ] || { echo 'runtime abort gate fired' >&2; exit 44; }
for trial in 1 2 3; do docker exec "$RUNNER" cat "/run/t034-output/trial-$trial.json" > "$REMOTE_TMP/trial-$trial.json"; done
docker exec "$RUNNER" cat /run/t034-output/trial-times > "$REMOTE_TMP/trial-times"
docker exec "$RUNNER" cat /usr/local/typed_eav_pg_version > "$REMOTE_TMP/pg-version"
docker exec "$RUNNER" touch /run/t034-output/stop
for wait in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" != running ] && break; sleep 1; done
[ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" != running ] || exit 44

aggregate_existing_stats > "$REMOTE_TMP/contention-after"
docker system df --format '{{.Type}} {{.Size}} {{.Reclaimable}}' | sort > "$REMOTE_TMP/docker-df-after"
docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}} {{json .HostConfig.ShmSize}}' "$PG" > "$REMOTE_TMP/limits.pg"
docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}} {{json .HostConfig.ShmSize}}' "$RUNNER" > "$REMOTE_TMP/limits.runner"
docker inspect --format '{{.Id}}' postgres:17 > "$REMOTE_TMP/image.postgres"
docker inspect --format '{{.Id}}' "$RUN_ID:runner" > "$REMOTE_TMP/image.runner"
after=$(mktemp)
snapshot > "$after"
cmp -s "$before" "$after" || { echo 'pre-existing container invariant failed' >&2; exit 43; }

python3 - "$REMOTE_TMP" "$RUN_ID" "$root" <<'PY'
import json, statistics, sys
directory, run_id, docker_root = sys.argv[1:]
trials = [json.load(open(directory + f"/trial-{n}.json")) for n in (1, 2, 3)]
# T034 correction: deep-copy trial 1 before attaching the independent trial
# list. The aggregate can never contain itself.
result = json.loads(json.dumps(trials[0]))
def read(path):
    with open(path) as stream: return stream.read().strip()
result["environment"]["remote_execution"] = {
    "run_id": run_id, "docker_root": docker_root,
    "resource_limits": {"postgres": read(directory + "/limits.pg"), "runner": read(directory + "/limits.runner")},
    "image_ids": {"postgres": read(directory + "/image.postgres"), "runner": read(directory + "/image.runner"), "ruby_base": "ruby:3.4.4-bookworm"},
    "pg_gem_version": read(directory + "/pg-version"), "source_manifest": read(directory + "/source-manifest.sha256"),
    "docker_system_df": {"before": read(directory + "/docker-df-before"), "after": read(directory + "/docker-df-after")},
    "before_after_existing_container_invariant": "pass",
    "comparison_class": "co-tenant repeated same-seed relative evidence; no clean-room absolute latency claim",
    "contention_metrics": {"before": read(directory + "/contention-before"), "after": read(directory + "/contention-after"), "telemetry": read(directory + "/telemetry")},
    "trial_timestamps": read(directory + "/trial-times"), "trials": trials,
}
summary = {}
for distribution in ("low_null", "high_null"):
    summary[distribution] = {}
    for candidate in ("partial_covering", "partial_covering_with_integer_null"):
        summary[distribution][candidate] = {}
        for metric in ("relation_bytes", "index_bytes", "insert_wal_bytes"):
            values = [t["measurements"][distribution][candidate][metric] for t in trials]
            summary[distribution][candidate][metric] = {"median": statistics.median(values), "raw": values, "pstdev": statistics.pstdev(values)}
        for direction in ("forward", "reverse"):
            values = [t["measurements"][distribution][candidate]["null_transition_update"][direction]["wal_bytes"] for t in trials]
            summary[distribution][candidate][f"null_transition_{direction}_wal_bytes"] = {"median": statistics.median(values), "raw": values, "pstdev": statistics.pstdev(values)}
result["trial_medians_and_dispersion"] = summary
checks = []
for trial in trials:
    checks.append(trial["dataset"]["checksum_equal_within_distribution"])
    for distribution in ("low_null", "high_null"):
        checks.append(trial["measurements"][distribution]["partial_covering"]["counts"] == trial["measurements"][distribution]["partial_covering_with_integer_null"]["counts"])
result["evidence_quality"] = {"same_seed_and_counts_all_trials": all(checks), "trial_count": len(trials), "sufficient_for_relative_comparison": all(checks)}
if not all(checks): raise SystemExit("trial invariant failed")
with open(directory + "/result.json", "w") as stream:
    json.dump(result, stream, indent=2)
    stream.write("\n")
PY
cp "$REMOTE_TMP/result.json" "$RESULT_REMOTE"
cleanup
audit_clean() {
  [ -z "$(docker ps -aq --filter "label=goalbuddy.run=$RUN_ID")" ] &&
    [ -z "$(docker network ls -q --filter "label=goalbuddy.run=$RUN_ID")" ] &&
    [ -z "$(docker volume ls -q --filter "label=goalbuddy.run=$RUN_ID")" ] &&
    [ -z "$(docker image ls -q --filter "label=goalbuddy.run=$RUN_ID")" ] &&
    [ ! -e "$REMOTE_TMP" ] && [ ! -e "$REMOTE_TMP.tgz" ]
}
audit_clean || { echo 'post-cleanup ownership audit failed' >&2; exit 47; }
python3 - "$RESULT_REMOTE" <<'PY'
import json, sys
with open(sys.argv[1]) as stream: result = json.load(stream)
result["environment"]["remote_execution"]["post_cleanup_verified"] = True
with open(sys.argv[1], "w") as stream:
    json.dump(result, stream, indent=2)
    stream.write("\n")
PY
REMOTE_RUN

scp -q -o BatchMode=yes "${REMOTE}:${RESULT_REMOTE}" "$OUT"
ssh -o BatchMode=yes "$REMOTE" "rm -f -- '${RESULT_REMOTE}'"
ssh -o BatchMode=yes "$REMOTE" "test ! -e '${RESULT_REMOTE}'"
test -s "$OUT" || die "representative result was not copied back"
echo "T034 remote run complete: ${OUT}"
