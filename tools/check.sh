#!/usr/bin/env bash
# Full vela verification. Usage: tools/check.sh   (DC=ldmd2 to use LDC)
#
# Every step is a "section". A section that cannot run (missing Postgres, h2spec, Playwright...) exits 77 and
# prints "skip: <reason>" on stderr; the summary at the end lists what was skipped.
#   VELA_STRICT=1  a skipped section fails the run (CI uses this, so a green run means everything ran)
#   VELA_ALLOW_SKIP="browser h2spec"  with VELA_STRICT=1, a skipped section whose name or reason contains one of
#                  these words is still accepted (CI runs the browser test in its own job)
#   VELA_ONLY="browser"  run only the sections whose name contains this text
#   VELA_CI=1      the compile-time budget is printed but does not fail the run (shared runners are noisy)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source"
STRICT="${VELA_STRICT:-0}"
CI="${VELA_CI:-0}"
export DC
work=$(mktemp -d)
errf="$work/stderr"
trap 'rm -rf "$work"' EXIT

# build_test <source.d>: compiles into $work and prints the binary's path. Tests that can skip themselves (exit 77)
# are built first and run afterwards, because `$DC -run` turns every non-zero exit code into 1.
build_test() {
    local out="$work/$(basename "$1" .d)"
    $DC $I -i -of"$out" "$1" > /dev/null
    echo "$out"
}

passed=0
failed=()
skipped=()

# section <name> <function-or-command...>
# Runs in a subshell with `set -e`, so the first failing command ends the section.
section() {
    local name=$1; shift
    if [[ -n "${VELA_ONLY:-}" && "$name" != *"$VELA_ONLY"* ]]; then return 0; fi
    echo "== $name"
    local rc=0
    set +e
    ( set -e; "$@" ) 2> "$errf"
    rc=$?
    set -e
    cat "$errf" >&2
    if (( rc == 0 )); then
        passed=$(( passed + 1 ))
    elif (( rc == 77 )); then
        local why
        why=$(sed -n 's/^skip: *//p' "$errf" | head -1)
        echo "skipped: ${why:-no reason given}"
        skipped+=("$name${why:+ ($why)}")
    else
        echo "FAILED: $name (exit $rc)"
        failed+=("$name")
    fi
}

# have_libssl3: the server and the tests load libssl.so.3 with dlopen. ldconfig is often missing from PATH
# for normal users (openSUSE, Fedora), so also try /sbin.
have_libssl3() {
    local ldc libs; ldc=$(command -v ldconfig || echo /sbin/ldconfig)
    [[ -x "$ldc" ]] || return 1
    # (no "| grep -q" under pipefail: grep exiting early kills ldconfig with SIGPIPE and fails the pipeline)
    libs=$("$ldc" -p 2> /dev/null || true)
    [[ "$libs" == *libssl.so.3* ]]
}

# ---------------------------------------------------------------- unit and web-layer tests

s_unittests() {
    $DC -unittest -main $I -i -run engine/source/vela/engine/package.d
    $DC -unittest -main $I -i -run web/source/vela/web/package.d
    $DC -unittest -main $I -i -run drivers/pg/source/vela/db/package.d
}

