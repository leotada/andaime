#!/usr/bin/env bash
# Full vela verification. Usage: tools/check.sh   (DC=ldmd2 to use LDC)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source"
fail=0

echo "== module unittests"
$DC -unittest -main $I -i -run engine/source/vela/engine/package.d
$DC -unittest -main $I -i -run web/source/vela/web/package.d
$DC -unittest -main $I -i -run drivers/pg/source/vela/db/package.d

echo "== web-layer features (groups, locals, onError, CORS, static files, OpenAPI, middlewares)"
for t in tests/web/*.d; do
    $DC -unittest -main $I -i -run "$t" > /dev/null 2>&1 || { echo "FAILED: $t"; $DC -unittest -main $I -i -run "$t" 2>&1 | grep -v '^vela: error in' | tail -15; fail=1; }
done
echo "ok  $(ls tests/web/*.d | wc -l) files in tests/web"

echo "== HTTP parser: attack corpus and mutation fuzz"
$DC $I -i -run tests/fuzz/corpus_test.d
$DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_parse.d 300000

echo "== HTTP/2: session (frames, streams, flow control, errors, limits) and mutation fuzz"
$DC -unittest $I -i -run tests/h2/session_test.d
$DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_h2.d 300000

echo "== example tests (TestClient, no network)"
$DC -unittest -main $I -i -run examples/hello/source/app.d > /dev/null

echo "== hot path without GC allocation"
$DC $I -i -run tests/alloc/hot_path.d
$DC $I -i -run tests/alloc/h2_hot_path.d

echo "== network tests (EpollLoop + fibers: cancellation, ceiling, deadlines, pools)"
ulimit -n 20000 2>/dev/null || true
$DC $I -i -run tests/net/epoll_net.d

echo "== HTTP/2 network tests (h2c, multiplexing, cancellation, deadlines, flow control, upgrade, stop)"
$DC $I -i -run tests/net/h2_net.d

echo "== HTTP/2 interoperability (curl, python-h2, h2spec; each skips itself when missing)"
DC=$DC tools/h2_interop.sh || fail=1

echo "== M3: PostgreSQL (async libpq), HTTP/HTTPS client and thread pool"
tools/with_postgres.sh $DC $I -i -run tests/db/pg_net.d
tools/with_upstream.sh $DC $I -i -run tests/net/client_net.d

echo "== real API example end to end (Postgres + external API + auth + CORS + static files + OpenAPI)"
DC=$DC tools/with_postgres.sh tools/with_upstream.sh tools/api_e2e.sh

echo "== memory: 1,000 in-flight requests (plan target: peak RSS < 30 MB)"
ulimit -n 20000 2>/dev/null || ulimit -n 4096 2>/dev/null || true
tmp=$(mktemp -d)
$DC -O -release tests/net/loadgen.d -of"$tmp/loadgen" > /dev/null
$DC -O -release tests/net/h2_loadgen.d -of"$tmp/h2_loadgen" > /dev/null
$DC -O -release $I -i -of"$tmp/serve_slow" tests/net/serve_slow.d > /dev/null
# usage: memtest <label> <load command...>  (the command gets the port as its first argument)
memtest() {
    local label=$1; shift
    local port=$(( 18700 + RANDOM % 200 ))
    "$tmp/serve_slow" "$port" 1500 > "$tmp/srv.log" 2>&1 &
    local srv=$!
    sleep 0.5
    local idle=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
    ( while kill -0 $srv 2>/dev/null; do awk '/VmRSS/{print $2}' /proc/$srv/status 2>/dev/null; sleep 0.1; done > "$tmp/rss" ) &
    if ! "$@" "$port" > "$tmp/load.log" 2>&1; then
        echo "FAILED: $label load"; cat "$tmp/load.log"; fail=1
    fi
    local peak=$(sort -n "$tmp/rss" | tail -1)
    sleep 1
    local after=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
    kill -INT $srv
    for _ in $(seq 1 30); do kill -0 $srv 2>/dev/null || break; sleep 0.1; done
    if kill -0 $srv 2>/dev/null; then echo "FAILED: server did not stop on SIGINT"; kill -9 $srv; fail=1; fi
    wait $srv 2>/dev/null || true
    tail -1 "$tmp/load.log"
    echo "$label RSS: idle ${idle} KiB, peak ${peak} KiB, after the burst ${after} KiB"
    (( peak < 30 * 1024 )) || { echo "ABOVE 30 MB"; fail=1; }
}
loadgen_h1() { "$tmp/loadgen" "$1" 1000 500 1500; }
loadgen_h2() { "$tmp/h2_loadgen" "$1" 10 100 1500; }
memtest "HTTP/1.1 (1,000 connections)" loadgen_h1
memtest "HTTP/2 (10 connections x 100 streams)" loadgen_h2
rm -rf "$tmp"

echo "== compile-error tests (expected message + at most 2 error lines)"
for f in tests/compile_fail/*.d; do
    expect=$(sed -n 's#^// EXPECT: ##p' "$f")
    flags=$(sed -n 's#^// FLAGS: ##p' "$f")
    out=$($DC $I $flags -o- -c -verrors=simple "$f" 2>&1 || true)
    errlines=$(printf '%s\n' "$out" | grep -c . || true)
    if [[ "$out" != *"$expect"* ]]; then
        echo "FAILED $f: message not found"; printf '%s\n' "$out" | head -5; fail=1
    elif (( errlines > 2 )); then
        echo "FAILED $f: $errlines error lines (maximum 2)"; printf '%s\n' "$out"; fail=1
    else
        echo "ok  $f"
    fi
done

echo "== compile budget (app.d without the libs' codegen; target < 400 ms on DMD)"
best=999999
for _ in 1 2 3 4 5; do
    s=$(date +%s%N); $DC $I -o- -c examples/hello/source/app.d; e=$(date +%s%N)
    ms=$(( (e - s) / 1000000 )); (( ms < best )) && best=$ms
done
echo "app.d: ${best} ms (best of 5)"
(( best < 400 )) || { echo "ABOVE BUDGET"; fail=1; }

exit $fail
