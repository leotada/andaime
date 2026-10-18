/// HTTP/2 session tests without sockets: a tiny client builds frames, feeds `H2Session` and
/// reads back what it would have sent. Covers the request/response cycle, flow control,
/// stream and connection errors, limits and abuse protection.
module session_test 2025;

import andaime.http;
import andaime.http.hpack : encodeField, encodeStatus, encodeInt;

import std.conv : to;
import std.stdio : writeln;

struct Frame
{
    ubyte type, flags;
    uint sid;
    ubyte[] payload;

    uint u32(size_t at = 0) const => (payload[at] << 24) | (payload[at + 1] << 16) | (payload[at + 2] << 8) | payload[at + 3];
}

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

ubyte[] setting(ushort id, uint v) => [cast(ubyte)(id >> 8), cast(ubyte) id] ~ u32(v);

/// Header block with literal fields (names written as given).
ubyte[] block(string[2][] fields...)
{
    ByteBuffer b;
    foreach (f; fields)
    {
        // write the name raw (encodeField lowercases, and some tests need uppercase)
        b.put(cast(char) 0x00);
        encodeInt(b, 7, 0, f[0].length);
        b.put(f[0]);
        encodeInt(b, 7, 0, f[1].length);
        b.put(f[1]);
    }
    return cast(ubyte[]) b.data.dup;
}

ubyte[] get(string path = "/") => block([":method", "GET"], [":scheme", "http"], [":path", path], [":authority", "t"]);

ubyte[] post(string path, string cl) => block([":method", "POST"], [":scheme", "http"], [":path", path],
    [":authority", "t"], ["content-length", cl]);

class Peer
{
    H2Session s;
    ubyte[] pending;
    HpackDecoder dec;

    this(H2Config cfg = H2Config.init, bool handshake = true)
    {
        s = new H2Session(cfg);
        dec.setMaxAllowed(4096);
        if (handshake)
        {
            send(cast(ubyte[]) clientPreface.dup ~ frame(4, 0, 0, null));
            auto f = frames();
            assert(f.length >= 2 && f[0].type == FrameType.settings && f[$ - 1].type == FrameType.settings
                && f[$ - 1].flags == flagAck, f.to!string);
        }
    }

    void send(const(ubyte)[] bytes)
    {
        pending ~= bytes;
        auto n = s.receive(pending);
        pending = pending[n .. $].dup;
    }

    Frame[] frames()
    {
        Frame[] r;
        auto o = cast(const(ubyte)[]) s.pendingOutput;
        size_t p = 0;
        while (p + 9 <= o.length)
        {
            auto len = (o[p] << 16) | (o[p + 1] << 8) | o[p + 2];
            r ~= Frame(o[p + 3], o[p + 4], ((o[p + 5] & 0x7f) << 24) | (o[p + 6] << 16) | (o[p + 7] << 8) | o[p + 8],
                o[p + 9 .. p + 9 + len].dup);
            p += 9 + len;
        }
        assert(p == o.length, "partial frame in output");
        s.sent(o.length);
        return r;
    }

    string headers(const(ubyte)[] blk)
    {
        string got;
        assert(dec.decode(blk, (scope n, scope v, bool sens) { got ~= n ~ "=" ~ v ~ ";"; }) == HpackError.none);
        return got;
    }

    H2Stream ready()
    {
        H2Stream st;
        assert(s.popReady(st), "no stream ready");
        return st;
    }

    void respond(H2Stream st, string h1)
    {
        respondH1(s, st, h1);
    }
}

/// The tests describe responses as HTTP/1.1 text, which is easy to read; this turns the text into the structured head
/// plus body that `H2Session.respond` takes.
void respondH1(H2Session s, H2Stream st, string text)
{
    import std.string : indexOf, split, strip;

    auto he = text.indexOf("\r\n\r\n");
    assert(he > 0, "no end of head");
    auto lines = text[0 .. he].split("\r\n");
    ResponseHead head;
    head.status = lines[0][9 .. 12].to!int;
    HeaderField[] extra;
    foreach (l; lines[1 .. $])
    {
        auto c = l.indexOf(':');
        auto name = l[0 .. c];
        auto value = l[c + 1 .. $].strip;
        if (equalsIgnoreCase(name, "content-type"))
            head.contentType = value;
        else if (equalsIgnoreCase(name, "content-length"))
            head.contentLength = value.to!long;
        else
            extra ~= HeaderField(name, value);
    }
    head.headers = extra;
    ByteBuffer body_;
    body_.put(text[he + 4 .. $]);
    s.respond(st, head, body_);
}

Frame only(Frame[] fs, ubyte type)
{
    foreach (f; fs)
        if (f.type == type)
            return f;
    assert(0, "no frame of type " ~ type.to!string ~ " in " ~ fs.to!string);
}

void expectGoAway(Peer p, H2Error code, string what)
{
    auto f = p.frames();
    auto g = only(f, FrameType.goAway);
    assert(g.u32(4) == code, what ~ ": GOAWAY " ~ g.u32(4).to!string ~ ", expected " ~ (cast(uint) code).to!string);
    assert(p.s.fatal, what);
}

void expectRst(Peer p, uint sid, H2Error code, string what)
{
    auto f = p.frames();
    foreach (x; f)
        if (x.type == FrameType.rstStream && x.sid == sid)
        {
            assert(x.u32 == code, what ~ ": RST " ~ x.u32.to!string);
            assert(!p.s.fatal, what ~ ": should not be a connection error");
            return;
        }
    assert(0, what ~ ": no RST_STREAM in " ~ f.to!string);
}

