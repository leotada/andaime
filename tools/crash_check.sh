#!/usr/bin/env bash
# A fiber stack overflow kills the whole process with SIGSEGV. vela must at least say which request was running and
# what to change, then die as usual (exit status 139). Builds tests/net/stack_overflow.d and checks both.
# Skips (exit 77) without curl.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
if ! command -v curl > /dev/null; then echo "skip: curl missing" >&2; exit 77; fi
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC $I -i -of"$tmp/srv" tests/net/stack_overflow.d > /dev/null
port=$(( 19600 + RANDOM % 300 ))
( ulimit -c 0; exec "$tmp/srv" "$port" > "$tmp/out" 2> "$tmp/err" ) &
pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/fast" 2> /dev/null && break; sleep 0.1; done
[[ "$(curl -s "http://127.0.0.1:$port/recurse/3")" == "deep" ]] || { echo "FAILED: a shallow recursion should work"; exit 1; }
curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$port/recurse/100000" || true
rc=0; wait $pid || rc=$?
if (( rc != 139 )); then echo "FAILED: expected the server to die with SIGSEGV (139), got $rc"; cat "$tmp/err"; exit 1; fi
if ! grep -q "segmentation fault .* while running GET /recurse/100000.*raise ServerConfig.fiberStackBytes (now 256 KiB)" "$tmp/err"; then
    echo "FAILED: the crash message is missing"; cat "$tmp/err"; exit 1
fi
echo "ok  fiber stack overflow: $(grep -o 'vela: segmentation fault.*while running GET [^.]*' "$tmp/err"), exit status $rc"
