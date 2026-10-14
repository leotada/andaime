/// Guarantees a WebSocket's message path does not allocate on the GC once warm: frame parsing, unmasking, UTF-8 check,
/// echo and framing, with and without permessage-deflate (zlib's memory is its own, freed by `release`).
import vela;
import vela.http;
import vela.engine.zlib : zlibDeflate;
import core.memory : GC;
import core.time : Duration;
import core.stdc.stdio : printf;

/// Plays the same client frame over and over; collects what the server writes into a reused buffer.
final class Replay : UpgradedConn
{
    const(ubyte)[] frame;
    size_t pos;
    ByteBuffer output;

    this(const(ubyte)[] f) { frame = f; }

    override const(ubyte)[] buffered() @safe => frame[pos .. $];
    override FillResult fill(int timeoutMs) @safe { pos = 0; return FillResult.data; }
    override void consume(size_t n) @safe { pos += n; }
    override void write(scope const(ubyte)[] data) @safe { output.clear(); output.put(cast(const(char)[]) data); }
    override void close() @safe {}
}

ulong echoLoop(WsConn ws, size_t n)
{
    foreach (i; 0 .. 100) // warm-up: buffers grow once
        ws.send(ws.receive().text);
    immutable before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. n)
    {
        auto m = ws.receive();
        ws.send(m.text);
    }
    return GC.allocatedInCurrentThread - before;
}

void main()
{
    enum text = "a chat message that is long enough to be compressed, about the weather, the weather, the weather.";
    static immutable ubyte[4] key = [0x11, 0x22, 0x33, 0x44];
    WsOptions opts;
    opts.pingInterval = Duration.zero;

    // plain
    ByteBuffer f;
    encodeFrame(f, WsOpcode.text, true, false, cast(const(ubyte)[]) text, key[]);
    auto io = new Replay(cast(const(ubyte)[]) f.data.dup);
    auto ws = new WsConn;
    ws.reset(io, false, opts);
    immutable plain = echoLoop(ws, 100_000);
    printf("bytes allocated on the GC in 100k WebSocket echoes: %llu\n", plain);
    assert(plain == 0, "the WebSocket message path allocated on the GC");

    // compressed both ways
    auto client = zlibDeflate(15, false);
    if (client is null)
    {
        printf("zlib not available: the compressed echo is not measured\n");
        return;
    }
    ByteBuffer z, cf;
    assert(client.compress(cast(const(ubyte)[]) text, z));
    client.release();
    encodeFrame(cf, WsOpcode.text, true, true, cast(const(ubyte)[]) z.data, key[]);
    auto zio = new Replay(cast(const(ubyte)[]) cf.data.dup);
    auto zws = new WsConn;
    zws.reset(zio, false, opts, zlibDeflate(15, false));
    immutable compressed = echoLoop(zws, 100_000);
    FrameHeader h;
    assert(parseFrameHeader(cast(const(ubyte)[]) zio.output.data, h) == FrameParse.ok && h.rsv1, "the echo is compressed");
    zws.abort();
    printf("bytes allocated on the GC in 100k compressed WebSocket echoes: %llu\n", compressed);
    assert(compressed == 0, "the compressed WebSocket message path allocated on the GC");
}
