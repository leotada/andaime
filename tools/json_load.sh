#!/usr/bin/env bash
# JSON load test: the same POST (a 1.7 KB order, 20 items) against two routes of one worker, as hard as the client can push:
# /andaime decodes and encodes with andaime's JSON, /stdjson with std.json. Reports req/s and latency (from the load
# generator) plus the server's peak RSS and CPU seconds. For justifying the design, not a gate: numbers depend on the machine.
#
# Usage: tools/json_load.sh [seconds=60]      DC=ldmd2 by default (DC=dmd works, slower code)
#   CONNS=64  connections       LOAD_THREADS=4  client threads
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-ldmd2}"
SECS="${1:-60}"
CONNS="${CONNS:-64}"
LOAD_THREADS="${LOAD_THREADS:-4}"
PORT=18101
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Itests/bench"
work=$(mktemp -d)
trap 'kill "$srv" 2> /dev/null || true; rm -rf "$work"' EXIT
srv=

$DC -O -release -inline -boundscheck=off $I -i tests/bench/json_serve.d -of"$work/serve" > /dev/null
$DC -O -release -inline tests/net/bench.d -of"$work/bench" > /dev/null

# The payload: what `std.json` writes for the benchmark's sample order.
cat > "$work/payload.d" <<'EOF'
module payload 2025;
import order;
import std.file : write;
void main(string[] a) { write(a[1], toStd(sample())); }
EOF
$DC -Itests/bench -i "$work/payload.d" -of"$work/payload" > /dev/null
"$work/payload" "$work/order.json"

pin_server=() pin_client=()
if command -v taskset > /dev/null; then
    cpus=$(nproc)
    pin_server=(taskset -c 0)
    (( cpus > 2 )) && pin_client=(taskset -c "1-$(( cpus > 9 ? 8 : cpus - 1 ))")
fi

# status_kb <field>: a line of the server's /proc/<pid>/status in kB
status_kb() { awk -v k="$1:" '$1 == k { print $2 }' "/proc/$srv/status"; }
# cpu_seconds: user + system CPU time of the server so far
cpu_seconds() { awk '{ printf "%.1f", ($14 + $15) / '"$(getconf CLK_TCK)"' }' "/proc/$srv/stat"; }

run_route() {
    local route=$1
    "${pin_server[@]}" "$work/serve" "$PORT" 1 > /dev/null 2>&1 &
    srv=$!
    for _ in $(seq 100); do
        if (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null; then break; fi
        sleep 0.05
    done
    echo "== $route: $CONNS connections, $SECS s"
    "${pin_client[@]}" "$work/bench" "$PORT" "$route" "$CONNS" "$SECS" "$LOAD_THREADS" 1 "$work/order.json"
    echo "   server: peak RSS $(( $(status_kb VmHWM) / 1024 )) MB, CPU $(cpu_seconds) s"
    kill "$srv"; wait "$srv" 2> /dev/null || true; srv=
}

run_route /andaime
run_route /stdjson