unittest // a GET, answered with a transcoded HTTP/1.1 response
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get("/users/7?x=1")));
    auto st = p.ready();
    assert(st.req.method == Method.GET && st.req.path == "/users/7" && st.req.query == "x=1");
    assert(st.req.protocol == Protocol.http2 && st.req.keepAlive);
    assert(st.req.header("host") == "t");
    p.respond(st, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\nX-Id: 9\r\n\r\nhello");
    auto f = p.frames();
    assert(f.length == 2 && f[0].type == FrameType.headers && f[0].flags == flagEndHeaders, f.to!string);
    assert(p.headers(f[0].payload) == ":status=200;content-type=text/plain;content-length=5;x-id=9;", p.headers(f[0].payload));
    assert(f[1].type == FrameType.data && f[1].flags == flagEndStream && f[1].payload == "hello");
    assert(p.s.busy == 0);
    H2Stream none;
    assert(!p.s.popReady(none));
}

unittest // POST with a body in two DATA frames, padding, cookie crumbs merged, no-body response
{
    auto p = new Peer;
    auto b = block([":method", "POST"], [":scheme", "http"], [":path", "/x"], [":authority", "h"],
        ["cookie", "a=1"], ["content-length", "6"], ["cookie", "b=2"], ["cookie", "c=3"]);
    p.send(frame(1, flagEndHeaders, 3, b));
    H2Stream st;
    assert(!p.s.popReady(st));
    p.send(frame(0, flagPadded, 3, cast(ubyte[]) "\x02abc\0\0"));
    p.send(frame(0, flagEndStream, 3, cast(ubyte[]) "def"));
    st = p.ready();
    assert(cast(string) st.req.body == "abcdef");
    assert(st.req.header("cookie") == "a=1; b=2; c=3", st.req.header("cookie"));
    size_t cookies;
    foreach (h; st.req.headers)
        cookies += h.name == "cookie";
    assert(cookies == 1);
    p.respond(st, "HTTP/1.1 204 No Content\r\nDate: x\r\n\r\n");
    auto f = p.frames();
    auto h = only(f, FrameType.headers);
    assert(h.flags == (flagEndHeaders | flagEndStream));
    assert(p.headers(h.payload) == ":status=204;date=x;");
}

unittest // flow control: the peer's window limits DATA, WINDOW_UPDATE releases it
{
    auto p = new Peer;
    p.send(frame(4, 0, 0, setting(4, 10))); // INITIAL_WINDOW_SIZE = 10
    p.frames();
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get()));
    p.respond(p.ready(), "HTTP/1.1 200 OK\r\nContent-Length: 25\r\n\r\n0123456789abcdefghijKLMNO");
    auto f = p.frames();
    assert(f.length == 2 && f[1].payload == "0123456789" && f[1].flags == 0, f.to!string);
    p.send(frame(8, 0, 1, u32(12)));
    f = p.frames();
    assert(f.length == 1 && f[0].payload == "abcdefghijKL" && f[0].flags == 0, f.to!string);
    // a SETTINGS change applies to open streams too (may also go negative)
    p.send(frame(4, 0, 0, setting(4, 100)));
    f = p.frames();
    assert(f.length == 2 && f[1].payload == "MNO" && f[1].flags == flagEndStream, f.to!string);
}

unittest // connection window: DATA of all streams stops at 65535 until the peer opens it
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get()));
    p.send(frame(1, flagEndHeaders | flagEndStream, 3, get()));
    auto big = new char[50_000];
    big[] = 'z';
    p.respond(p.ready(), "HTTP/1.1 200 OK\r\n\r\n" ~ big.idup);
    p.respond(p.ready(), "HTTP/1.1 200 OK\r\n\r\n" ~ big.idup);
    size_t total;
    bool[uint] ended;
    foreach (round; 0 .. 10)
        foreach (f; p.frames())
            if (f.type == FrameType.data)
            {
                assert(f.payload.length <= 16_384);
                total += f.payload.length;
                if (f.flags & flagEndStream)
                    ended[f.sid] = true;
            }
    assert(total == 65_535, total.to!string); // both streams together
    p.send(frame(8, 0, 0, u32(1 << 20)));
    p.send(frame(8, 0, 1, u32(1 << 20)));
    p.send(frame(8, 0, 3, u32(1 << 20)));
    foreach (round; 0 .. 20)
        foreach (f; p.frames())
            if (f.type == FrameType.data)
            {
                total += f.payload.length;
                if (f.flags & flagEndStream)
                    ended[f.sid] = true;
            }
    assert(total == 100_000 && ended.length == 2, total.to!string ~ " " ~ ended.to!string);
}

unittest // the receive window is replenished as bodies arrive
{
    H2Config small;
    small.initialWindowSize = 65_535;
    auto p = new Peer(small);
    p.send(frame(1, flagEndHeaders, 1, post("/", "100000")));
    auto chunk = new ubyte[16_000];
    uint conn, stream;
    foreach (i; 0 .. 6)
    {
        p.send(frame(0, 0, 1, chunk));
        foreach (f; p.frames())
            if (f.type == FrameType.windowUpdate)
                (f.sid == 0 ? conn : stream) += f.u32;
    }
    assert(stream >= 32_000, stream.to!string);
    p.send(frame(0, flagEndStream, 1, chunk[0 .. 4000]));
    assert(p.ready().req.body.length == 100_000);
}

