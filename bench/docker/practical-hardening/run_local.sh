#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROJECT_RUBY="${TYPED_EAV_PROJECT_RUBY:-/Users/darrindemchuk/.rbenv/versions/3.4.4/bin/ruby}"
BUNDLE="$(dirname "$PROJECT_RUBY")/bundle"
TIER=""; OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ "$TIER" = smoke ] || [ "$TIER" = bounded ] || { echo "tier must be smoke or bounded" >&2; exit 2; }
[ -n "$OUTPUT" ] || { echo "--output required" >&2; exit 2; }
[ -x "$PROJECT_RUBY" ] && [ -x "$BUNDLE" ] || { echo "Ruby 3.4.4 toolchain missing" >&2; exit 2; }
[ "$($PROJECT_RUBY -e 'print RUBY_VERSION')" = 3.4.4 ] || { echo "Ruby 3.4.4 required" >&2; exit 2; }

DB="typed_eav_t167_${TIER}_$$"
TOTAL_START=$SECONDS
DB_OWNED=0
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "timeout command unavailable" >&2; exit 10; }
CELL_LIMIT=30; [ "$TIER" = bounded ] && CELL_LIMIT=90
TOTAL_LIMIT=120; [ "$TIER" = bounded ] && TOTAL_LIMIT=300
CLEANUP_RESERVE=30
if ! db_probe=$(psql --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" postgres -Atqc "select 1 from pg_database where datname='$DB'"); then
  echo "database preflight query failed" >&2; exit 9
fi
if [ "$db_probe" = 1 ]; then
  echo "refusing pre-existing database: $DB" >&2
  exit 8
fi
finalize_partial() {
  set +e
  if [ "$DB_OWNED" = 1 ]; then
    dropdb --force --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" "$DB" >/dev/null 2>&1
  fi
  absent_probe=$(psql --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" postgres -Atqc "select 1 from pg_database where datname='$DB'") || return 0
  absent=0; [ -z "$absent_probe" ] && absent=1
  [ "$absent" = 1 ] || { echo "partial cleanup could not prove database absence" >&2; return 0; }
  [ -f "$OUTPUT" ] || return 0
  partial_seconds=$((SECONDS - TOTAL_START))
  "$PROJECT_RUBY" -rjson -e 'path, tier, db, seconds = ARGV; data = JSON.parse(File.read(path)); p = data.fetch("protocol"); p["tier"] = tier; p["measured_total_seconds"] = seconds.to_i; p["cleanup"] = { "database" => db, "database_absent" => true }; p["finalized"] = false; tmp = "#{path}.partial-#{Process.pid}"; File.write(tmp, JSON.pretty_generate(data) + "\n"); File.rename(tmp, path)' "$OUTPUT" "$TIER" "$DB" "$partial_seconds"
  sha=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
  "$BUNDLE" exec "$PROJECT_RUBY" bench/validate_practical_hardening_artifact.rb "$OUTPUT" --expected-sha "$sha" --partial >/dev/null 2>&1 || echo "partial artifact validation failed (diagnostic only)" >&2
}
cleanup() { set +e; finalize_partial; }
trap cleanup EXIT
DATABASE_URL="postgresql://${PGUSER:-$USER}@${PGHOST:-localhost}:${PGPORT:-5432}/$DB"
export DATABASE_URL RAILS_ENV=test TYPED_EAV_PRACTICAL_DB="$DB"
rm -f -- "$OUTPUT"
createdb --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" "$DB"
DB_OWNED=1
[ "$(psql "$DATABASE_URL" -Atqc 'select current_database()')" = "$DB" ] || exit 5
[ "$DB" != typed_eav_test ] || exit 6
cd "$ROOT"
"$BUNDLE" exec "$PROJECT_RUBY" -r ./spec/dummy/config/environment -e 'ActiveRecord::MigrationContext.new([File.expand_path("db/migrate")]).migrate'
for cell in backfill_default_all backfill_relation bulk_update_versioning_off bulk_update_versioning_on field_delete_versioning_on; do
  work_remaining=$((TOTAL_LIMIT - CLEANUP_RESERVE - (SECONDS - TOTAL_START)))
  [ "$work_remaining" -gt 0 ] || { echo "work deadline reserve exhausted" >&2; exit 11; }
  cell_timeout=$CELL_LIMIT; [ "$work_remaining" -lt "$cell_timeout" ] && cell_timeout=$work_remaining
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5 "$cell_timeout" "$BUNDLE" exec "$PROJECT_RUBY" bench/practical_hardening_benchmark.rb --tier "$TIER" --cell "$cell" --output "$OUTPUT"
done
dropdb --force --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" "$DB"
if ! absent_probe=$(psql --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" postgres -Atqc "select 1 from pg_database where datname='$DB'"); then exit 7; fi
[ -z "$absent_probe" ] || exit 7
DB_OWNED=0
TOTAL_SECONDS=$((SECONDS - TOTAL_START))
[ "$TOTAL_SECONDS" -lt "$TOTAL_LIMIT" ] || { echo "end-to-end deadline exhausted before finalization" >&2; exit 12; }
# Cleanup is complete before the artifact is finalized and externally hashed.
finalize_remaining=$((TOTAL_LIMIT - (SECONDS - TOTAL_START)))
[ "$finalize_remaining" -gt 0 ] || { echo "end-to-end deadline exhausted before finalization" >&2; exit 12; }
"$TIMEOUT_BIN" --signal=TERM --kill-after=5 "$finalize_remaining" "$PROJECT_RUBY" -rjson -e 'path, tier, db, seconds = ARGV; data = JSON.parse(File.read(path)); protocol = data.fetch("protocol"); protocol["tier"] = tier; protocol["measured_total_seconds"] = seconds.to_i; protocol["cleanup"] = { "database" => db, "database_absent" => true }; protocol["finalized"] = true; tmp = "#{path}.finalized-#{Process.pid}"; File.write(tmp, JSON.pretty_generate(data) + "\n"); File.rename(tmp, path)' "$OUTPUT" "$TIER" "$DB" "$TOTAL_SECONDS"
ARTIFACT_SHA=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
validate_remaining=$((TOTAL_LIMIT - (SECONDS - TOTAL_START)))
[ "$validate_remaining" -gt 0 ] || { echo "end-to-end deadline exhausted before validation" >&2; exit 12; }
"$TIMEOUT_BIN" --signal=TERM --kill-after=5 "$validate_remaining" "$BUNDLE" exec "$PROJECT_RUBY" bench/validate_practical_hardening_artifact.rb "$OUTPUT" --expected-sha "$ARTIFACT_SHA"
[ "$((SECONDS - TOTAL_START))" -le "$TOTAL_LIMIT" ] || { echo "end-to-end deadline exceeded" >&2; exit 12; }
trap - EXIT
echo "T167 $TIER practical hardening workflow passed: $OUTPUT sha=$ARTIFACT_SHA"
