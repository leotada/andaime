#!/usr/bin/env bash
# Sobe examples/api de verdade (Postgres + upstream de teste) e roda tests/example/api_e2e.py.
# Chamado pelo check.sh dentro de with_postgres.sh + with_upstream.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source"
if [ -z "${VELA_PG:-}" ] || [ -z "${VELA_UP_PLAIN:-}" ] || ! command -v python3 >/dev/null; then
    echo "(pulado: precisa de PostgreSQL, upstream de teste e python3)"; exit 0
fi
tmp=$(mktemp -d)
trap 'kill $srv 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC -O $I -i -of"$tmp/api" examples/api/source/app.d > /dev/null
port=$(( 19000 + RANDOM % 500 ))
# exec: $! passa a ser o próprio servidor, e o trap consegue matá-lo
( cd examples/api && exec env PORT=$port DATABASE_URL="$VELA_PG" API_TOKEN=segredo123 \
    RATES_URL="http://127.0.0.1:$VELA_UP_PLAIN" CORS_ORIGINS="https://app.exemplo.com" \
    "$tmp/api" > /dev/null 2> "$tmp/api.log" ) &
srv=$!
for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && break
    sleep 0.1
done
if ! python3 tests/example/api_e2e.py "$port" segredo123; then
    echo "--- log do servidor ---"; tail -30 "$tmp/api.log"; exit 1
fi