unittest // the per-stream window is configurable, announced in SETTINGS and enforced
{
    uint announced(H2Config cfg)
    {
        auto s = new H2Session(cfg);
        s.receive(cast(ubyte[]) clientPreface.dup);
        auto o = cast(const(ubyte)[]) s.pendingOutput;
        assert(o[3] == FrameType.settings);
        immutable len = (o[0] << 16) | (o[1] << 8) | o[2];
        for (size_t i = 9; i < 9 + len; i += 6)
            if (o[i] == 0 && o[i + 1] == 4)
                return (o[i + 2] << 24) | (o[i + 3] << 16) | (o[i + 4] << 8) | o[i + 5];
        return 65_535; // not announced: the protocol default
    }

    H2Config cfg;
    assert(announced(cfg) == 256 << 10, "default per-stream window");
    cfg.initialWindowSize = 1 << 20;
    assert(announced(cfg) == 1 << 20);
    cfg.initialWindowSize = 1000; // below the protocol default: raised to it
    assert(announced(cfg) == 65_535);
    cfg.initialWindowSize = uint.max; // above 2^31 - 1: lowered to it
    assert(announced(cfg) == 0x7fff_ffff);

    // a client may send its whole window without reading anything from the server
    cfg = H2Config.init;
    cfg.initialWindowSize = 200_000;
    auto p = new Peer(cfg);
    ubyte[] burst = frame(1, flagEndHeaders, 1, post("/", "200000"));
    auto chunk = new ubyte[16_384];
    size_t left = 200_000;
    while (left)
    {
        immutable n = left < chunk.length ? left : chunk.length;
        left -= n;
        burst ~= frame(0, left ? 0 : flagEndStream, 1, chunk[0 .. n]);
    }
    p.send(burst);
    assert(!p.s.fatal);
    assert(p.ready().req.body.length == 200_000);
}

unittest // connection errors
{
    void conn(string what, H2Error code, ubyte[] bytes)
    {
        auto p = new Peer;
        p.send(bytes);
        expectGoAway(p, code, what);
    }

    auto blk = get();
    conn("DATA on stream 0", H2Error.protocol, frame(0, 0, 0, cast(ubyte[]) "x"));
    conn("DATA on an idle stream", H2Error.protocol, frame(0, 0, 9, cast(ubyte[]) "x"));
    conn("HEADERS on stream 0", H2Error.protocol, frame(1, flagEndHeaders, 0, blk));
    conn("even stream id", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 2, blk));
    conn("decreasing stream id", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 5, blk)
        ~ frame(1, flagEndHeaders | flagEndStream, 3, blk));
    conn("SETTINGS on a stream", H2Error.protocol, frame(4, 0, 1, null));
    conn("SETTINGS length", H2Error.frameSize, frame(4, 0, 0, [0, 1, 0]));
    conn("SETTINGS ACK with payload", H2Error.frameSize, frame(4, flagAck, 0, setting(1, 1)));
    conn("ENABLE_PUSH = 2", H2Error.protocol, frame(4, 0, 0, setting(2, 2)));
    conn("INITIAL_WINDOW_SIZE = 2^31", H2Error.flowControl, frame(4, 0, 0, setting(4, 1u << 31)));
    conn("MAX_FRAME_SIZE too small", H2Error.protocol, frame(4, 0, 0, setting(5, 16_383)));
    conn("MAX_FRAME_SIZE too large", H2Error.protocol, frame(4, 0, 0, setting(5, 1 << 24)));
    conn("PING on a stream", H2Error.protocol, frame(6, 0, 1, new ubyte[8]));
    conn("PING length", H2Error.frameSize, frame(6, 0, 0, new ubyte[6]));
    conn("GOAWAY on a stream", H2Error.protocol, frame(7, 0, 1, new ubyte[8]));
    conn("RST_STREAM on stream 0", H2Error.protocol, frame(3, 0, 0, u32(8)));
    conn("RST_STREAM on an idle stream", H2Error.protocol, frame(3, 0, 1, u32(8)));
    conn("RST_STREAM length", H2Error.frameSize, frame(1, flagEndHeaders, 1, blk) ~ frame(3, 0, 1, [0, 0, 8]));
    conn("WINDOW_UPDATE on an idle stream", H2Error.protocol, frame(8, 0, 1, u32(1)));
    conn("WINDOW_UPDATE 0 on the connection", H2Error.protocol, frame(8, 0, 0, u32(0)));
    conn("WINDOW_UPDATE length", H2Error.frameSize, frame(8, 0, 0, [0, 0, 1]));
    conn("connection window overflow", H2Error.flowControl, frame(8, 0, 0, u32(0x7fff_ffff)));
    conn("frame above MAX_FRAME_SIZE", H2Error.frameSize, frame(0, 0, 1, new ubyte[16_385]));
    conn("PUSH_PROMISE from a client", H2Error.protocol, frame(5, flagEndHeaders, 1, u32(2) ~ blk));
    conn("CONTINUATION without HEADERS", H2Error.protocol, frame(9, flagEndHeaders, 1, blk));
    conn("frame inside a header block", H2Error.protocol, frame(1, 0, 1, blk[0 .. 3]) ~ frame(2, 0, 1, [0, 0, 0, 0, 16]));
    conn("CONTINUATION on another stream", H2Error.protocol, frame(1, 0, 1, blk[0 .. 3]) ~ frame(9, flagEndHeaders, 3, blk[3 .. $]));
    conn("bad padding", H2Error.protocol, frame(1, flagEndHeaders | flagPadded, 1, [cast(ubyte) 200] ~ blk));
    // stream errors on streams that were never opened: RST_STREAM is not allowed there (§6.4)
    conn("PRIORITY depending on itself, idle stream", H2Error.protocol, frame(2, 0, 1, u32(1) ~ cast(ubyte[])[16]));
    conn("PRIORITY length, idle stream", H2Error.frameSize, frame(2, 0, 1, [0, 0, 0, 0]));
    conn("PRIORITY length, even stream", H2Error.frameSize, frame(1, flagEndHeaders | flagEndStream, 5, blk)
        ~ frame(2, 0, 2, [0, 0, 0, 0]));
    conn("DATA on an even stream", H2Error.streamClosed, frame(1, flagEndHeaders | flagEndStream, 5, blk)
        ~ frame(0, 0, 2, cast(ubyte[]) "x"));
    conn("HPACK error", H2Error.compression, frame(1, flagEndHeaders, 1, [0x80]));
    conn("HPACK index out of range", H2Error.compression, frame(1, flagEndHeaders, 1, [0xff, 0x7f]));
    conn("HEADERS on a closed stream", H2Error.streamClosed, frame(1, flagEndHeaders | flagEndStream, 1, blk)
        ~ frame(3, 0, 1, u32(8)) ~ frame(1, flagEndHeaders | flagEndStream, 1, blk));

    // bad preface, and a first frame that is not SETTINGS
    auto p = new Peer(H2Config.init, false);
    p.send(cast(ubyte[]) "GET / HTTP/1.1\r\n\r\n12345678");
    expectGoAway(p, H2Error.protocol, "bad preface");
    p = new Peer(H2Config.init, false);
    p.send(cast(ubyte[]) clientPreface.dup ~ frame(6, 0, 0, new ubyte[8]));
    expectGoAway(p, H2Error.protocol, "first frame not SETTINGS");
}

