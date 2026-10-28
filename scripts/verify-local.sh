#!/usr/bin/env bash
# Apply all migrations + seed to a throwaway plain Postgres (no Docker needed)
# and run tests/database.test.sql. Uses tests/supabase-stubs.sql to stand in
# for the auth/storage schemas and roles a Supabase project already has.
#
#   scripts/verify-local.sh            # needs postgres binaries (initdb, pg_ctl) on PATH or PG_BIN
#
# With the Supabase CLI instead:  supabase start && supabase db reset &&
#   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/database.test.sql
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-$(dirname "$(command -v pg_ctl || ls /usr/lib/postgresql/*/bin/pg_ctl | tail -1)")}"
PORT="${PGPORT_TEST:-54399}"
WORK="$(mktemp -d)"
RUN_AS=()
if [ "$(id -u)" = 0 ]; then
  # Postgres refuses to run as root.
  chown postgres "$WORK"
  RUN_AS=(runuser -u postgres --)
fi

cleanup() { "${RUN_AS[@]}" "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"${RUN_AS[@]}" "$PG_BIN/initdb" -D "$WORK/data" -U postgres -A trust --locale=C.UTF-8 -E UTF8 >/dev/null
"${RUN_AS[@]}" "$PG_BIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" -w start >/dev/null

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PORT" -U postgres -d postgres)

"${PSQL[@]}" -f "$ROOT/tests/supabase-stubs.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate  $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done
echo "seed     supabase/seed.sql"
"${PSQL[@]}" -f "$ROOT/supabase/seed.sql"
echo "test     tests/database.test.sql"
"${PSQL[@]}" -f "$ROOT/tests/database.test.sql" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /'
