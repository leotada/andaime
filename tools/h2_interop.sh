#!/usr/bin/env bash
# HTTP/2 against independent implementations: h2spec (conformance), curl (nghttp2) and
# python-h2. Each one skips itself with a warning when it is not installed.
# Usage: DC=dmd tools/h2_interop.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
tmp=$(mktemp -d)
$DC $I -i -of"$tmp/h2_serve" tests/net/h2_serve.d > /dev/null
port=$(( 19100 + RANDOM % 400 ))
"$tmp/h2_serve" "$port" > "$tmp/srv.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
done
fail=0
url="http://127.0.0.1:$port"

if curl -V 2>/dev/null | grep -q HTTP2; then
    out=$(curl -sS --http2-prior-knowledge -w ' %{http_version}' "$url/proto")
    [[ "$out" == "h2 2" ]] || { echo "FAILED curl prior knowledge: $out"; fail=1; }
    out=$(curl -sS --http2 -w ' %{http_version}' "$url/proto")
    [[ "$out" == "h2 2" ]] || { echo "FAILED curl Upgrade: h2c: $out"; fail=1; }
    out=$(curl -sS --http2-prior-knowledge --data-binary @tests/net/h2_client.py "$url/echo" | cmp - tests/net/h2_client.py && echo same)
    [[ "$out" == "same" ]] || { echo "FAILED curl upload"; fail=1; }
    out=$(curl -sS --http2-prior-knowledge "$url/big/4096" | wc -c)
    [[ "$out" -eq 4194304 ]] || { echo "FAILED curl 4 MiB download: $out bytes"; fail=1; }
    out=$(curl -sS --http1.1 "$url/proto")
    [[ "$out" == "http/1.1" ]] || { echo "FAILED HTTP/1.1 on the same port: $out"; fail=1; }
    (( fail )) || echo "ok  curl: prior knowledge, Upgrade: h2c, upload, 4 MiB download, HTTP/1.1 alongside"
else
    echo "warning: curl without HTTP/2 support; skipping the curl checks"
fi

if python3 -c "import h2" 2>/dev/null; then
    python3 tests/net/h2_client.py "$port" || fail=1
else
    echo "warning: python3 module h2 not found (pip install h2); skipping the python-h2 checks"
fi

h2spec_bin="${H2SPEC:-$(command -v h2spec || true)}"
if [[ -n "$h2spec_bin" ]]; then
    # 3.5/2 cannot pass on a port that also serves HTTP/1.1: an invalid preface is just a
    # malformed HTTP/1 request there, and it gets a 400 (h2spec expects silence or GOAWAY)
    "$h2spec_bin" -h 127.0.0.1 -p "$port" -o 3 > "$tmp/h2spec.log" 2>&1 || true
    summary=$(grep -E '^[0-9]+ tests,' "$tmp/h2spec.log" || true)
    failures=$(grep -c '×' "$tmp/h2spec.log" || true)
    known=$(grep -c '× 2: Sends invalid connection preface' "$tmp/h2spec.log" || true)
    if [[ -z "$summary" ]]; then
        echo "FAILED h2spec did not run"; tail -5 "$tmp/h2spec.log"; fail=1
    elif (( failures != known )); then
        echo "FAILED h2spec: $summary"; grep -A6 '×' "$tmp/h2spec.log" | head -60; fail=1
    else
        echo "ok  h2spec: $summary (the only failure is 3.5/2, expected on a mixed HTTP/1.1 + h2c port)"
    fi
else
    echo "warning: h2spec not found (set H2SPEC=/path/to/h2spec); skipping the conformance suite"
fi
exit $fail