unittest // stream errors (RST_STREAM, connection stays up)
{
    void stream(string what, H2Error code, ubyte[] bytes, uint sid = 1)
    {
        auto p = new Peer;
        p.send(bytes);
        expectRst(p, sid, code, what);
        // and the connection still works
        p.send(frame(1, flagEndHeaders | flagEndStream, 101, get()));
        assert(p.ready().id == 101, what ~ ": connection unusable afterwards");
    }

    auto ok = get();
    stream("uppercase name", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], ["X-Up", "1"])));
    stream("unknown pseudo", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], [":foo", "1"])));
    stream(":status in a request", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], [":status", "200"])));
    stream("pseudo after regular", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], ["a", "1"], [":path", "/"])));
    stream("duplicated :path", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], [":path", "/"])));
    stream("missing :method", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":scheme", "http"], [":path", "/"])));
    stream("empty :path", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", ""])));
    stream("connection-specific", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], ["connection", "keep-alive"])));
    stream("te: gzip", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], ["te", "gzip"])));
    stream("value with CR", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"],
        [":scheme", "http"], [":path", "/"], ["a", "x\ry"])));
    stream("content-length mismatch", H2Error.protocol, frame(1, flagEndHeaders, 1, post("/", "4"))
        ~ frame(0, flagEndStream, 1, cast(ubyte[]) "abc"));
    stream("content-length exceeded", H2Error.protocol, frame(1, flagEndHeaders, 1, post("/", "2"))
        ~ frame(0, flagEndStream, 1, cast(ubyte[]) "abc"));
    stream("second HEADERS without END_STREAM", H2Error.protocol, frame(1, flagEndHeaders, 1, ok)
        ~ frame(1, flagEndHeaders, 1, block(["x", "1"])));
    stream("pseudo in trailers", H2Error.protocol, frame(1, flagEndHeaders, 1, ok)
        ~ frame(1, flagEndHeaders | flagEndStream, 1, block([":path", "/"])));
    stream("DATA on a half-closed stream", H2Error.streamClosed, frame(1, flagEndHeaders | flagEndStream, 1, ok)
        ~ frame(0, 0, 1, cast(ubyte[]) "x"));
    stream("HEADERS on a half-closed stream", H2Error.streamClosed, frame(1, flagEndHeaders | flagEndStream, 1, ok)
        ~ frame(1, flagEndHeaders | flagEndStream, 1, ok));
    stream("HEADERS depending on itself", H2Error.protocol, frame(1, flagEndHeaders | flagEndStream | flagPriority, 1,
        u32(1) ~ cast(ubyte[])[16] ~ ok));
    stream("PRIORITY depending on itself", H2Error.protocol, frame(1, flagEndHeaders, 1, ok)
        ~ frame(2, 0, 1, u32(1) ~ cast(ubyte[])[16]));
    stream("PRIORITY length", H2Error.frameSize, frame(1, flagEndHeaders, 1, ok) ~ frame(2, 0, 1, [0, 0, 0, 0]));
    stream("WINDOW_UPDATE 0 on a stream", H2Error.protocol, frame(1, flagEndHeaders, 1, ok) ~ frame(8, 0, 1, u32(0)));
    stream("stream window overflow", H2Error.flowControl, frame(1, flagEndHeaders, 1, ok) ~ frame(8, 0, 1, u32(0x7fff_ffff)));
    stream("DATA after RST", H2Error.streamClosed, frame(1, flagEndHeaders, 1, ok) ~ frame(3, 0, 1, u32(8))
        ~ frame(0, 0, 1, cast(ubyte[]) "x"));
}

