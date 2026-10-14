#!/usr/bin/env bash
# Throughput benchmark: builds tests/net/bench_serve.d and the load generator tests/net/bench.d with optimizations and
# runs a few scenarios against one worker. For comparing before/after a change, not a gate: the numbers depend on the
# machine and are noisy (run it twice). The server is pinned to CPU 0 and the client to the next CPUs when `taskset`
# exists, so the two do not compete for one core.
#
# Usage: tools/bench.sh [seconds=5]      DC=ldmd2 by default (DC=dmd works, slower code)
#   BENCH_WORKERS=4  also run the multi-worker scenario with that many workers
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-ldmd2}"
SECS="${1:-5}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
work=$(mktemp -d)
trap 'kill "$srv" 2> /dev/null || true; rm -rf "$work"' EXIT
srv=

$DC -O -release -inline -boundscheck=off $I -i tests/net/bench_serve.d -of"$work/serve" > /dev/null
$DC -O -release -inline tests/net/bench.d -of"$work/bench" > /dev/null

pin_server=() pin_client=()
if command -v taskset > /dev/null; then
    cpus=$(nproc)
    pin_server=(taskset -c 0)
    (( cpus > 2 )) && pin_client=(taskset -c "1-$(( cpus > 9 ? 8 : cpus - 1 ))")
fi

# run_server <workers>: starts the server on port 18100 and waits until it answers
run_server() {
    local pin=("${pin_server[@]}")
    (( $1 > 1 )) && pin=()
    "${pin[@]}" "$work/serve" 18100 "$1" > /dev/null 2>&1 &
    srv=$!
    for _ in $(seq 100); do
        if (exec 3<> /dev/tcp/127.0.0.1/18100) 2> /dev/null; then return 0; fi
        sleep 0.05
    done
    echo "bench: the server did not start" >&2
    exit 1
}

stop_server() { kill "$srv"; wait "$srv" 2> /dev/null || true; srv=; }

echo "== 1 worker, 64 connections, one request at a time"
run_server 1
for path in /plaintext /json "/users/42?full=1"; do
    "${pin_client[@]}" "$work/bench" 18100 "$path" 64 "$SECS" 4 1
done
echo "== 1 worker, 64 connections, 16 pipelined requests each"
"${pin_client[@]}" "$work/bench" 18100 /plaintext 64 "$SECS" 4 16
stop_server

if [[ -n "${BENCH_WORKERS:-}" ]]; then
    echo "== $BENCH_WORKERS workers, 256 connections, one request at a time"
    run_server "$BENCH_WORKERS"
    "$work/bench" 18100 /json 256 "$SECS" 8 1
    stop_server
fi
