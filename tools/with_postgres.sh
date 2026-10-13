#!/usr/bin/env bash
# Starts a throwaway PostgreSQL, exports VELA_PG and runs the given command.
# Usage: tools/with_postgres.sh command args...
# - VELA_PG already set: uses that database and starts nothing.
# - no PostgreSQL server installed (initdb not found): runs the command without VELA_PG (the test declares
#   itself skipped with exit 77).
# initdb is looked up in `pg_config --bindir`, on PATH and in the usual per-distribution locations
# (Debian/Ubuntu /usr/lib/postgresql/N/bin, openSUSE /usr/lib/postgresqlN/bin, Fedora/RHEL /usr/pgsql-N/bin).
set -euo pipefail
if [ -n "${VELA_PG:-}" ]; then exec "$@"; fi

find_bin() {
    local d
    if command -v pg_config > /dev/null && d=$(pg_config --bindir 2> /dev/null) && [ -x "$d/initdb" ]; then
        echo "$d"; return
    fi
    if d=$(command -v initdb 2> /dev/null); then dirname "$d"; return; fi
    for d in $(ls -d /usr/lib/postgresql/*/bin /usr/lib/postgresql*/bin /usr/pgsql-*/bin /usr/local/pgsql/bin 2> /dev/null | sort -V -r); do
        if [ -x "$d/initdb" ]; then echo "$d"; return; fi
    done
}
bin=$(find_bin || true)
if [ -z "$bin" ]; then
    echo "(PostgreSQL server not found: the database tests will be skipped)" >&2
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
