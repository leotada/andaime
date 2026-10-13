#!/usr/bin/env bash
# Starts the HTTP/HTTPS test upstream (tests/net/upstream.py), exports
# VELA_UP_PLAIN / VELA_UP_TLS / VELA_UP_CERT and runs the given command.
# Without python3 or openssl, runs the command without the variables (the test declares itself skipped, exit 77).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v python3 >/dev/null || ! command -v openssl >/dev/null; then
    echo "(python3/openssl missing: the HTTP client test will be skipped)" >&2
    exec "$@"
fi
dir=$(mktemp -d)
trap 'kill $up 2>/dev/null || true; rm -rf "$dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 2 \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
python3 tests/net/upstream.py "$dir/cert.pem" "$dir/key.pem" > "$dir/out" 2>/dev/null &
up=$!
for _ in $(seq 1 50); do [ -s "$dir/out" ] && break; sleep 0.1; done
export VELA_UP_PLAIN=$(awk '{print $2}' "$dir/out") VELA_UP_TLS=$(awk '{print $4}' "$dir/out") VELA_UP_CERT="$dir/cert.pem"
"$@"
