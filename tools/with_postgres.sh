#!/usr/bin/env bash
# Sobe um PostgreSQL descartável, exporta VELA_PG e roda o comando dado.
# Uso: tools/with_postgres.sh comando args...
# - VELA_PG já definido: usa o banco indicado e não sobe nada.
# - sem PostgreSQL instalado (initdb): roda o comando sem VELA_PG (o teste se declara pulado).
set -euo pipefail
if [ -n "${VELA_PG:-}" ]; then exec "$@"; fi

bin=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$bin" ] || [ ! -x "$bin/initdb" ]; then
    echo "(PostgreSQL não instalado: teste do driver será pulado)" >&2
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
