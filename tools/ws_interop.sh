#!/usr/bin/env bash
# WebSockets against python's `websockets` library: vela's server with and without permessage-deflate (echo of text,
# UTF-8, 3 MiB binary, ordering, ping, close codes), and vela's client against a python server. Skips (exit 77) without
# python3 or its `websockets` module (>= 13).
# Usage: DC=dmd tools/ws_interop.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
if ! command -v python3 > /dev/null; then echo "skip: python3 missing" >&2; exit 77; fi
if ! python3 -c 'from websockets.asyncio.client import connect' 2> /dev/null; then
    echo "skip: python3 websockets (>= 13) not installed" >&2; exit 77
fi
pids=()
tmp=$(mktemp -d)
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"' EXIT
$DC $I -i -of"$tmp/srv" tests/net/ws_serve.d > /dev/null
$DC $I -i -of"$tmp/cli" tests/net/ws_client_check.d > /dev/null

fail=0
port=$(( 19600 + RANDOM % 200 ))
"$tmp/srv" "$port" > "$tmp/srv.out" 2> "$tmp/srv.err" &
pids+=($!)
for _ in $(seq 1 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port))" 2> /dev/null && break; sleep 0.1; done
echo "-- vela server, python client"
python3 tests/net/ws_interop.py client "$port" || fail=1

echo "-- python server, vela client"
pport=$(( port + 1 ))
python3 tests/net/ws_interop.py server "$pport" > "$tmp/py.out" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do grep -q ready "$tmp/py.out" 2> /dev/null && break; sleep 0.1; done
"$tmp/cli" "$pport" || fail=1
exit $fail
