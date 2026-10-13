#!/usr/bin/env bash
# Streamed responses against curl: Server-Sent Events arrive one at a time (HTTP/1.1 chunked and HTTP/2 over h2c), and a
# 20 MiB stream arrives intact. Skips (exit 77) without curl.
# Usage: DC=dmd tools/stream_interop.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
if ! command -v curl > /dev/null; then echo "skip: curl missing" >&2; exit 77; fi
pid=
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC $I -i -of"$tmp/srv" tests/net/stream_serve.d > /dev/null
port=$(( 19400 + RANDOM % 200 ))
"$tmp/srv" "$port" > "$tmp/out" 2> "$tmp/err" &
pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/mb/0" 2> /dev/null && break; sleep 0.1; done

fail=0
check_ticks() {   # check_ticks <label> <curl args...>
    local label=$1; shift
    local start; start=$(date +%s%N)
    # each line is stamped when curl prints it: the events must arrive spread over the ~800 ms, not all at the end
    local stamped; stamped=$(curl -sN "$@" "http://127.0.0.1:$port/ticks" | while IFS= read -r line; do
        if [[ -n "$line" ]]; then echo "$(( ($(date +%s%N) - start) / 1000000 )) $line"; fi; done)
    local n; n=$(grep -c 'data: tick' <<< "$stamped" || true)
    local first last
    first=$(grep 'data: tick 0' <<< "$stamped" | cut -d' ' -f1)
    last=$(grep 'data: tick 4' <<< "$stamped" | cut -d' ' -f1)
    if [[ "$n" != 5 ]] || (( last - first < 600 )); then
        echo "FAILED: $label: expected 5 events spread over time, got $n (first ${first:-?} ms, last ${last:-?} ms)"; fail=1
    else
        echo "ok  $label: 5 events, first at ${first} ms, last at ${last} ms"
    fi
}
check_ticks "curl -N, HTTP/1.1 chunked"
check_ticks "curl -N, HTTP/2 (h2c prior knowledge)" --http2-prior-knowledge

for proto in --http1.1 --http2-prior-knowledge; do
    bytes=$(curl -s $proto "http://127.0.0.1:$port/mb/20" | wc -c)
    if [[ "$bytes" -ne $(( 20 * 1024 * 1024 )) ]]; then echo "FAILED: 20 MiB download ($proto): $bytes bytes"; fail=1
    else echo "ok  20 MiB stream intact ($proto)"; fi
done
exit $fail
