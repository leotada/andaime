/// libFuzzer target for `Timestamp` and `CalendarDate` text (LDC: -fsanitize=fuzzer,address). See tools/fuzz.sh.
module libfuzzer_time 2025;

import time_invariants;

/// There is no D `main` under libFuzzer: start druntime here (the invariants allocate their messages on the GC heap).
extern (C) int LLVMFuzzerInitialize(int* argc, char*** argv)
{
    import core.runtime : rt_init;

    rt_init();
    return 0;
}

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size)
{
    checkTime(data[0 .. size]);
    return 0;
}
