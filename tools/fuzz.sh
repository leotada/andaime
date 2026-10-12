#!/usr/bin/env bash
# Fuzzing do parser HTTP com libFuzzer + AddressSanitizer (precisa do LDC).
# Uso: tools/fuzz.sh [segundos]   (padrão 60). Descobertas ficam em tests/fuzz/crashes/.
set -euo pipefail
cd "$(dirname "$0")/.."
secs="${1:-60}"
mkdir -p tests/fuzz/crashes /tmp/vela_fuzz_corpus
cp tests/fuzz/corpus/*.http /tmp/vela_fuzz_corpus/
ldmd2 -g -Ihttp/source -Itests/fuzz -i -fsanitize=fuzzer,address -of/tmp/vela_fuzz_bin tests/fuzz/libfuzzer_parse.d
cd tests/fuzz/crashes
/tmp/vela_fuzz_bin /tmp/vela_fuzz_corpus -max_len=4096 -max_total_time="$secs" -print_final_stats=1 -artifact_prefix=./
