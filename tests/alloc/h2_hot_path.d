/// The HTTP/2 hot path does not allocate on the GC either: frames in, HPACK decoding, the
/// request handed to the app through the server's callback, the response transcoded and framed.
import vela;
import vela.http;
import vela.http.hpack : encodeField;
import vela.server : handlerFactory;
import core.memory : GC;
import core.stdc.stdio : printf;

struct Out { long id; long doubled; bool even; }

Out calc(long id, int factor = 2) @safe => Out(id, id * factor, id % 2 == 0);

ubyte[9] frameHeader(size_t len, ubyte type, ubyte flags, uint sid)
{
    return [cast(ubyte)(len >> 16), cast(ubyte)(len >> 8), cast(ubyte) len, type, flags,
        cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
}

void main()
{
    auto app = new App;
    app.get!("/calc/{id}", calc);
    auto cb = handlerFactory(app)();
    auto sink = new BufferedSink;

    ByteBuffer blk;
    encodeField(blk, ":method", "GET");
    encodeField(blk, ":scheme", "http");
    encodeField(blk, ":path", "/calc/21?factor=3");
    encodeField(blk, ":authority", "example.com");
    encodeField(blk, "user-agent", "bench");
    encodeField(blk, "accept", "application/json");

    auto s = new H2Session();
    ubyte[] wire = cast(ubyte[]) clientPreface.dup ~ frameHeader(0, 4, 0, 0)[];
    s.receive(wire);
    s.sent(s.pendingOutput.length);

    ubyte[64 << 10] frame;
    uint sid = 1;
    size_t outBytes;

    void one()
    {
        frame[0 .. 9] = frameHeader(blk.length, 1, 0x5, sid);
        frame[9 .. 9 + blk.length] = cast(const(ubyte)[]) blk.data;
        sid += 2;
        s.receive(frame[0 .. 9 + blk.length]);
        H2Stream st;
        while (s.popReady(st))
        {
            sink.reset();
            cb(st.req, sink);
            s.respond(st, sink.head, sink.body);
        }
        outBytes = s.pendingOutput.length;
        s.sent(outBytes);
        // a client keeps the connection window open
        frame[0 .. 9] = frameHeader(4, 8, 0, 0);
        static immutable ubyte[4] increment = [0, 0, 0x10, 0]; // a literal here would allocate
        frame[9 .. 13] = increment[];
        s.receive(frame[0 .. 13]);
    }

    foreach (i; 0 .. 100) // warm-up: pools and buffers settle
        one();
    immutable before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 100_000)
        one();
    immutable after = GC.allocatedInCurrentThread;

    assert(outBytes > 40 && s.busy == 0);
    printf("bytes allocated on the GC in 100k HTTP/2 requests: %llu\n", cast(ulong)(after - before));
    assert(after == before, "the HTTP/2 hot path allocated on the GC");
}
