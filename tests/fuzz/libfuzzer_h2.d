/// libFuzzer target for the HTTP/2 session (LDC: -fsanitize=fuzzer,address). See tools/fuzz.sh.
module libfuzzer_h2 2025;

import h2_invariants;

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size)
{
    checkH2(data[0 .. size]);
    return 0;
}