unittest // a recycled stream object carries nothing over (found by libFuzzer: stale offsets)
{
    auto p = new Peer;
    // stream 1: complete pseudo-fields, then rejected; its object goes back to the pool
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"], [":scheme", "http"],
        [":path", "/a"], ["X-Up", "1"])));
    expectRst(p, 1, H2Error.protocol, "first stream");
    // stream 3 reuses the object and has no pseudo-fields at all
    p.send(frame(1, flagEndHeaders | flagEndStream, 3, block(["a", "b"])));
    expectRst(p, 3, H2Error.protocol, "stream without pseudo-fields on a recycled object");
    p.send(frame(1, flagEndHeaders | flagEndStream, 5, block([":scheme", "http"], [":path", "/"])));
    expectRst(p, 5, H2Error.protocol, "stream without :method on a recycled object");
    p.send(frame(1, flagEndHeaders | flagEndStream, 7, get("/ok")));
    assert(p.ready().req.path == "/ok");
}

unittest // what is answered with a status, not an error
{
    int status(ubyte[] bytes, H2Config cfg = H2Config.init)
    {
        auto p = new Peer(cfg);
        p.send(bytes);
        H2Stream st;
        assert(!p.s.popReady(st), "should not reach a handler");
        auto h = only(p.frames(), FrameType.headers);
        auto s = p.headers(h.payload);
        return s[8 .. 11].to!int;
    }

    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "BREW"], [":scheme", "http"],
        [":path", "/"]))) == 501);
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "CONNECT"], [":authority", "x:1"]))) == 501);
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"], [":scheme", "http"],
        [":path", "*"]))) == 400);
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"], [":scheme", "http"],
        [":path", "/a b"]))) == 400);
    H2Config small;
    small.limits.maxTargetBytes = 10;
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, get("/0123456789abc")), small) == 414);
    string[2][] many = [[":method", "GET"], [":scheme", "http"], [":path", "/"]];
    foreach (i; 0 .. 40)
        many ~= ["x" ~ i.to!string, "v"];
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block(many))) == 431);
    assert(status(frame(1, flagEndHeaders | flagEndStream, 1, block([":method", "GET"], [":scheme", "http"],
        [":path", "/"], ["big", new char[9000].idup]))) == 431);
    assert(status(frame(1, flagEndHeaders, 1, post("/", "99999999"))) == 413);
}

unittest // 413 while the client is still sending: answer, then RST(NO_ERROR); late DATA ignored
{
    H2Config cfg;
    cfg.limits.maxBodyBytes = 10;
    auto p = new Peer(cfg);
    p.send(frame(1, flagEndHeaders, 1, block([":method", "POST"], [":scheme", "http"], [":path", "/"])));
    p.send(frame(0, 0, 1, cast(ubyte[]) "0123456789abc"));
    auto f = p.frames();
    assert(p.headers(only(f, FrameType.headers).payload)[0 .. 11] == ":status=413");
    assert(only(f, FrameType.rstStream).u32 == H2Error.noError);
    p.send(frame(0, flagEndStream, 1, cast(ubyte[]) "more"));
    assert(p.frames().length == 0 && !p.s.fatal);
}

unittest // the peer resets a stream whose handler is running: the engine gets it back
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get()));
    auto st = p.ready();
    st.task = new Object; // the engine started a fiber
    p.send(frame(3, 0, 1, u32(H2Error.cancel)));
    H2Stream r;
    assert(p.s.popReset(r) && r is st && r.resetByPeer);
    assert(p.s.busy == 1);
    respondH1(p.s, r, "HTTP/1.1 200 OK\r\n\r\nlate"); // the cancelled handler still finishes: nothing goes out
    assert(p.frames().length == 0 && p.s.busy == 0);
}

unittest // MAX_CONCURRENT_STREAMS: the stream above the limit is refused
{
    H2Config cfg;
    cfg.maxConcurrentStreams = 2;
    auto p = new Peer(cfg);
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get()));
    p.send(frame(1, flagEndHeaders | flagEndStream, 3, get()));
    p.send(frame(1, flagEndHeaders | flagEndStream, 5, get()));
    expectRst(p, 5, H2Error.refusedStream, "third stream");
    auto a = p.ready();
    p.respond(a, "HTTP/1.1 200 OK\r\n\r\n");
    p.send(frame(1, flagEndHeaders | flagEndStream, 7, get())); // a slot is free again
    p.ready();
    assert(p.ready().id == 7);
}

unittest // header blocks split in CONTINUATIONs, both ways
{
    auto p = new Peer;
    string[2][] fs = [[":method", "GET"], [":scheme", "http"], [":path", "/"]];
    foreach (i; 0 .. 5)
        fs ~= ["h" ~ i.to!string, new char[1000].idup];
    auto blk = block(fs);
    p.send(frame(1, flagEndStream, 1, blk[0 .. 2000]) ~ frame(9, 0, 1, blk[2000 .. 4000])
        ~ frame(9, flagEndHeaders, 1, blk[4000 .. $]));
    auto st = p.ready();
    assert(st.req.header("h4").length == 1000);
    string head = "HTTP/1.1 200 OK\r\n";
    foreach (i; 0 .. 20)
        head ~= "X-Long-" ~ i.to!string ~ ": " ~ new char[1000].idup ~ "\r\n";
    p.respond(st, head ~ "\r\nok");
    auto f = p.frames();
    assert(f[0].type == FrameType.headers && f[0].flags == 0);
    assert(f[1].type == FrameType.continuation && f[1].flags == flagEndHeaders);
    assert(f[2].type == FrameType.data && f[2].payload == "ok");
    assert(p.headers(f[0].payload ~ f[1].payload).length > 20_000);
}

