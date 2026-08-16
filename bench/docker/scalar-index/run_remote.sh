#!/usr/bin/env bash
set -euo pipefail

# Standalone, label-owned remote runner. It deliberately has no Compose, host
# ports, host mounts, Docker socket, restart policy, or pre-existing-object reuse.
ROOT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REMOTE=${REMOTE_SSH_TARGET:-dchuk@100.81.180.103}
RUN_ID="t032-$(date -u +%Y%m%dt%H%M%Sz)-$$"
NET="${RUN_ID}-net"
VOL="${RUN_ID}-pgdata"
PG="${RUN_ID}-postgres"
RUNNER="${RUN_ID}-runner"
REMOTE_TMP="/tmp/${RUN_ID}"
OUT="${ROOT_DIR}/bench/results/phase-2-scalar-representative.json"
RESULT_REMOTE="${REMOTE_TMP}.result.json"
TMP_ROOT=/private/tmp
[ -d "$TMP_ROOT" ] || TMP_ROOT=/tmp

die() { echo "run_remote.sh: $*" >&2; exit 1; }
cleanup_local() {
  case "${LOCAL_TMP:-}" in /private/tmp/typed-eav-t032-*|/tmp/typed-eav-t032-*) rm -rf -- "$LOCAL_TMP";; esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE}" "case '${RESULT_REMOTE}' in /tmp/t032-*.result.json) rm -f -- '${RESULT_REMOTE}';; esac" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT

command -v ssh >/dev/null || die "ssh is required"
command -v scp >/dev/null || die "scp is required"
command -v tar >/dev/null || die "tar is required"

# This is read-only. Three consecutive samples are mandatory; a single sample
# is insufficient. Existing high-CPU media work is never stopped or changed.
ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE}" 'bash -s' <<'REMOTE_PREFLIGHT'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}')
snapshot=$(mktemp)
current=""
trap 'rm -f -- "$snapshot" "$current"' EXIT
snapshot_existing() { for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; s=d["State"]; print("%s|%s|%s|%s|%s" % (d["Id"], d["Name"], s["Status"], s.get("Health", {}).get("Status", "none"), d.get("RestartCount", 0)))'; done | sort; }
snapshot_existing > "$snapshot"
for sample in 1 2 3; do
  available=$(free -b | awk '/^Mem:/ {print $7}')
  free_bytes=$(df -Pk "$root" | tail -1 | awk '{print $4 * 1024}')
  printf 'T032_PREFLIGHT sample=%s available=%s docker_free=%s\n' "$sample" "$available" "$free_bytes"
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
mkdir -- "$STAGE"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$STAGE"
for path in bench/README.md bench/scalar_index_benchmark.rb bench/docker/scalar-index/Dockerfile bench/docker/scalar-index/run_remote.sh docs/improvement-program.md; do
  mkdir -p "$STAGE/$(dirname "$path")"
  cp "$ROOT_DIR/$path" "$STAGE/$path"
done
[ ! -e "$ROOT_DIR/Gemfile.lock" ] || cp "$ROOT_DIR/Gemfile.lock" "$STAGE/Gemfile.lock"
(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$LOCAL_TMP/source-manifest.sha256"
cp "$LOCAL_TMP/source-manifest.sha256" "$STAGE/source-manifest.sha256"
tar -C "$STAGE" -czf "${LOCAL_TMP}/source.tgz" .
ssh -o BatchMode=yes "${REMOTE}" "test ! -e '${REMOTE_TMP}' && test ! -e '${REMOTE_TMP}.tgz' && test ! -e '${RESULT_REMOTE}'"
scp -q -o BatchMode=yes "${LOCAL_TMP}/source.tgz" "${REMOTE}:${REMOTE_TMP}.tgz"

ssh -o BatchMode=yes "${REMOTE}" "RUN_ID='${RUN_ID}' NET='${NET}' VOL='${VOL}' PG='${PG}' RUNNER='${RUNNER}' REMOTE_TMP='${REMOTE_TMP}' RESULT_REMOTE='${REMOTE_TMP}.result.json' bash -s" <<'REMOTE_RUN'
set -euo pipefail
root=$(docker info --format '{{.DockerRootDir}}')
case "$REMOTE_TMP" in /tmp/t032-*) ;; *) exit 45;; esac
case "$RESULT_REMOTE" in /tmp/t032-*.result.json) ;; *) exit 45;; esac
cleanup() {
  set +e
  owned() {
    case "$1" in
      container|image) labels=$(docker inspect -f '{{json .Config.Labels}}' "$2" 2>/dev/null);;
      network|volume) labels=$(docker inspect -f '{{json .Labels}}' "$2" 2>/dev/null);;
    esac
    python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); raise SystemExit(0 if d.get("goalbuddy.task")=="T032" and d.get("goalbuddy.run")==sys.argv[2] else 1)' "$labels" "$RUN_ID"
  }
  owned container "$RUNNER" && docker rm -f "$RUNNER" >/dev/null 2>&1 || true
  owned container "$PG" && docker rm -f "$PG" >/dev/null 2>&1 || true
  owned image "$RUN_ID:runner" && docker image rm "$RUN_ID:runner" >/dev/null 2>&1 || true
  owned network "$NET" && docker network rm "$NET" >/dev/null 2>&1 || true
  owned volume "$VOL" && docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -f -- "${before:-}" "${after:-}"
  case "$REMOTE_TMP" in /tmp/t032-*) rm -rf -- "$REMOTE_TMP" "$REMOTE_TMP.tgz";; esac
}
trap cleanup EXIT

