/// libFuzzer target (LDC: -fsanitize=fuzzer,address). See tools/fuzz.sh.
module libfuzzer_parse;

import invariants;

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size)
{
    check(cast(const(char)[]) data[0 .. size]);
    return 0;
}
