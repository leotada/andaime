/// libFuzzer target for the WebSocket message layer (LDC: -fsanitize=fuzzer,address). See tools/fuzz.sh.
module libfuzzer_ws;

import ws_invariants;

/// There is no D `main` under libFuzzer: start druntime here (WsConn reads the monotonic clock, which it sets up).
extern (C) int LLVMFuzzerInitialize(int* argc, char*** argv)
{
    import core.runtime : rt_init;

    rt_init();
    return 0;
}

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size)
{
    checkWs(data[0 .. size]);
    return 0;
}