before=$(mktemp)
snapshot() { for id in $(docker ps -aq); do docker inspect "$id" | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; s=d["State"]; print("%s|%s|%s|%s|%s" % (d["Id"], d["Name"], s["Status"], s.get("Health", {}).get("Status", "none"), d.get("RestartCount", 0)))'; done | awk -F'|' -v pg="/$PG" -v runner="/$RUNNER" '$2 != pg && $2 != runner' | sort; }
snapshot > "$before"
mkdir -- "$REMOTE_TMP"
tar -xzf "$REMOTE_TMP.tgz" -C "$REMOTE_TMP"
aggregate_existing_stats() { docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' | awk -v pg="$PG" -v runner="$RUNNER" '$1 != pg && $1 != runner {gsub(/%/, "", $2); gsub(/%/, "", $3); cpu += $2; mem += $3} END {printf "existing_cpu_percent=%.3f existing_mem_percent=%.3f\n", cpu, mem}'; }
aggregate_existing_stats > "$REMOTE_TMP/contention-before"
docker system df --format '{{.Type}} {{.Size}} {{.Reclaimable}}' | sort > "$REMOTE_TMP/docker-df-before"
docker network create --internal --label goalbuddy.task=T032 --label "goalbuddy.run=$RUN_ID" "$NET" >/dev/null
docker volume create --label goalbuddy.task=T032 --label "goalbuddy.run=$RUN_ID" "$VOL" >/dev/null
docker buildx build --load --resource memory=2g --resource cpu-quota=100000 --label goalbuddy.task=T032 --label "goalbuddy.run=$RUN_ID" -f "$REMOTE_TMP/bench/docker/scalar-index/Dockerfile" -t "$RUN_ID:runner" "$REMOTE_TMP" >/dev/null
printf '%s\n' 'docker buildx --load --resource memory=2g --resource cpu-quota=100000' > "$REMOTE_TMP/build-resources"
docker run -d --name "$PG" --label goalbuddy.task=T032 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=2 --cpu-shares=256 --blkio-weight=100 --memory=8g --memory-swap=8g --shm-size=256m --health-cmd='pg_isready -U postgres' --health-interval=2s --health-timeout=2s --health-retries=30 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$VOL:/var/lib/postgresql/data" postgres:17 >/dev/null
health_wait=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$PG")" = healthy ]; do health_wait=$((health_wait + 1)); [ "$health_wait" -lt 60 ] || { echo 'postgres health timeout' >&2; exit 46; }; sleep 2; done
abort_file="$REMOTE_TMP/abort"
high_iowait=0
monitor() {
  while [ ! -f "$REMOTE_TMP/runner_done" ]; do
    set -- $(cat /proc/loadavg)
    available=$(free -b | awk '/^Mem:/ {print $7}')
    free_bytes=$(df -Pk "$root" | tail -1 | awk '{print $4 * 1024}')
    docker stats --no-stream >/dev/null 2>&1 || { : > "$abort_file"; return; }
    set -- $(cat /proc/loadavg)
    iowait=$(vmstat 1 2 | tail -1 | awk '{print $16 + 0}')
    aggregate=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' | awk -v pg="$PG" -v runner="$RUNNER" '$1 != pg && $1 != runner {gsub(/%/, "", $2); gsub(/%/, "", $3); cpu += $2; mem += $3} END {printf "existing_cpu_percent=%.3f existing_mem_percent=%.3f", cpu, mem}')
    printf '%s load1=%s iowait=%s available=%s docker_free=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$iowait" "$available" "$free_bytes" "$aggregate" >> "$REMOTE_TMP/telemetry"
    snapshot > "$REMOTE_TMP/current-containers"
    cmp -s "$before" "$REMOTE_TMP/current-containers" || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    iowait=$(vmstat 1 2 | tail -1 | awk '{print $16 + 0}')
    if awk -v w="$iowait" 'BEGIN { exit !(w <= 25) }'; then high_iowait=0; else high_iowait=$((high_iowait + 1)); fi
    awk -v m="$available" -v d="$free_bytes" 'BEGIN { exit !(m >= 12884901888 && d >= 21474836480) }' || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    [ "$high_iowait" -lt 2 ] || { : > "$abort_file"; docker rm -f "$RUNNER" >/dev/null 2>&1 || true; return; }
    sleep 15
  done
}
monitor & monitor_pid=$!
docker run -d --name "$RUNNER" --label goalbuddy.task=T032 --label "goalbuddy.run=$RUN_ID" --network "$NET" --cpus=1 --cpu-shares=128 --blkio-weight=100 --memory=2g --memory-swap=2g --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --tmpfs /tmp:rw,noexec,nosuid,size=1g --tmpfs /run/t032-output:rw,noexec,nosuid,size=1g -v "$VOL:/var/lib/postgresql/data:ro" -e PGHOST="$PG" -e PGUSER=postgres -e TYPED_EAV_REPRESENTATIVE_OK=1 -e TYPED_EAV_REPRESENTATIVE_ENTITIES=100000 --entrypoint bash "$RUN_ID:runner" -lc 'set -e; : > /run/t032-output/trial-times; for trial in 1 2 3; do case "$trial" in 1) order=current_covering,partial_non_covering,partial_covering;; 2) order=partial_non_covering,partial_covering,current_covering;; 3) order=partial_covering,current_covering,partial_non_covering;; esac; start=$(date -u +%Y-%m-%dT%H:%M:%SZ); TYPED_EAV_TRIAL="$trial" TYPED_EAV_CANDIDATE_ORDER="$order" ruby bench/scalar_index_benchmark.rb --tier representative --seed 2201 --output "/run/t032-output/trial-$trial.json"; test -s "/run/t032-output/trial-$trial.json"; end=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf "%s|%s|%s|%s\\n" "$trial" "$order" "$start" "$end" >> /run/t032-output/trial-times; done; : > /run/t032-output/done; while [ ! -e /run/t032-output/stop ]; do sleep 2; done'
for wait in $(seq 1 720); do
  state=$(docker inspect -f '{{.State.Status}}' "$RUNNER")
  [ "$state" = running ] || { echo 'runner exited before done sentinel' >&2; exit 44; }
  docker exec "$RUNNER" test -e /run/t032-output/done && break
  [ "$wait" -lt 720 ] || { echo 'runner done timeout' >&2; exit 44; }
  sleep 5
done
: > "$REMOTE_TMP/runner_done"
kill "$monitor_pid" >/dev/null 2>&1 || true
[ ! -f "$abort_file" ] || { echo 'runtime abort gate fired' >&2; exit 44; }
for trial in 1 2 3; do docker exec "$RUNNER" cat "/run/t032-output/trial-$trial.json" > "$REMOTE_TMP/trial-$trial.json"; done
docker exec "$RUNNER" cat /run/t032-output/trial-times > "$REMOTE_TMP/trial-times"
docker exec "$RUNNER" cat /usr/local/typed_eav_pg_version > "$REMOTE_TMP/pg-version"
docker exec "$RUNNER" touch /run/t032-output/stop
for wait in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" != running ] && break; sleep 1; done
[ "$(docker inspect -f '{{.State.Status}}' "$RUNNER")" != running ] || { echo 'runner stop timeout' >&2; exit 44; }
aggregate_existing_stats > "$REMOTE_TMP/contention-after"
docker system df --format '{{.Type}} {{.Size}} {{.Reclaimable}}' | sort > "$REMOTE_TMP/docker-df-after"
docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}} {{json .HostConfig.ShmSize}}' "$PG" > "$REMOTE_TMP/limits.pg"
docker inspect --format '{{json .HostConfig.NanoCpus}} {{json .HostConfig.CpuShares}} {{json .HostConfig.BlkioWeight}} {{json .HostConfig.Memory}} {{json .HostConfig.MemorySwap}} {{json .HostConfig.ShmSize}}' "$RUNNER" > "$REMOTE_TMP/limits.runner"
docker inspect --format '{{.Id}}' postgres:17 > "$REMOTE_TMP/image.postgres"
: > "$REMOTE_TMP/image.runner"
docker inspect --format '{{.Id}}' "$RUN_ID:runner" > "$REMOTE_TMP/image.runner"
after=$(mktemp)
snapshot > "$after"
cmp -s "$before" "$after" || { echo 'pre-existing container invariant failed' >&2; exit 43; }
python3 - "$REMOTE_TMP" "$REMOTE_TMP/limits.pg" "$REMOTE_TMP/limits.runner" "$REMOTE_TMP/image.postgres" "$REMOTE_TMP/image.runner" "$RUN_ID" "$root" <<'PY'
import json, sys, statistics
directory, pg_limits, runner_limits, pg_image, runner_image, run_id, docker_root = sys.argv[1:]
with open(directory + "/trial-1.json") as stream:
    result = json.load(stream)
