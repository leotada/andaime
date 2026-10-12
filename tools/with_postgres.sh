#!/usr/bin/env bash
# Starts a throwaway PostgreSQL, exports VELA_PG and runs the given command.
# Usage: tools/with_postgres.sh command args...
# - VELA_PG already set: uses that database and starts nothing.
# - no PostgreSQL installed (initdb): runs the command without VELA_PG (the test declares itself skipped).
set -euo pipefail
if [ -n "${VELA_PG:-}" ]; then exec "$@"; fi

bin=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$bin" ] || [ ! -x "$bin/initdb" ]; then
    echo "(PostgreSQL not installed: the driver test will be skipped)" >&2
    exec "$@"
fi

dir=$(mktemp -d)
port=$(( 54000 + RANDOM % 900 ))
run_as() { if [ "$(id -u)" = 0 ]; then chown -R postgres "$dir"; su postgres -c "$*"; else sh -c "$*"; fi; }
cleanup() { run_as "$bin/pg_ctl -D $dir/data -m immediate stop >/dev/null 2>&1" || true; rm -rf "$dir"; }
trap cleanup EXIT
chmod 755 "$dir"
run_as "$bin/initdb -D $dir/data -A trust >/dev/null"
run_as "$bin/pg_ctl -D $dir/data -o '-p $port -k $dir -c listen_addresses=127.0.0.1 -c fsync=off' -l $dir/log -w start >/dev/null"
export VELA_PG="host=127.0.0.1 port=$port user=postgres dbname=postgres"
"$@"
