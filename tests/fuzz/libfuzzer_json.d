/// libFuzzer target for the JSON reader: `JsonValue` and a typed decode (LDC: -fsanitize=fuzzer,address). See tools/fuzz.sh.
module libfuzzer_json 2025;

import json_invariants;

/// There is no D `main` under libFuzzer: start druntime here (the reader allocates on the GC heap).
extern (C) int LLVMFuzzerInitialize(int* argc, char*** argv)
{
    import core.runtime : rt_init;

    rt_init();
    return 0;
}

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size)
{
    checkJson(data[0 .. size]);
    return 0;
}