def read(name):
    with open(name) as stream:
        return stream.read().strip()
result.setdefault("environment", {})["remote_execution"] = {
    "run_id": run_id, "docker_root": docker_root,
    "resource_limits": {"postgres": read(pg_limits), "runner": read(runner_limits)},
    "image_ids": {"postgres": read(pg_image), "runner": read(runner_image), "ruby_base": "ruby:3.4.4-bookworm"},
    "build_resources": read(directory + "/build-resources"),
    "pg_gem_version": read(directory + "/pg-version"),
    "source_manifest": read(directory + "/source-manifest.sha256"),
    "docker_system_df": {"before": read(directory + "/docker-df-before"), "after": read(directory + "/docker-df-after")},
    "before_after_existing_container_invariant": "pass",
    "owned_cleanup": "EXIT trap removes only the labeled runner, postgres, network, volume, and exact transfer directory",
    "allowed_retained_base_images": ["postgres:17", "ruby:3.4-bookworm"],
    "comparison_class": "co-tenant representative comparison; relative layout evidence only, not clean-room absolute latency",
    "contention_metrics": {"before": read(directory + "/contention-before"), "after": read(directory + "/contention-after"), "telemetry": read(directory + "/telemetry")},
    "trial_timestamps": read(directory + "/trial-times"),
    "trials": [json.load(open(directory + f"/trial-{n}.json")) for n in (1, 2, 3)],
}
trials = result["environment"]["remote_execution"]["trials"]
primary_metrics = ("insert_elapsed_ms", "update_elapsed_ms", "insert_rows_per_second", "update_rows_per_second")
query_metrics = ("equality_latency_ms", "range_latency_ms", "candidate_total_relation_bytes")
metrics = primary_metrics + query_metrics
summary = {}
for candidate in ("current_covering", "partial_non_covering", "partial_covering"):
    summary[candidate] = {}
    for metric in metrics:
        values = []
        for trial in trials:
            measurement = trial.get("measurements", {}).get(candidate, {})
            value = measurement.get(metric)
            if isinstance(value, list):
                value = statistics.median(value) if value else None
            if isinstance(value, (int, float)):
                values.append(value)
        if values:
            summary[candidate][metric] = {"median": statistics.median(values), "pstdev": statistics.pstdev(values), "raw": values}
