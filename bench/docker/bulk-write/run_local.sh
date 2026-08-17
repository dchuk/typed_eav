#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROJECT_RUBY="${TYPED_EAV_PROJECT_RUBY:-$HOME/.rbenv/versions/3.4.4/bin/ruby}"
BUNDLE="$(dirname "$PROJECT_RUBY")/bundle"
DB="typed_eav_t091_bounded_$$"
DB_PREFIX="typed_eav_t091_bounded_"
OUT="$ROOT/bench/results/phase-6-bulk-write-bounded.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/typed-eav-t092.XXXXXX")"
cleanup() {
  set +e
  dropdb --if-exists --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" "$DB" >/dev/null 2>&1
  rm -rf -- "$WORK"
}
trap cleanup EXIT

[ -x "$PROJECT_RUBY" ] || { echo "project Ruby missing: $PROJECT_RUBY" >&2; exit 2; }
[ -x "$BUNDLE" ] || { echo "project Bundler missing: $BUNDLE" >&2; exit 2; }
[ "$($PROJECT_RUBY -e 'print RUBY_VERSION')" = 3.4.4 ] || { echo "Ruby 3.4.4 required" >&2; exit 2; }
free_kb=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
[ "${free_kb:-0}" -ge 2097152 ] || { echo "disk floor below 2 GiB" >&2; exit 3; }
case "$DB" in "$DB_PREFIX"*) ;; *) exit 4 ;; esac
DATABASE_URL="postgresql://${PGUSER:-$USER}@${PGHOST:-localhost}:${PGPORT:-5432}/$DB"
export DATABASE_URL RAILS_ENV=test
createdb --host="${PGHOST:-localhost}" --port="${PGPORT:-5432}" --username="${PGUSER:-$USER}" "$DB"
[ "$(psql "$DATABASE_URL" -Atqc 'select current_database()')" = "$DB" ] || { echo "database identity mismatch" >&2; exit 5; }
[ "$DB" != typed_eav_test ] || { echo "forbidden database" >&2; exit 6; }
"$BUNDLE" exec "$PROJECT_RUBY" -r ./spec/dummy/config/environment -e 'ActiveRecord::MigrationContext.new([File.expand_path("db/migrate")]).migrate'
for table in typed_eav_fields typed_eav_values typed_eav_value_versions; do
  [ "$(psql "$DATABASE_URL" -Atqc "select to_regclass('$table')")" = "$table" ] || { echo "missing table: $table" >&2; exit 7; }
done
printf '%s\n' "$DB" > "$WORK/database.identity"
printf '%s\n' "$DATABASE_URL" | sed 's#//[^@]*@#//REDACTED@#' > "$WORK/database.url"
"$BUNDLE" exec "$PROJECT_RUBY" bench/bulk_write_benchmark.rb --tier bounded --output "$OUT"
"$BUNDLE" exec "$PROJECT_RUBY" bench/validate_bulk_write_artifact.rb "$OUT"
[ "$(psql "$DATABASE_URL" -Atqc 'select current_database()')" = "$DB" ]
echo "T092 local bounded workflow passed: $OUT"