unittest // Expect: 100-continue gets an interim 100 before the body
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders, 1, block([":method", "POST"], [":scheme", "http"], [":path", "/"],
        ["expect", "100-continue"], ["content-length", "2"])));
    auto f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.headers && f[0].flags == flagEndHeaders);
    assert(p.headers(f[0].payload) == ":status=100;");
    p.send(frame(0, flagEndStream, 1, cast(ubyte[]) "hi"));
    assert(p.ready().req.body == cast(ubyte[]) "hi");
}

unittest // PING answered, unknown frames and settings ignored, trailers accepted
{
    auto p = new Peer;
    p.send(frame(6, 0, 0, cast(ubyte[]) "12345678"));
    auto f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.ping && f[0].flags == flagAck && f[0].payload == "12345678");
    p.send(frame(0xfa, 0, 0, cast(ubyte[]) "whatever") ~ frame(4, 0, 0, setting(0x99, 7)));
    f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.settings && f[0].flags == flagAck);
    p.send(frame(1, flagEndHeaders, 1, post("/", "1")) ~ frame(0, 0, 1, cast(ubyte[]) "x")
        ~ frame(1, flagEndHeaders | flagEndStream, 1, block(["x-checksum", "abc"])));
    assert(p.ready().req.body == cast(ubyte[]) "x");
}

unittest // floods end with ENHANCE_YOUR_CALM; tick forgives a steady rate
{
    auto p = new Peer;
    foreach (i; 0 .. 400)
    {
        p.send(frame(6, 0, 0, new ubyte[8]));
        if (i % 100 == 99)
            p.s.tick(0);
    }
    assert(!p.s.fatal);
    ubyte[] burst;
    foreach (i; 0 .. 1100)
        burst ~= frame(6, 0, 0, new ubyte[8]);
    p.send(burst);
    assert(p.s.fatal && p.s.lastError == H2Error.enhanceYourCalm);

    // rapid reset: open and cancel streams over and over
    p = new Peer;
    ubyte[] rr;
    foreach (i; 0 .. 600)
        rr ~= frame(1, flagEndHeaders | flagEndStream, 1 + 2 * i, get()) ~ frame(3, 0, 1 + 2 * i, u32(8));
    p.send(rr);
    assert(p.s.fatal && p.s.lastError == H2Error.enhanceYourCalm);

    // a header block that never ends
    p = new Peer;
    p.send(frame(1, 0, 1, get()));
    foreach (i; 0 .. 4)
        p.send(frame(9, 0, 1, new ubyte[16_000]));
    assert(p.s.fatal && p.s.lastError == H2Error.enhanceYourCalm);
}

unittest // SETTINGS must be acknowledged in time (§6.5.3)
{
    H2Config cfg;
    cfg.settingsTimeoutMs = 1000;
    auto p = new Peer(cfg, false);
    p.s.nowMs = 100;
    p.send(cast(ubyte[]) clientPreface.dup ~ frame(4, 0, 0, null)); // our SETTINGS go out at t = 100
    p.frames();
    p.s.tick(1000);
    assert(!p.s.fatal);
    p.s.tick(1101);
    expectGoAway(p, H2Error.settingsTimeout, "no SETTINGS ACK");
    assert(h2ErrorName(p.s.lastError) == "SETTINGS_TIMEOUT");

    p = new Peer(cfg, false);
    p.send(cast(ubyte[]) clientPreface.dup ~ frame(4, 0, 0, null) ~ frame(4, flagAck, 0, null));
    p.s.tick(1_000_000);
    assert(!p.s.fatal, "an acknowledged SETTINGS never times out");
}

unittest // graceful GOAWAY: running streams finish, new ones are ignored
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders | flagEndStream, 1, get()));
    auto st = p.ready();
    p.s.goAway();
    auto g = only(p.frames(), FrameType.goAway);
    assert(g.u32 == 1 && g.u32(4) == H2Error.noError);
    p.send(frame(1, flagEndHeaders | flagEndStream, 3, get()));
    H2Stream none;
    assert(!p.s.popReady(none));
    assert(!p.s.finished);
    p.respond(st, "HTTP/1.1 200 OK\r\n\r\nbye");
    assert(only(p.frames(), FrameType.data).payload == "bye");
    assert(p.s.finished);
}

unittest // h2c upgrade: the HTTP/1.1 request becomes stream 1
{
    HeaderField[8] store;
    Request r;
    auto raw = "POST /up?q=1 HTTP/1.1\r\nHost: example\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\n"
        ~ "HTTP2-Settings: AAMAAABkAAQAAP__\r\nContent-Length: 3\r\n\r\nabc";
    auto h = parseRequestHead(raw, r, store[]);
    const(char)[] settings;
    assert(wantsH2cUpgrade(r, settings) && settings == "AAMAAABkAAQAAP__");
    ByteBuffer dec;
    assert(decodeBase64Url(settings, dec));
    assert(cast(const(ubyte)[]) dec.data == [0, 3, 0, 0, 0, 100, 0, 4, 0, 0, 0xff, 0xff]);

    auto p = new Peer(H2Config.init, false);
    assert(p.s.startUpgrade(r, cast(const(ubyte)[]) raw[h.headLength .. $], cast(const(ubyte)[]) dec.data));
    auto out1 = p.s.pendingOutput.idup;
    assert(out1[0 .. 35] == "HTTP/1.1 101 Switching Protocols\r\nC", out1);
    p.s.sent(out1.length);
    auto st = p.ready();
    assert(st.id == 1 && st.req.method == Method.POST && st.req.path == "/up" && st.req.query == "q=1");
    assert(st.req.header("host") == "example" && st.req.header("upgrade") is null);
    assert(cast(string) st.req.body == "abc");
    p.send(cast(ubyte[]) clientPreface.dup ~ frame(4, 0, 0, null));
    p.frames();
    p.respond(st, "HTTP/1.1 200 OK\r\n\r\nupgraded");
    assert(only(p.frames(), FrameType.data).payload == "upgraded");

    // not an upgrade: missing token in Connection
    parseRequestHead("GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: h2c\r\nHTTP2-Settings: \r\n\r\n", r, store[]);
    assert(!wantsH2cUpgrade(r, settings));
}