result["trial_medians_and_dispersion"] = summary
ratios = [summary[candidate][metric]["pstdev"] / abs(summary[candidate][metric]["median"]) for candidate in summary for metric in primary_metrics if metric in summary[candidate] and summary[candidate][metric]["median"]]
query_ratios = [summary[candidate][metric]["pstdev"] / abs(summary[candidate][metric]["median"]) for candidate in summary for metric in query_metrics if metric in summary[candidate] and summary[candidate][metric]["median"]]
result["evidence_quality"] = {"dispersion_threshold": 0.25, "max_primary_relative_pstdev": max(ratios, default=0), "max_query_relative_pstdev": max(query_ratios, default=0), "sufficient_for_relative_comparison": max(ratios, default=0) <= 0.25}
with open(directory + "/result.json", "w") as stream:
    json.dump(result, stream, indent=2)
    stream.write("\n")
if not result["evidence_quality"]["sufficient_for_relative_comparison"]:
    raise SystemExit("dispersion exceeds 25%; evidence rejected")
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
with open(sys.argv[1]) as stream:
    result = json.load(stream)
result.setdefault("environment", {})["remote_execution"]["post_cleanup_verified"] = True
with open(sys.argv[1], "w") as stream:
    json.dump(result, stream, indent=2)
    stream.write("\n")
PY
REMOTE_RUN

scp -q -o BatchMode=yes "${REMOTE}:${REMOTE_TMP}.result.json" "$OUT"
ssh -o BatchMode=yes "${REMOTE}" "rm -f -- '${REMOTE_TMP}.result.json'"
ssh -o BatchMode=yes "${REMOTE}" "test ! -e '${REMOTE_TMP}.result.json'"
test -s "$OUT" || die "representative result was not copied back"
echo "T032 remote run complete: ${OUT}"