s_web() {
    local rc=0 t
    # (helper modules for these tests live in tests/web/support/, which is on the import path)
    for t in tests/web/*.d; do
        if ! $DC -unittest -main $I -Itests/web -i -run "$t" > /dev/null 2>&1; then
            echo "FAILED: $t"
            $DC -unittest -main $I -Itests/web -i -run "$t" 2>&1 | grep -v '^vela: error in' | tail -15
            rc=1
        fi
    done
    echo "ok  $(ls tests/web/*.d | wc -l) files in tests/web"
    return $rc
}


# -Ijobs/source stays on these commands only. The global I= must not grow it: the compile budget
# type-checks examples/hello with the current -I list.
s_jobs() {
    local rc=0 t ji="-Ijobs/source"
    for t in tests/jobs/*.d; do
        if ! $DC -unittest -main $I $ji -i -run "$t" > /dev/null 2>&1; then
            echo "FAILED: $t"
            $DC -unittest -main $I $ji -i -run "$t" 2>&1 | tail -40
            rc=1
        fi
    done
    if ! $DC -unittest -main $I $ji -i -run jobs/source/vela/jobs/package.d > /dev/null 2>&1; then
        echo "FAILED: jobs/source/vela/jobs/package.d"
        $DC -unittest -main $I $ji -i -run jobs/source/vela/jobs/package.d 2>&1 | tail -40
        rc=1
    fi
    echo "ok  $(ls tests/jobs/*.d | wc -l) files in tests/jobs"
    return $rc
}

s_docs() {
    tools/doc_examples.sh
}

s_openapi() {
    tools/openapi_validate.sh
}

s_parser() {
    $DC $I -i -run tests/fuzz/corpus_test.d
    $DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_parse.d 300000
}

s_h2_session() {
    $DC -unittest $I -i -run tests/h2/session_test.d
    $DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_h2.d 300000
}

s_ws_session() {
    $DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_ws.d 300000
}

s_json_fuzz() {
    $DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_json.d 300000
}

s_example_tests() {
    $DC -unittest -main $I -i -run examples/hello/source/app.d > /dev/null
}

s_hot_path() {
    $DC $I -i -run tests/alloc/hot_path.d
    $DC $I -i -run tests/alloc/h2_hot_path.d
    $DC $I -i -run tests/alloc/ws_hot_path.d
}

# ---------------------------------------------------------------- network tests

s_net() {
    ulimit -n 20000 2>/dev/null || true
    $DC $I -i -run tests/net/epoll_net.d
    $DC $I -i -run tests/net/workers_net.d
    $DC $I -i -run tests/net/stream_net.d
    $DC $I -i -run tests/net/spawn_net.d
    # jobs_worker_net.d imports vela.jobs; -Ijobs/source stays on this command only
    $DC $I -Ijobs/source -i -run tests/net/jobs_worker_net.d
}

s_h2_net() {
    ulimit -n 20000 2>/dev/null || true
    $DC $I -i -run tests/net/h2_net.d
}

s_ws_net() {
    ulimit -n 20000 2>/dev/null || true
    $DC $I -i -run tests/net/ws_net.d
    $DC $I -i -run tests/net/ws_h2_net.d
}

s_ws_interop() {
    tools/ws_interop.sh
}

s_tls_net() {
    "$(build_test tests/net/tls_net.d)"
}

s_interop() {
    tools/h2_interop.sh
}

s_proxy_interop() {
    tools/proxy_interop.sh
}

s_crash() {
    tools/crash_check.sh
}

s_stream_interop() {
    tools/stream_interop.sh
}

s_browser() {
    # (under $work, removed by the script's own trap: a trap on a "local" fires after the variable is gone)
    local btmp="$work/browser"; mkdir -p "$btmp"
    if ! command -v python3 > /dev/null || ! command -v openssl > /dev/null; then
        echo "skip: python3 or openssl missing" >&2; return 77
    fi
    $DC $I -i -of"$btmp/browser_serve" tests/net/browser_serve.d > /dev/null
    python3 tests/net/browser_test.py "$btmp/browser_serve"
}

s_postgres() {
    tools/with_postgres.sh "$(build_test tests/db/pg_net.d)"
    # pg_jobs.d imports vela.jobs and vela.jobs.pg. Those -I flags stay on this compile only.
    tools/with_postgres.sh "$(I="$I -Ijobs/source -Idrivers/pgjobs/source" build_test tests/db/pg_jobs.d)"
}

s_client() {
    tools/with_upstream.sh "$(build_test tests/net/client_net.d)"
}

s_api_e2e() {
    tools/with_postgres.sh tools/with_upstream.sh tools/api_e2e.sh
}

# ---------------------------------------------------------------- memory

# memtest <label> <limit KiB> "<server args after the port>" <load command...>
# (the load command gets the port as its first argument). Needs $tmp (set by the caller).
memtest() {
    local label=$1 limit=$2 srvargs=$3; shift 3
    local rc=0
    local port=$(( 18700 + RANDOM % 200 ))
    "$tmp/serve_slow" "$port" $srvargs > "$tmp/srv.log" 2>&1 &
    local srv=$!
    sleep 0.5
    local idle=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
    ( while kill -0 $srv 2>/dev/null; do awk '/VmRSS/{print $2}' /proc/$srv/status 2>/dev/null; sleep 0.1; done > "$tmp/rss" ) &
    if ! "$@" "$port" > "$tmp/load.log" 2>&1; then
        echo "FAILED: $label load"; cat "$tmp/load.log"; rc=1
    fi
    local peak=$(sort -n "$tmp/rss" | tail -1)
    sleep 1
    local after=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
    kill -INT $srv
    for _ in $(seq 1 30); do kill -0 $srv 2>/dev/null || break; sleep 0.1; done
    if kill -0 $srv 2>/dev/null; then echo "FAILED: server did not stop on SIGINT"; kill -9 $srv; rc=1; fi
    wait $srv 2>/dev/null || true
    tail -1 "$tmp/load.log"
    echo "$label RSS: idle ${idle} KiB, peak ${peak} KiB, after the burst ${after} KiB"
    (( peak < limit )) || { echo "ABOVE $(( limit / 1024 )) MB"; rc=1; }
    return $rc
}
loadgen_h1() { "$tmp/loadgen" "$1" 1000 500 1500; }
loadgen_h2() { "$tmp/h2_loadgen" "$1" 10 100 1500; }
loadgen_tls_h1() { "$tmp/tls_loadgen" "$1" 1000 "$tmp/cert.pem"; }
loadgen_tls_h2() { "$tmp/tls_loadgen" "$1" 1000 "$tmp/cert.pem" h2; }
loadgen_ws() { "$tmp/ws_loadgen" "$1" 1000 1500; }
loadgen_ws_h2() { "$tmp/ws_loadgen" "$1" 1000 1500 h2 100; }

memory_build() {
    ulimit -n 20000 2>/dev/null || ulimit -n 4096 2>/dev/null || true
    tmp=$(mktemp -d)
    $DC -O -release tests/net/loadgen.d -of"$tmp/loadgen" > /dev/null
    $DC -O -release tests/net/h2_loadgen.d -of"$tmp/h2_loadgen" > /dev/null
    $DC -O -release tests/net/ws_loadgen.d -of"$tmp/ws_loadgen" > /dev/null
    $DC -O -release $I -i -of"$tmp/serve_slow" tests/net/serve_slow.d > /dev/null
    $DC -O -release -Iengine/source -Ihttp/source -i -of"$tmp/tls_loadgen" tests/net/tls_loadgen.d > /dev/null
}

s_memory() {
    local rc=0
    memory_build
    trap 'rm -rf "$tmp"' EXIT
    memtest "HTTP/1.1 (1,000 connections)" $(( 30 * 1024 )) 1500 loadgen_h1 || rc=1
    memtest "HTTP/2 (10 connections x 100 streams)" $(( 30 * 1024 )) 1500 loadgen_h2 || rc=1
    # each open WebSocket holds a fiber, its request buffer and its WsConn (measured: ~21 MB peak for 1,000)
    memtest "WebSocket (1,000 open connections)" $(( 30 * 1024 )) 1500 loadgen_ws || rc=1
    # the same over HTTP/2 (RFC 8441): a stream instead of a connection each (measured: ~19 MB peak)
    memtest "WebSocket over HTTP/2 (10 connections x 100 streams)" $(( 30 * 1024 )) 1500 loadgen_ws_h2 || rc=1
    return $rc
}

# HTTPS: OpenSSL keeps tens of KiB per connection on top of the request itself, so it has its own ceiling.
# Measured peaks for 1,000 connections: ~44 MB with OpenSSL 3.0; with OpenSSL 3.5, 55-65 MB before the network buffers
# moved to the GC heap and 56-71 MB after (HTTP/1.1 over TLS is the high one: the same 1,000 buffers take ~3 MB more as
# GC regions than in the malloc heap). So the default is 80 MB; VELA_TLS_RSS_MB overrides it. Handshakes run one after another in the
# load generator, so the handler waits longer for all 1,000 requests to be in flight at once.
s_memory_tls() {
    local limit_mb="${VELA_TLS_RSS_MB:-80}"
    if ! command -v openssl > /dev/null || ! have_libssl3; then
        echo "skip: openssl or libssl.so.3 missing" >&2; return 77
    fi
    local rc=0
    memory_build
    trap 'rm -rf "$tmp"' EXIT
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -days 2 -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2> /dev/null
    memtest "HTTPS HTTP/1.1 (1,000 connections)" $(( limit_mb * 1024 )) "5000 $tmp/cert.pem $tmp/key.pem" loadgen_tls_h1 || rc=1
    memtest "HTTPS h2 (1,000 connections)" $(( limit_mb * 1024 )) "5000 $tmp/cert.pem $tmp/key.pem" loadgen_tls_h2 || rc=1
    return $rc
}

# 200 uploads of 512 KiB at once go through the buffer pool's exact-size (above 64 KiB) path. Their buffers are GC
# memory: the peak is what 200 bodies need (about 100 MB plus the runtime), and after the burst the loop's trim
# (a collection once it has been quiet for a second) must give most of it back.
s_memory_uploads() {
    ulimit -n 20000 2>/dev/null || true
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    $DC -O -release tests/net/upload_loadgen.d -of"$tmp/upload_loadgen" > /dev/null
    $DC -O -release $I -i -of"$tmp/serve_slow" tests/net/serve_slow.d > /dev/null
    local port=$(( 18700 + RANDOM % 200 ))
    "$tmp/serve_slow" "$port" 1500 > "$tmp/srv.log" 2>&1 &
    local srv=$!
    sleep 0.5
    ( while kill -0 $srv 2>/dev/null; do awk '/VmRSS/{print $2}' /proc/$srv/status 2>/dev/null; sleep 0.05; done > "$tmp/rss" ) &
    local rc=0
    "$tmp/upload_loadgen" "$port" 200 512 || rc=1
    local peak; peak=$(sort -n "$tmp/rss" | tail -1)
    sleep 3.5
    local after; after=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
    kill -INT $srv
    for _ in $(seq 1 30); do kill -0 $srv 2>/dev/null || break; sleep 0.1; done
    kill -9 $srv 2>/dev/null || true
    echo "200 uploads of 512 KiB: peak RSS ${peak} KiB, 3.5 s after the burst ${after} KiB"
    (( peak < 220 * 1024 )) || { echo "ABOVE 220 MB at the peak"; rc=1; }
    (( after < peak * 6 / 10 )) || { echo "memory did not come back after the burst (${after} KiB of ${peak} KiB)"; rc=1; }
    return $rc
}

# ---------------------------------------------------------------- compile-time checks

s_compile_fail() {
    local rc=0 f expect flags out errlines
    # Newer DMD prints source context by default and has -verrors=simple to turn it off; older DMD rejects the
    # switch (and prints no context anyway). LDC (ldc2 and ldmd2) uses --verrors-context=false; some LDC builds show
    # the context by default.
    local errflag="" f2
    local probe; probe=$(mktemp -d)
    echo 'void main() {}' > "$probe/ok.d"
    for f2 in -verrors=simple --verrors-context=false; do
        if $DC $f2 -o- -c "$probe/ok.d" > /dev/null 2>&1; then errflag=$f2; break; fi
    done
    rm -rf "$probe"
    for f in tests/compile_fail/*.d; do
        expect=$(sed -n 's#^// EXPECT: ##p' "$f")
        flags=$(sed -n 's#^// FLAGS: ##p' "$f")
        out=$($DC $I $flags -o- -c $errflag "$f" 2>&1 || true)
        errlines=$(printf '%s\n' "$out" | grep -c . || true)
        if [[ "$out" != *"$expect"* ]]; then
            echo "FAILED $f: message not found"; printf '%s\n' "$out" | head -5; rc=1
        elif (( errlines > 2 )); then
            echo "FAILED $f: $errlines error lines (maximum 2)"; printf '%s\n' "$out"; rc=1
        else
            echo "ok  $f"
        fi
    done
    return $rc
}

# DUB packaging: sub-package dependencies and layering (vela:web must not import vela:engine, so building it alone
# proves the direction), the vela-pg and vela-pg-jobs path dependencies and both examples.
s_dub() {
    if ! command -v dub > /dev/null; then echo "skip: dub not installed" >&2; return 77; fi
    local rc=0
    local dubc="--compiler=${DC/ldmd2/ldc2}"
    dub build $dubc -q || rc=1
    dub build $dubc -q :http || rc=1
    dub build $dubc -q :web || rc=1
    dub build $dubc -q :engine || rc=1
    dub build $dubc -q :jobs || rc=1
    (cd drivers/pg && dub build $dubc -q) || rc=1
    dub build $dubc -q --root=drivers/pgjobs || rc=1
    (cd examples/hello && dub build $dubc -q) || rc=1
    (cd examples/api && dub build $dubc -q) || rc=1
    # the core must never import a driver; jobs depends on web and engine, not on vela-pg
    if grep -rn "import vela\.db" http web engine source jobs --include=*.d; then
        echo "FAILED: the core or vela:jobs imports a driver (vela.db)"; rc=1
    fi
    return $rc
}

# The 400 ms target protects template cost, so it is measured with -o- -c: type-check only, no code generation and no
# linking. The edit-and-rebuild time (a real `dub build` after touching app.d) is reported, not enforced.
# Wall-clock time on a laptop moves by 10% or more with the CPU clock and the temperature (the same unchanged tree measured
# 335-390 ms in one afternoon), so the target is 400 ms but the run fails only above 440 ms: a real regression, not noise.
s_budget() {
    local best=999999 s e ms round
    # best of 5; if that is over the target, measure again (up to 3 rounds): a busy machine only adds time
    for round in 1 2 3; do
        for _ in 1 2 3 4 5; do
            s=$(date +%s%N); $DC $I -o- -c examples/hello/source/app.d; e=$(date +%s%N)
            ms=$(( (e - s) / 1000000 )); (( ms < best )) && best=$ms
        done
        (( best < 400 )) && break
    done
    echo "examples/hello/source/app.d type-checks in ${best} ms (best of up to 15, -o- -c; target 400 ms, fails above 440 ms, on DMD)"
    if command -v dub > /dev/null; then
        local dubc="--compiler=${DC/ldmd2/ldc2}"
        ( cd examples/hello
          dub build $dubc -q > /dev/null 2>&1
          touch source/app.d
          s=$(date +%s%N); dub build $dubc -q > /dev/null 2>&1; e=$(date +%s%N)
          echo "examples/hello edit-and-rebuild: $(( (e - s) / 1000000 )) ms (touch app.d + dub build, debug; reported, not enforced)" )
    fi
    if (( best >= 440 )); then
        if [[ "$CI" == 1 ]]; then echo "above the budget (VELA_CI=1: not failing)"
        else echo "ABOVE BUDGET"; return 1; fi
    elif (( best >= 400 )); then
        echo "warning: above the 400 ms target but within the noise of this machine"
    fi
}

section "module unittests" s_unittests
section "web-layer features (groups, locals, onError, CORS, static files, OpenAPI, middlewares)" s_web
section "background jobs (memory store, retry, unique window)" s_jobs
section "documentation examples compile (blocks marked // check)" s_docs
section "OpenAPI document validity (openapi-spec-validator)" s_openapi
section "HTTP parser: attack corpus and mutation fuzz" s_parser
section "HTTP/2: session (frames, streams, flow control, errors, limits) and mutation fuzz" s_h2_session
section "WebSocket: message layer mutation fuzz (frames, fragments, control frames, close codes, limits)" s_ws_session
section "JSON reader: mutation fuzz (JsonValue round trip, depth limit, typed decode)" s_json_fuzz
section "example tests (TestClient, no network)" s_example_tests
section "hot path without GC allocation (HTTP/1.1, HTTP/2, WebSocket messages)" s_hot_path
section "network tests (EpollLoop + fibers: cancellation, ceiling, deadlines, pools, background fibers)" s_net
section "HTTP/2 network tests (h2c, multiplexing, cancellation, deadlines, flow control, upgrade, stop)" s_h2_net
section "WebSocket network tests (takeover, broadcast, backpressure, pings, close handshake, graceful stop, client, over HTTP/2)" s_ws_net
section "HTTPS (ALPN, HTTP/1.1 and HTTP/2 over TLS, handshake limits, cancellation, certificate reload, wss)" s_tls_net
section "fiber stack overflow: the crash message names the request" s_crash
section "HTTP/2 and HTTPS interoperability (curl, python-h2, h2spec)" s_interop
section "streamed responses against curl (SSE and a 20 MiB stream, HTTP/1.1 and h2c)" s_stream_interop
section "WebSockets against python websockets (server and client, with and without permessage-deflate; RFC 8441 over h2c and TLS)" s_ws_interop
section "behind a reverse proxy over h2c (Caddy: requests, upload, concurrency, SSE, 20 MiB stream)" s_proxy_interop
section "real browser (Chromium via Playwright: HTTPS, h2, redirect port, HTTP/1.1 fallback)" s_browser
section "PostgreSQL (async libpq, job queue)" s_postgres
section "HTTP/HTTPS client and thread pool" s_client
section "real API example end to end (Postgres + external API + auth + CORS + static files + OpenAPI)" s_api_e2e
section "memory: 1,000 in-flight requests over HTTP/1.1 and HTTP/2, 1,000 open WebSockets on each (peak RSS < 30 MB)" s_memory
section "memory: 1,000 in-flight requests over HTTPS (peak RSS < 80 MB, depends on the OpenSSL version)" s_memory_tls
section "memory: 200 uploads of 512 KiB at once (above the pool classes), memory comes back" s_memory_uploads
section "compile-error tests (expected message + at most 2 error lines)" s_compile_fail
section "DUB builds and layering" s_dub
section "compile budget (type-check; target < 400 ms on DMD) and rebuild time" s_budget

echo
echo "================ summary ($DC)"
echo "passed ${passed}, failed ${#failed[@]}, skipped ${#skipped[@]}"
for n in "${failed[@]}"; do echo "  FAILED:  $n"; done
for n in "${skipped[@]}"; do echo "  skipped: $n"; done
if (( ${#failed[@]} > 0 )); then exit 1; fi
if [[ "$STRICT" == 1 ]]; then
    unexpected=()
    for n in "${skipped[@]}"; do
        allowed=0
        for w in ${VELA_ALLOW_SKIP:-}; do [[ "$n" == *"$w"* ]] && allowed=1; done
        (( allowed )) || unexpected+=("$n")
    done
    if (( ${#unexpected[@]} > 0 )); then
        echo "VELA_STRICT=1: ${#unexpected[@]} skipped section(s) count as failures"
        exit 1
    fi
fi
exit 0
