/// Guarantees a WebSocket's message path does not allocate on the GC once warm: frame parsing, unmasking, UTF-8 check,
/// echo and framing, with and without permessage-deflate (zlib's memory is its own, freed by `release`), and over an
/// HTTP/2 stream (RFC 8441: DATA frames in, the session's tunnel input, DATA frames out, WINDOW_UPDATEs).
import andaime;
import andaime.http;
import andaime.http.hpack : encodeField;
import andaime.engine.zlib : zlibDeflate;
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

/// The engine's side of an HTTP/2 WebSocket, reduced to the session calls: each `fill` delivers the client's frame in a
/// DATA frame (with the WINDOW_UPDATEs a reading client sends for what it got); `write` queues DATA and drains the output.
final class H2Replay : UpgradedConn
{
    H2Session s;
    H2Stream st;
    ubyte[] wire; // DATA(frame) + WINDOW_UPDATE(0) + WINDOW_UPDATE(1), rewritten in place
    size_t frameLen;
    uint owed;    // DATA payload the server sent since the last fill: the client gives it back

    this(H2Session s, H2Stream st, const(ubyte)[] frame)
    {
        this.s = s;
        this.st = st;
        frameLen = frame.length;
        wire = new ubyte[9 + frame.length + 2 * 13];
        put(wire[0 .. 9], frame.length, 0, 0, 1);
        wire[9 .. 9 + frame.length] = frame[];
    }

    static void put(ubyte[] h, size_t len, ubyte type, ubyte flags, uint sid) @safe
    {
        h[0] = cast(ubyte)(len >> 16); h[1] = cast(ubyte)(len >> 8); h[2] = cast(ubyte) len;
        h[3] = type; h[4] = flags;
        h[5] = cast(ubyte)(sid >> 24); h[6] = cast(ubyte)(sid >> 16); h[7] = cast(ubyte)(sid >> 8); h[8] = cast(ubyte) sid;
    }

    static void u32(ubyte[] b, uint v) @safe
    {
        b[0] = cast(ubyte)(v >> 24); b[1] = cast(ubyte)(v >> 16); b[2] = cast(ubyte)(v >> 8); b[3] = cast(ubyte) v;
    }

    override const(ubyte)[] buffered() @safe => s.tunnelInput(st);
    override void consume(size_t n) @safe { s.tunnelConsume(st, n); }

    override FillResult fill(int timeoutMs) @safe
    {
        size_t n = 9 + frameLen;
        if (owed)
        {
            foreach (uint sid; 0 .. 2) // the connection, then the stream
            {
                put(wire[n .. n + 9], 4, 8, 0, sid);
                u32(wire[n + 9 .. n + 13], owed);
                n += 13;
            }
            owed = 0;
        }
        s.receive(wire[0 .. n]);
        s.sent(s.pendingOutput.length); // our WINDOW_UPDATEs
        return FillResult.data;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        s.sendData(st, cast(const(char)[]) data);
        owed += cast(uint) data.length;
        s.sent(s.pendingOutput.length);
    }

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

    // over HTTP/2: the same echo through a session's tunnel (RFC 8441)
    {
        auto s = new H2Session();
        ByteBuffer blk;
        encodeField(blk, ":method", "CONNECT");
        encodeField(blk, ":protocol", "websocket");
        encodeField(blk, ":scheme", "https");
        encodeField(blk, ":path", "/ws");
        encodeField(blk, ":authority", "example.com");
        encodeField(blk, "sec-websocket-version", "13");
        auto start = cast(ubyte[]) clientPreface.dup ~ cast(ubyte[]) [0, 0, 0, 4, 0, 0, 0, 0, 0];
        auto hdr = new ubyte[9];
        H2Replay.put(hdr, blk.length, 1, 0x4, 1);
        s.receive(start ~ hdr ~ cast(const(ubyte)[]) blk.data);
        H2Stream st;
        assert(s.popReady(st) && st.tunnel);
        st.task = s; // the engine holds it
        const ResponseHead ok = ResponseHead(200, null, null, -1);
        s.beginResponse(st, ok, false);
        s.sent(s.pendingOutput.length);
        auto hio = new H2Replay(s, st, cast(const(ubyte)[]) f.data);
        auto hws = new WsConn;
        hws.reset(hio, false, opts);
        immutable h2 = echoLoop(hws, 100_000);
        assert(hws.isOpen && !s.fatal && !s.tunnelEnded(st), "the echo over HTTP/2 really ran");
        printf("bytes allocated on the GC in 100k WebSocket echoes over HTTP/2: %llu\n", h2);
        assert(h2 == 0, "the HTTP/2 WebSocket message path allocated on the GC");
    }

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