unittest // fragmented input: one byte at a time gives the same result
{
    auto p = new Peer(H2Config.init, false);
    auto bytes = cast(ubyte[]) clientPreface.dup ~ frame(4, 0, 0, setting(4, 1000))
        ~ frame(1, flagEndHeaders, 1, post("/f", "5")) ~ frame(0, flagEndStream, 1, cast(ubyte[]) "12345");
    foreach (b; bytes)
        p.send([b]);
    auto st = p.ready();
    assert(st.req.path == "/f" && st.req.body == cast(ubyte[]) "12345");
}

// ---- RFC 8441: WebSockets over HTTP/2 (extended CONNECT)

ubyte[] wsConnect(string path = "/ws", string protocol = "websocket")
    => block([":method", "CONNECT"], [":protocol", protocol], [":scheme", "https"], [":path", path],
        [":authority", "t"], ["sec-websocket-version", "13"]);

/// Opens a tunnel on stream 1 and answers it 200, as the engine does when the WebSocket handler accepts.
H2Stream openTunnel(Peer p)
{
    p.send(frame(1, flagEndHeaders, 1, wsConnect()));
    auto st = p.ready();
    st.task = new Object; // the engine runs the handler
    ResponseHead head = ResponseHead(200, null, null, -1);
    p.s.beginResponse(st, head, false);
    auto f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.headers && f[0].flags == flagEndHeaders, f.to!string);
    assert(p.headers(f[0].payload) == ":status=200;", p.headers(f[0].payload));
    return st;
}

unittest // SETTINGS_ENABLE_CONNECT_PROTOCOL is announced, unless disabled
{
    bool announced(H2Config cfg)
    {
        auto s = new H2Session(cfg);
        s.receive(cast(ubyte[]) clientPreface.dup);
        auto o = cast(const(ubyte)[]) s.pendingOutput;
        immutable len = (o[0] << 16) | (o[1] << 8) | o[2];
        for (size_t i = 9; i < 9 + len; i += 6)
            if (o[i] == 0 && o[i + 1] == 8)
                return o[i + 5] == 1;
        return false;
    }

    H2Config cfg;
    assert(announced(cfg));
    cfg.enableConnectProtocol = false;
    assert(!announced(cfg));
}

unittest // an extended CONNECT runs at once, as a GET with connectProtocol, and carries bytes both ways
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders, 1, wsConnect("/chat?room=a")));
    auto st = p.ready(); // no END_STREAM needed
    assert(st.tunnel && st.req.method == Method.GET && st.req.connectProtocol == "websocket");
    assert(st.req.path == "/chat" && st.req.query == "room=a" && st.req.header("sec-websocket-version") == "13");
    assert(st.req.header("host") == "t");
    st.task = new Object;
    p.send(frame(0, 0, 1, cast(ubyte[]) "early")); // bytes before the answer are kept
    ResponseHead head = ResponseHead(200, null, [HeaderField("Sec-WebSocket-Protocol", "chat")], -1);
    p.s.beginResponse(st, head, false);
    assert(p.headers(only(p.frames(), FrameType.headers).payload) == ":status=200;sec-websocket-protocol=chat;");

    H2Stream in_;
    assert(p.s.popInput(in_) && in_ is st && !p.s.popInput(in_));
    assert(cast(string) p.s.tunnelInput(st) == "early");
    p.s.tunnelConsume(st, 2);
    p.send(frame(0, 0, 1, cast(ubyte[]) "+more"));
    assert(cast(string) p.s.tunnelInput(st) == "rly+more");
    p.s.tunnelConsume(st, 8);
    assert(p.s.tunnelInput(st).length == 0 && !p.s.tunnelEnded(st));

    p.s.sendData(st, "pong");
    auto f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.data && f[0].flags == 0 && f[0].payload == "pong", f.to!string);

    // the client ends its side: the engine learns it, then ends ours, and the stream is gone
    p.send(frame(0, flagEndStream, 1, null));
    assert(p.s.popInput(in_) && in_ is st && p.s.tunnelEnded(st));
    p.s.endResponse(st);
    f = p.frames();
    assert(f.length == 1 && f[0].type == FrameType.data && f[0].flags == flagEndStream && f[0].payload.length == 0);
    assert(p.s.busy == 0 && !p.s.fatal);
}

unittest // a tunnel is not a body: no maxBodyBytes, the stream window only reopens as the engine consumes
{
    H2Config cfg;
    cfg.limits.maxBodyBytes = 10;
    cfg.initialWindowSize = 65_535;
    auto p = new Peer(cfg);
    auto st = openTunnel(p);
    auto chunk = new ubyte[16_384];
    foreach (i; 0 .. 3)
        p.send(frame(0, 0, 1, chunk));
    assert(p.s.tunnelInput(st).length == 3 * 16_384 && !p.s.fatal);
    auto f = p.frames();
    foreach (x; f)
        assert(x.type != FrameType.windowUpdate || x.sid == 0, "the stream window must wait for the engine: " ~ f.to!string);
    p.s.tunnelConsume(st, 3 * 16_384);
    f = p.frames();
    auto wu = only(f, FrameType.windowUpdate);
    assert(wu.sid == 1 && wu.u32 == 3 * 16_384, f.to!string);
    // past the window: a stream error, the connection stays up
    foreach (i; 0 .. 4)
        p.send(frame(0, 0, 1, chunk));
    expectRst(p, 1, H2Error.flowControl, "beyond the stream window");
    H2Stream r;
    assert(p.s.popReset(r) && r is st && p.s.tunnelEnded(st));
}

