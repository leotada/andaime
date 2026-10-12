#!/usr/bin/env bash
# Starts examples/api for real (Postgres + test upstream) and runs tests/example/api_e2e.py.
# Called by check.sh inside with_postgres.sh + with_upstream.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source"
if [ -z "${VELA_PG:-}" ] || [ -z "${VELA_UP_PLAIN:-}" ] || ! command -v python3 >/dev/null; then
    echo "(skipped: needs PostgreSQL, the test upstream and python3)"; exit 0
fi
tmp=$(mktemp -d)
trap 'kill $srv 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC -O $I -i -of"$tmp/api" examples/api/source/app.d > /dev/null
port=$(( 19000 + RANDOM % 500 ))
# exec: $! becomes the server itself, and the trap can kill it
( cd examples/api && exec env PORT=$port DATABASE_URL="$VELA_PG" API_TOKEN=secret123 \
    RATES_URL="http://127.0.0.1:$VELA_UP_PLAIN" CORS_ORIGINS="https://app.example.com" \
    "$tmp/api" > /dev/null 2> "$tmp/api.log" ) &
srv=$!
for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && break
    sleep 0.1
done
if ! python3 tests/example/api_e2e.py "$port" secret123; then
    echo "--- server log ---"; tail -30 "$tmp/api.log"; exit 1
fi
