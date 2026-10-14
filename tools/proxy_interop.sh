#!/usr/bin/env bash
# vela behind a real reverse proxy that speaks h2c to its upstreams (Caddy, `reverse_proxy h2c://...`, the setup that
# docs/http2.md recommends). curl talks HTTP/1.1 to Caddy; Caddy talks cleartext HTTP/2 to vela. Checks that the requests
# reach the handlers as HTTP/2, an upload and a 4 MiB download intact, concurrent slow requests in parallel, Server-Sent
# Events arriving one at a time and a 20 MiB stream. Skips (exit 77) without Caddy or curl.
# Usage: DC=dmd tools/proxy_interop.sh   (CADDY=/path/to/caddy when it is not on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source"
caddy="${CADDY:-$(command -v caddy || true)}"
if [[ -z "$caddy" ]]; then echo "skip: caddy not available (set CADDY=/path/to/caddy)" >&2; exit 77; fi
if ! command -v curl > /dev/null; then echo "skip: curl missing" >&2; exit 77; fi
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
$DC $I -i -of"$tmp/h2_serve" tests/net/h2_serve.d > /dev/null
$DC $I -i -of"$tmp/stream_serve" tests/net/stream_serve.d > /dev/null

aport=$(( 19600 + RANDOM % 100 ))
sport=$(( aport + 100 ))
cport=$(( aport + 200 ))
"$tmp/h2_serve" "$aport" > "$tmp/app.log" 2>&1 &
pids+=($!)
"$tmp/stream_serve" "$sport" > "$tmp/stream.log" 2>&1 &
pids+=($!)
cat > "$tmp/Caddyfile" << EOF
{
	admin off
	auto_https off
	persist_config off
}
http://127.0.0.1:$cport {
	handle /ticks {
		reverse_proxy h2c://127.0.0.1:$sport
	}
	handle /mb/* {
		reverse_proxy h2c://127.0.0.1:$sport
	}
	handle {
		reverse_proxy h2c://127.0.0.1:$aport
	}
}
EOF
# (Caddy's own state goes to the temporary directory, not to the user's home)
XDG_DATA_HOME="$tmp/xdg" XDG_CONFIG_HOME="$tmp/xdg" \
    "$caddy" run --adapter caddyfile --config "$tmp/Caddyfile" > "$tmp/caddy.log" 2>&1 &
pids+=($!)
url="http://127.0.0.1:$cport"
for _ in $(seq 1 100); do curl -s -o /dev/null "$url/" 2> /dev/null && break; sleep 0.1; done

fail=0
f=0
out=$(curl -sS "$url/proto" || true)
[[ "$out" == "h2" ]] || { echo "FAILED: the handler saw '$out' through Caddy, expected h2"; f=1; }
out=$(curl -sS --data-binary @tests/net/h2_client.py "$url/echo" | cmp - tests/net/h2_client.py && echo same || true)
[[ "$out" == "same" ]] || { echo "FAILED: upload through Caddy"; f=1; }
out=$(curl -sS "$url/big/4096" | wc -c)
[[ "$out" -eq 4194304 ]] || { echo "FAILED: 4 MiB download through Caddy: $out bytes"; f=1; }
out=$(curl -sS -o /dev/null -w '%{http_code}' "$url/missing" || true)
[[ "$out" == "404" ]] || { echo "FAILED: 404 through Caddy: $out"; f=1; }
# 40 requests of 300 ms at once: multiplexed (or spread over a few connections), they finish in well under 40 x 300 ms
s=$(date +%s%N)
naps=()
for i in $(seq 1 40); do curl -sS -o "$tmp/nap.$i" "$url/nap/300" & naps+=($!); done
for p in "${naps[@]}"; do wait "$p" || true; done
ms=$(( ($(date +%s%N) - s) / 1000000 ))
naps=$(cat "$tmp"/nap.* 2> /dev/null | grep -o slept | wc -l)
if [[ "$naps" -ne 40 ]] || (( ms > 2000 )); then echo "FAILED: 40 concurrent requests through Caddy: $naps answered in $ms ms"; f=1; fi
(( f )) && fail=1 || echo "ok  Caddy -> vela over h2c: handler sees HTTP/2, upload, 4 MiB download, 404, 40 concurrent requests of 300 ms in $ms ms"

# Server-Sent Events: each event must reach the client when it is sent, not all at the end
start=$(date +%s%N)
stamped=$(curl -sN "$url/ticks" | while IFS= read -r line; do
    if [[ -n "$line" ]]; then echo "$(( ($(date +%s%N) - start) / 1000000 )) $line"; fi; done)
n=$(grep -c 'data: tick' <<< "$stamped" || true)
first=$(grep 'data: tick 0' <<< "$stamped" | cut -d' ' -f1)
last=$(grep 'data: tick 4' <<< "$stamped" | cut -d' ' -f1)
if [[ "$n" != 5 ]] || (( last - first < 600 )); then
    echo "FAILED: SSE through Caddy: expected 5 events spread over time, got $n (first ${first:-?} ms, last ${last:-?} ms)"; fail=1
else
    echo "ok  SSE through Caddy: 5 events, first at ${first} ms, last at ${last} ms"
fi
bytes=$(curl -s "$url/mb/20" | wc -c)
if [[ "$bytes" -ne $(( 20 * 1024 * 1024 )) ]]; then echo "FAILED: 20 MiB stream through Caddy: $bytes bytes"; fail=1
else echo "ok  20 MiB stream through Caddy intact"; fi

if (( fail )); then echo "--- caddy log"; tail -20 "$tmp/caddy.log"; echo "--- vela logs"; tail -10 "$tmp/app.log" "$tmp/stream.log"; fi
exit $fail