unittest // our side ends first: half-closed, late frames dropped, closed by the peer's END_STREAM or reset after 1 s
{
    auto p = new Peer;
    auto st = openTunnel(p);
    p.s.sendData(st, "bye");
    p.s.endResponse(st); // the engine gives the stream back
    auto f = p.frames();
    assert(f.length == 2 && f[0].payload == "bye" && f[1].flags == flagEndStream && f[1].payload.length == 0, f.to!string);
    assert(p.s.busy == 1, "waits for the peer's side");
    p.send(frame(0, 0, 1, cast(ubyte[]) "late close frame"));
    p.send(frame(0, flagEndStream, 1, null));
    f = p.frames();
    foreach (x; f)
        assert(x.type != FrameType.rstStream, f.to!string);
    assert(p.s.busy == 0 && !p.s.fatal);

    // a peer that never ends its side is reset with NO_ERROR
    p.send(frame(1, flagEndHeaders, 3, wsConnect()));
    auto st2 = p.ready();
    st2.task = new Object;
    ResponseHead head = ResponseHead(200, null, null, -1);
    p.s.beginResponse(st2, head, false);
    p.s.endResponse(st2);
    p.frames();
    p.s.tick(1000); // (below the 10 s SETTINGS timeout: the test peer never acknowledges)
    assert(p.s.busy == 1);
    p.s.tick(1500);
    assert(p.s.busy == 1);
    p.s.tick(2001);
    expectRst(p, 3, H2Error.noError, "lingering tunnel");
    assert(p.s.busy == 0);
}

unittest // a refused tunnel (403) is answered and reset like any early answer
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders, 1, wsConnect()));
    auto st = p.ready();
    respondH1(p.s, st, "HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\nno");
    auto f = p.frames();
    assert(p.headers(only(f, FrameType.headers).payload)[0 .. 11] == ":status=403");
    assert(only(f, FrameType.rstStream).u32 == H2Error.noError);
    assert(p.s.busy == 0);
}

unittest // the peer resets a running tunnel: the engine gets it back through popReset
{
    auto p = new Peer;
    auto st = openTunnel(p);
    p.send(frame(3, 0, 1, u32(H2Error.cancel)));
    H2Stream r;
    assert(p.s.popReset(r) && r is st && p.s.tunnelEnded(st));
    p.s.endResponse(st);
    assert(p.frames().length == 0 && p.s.busy == 0);
}

unittest // malformed extended CONNECTs
{
    auto p = new Peer;
    p.send(frame(1, flagEndHeaders, 1, block([":method", "CONNECT"], [":protocol", "websocket"], [":scheme", "https"],
        [":authority", "t"])));
    expectRst(p, 1, H2Error.protocol, "no :path");
    p.send(frame(1, flagEndHeaders, 3, block([":method", "CONNECT"], [":protocol", "websocket"], [":path", "/"],
        [":authority", "t"])));
    expectRst(p, 3, H2Error.protocol, "no :scheme");
    p.send(frame(1, flagEndHeaders, 5, block([":method", "CONNECT"], [":protocol", "websocket"], [":scheme", "https"],
        [":path", "/"])));
    expectRst(p, 5, H2Error.protocol, "no :authority");
    p.send(frame(1, flagEndHeaders | flagEndStream, 7, block([":method", "GET"], [":protocol", "websocket"],
        [":scheme", "https"], [":path", "/"], [":authority", "t"])));
    expectRst(p, 7, H2Error.protocol, ":protocol on a GET");
    p.send(frame(1, flagEndHeaders, 9, wsConnect("/", "webtransport")));
    assert(p.headers(only(p.frames(), FrameType.headers).payload)[0 .. 11] == ":status=501");
    // a plain CONNECT is still 501
    p.send(frame(1, flagEndHeaders, 11, block([":method", "CONNECT"], [":authority", "t:443"])));
    assert(p.headers(only(p.frames(), FrameType.headers).payload)[0 .. 11] == ":status=501");

    H2Config off;
    off.enableConnectProtocol = false;
    auto q = new Peer(off);
    q.send(frame(1, flagEndHeaders, 1, wsConnect()));
    expectRst(q, 1, H2Error.protocol, ":protocol without the setting");
    q.send(frame(4, 0, 0, setting(8, 2)));
    expectGoAway(q, H2Error.protocol, "ENABLE_CONNECT_PROTOCOL = 2");
}

unittest // a tunnel and ordinary requests share the connection
{
    auto p = new Peer;
    auto st = openTunnel(p);
    p.send(frame(1, flagEndHeaders | flagEndStream, 3, get("/plain")));
    auto g = p.ready();
    assert(g.id == 3 && !g.tunnel && g.req.connectProtocol is null);
    p.respond(g, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    p.send(frame(0, 0, 1, cast(ubyte[]) "x"));
    p.s.sendData(st, "y");
    auto f = p.frames();
    assert(f.length == 3, f.to!string);
    assert(cast(string) p.s.tunnelInput(st) == "x");
}

void main()
{
    writeln("ok  HTTP/2 session (frames, streams, flow control, errors, limits, upgrade, RFC 8441 tunnels)");
}
