#!/usr/bin/env bash
# HTTP/2 and HTTPS against independent implementations: h2spec (conformance), curl (nghttp2,
# OpenSSL) and python-h2 (with Python's ssl module), on a cleartext server (h2c) and on a TLS
# server (ALPN). A tool that is not installed is skipped; the script then exits 77 (after running the rest).
# Usage: DC=dmd tools/h2_interop.sh   (H2SPEC=/path/to/h2spec when it is not on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC $I -i -of"$tmp/h2_serve" tests/net/h2_serve.d > /dev/null
fail=0
skips=()
# finish: a failure wins; otherwise any missing tool makes the whole run "skipped" (exit 77, see tools/check.sh)
finish() {
    (( fail )) && exit 1
    if (( ${#skips[@]} )); then
        local IFS=,
        echo "skip: ${skips[*]} not available" >&2
        exit 77
    fi
    exit 0
}
h2spec_bin="${H2SPEC:-$(command -v h2spec || true)}"
have_curl=0; curl -V 2>/dev/null | grep -q HTTP2 && have_curl=1
have_py=0; python3 -c "import h2" 2>/dev/null && have_py=1

# start <port> [cert key]: runs the server and waits until it answers
start() {
    "$tmp/h2_serve" "$@" > "$tmp/srv_$1.log" 2>&1 &
    pids+=($!)
    local scheme=http; [[ $# -gt 1 ]] && scheme=https
    for _ in $(seq 1 50); do
        curl -sk -o /dev/null "$scheme://127.0.0.1:$1/" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "FAILED: the $scheme server did not start"; cat "$tmp/srv_$1.log"; fail=1
}

# h2spec_run <label> <expected failures> <args...>
h2spec_run() {
    local label=$1 known=$2; shift 2
    "$h2spec_bin" "$@" -o 3 > "$tmp/h2spec.log" 2>&1 || true
    local summary failures
    # -a: the log has control characters, and without it grep answers "binary file matches" instead of the line
    summary=$(grep -a -E '^[0-9]+ tests,' "$tmp/h2spec.log" || true)
    failures=$(grep -a -c '×' "$tmp/h2spec.log" || true)
    if [[ -z "$summary" ]]; then
        echo "FAILED h2spec ($label) did not run"; tail -5 "$tmp/h2spec.log"; fail=1
    elif [[ "$known" == "preface" ]]; then
        # 3.5/2 cannot pass on a port that also serves HTTP/1.1: an invalid preface is just a
        # malformed HTTP/1.1 request there, and it gets a 400 (h2spec expects GOAWAY)
        if (( failures != $(grep -a -c '× 2: Sends invalid connection preface' "$tmp/h2spec.log" || true) )); then
            echo "FAILED h2spec ($label): $summary"; grep -a -A6 '×' "$tmp/h2spec.log" | head -60; fail=1
        else
            echo "ok  h2spec ($label): $summary (the only failure is 3.5/2, expected on a mixed HTTP/1.1 + h2c port)"
        fi
    elif (( failures != 0 )); then
        echo "FAILED h2spec ($label): $summary"; grep -a -A6 '×' "$tmp/h2spec.log" | head -60; fail=1
    else
        echo "ok  h2spec ($label): $summary"
    fi
}

# ---------------------------------------------------------------- cleartext (h2c)
port=$(( 19100 + RANDOM % 400 ))
start "$port"
url="http://127.0.0.1:$port"
if (( have_curl )); then
    f=0
    out=$(curl -sS --http2-prior-knowledge -w ' %{http_version}' "$url/proto")
    [[ "$out" == "h2 2" ]] || { echo "FAILED curl prior knowledge: $out"; f=1; }
    out=$(curl -sS --http2 -w ' %{http_version}' "$url/proto")
    [[ "$out" == "h2 2" ]] || { echo "FAILED curl Upgrade: h2c: $out"; f=1; }
    out=$(curl -sS --http2-prior-knowledge --data-binary @tests/net/h2_client.py "$url/echo" | cmp - tests/net/h2_client.py && echo same)
    [[ "$out" == "same" ]] || { echo "FAILED curl upload"; f=1; }
    out=$(curl -sS --http2-prior-knowledge "$url/big/4096" | wc -c)
    [[ "$out" -eq 4194304 ]] || { echo "FAILED curl 4 MiB download: $out bytes"; f=1; }
    out=$(curl -sS --http1.1 "$url/proto")
    [[ "$out" == "http/1.1" ]] || { echo "FAILED HTTP/1.1 on the same port: $out"; f=1; }
    (( f )) && fail=1 || echo "ok  curl (h2c): prior knowledge, Upgrade: h2c, upload, 4 MiB download, HTTP/1.1 alongside"
else
    skips+=("curl with HTTP/2")
fi
if (( have_py )); then python3 tests/net/h2_client.py "$port" || fail=1
else skips+=("python module h2 (pip install h2)"); fi
if [[ -n "$h2spec_bin" ]]; then h2spec_run "h2c" preface -h 127.0.0.1 -p "$port"
else skips+=("h2spec (set H2SPEC=/path/to/h2spec)"); fi

# ---------------------------------------------------------------- TLS (ALPN)
if ! command -v openssl > /dev/null; then
    skips+=("openssl command")
    finish
fi
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$tmp/key.pem" \
    -out "$tmp/cert.pem" -days 2 -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2> /dev/null
tport=$(( port + 1 ))
start "$tport" "$tmp/cert.pem" "$tmp/key.pem"
turl="https://127.0.0.1:$tport"
if (( have_curl )); then
    f=0
    c=(curl -sS --cacert "$tmp/cert.pem")
    out=$("${c[@]}" -w ' %{http_version}' "$turl/proto")
    [[ "$out" == "h2 2" ]] || { echo "FAILED curl HTTPS ALPN h2: $out"; f=1; }
    out=$("${c[@]}" --http1.1 -w ' %{http_version}' "$turl/proto")
    [[ "$out" == "http/1.1 1.1" ]] || { echo "FAILED curl HTTPS ALPN http/1.1: $out"; f=1; }
    for v in --http2 --http1.1; do
        out=$("${c[@]}" $v --data-binary @tests/net/h2_client.py "$turl/echo" | cmp - tests/net/h2_client.py && echo same)
        [[ "$out" == "same" ]] || { echo "FAILED curl HTTPS upload ($v)"; f=1; }
        out=$("${c[@]}" $v "$turl/big/4096" | wc -c)
        [[ "$out" -eq 4194304 ]] || { echo "FAILED curl HTTPS 4 MiB download ($v): $out bytes"; f=1; }
    done
    out=$(curl -sS -o /dev/null -w '%{http_code}' "$turl/proto" 2>&1 || true)
    [[ "$out" != "200" ]] || { echo "FAILED: an untrusted certificate was accepted"; f=1; }
    (( f )) && fail=1 || echo "ok  curl (HTTPS): ALPN h2 and http/1.1, upload and 4 MiB download on both, certificate verified"
fi
if (( have_py )); then python3 tests/net/h2_client.py "$tport" "$tmp/cert.pem" || fail=1; fi
if [[ -n "$h2spec_bin" ]]; then h2spec_run "TLS" none -t -k -h 127.0.0.1 -p "$tport"; fi
finish
