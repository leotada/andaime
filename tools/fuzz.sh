#!/usr/bin/env bash
# Fuzzing with libFuzzer + AddressSanitizer (needs LDC).
# Usage: tools/fuzz.sh [seconds] [parse|h2|ws|json]   (default: 60 s, the HTTP/1 parser; ws: the WebSocket message layer;
# json: JsonValue and a typed decode).
# Findings go to tests/fuzz/crashes/.
set -euo pipefail
cd "$(dirname "$0")/.."
secs="${1:-60}"
target="${2:-parse}"
mkdir -p tests/fuzz/crashes
corpus="/tmp/vela_fuzz_corpus_$target"
extra=""
leaks=""
mkdir -p "$corpus"
case "$target" in
    parse)
        cp tests/fuzz/corpus/*.http "$corpus/"
        maxlen=4096 ;;
    h2)
        # one session (a GC object) is reused across inputs and holds malloc'd buffers; LeakSanitizer
        # does not scan the GC heap, so it would report them. tools/check.sh's memory tests cover leaks.
        extra="-detect_leaks=0"
        leaks="detect_leaks=0:"
        # start from the mutation fuzzer's seeds (requests, bodies, CONTINUATION, WebSockets over HTTP/2...): libFuzzer
        # alone rarely builds a valid HPACK block with an extended CONNECT
        ldmd2 -Ihttp/source -Itests/fuzz -i -run tests/fuzz/fuzz_h2.d --seeds "$corpus"
        maxlen=32768 ;;
    ws)
        # the target starts druntime itself (rt_init), whose module-constructor sorting keeps ~100 bytes of malloc that
        # LeakSanitizer reports at exit; the WebSocket code itself allocates only on the GC heap
        extra="-detect_leaks=0"
        leaks="detect_leaks=0:"
        maxlen=16384 ;;
    json)
        # same as ws: druntime is started by the target (rt_init); the reader allocates only on the GC heap
        extra="-detect_leaks=0"
        leaks="detect_leaks=0:"
        ldmd2 -Ihttp/source -Iweb/source -Itests/fuzz -i -run tests/fuzz/fuzz_json.d --seeds "$corpus"
        maxlen=8192 ;;
    *)
        echo "unknown target: $target (parse, h2, ws or json)"; exit 2 ;;
esac
ldmd2 -g -Ihttp/source -Iweb/source -Itests/fuzz -i -fsanitize=fuzzer,address -of"/tmp/vela_fuzz_$target" "tests/fuzz/libfuzzer_$target.d"
cd tests/fuzz/crashes
# ASan keeps freed blocks in a quarantine (256 MB by default) to catch use-after-free; 64 MB still
# catches them and leaves room under libFuzzer's RSS limit for millions of runs.
# detect_stack_use_after_return=0: ASan's "fake stack" keeps locals in heap frames the D GC does not scan, so a
# collection frees objects only a local still points to (the json target hit it after ~700k runs: a round trip "changed"
# a value). The GC-managed code is memory-safe D; the sanitizer is there for the @trusted/@system parts.
export ASAN_OPTIONS="${ASAN_OPTIONS:-${leaks}quarantine_size_mb=64:detect_stack_use_after_return=0}"
"/tmp/vela_fuzz_$target" "$corpus" $extra -max_len="$maxlen" -max_total_time="$secs" -print_final_stats=1 -artifact_prefix=./
