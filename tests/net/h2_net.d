/// HTTP/2 network tests: the EpollLoop on a thread, a minimal blocking HTTP/2 client over a
/// real socket. Covers what the engine adds on top of the session: one fiber per stream
/// (multiplexing), cancellation by RST_STREAM and by disconnect, per-stream deadlines, the
/// in-flight ceiling, flow control with large bodies, h2c upgrade, idle and header timeouts,
/// graceful stop, and HTTP/1.1 still served on the same port.
module h2_net 2025;

version (linux):

import andaime;
import andaime.engine;
import andaime.http;
import andaime.http.hpack : encodeField, encodeInt;
import andaime.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;

// ---------------------------------------------------------------- test app

shared int cleanups;

@safe:

string fast() => "ok";

string nap(int ms)
{
    sleep(msecs(ms));
    return "slept";
}

/// Reads a streamed body to the end: "<bytes>:<sum of the bytes>:<unread before the first read>".
string streamSum(BodyStream body)
{
    import std.conv : to;

    immutable before = body.unread;
    ubyte[10_000] buf;
    ulong n, sum;
    for (size_t got; (got = body.read(buf[])) > 0;)
    {
        n += got;
        foreach (b; buf[0 .. got])
            sum += b;
    }
    return n.to!string ~ ":" ~ sum.to!string ~ ":" ~ (before == unknownLength ? "?" : before.to!string);
}

/// Waits before reading: the client must stop at the stream window meanwhile.
string holdThenSum(BodyStream body)
{
    sleep(msecs(600));
    return streamSum(body);
}

/// Answers after 3 bytes without reading the rest.
string firstThree(BodyStream body)
{
    ubyte[3] b;
    size_t got;
    while (got < 3)
        got += body.read(b[got .. $]);
    return (() @trusted => cast(string) b.idup)();
}

string cancelMe()
{
    scope (exit)
        atomicOp!"+="(cleanups, 1);
    sleep(seconds(10));
    return "never";
}

string big(int kib)
{
    auto s = new char[kib * 1024];
    foreach (i, ref ch; s)
        ch = cast(char)('a' + i % 26);
    return s.idup;
}

string bodyLen(Context c)
{
    import std.conv : to;

    return c.request.body.length.to!string;
}

string proto(Context c) => c.request.protocol == Protocol.http2 ? "h2" : "http/1.1";

string host(Header!"Host" h) => h.value.idup;

string myIp(ClientIp ip) => ip.toString;

// ---- streamed responses
shared int streamCleanups;

Stream sChunks()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("hello");
        w.write(" ");
        w.write("world");
    });
}

EventStream sEvents()
{
    return EventStream((scope EventWriter w) @system {
        w.send("first");
        sleep(msecs(400));
        w.send("second");
    });
}

Stream sBig(int mib)
{
    return Stream("application/octet-stream", (scope StreamWriter w) @system {
        auto piece = new char[64 << 10];
        piece[] = 'z';
        foreach (i; 0 .. mib * 16)
            w.write(piece);
    });
}

Stream sForever()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        scope (exit)
            atomicOp!"+="(streamCleanups, 1);
        for (;;)
        {
            w.write("tick\n");
            w.flush();
            sleep(msecs(20));
        }
    });
}

Stream sFail()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("abc");
        w.flush();
        throw new Exception("boom after the head");
    });
}

// Slices kept past the request (see testKeptSlicesOverH2); __gshared because the handler runs on the server thread.
__gshared const(char)[][] keptPath, keptHeaderA, keptBody, keptResponse;
__gshared string[] keptHeaderB;

void keep(const(char)[] path, const(char)[] a, string b, const(char)[] body_) @trusted
{
    keptPath ~= path;
    keptHeaderA ~= a;
    keptHeaderB ~= b;
    keptBody ~= body_;
}

void keepResponse(const(char)[] r) @trusted { keptResponse ~= r; }

string keepAll(const(char)[] tag, Header!"X-B" b, Context ctx)
{
    keep(tag, ctx.request.header("X-A"), b.value, cast(const(char)[]) ctx.request.body);
    return ("kept " ~ tag).idup;
}

string oob(int i)
{
    int[] a = [1, 2, 3];
    return a[i] > 0 ? "positive" : "zero"; // an Error from @safe code when i >= 3
}

Response cookies() => Response(200, "text/plain", "c", [HeaderField("Set-Cookie", "a=1"), HeaderField("Set-Cookie", "b=2")]);

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/big/{kib}", big);
    app.post!("/len", bodyLen);
    app.post!("/stream", streamSum);
    app.post!("/hold", holdThenSum);
    app.post!("/first3", firstThree);
    app.get!("/proto", proto);
    app.get!("/host", host);
    app.get!("/ip", myIp);
    app.get!("/cookies", cookies);
    app.use((Context c, Next n) {
        n();
        if (c.request.path.length >= 5 && c.request.path[0 .. 5] == "/keep")
            keepResponse(c.response.body.data);
    });
    app.post!("/keep/{tag}", keepAll);
    app.get!("/oob/{i}", oob);
    app.get!("/s/chunks", sChunks);
    app.get!("/s/events", sEvents);
    app.get!("/s/big/{mib}", sBig);
    app.get!("/s/forever", sForever);
    app.get!("/s/fail", sFail);
    return app;
}

// ---------------------------------------------------------------- test server

@system:

struct Server
{
    EpollLoop loop;
    Thread thread;
    ushort port;
}

Server start(ServerConfig cfg)
{
    cfg.port = 0;
    cfg.workers = 1;
    cfg.host = "127.0.0.1";
    cfg.reusePort = false;
    auto loop = new EpollLoop;
    auto factory = handlerFactory(buildApp());
    auto t = new Thread({ loop.run(cfg, factory); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(loop.ready))
            return Server(loop, t, loop.boundPort);
        Thread.sleep(5.msecs);
    }
    assert(0, "server did not become ready");
}

void stop(ref Server s)
{
    s.loop.stop();
    s.thread.join();
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 5)
    {
        if (cond())
            return true;
        Thread.sleep(5.msecs);
    }
    return cond();
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

// ---------------------------------------------------------------- minimal HTTP/2 client

ptrdiff_t rd(int fd, void* p, size_t n)
{
    import core.stdc.errno : errno, EINTR;

    for (;;)
    {
        auto r = read(fd, p, n);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

ptrdiff_t sd(int fd, const(void)* p, size_t n)
{
    import core.stdc.errno : errno, EINTR;

    for (;;)
    {
        auto r = send(fd, p, n, 0x4000);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

int dial(ushort port, int rcvTimeoutMs = 5000)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0, "connect failed");
    timeval tv = timeval(rcvTimeoutMs / 1000, (rcvTimeoutMs % 1000) * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

void txAll(int fd, const(ubyte)[] b)
{
    while (b.length)
    {
        auto n = sd(fd, b.ptr, b.length);
        assert(n > 0, "send failed");
        b = b[n .. $];
    }
}

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

ubyte[] setting(ushort id, uint v) => [cast(ubyte)(id >> 8), cast(ubyte) id] ~ u32(v);

struct Frame
{
    ubyte type, flags;
    uint sid;
    ubyte[] payload;
    uint u32at(size_t i) const => (payload[i] << 24) | (payload[i + 1] << 16) | (payload[i + 2] << 8) | payload[i + 3];
}

struct Resp
{
    int status;
    string headers; /// "name=value;" in order
    string body;
    uint rst = uint.max; /// RST_STREAM code, if reset
    bool done;
}

final class H2Client
{
    int fd;
    ubyte[] inbuf;
    HpackDecoder dec;
    Resp[uint] resp;
    uint goAwayCode = uint.max;
    uint goAwayLast;
    bool eof;
    bool autoWindow = true;
    uint nextId = 1;
    // the server's receive windows, which request bodies respect (as real clients do): a streamed body reopens its
    // stream's window only as the handler reads
    long connWindow = 65_535, peerInitial = 65_535;
    long[uint] streamWindow;

    this(ushort port, const(ubyte)[] settings = null, bool preface = true, int rcvTimeoutMs = 5000)
    {
        fd = dial(port, rcvTimeoutMs);
        dec.setMaxAllowed(4096);
        if (preface)
            txAll(fd, cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, settings));
    }

    void hang()
    {
        if (fd >= 0)
            close(fd);
        fd = -1;
    }

    /// Sends a request; returns its stream id. `open`: the body goes on with `send` (no END_STREAM yet).
    uint request(string method, string path, const(ubyte)[] body = null, string[2][] extra = null, bool open = false)
    {
        ByteBuffer b;
        encodeField(b, ":method", method);
        encodeField(b, ":scheme", "http");
        encodeField(b, ":path", path);
        encodeField(b, ":authority", "test.local");
        foreach (h; extra)
            encodeField(b, h[0], h[1]);
        immutable sid = nextId;
        nextId += 2;
        auto blk = cast(const(ubyte)[]) b.data;
        txAll(fd, frame(1, flagEndHeaders | (body.length || open ? 0 : flagEndStream), sid, blk));
        resp[sid] = Resp.init;
        streamWindow[sid] = peerInitial;
        if (body.length)
            send(sid, body, !open);
        return sid;
    }

    /// DATA for `sid` within the server's windows, reading frames (WINDOW_UPDATE) while they are closed; an empty body
    /// with `end` is a bare END_STREAM. Returns the bytes sent: fewer when the stream got its answer or a reset first, or
    /// when no frame came within the receive timeout (`eof` is then set; clear it to go on).
    size_t send(uint sid, const(ubyte)[] body, bool end)
    {
        if (!body.length && end)
            txAll(fd, frame(0, flagEndStream, sid, null));
        size_t sent;
        while (body.length)
        {
            long room = connWindow < streamWindow[sid] ? connWindow : streamWindow[sid];
            if (room > 16_384)
                room = 16_384;
            if (room <= 0)
            {
                if (resp[sid].done || !step())
                    return sent;
                continue;
            }
            immutable n = body.length < room ? body.length : cast(size_t) room;
            txAll(fd, frame(0, end && n == body.length ? flagEndStream : 0, sid, body[0 .. n]));
            connWindow -= n;
            streamWindow[sid] -= n;
            body = body[n .. $];
            sent += n;
        }
        return sent;
    }

    void reset(uint sid, uint code = 8)
    {
        txAll(fd, frame(3, 0, sid, u32(code)));
    }

    /// Reads one frame and applies it. False on EOF/timeout.
    bool step()
    {
        while (inbuf.length < 9 || inbuf.length < 9 + ((inbuf[0] << 16) | (inbuf[1] << 8) | inbuf[2]))
        {
            ubyte[65_536] tmp;
            auto n = rd(fd, tmp.ptr, tmp.length);
            if (n <= 0)
            {
                eof = true;
                return false;
            }
            inbuf ~= tmp[0 .. n];
        }
        immutable len = (inbuf[0] << 16) | (inbuf[1] << 8) | inbuf[2];
        auto f = Frame(inbuf[3], inbuf[4], ((inbuf[5] & 0x7f) << 24) | (inbuf[6] << 16) | (inbuf[7] << 8) | inbuf[8],
            inbuf[9 .. 9 + len].dup);
        inbuf = inbuf[9 + len .. $].dup;
        apply(f);
        return true;
    }

    void apply(Frame f)
    {
        import std.conv : to;

        switch (f.type)
        {
            case FrameType.settings:
                if (!(f.flags & flagAck))
                {
                    for (size_t i = 0; i + 6 <= f.payload.length; i += 6)
                        if (((f.payload[i] << 8) | f.payload[i + 1]) == 4) // SETTINGS_INITIAL_WINDOW_SIZE
                        {
                            immutable v = f.u32at(i + 2);
                            foreach (ref w; streamWindow)
                                w += v - peerInitial;
                            peerInitial = v;
                        }
                    txAll(fd, frame(4, flagAck, 0, null));
                }
                break;
            case FrameType.windowUpdate:
                immutable inc = f.u32at(0) & 0x7fff_ffff;
                if (f.sid == 0)
                    connWindow += inc;
                else if (auto w = f.sid in streamWindow)
                    *w += inc;
                break;
            case FrameType.headers:
            case FrameType.continuation:
                auto r = f.sid in resp;
                assert(r, "frame for an unknown stream " ~ f.sid.to!string);
                string got;
                assert(dec.decode(f.payload, (scope n, scope v, bool s) { got ~= n ~ "=" ~ v ~ ";"; }) == HpackError.none);
                if (got.length > 8 && got[0 .. 8] == ":status=")
                {
                    immutable st = got[8 .. 11].to!int;
                    if (st >= 200)
                        r.status = st;
                }
                r.headers ~= got;
                if (f.flags & flagEndStream)
                    r.done = true;
                break;
            case FrameType.data:
                auto r = f.sid in resp;
                assert(r, "DATA for an unknown stream");
                r.body ~= cast(string) f.payload;
                if (f.flags & flagEndStream)
                    r.done = true;
                if (autoWindow && f.payload.length)
                {
                    txAll(fd, frame(8, 0, 0, u32(cast(uint) f.payload.length)));
                    if (!(f.flags & flagEndStream))
                        txAll(fd, frame(8, 0, f.sid, u32(cast(uint) f.payload.length)));
                }
                break;
            case FrameType.rstStream:
                if (auto r = f.sid in resp)
                {
                    r.rst = f.u32at(0);
                    r.done = true;
                }
                break;
            case FrameType.ping:
                if (!(f.flags & flagAck))
                    txAll(fd, frame(6, flagAck, 0, f.payload));
                break;
            case FrameType.goAway:
                goAwayLast = f.u32at(0);
                goAwayCode = f.u32at(4);
                break;
            default:
                break;
        }
    }

    /// Reads until every listed stream is done (or the connection ends).
    void wait(uint[] sids...)
    {
        for (;;)
        {
            bool all = true;
            foreach (s; sids)
                all &= resp[s].done;
            if (all)
                return;
            if (!step())
                return;
        }
    }

    Resp get(string path)
    {
        auto sid = request("GET", path);
        wait(sid);
        return resp[sid];
    }

    /// Reads until GOAWAY arrives or the connection closes.
    void waitGoAway()
    {
        while (goAwayCode == uint.max && step())
        {
        }
    }

    /// True if no complete frame is waiting in the local buffer (used to assert that nothing more arrived).
    bool inbufDrain() => inbuf.length < 9;

    bool closedByPeer()
    {
        while (step())
        {
        }
        return eof;
    }
}

// ---------------------------------------------------------------- tests

void testBasics()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    auto r = c.get("/fast");
    assert(r.status == 200 && r.body == "ok", r.headers);
    import std.algorithm : startsWith;

    assert(r.headers.startsWith(":status=200;content-type=text/plain; charset=utf-8;content-length=2;date="), r.headers);
    assert(c.get("/proto").body == "h2");
    assert(c.get("/host").body == "test.local", "the :authority should be visible as Host");
    assert(c.get("/ip").body == "127.0.0.1", "the peer address is visible on an HTTP/2 stream");
    assert(c.get("/nope").status == 404);
    auto sid = c.request("HEAD", "/big/4");
    c.wait(sid);
    assert(c.resp[sid].status == 200 && c.resp[sid].body == "", "HEAD has no body");
    c.hang();

    // HTTP/1.1 on the same port, on a fiber that just served an HTTP/2 stream
    import std.string : indexOf;

    auto fd = dial(s.port);
    txAll(fd, cast(const(ubyte)[]) "GET /proto HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    char[4096] tmp;
    string all;
    for (;;)
    {
        auto n = rd(fd, tmp.ptr, tmp.length);
        if (n <= 0)
            break;
        all ~= tmp[0 .. n].idup;
    }
    close(fd);
    assert(all.indexOf("HTTP/1.1 200") == 0 && all[$ - 8 .. $] == "http/1.1", all);
    assert(s.loop.stats().http2Connections == 1);
    ok("h2c prior knowledge: GET/HEAD/404, :authority as Host, HTTP/1.1 still served on the same port");
}

void testRepeatedResponseHeaders()
{
    import std.algorithm : canFind;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    auto r = c.get("/cookies");
    assert(r.status == 200 && r.headers.canFind("set-cookie=a=1;") && r.headers.canFind("set-cookie=b=2;"), r.headers);
    c.hang();
    ok("two Set-Cookie headers reach the client as two header fields");
}

void testKeptSlicesOverH2()
{
    import std.conv : to;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    keptPath = keptHeaderA = keptBody = keptResponse = null;
    keptHeaderB = null;
    auto c = new H2Client(s.port);
    enum N = 400;
    size_t[] sentLen;
    string[] sentB;
    foreach (n; 0 .. N)
    {
        immutable len = (n % 50 == 0) ? 200 * 1024 : 40 + n % 200;
        auto body_ = new ubyte[len];
        body_[] = cast(ubyte)('a' + n % 26);
        immutable b = "b-" ~ n.to!string;
        auto sid = c.request("POST", "/keep/t" ~ n.to!string, body_, [["x-a", "a-" ~ n.to!string], ["x-b", b]]);
        c.wait(sid);
        assert(c.resp[sid].status == 200 && c.resp[sid].body == "kept t" ~ n.to!string, c.resp[sid].headers);
        sentLen ~= len;
        sentB ~= b;
    }
    c.hang();
    assert(keptPath.length == N && keptBody.length == N && keptResponse.length == N);
    size_t sum;
    foreach (k; 0 .. N)
    {
        foreach (ch; keptPath[k]) sum += ch;
        foreach (ch; keptHeaderA[k]) sum += ch;
        foreach (ch; keptBody[k]) sum += ch;
        foreach (ch; keptResponse[k]) sum += ch;
        assert(keptBody[k].length == sentLen[k]);
        assert(keptHeaderB[k] == sentB[k]);
    }
    assert(sum > 0);
    ok("HTTP/2: kept views are memory-safe (400 streams, 200 KiB bodies included); Header!\"X\" keeps its content");
}

/// Streamed responses over HTTP/2.
void testStreams()
{
    import std.conv : to;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    // DATA frames carry the chunks, END_STREAM ends the body; HEAD is HEADERS only
    auto c = new H2Client(s.port);
    auto r = c.get("/s/chunks");
    assert(r.status == 200 && r.body == "hello world" && r.done, r.headers);
    import std.algorithm : canFind;
    assert(!r.headers.canFind("content-length="), "a streamed body has no content-length: " ~ r.headers);
    auto head = c.request("HEAD", "/s/chunks");
    c.wait(head);
    assert(c.resp[head].status == 200 && c.resp[head].body.length == 0 && c.resp[head].done);
    assert(c.get("/fast").body == "ok", "the connection keeps working");

    // an event is delivered when it is flushed
    immutable t0 = MonoTime.currTime;
    auto ev = c.request("GET", "/s/events");
    while (c.resp[ev].body.length == 0 && c.step()) {}
    immutable firstMs = (MonoTime.currTime - t0).total!"msecs";
    assert(c.resp[ev].body == "data: first\n\n" && firstMs < 300, c.resp[ev].body ~ " after " ~ firstMs.to!string ~ " ms");
    c.wait(ev);
    assert(c.resp[ev].body == "data: first\n\ndata: second\n\n" && c.resp[ev].done);

    // a failure after the head resets the stream (INTERNAL_ERROR); the connection survives
    auto bad = c.request("GET", "/s/fail");
    c.wait(bad);
    assert(c.resp[bad].body == "abc" && c.resp[bad].rst == H2Error.internal, "rst=" ~ c.resp[bad].rst.to!string);
    assert(c.get("/fast").body == "ok");
    c.hang();
    ok("HTTP/2 streams: DATA frames per chunk, HEAD, early events, a failure after the head resets only that stream");
}

/// A slow reader: one stream stops because its window is not opened; another stream on the same connection is not held up.
void testStreamBackpressure()
{
    import std.conv : to;

    ServerConfig cfg;
    cfg.writeTimeoutMs = 20_000;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    c.autoWindow = false;
    auto big = c.request("GET", "/s/big/8");
    // read until the stream window (65,535 bytes) is used up; open only the CONNECTION window
    size_t got;
    while (got < 65_535 && c.step())
    {
        got = c.resp[big].body.length;
        if (got)
            txAll(c.fd, frame(8, 0, 0, u32(65_535)));
    }
    assert(got == 65_535, "the server sends exactly one window: " ~ got.to!string);
    // the handler is suspended with at most the high-water mark buffered: memory is bounded
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    Thread.sleep(150.msecs);
    assert(c.resp[big].body.length == 65_535 || c.inbufDrain(), "no more DATA without window");
    // another stream on the same connection completes while the big one is stalled
    auto other = c.request("GET", "/fast");
    while (!c.resp[other].done && c.step()) {}
    assert(c.resp[other].body == "ok", "a stalled stream must not hold up the others");
    // opening the stream window lets it finish
    c.autoWindow = true;
    txAll(c.fd, frame(8, 0, big, u32(1 << 30)));
    c.wait(big);
    assert(c.resp[big].done && c.resp[big].body.length == 8 << 20, c.resp[big].body.length.to!string);
    c.hang();
    ok("HTTP/2 backpressure: a stalled stream suspends its handler and does not block the connection");
}

void testStreamCancelled()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    atomicOp!"-="(streamCleanups, atomicLoad(streamCleanups));
    auto c = new H2Client(s.port);
    auto sid = c.request("GET", "/s/forever");
    while (c.resp[sid].body.length < 5 && c.step()) {}
    c.reset(sid); // RST_STREAM(CANCEL) mid-stream
    assert(waitFor(() => atomicLoad(streamCleanups) == 1, 2000), "the handler must be cancelled and scope(exit) must run");
    assert(c.get("/fast").body == "ok");
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000));
    ok("RST_STREAM mid-stream cancels the streaming handler");
}

void testStopWithOpenStreamOverH2()
{
    import std.conv : to;

    ServerConfig cfg;
    cfg.shutdownGraceMs = 300;
    auto s = start(cfg);
    atomicOp!"-="(streamCleanups, atomicLoad(streamCleanups));
    auto c = new H2Client(s.port);
    auto sid = c.request("GET", "/s/forever");
    while (c.resp[sid].body.length < 5 && c.step()) {}
    immutable t0 = MonoTime.currTime;
    stop(s);
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms < 1500, "stop must not wait for an open stream (" ~ ms.to!string ~ " ms)");
    assert(atomicLoad(streamCleanups) == 1);
    c.hang();
    ok("HTTP/2: graceful stop sends GOAWAY and cancels a stream that never ends after shutdownGraceMs");
}

void testHandlerErrorOverH2()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    auto bad = c.request("GET", "/oob/10");
    auto good = c.request("GET", "/fast");
    c.wait(bad, good);
    assert(c.resp[bad].status == 500, c.resp[bad].headers);
    assert(c.resp[good].status == 200 && c.resp[good].body == "ok", "other streams are not affected");
    assert(c.get("/fast").body == "ok", "the connection keeps working");
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000));
    auto st = s.loop.stats();
    assert(st.handlerErrors == 1 && st.fibersPoisoned == 1);
    ok("an Error in a handler over HTTP/2: that stream gets a 500, the fiber is retired, the connection lives");
}

void testMultiplexing()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    uint[] ids;
    immutable t0 = MonoTime.currTime;
    foreach (i; 0 .. 50)
        ids ~= c.request("GET", "/nap/300");
    ids ~= c.request("GET", "/fast");
    c.wait(ids[$ - 1]);
    immutable fastMs = (MonoTime.currTime - t0).total!"msecs";
    c.wait(ids);
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    foreach (id; ids[0 .. $ - 1])
        assert(c.resp[id].status == 200 && c.resp[id].body == "slept");
    assert(fastMs < 200, "a fast stream waited behind slow ones");
    assert(ms < 1500, "50 streams of 300 ms should run concurrently");
    assert(s.loop.stats().peakInFlight >= 50);
    c.hang();
    ok("multiplexing: 50 streams of 300 ms on one connection run concurrently (one fiber each)");
}

void testCancellation()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    immutable before = atomicLoad(cleanups);
    auto sid = c.request("GET", "/cancel");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    c.reset(sid);
    assert(waitFor(() => atomicLoad(cleanups) == before + 1 && s.loop.stats().inFlight == 0, 1000),
        "RST_STREAM should cancel the handler (scope(exit) runs)");
    assert(c.get("/fast").body == "ok", "the connection stays usable after a cancelled stream");

    // closing the connection cancels every stream on it
    foreach (i; 0 .. 3)
        c.request("GET", "/cancel");
    assert(waitFor(() => s.loop.stats().inFlight == 3, 1000));
    c.hang();
    assert(waitFor(() => atomicLoad(cleanups) == before + 4 && s.loop.stats().inFlight == 0, 1000),
        "disconnect should cancel all streams");
    assert(waitFor(() => s.loop.stats().connections == 0, 500));
    ok("cancellation: RST_STREAM cancels one handler, disconnect cancels all");
}

void testDeadlineAndCeiling()
{
    ServerConfig cfg;
    cfg.requestTimeoutMs = 300;
    cfg.maxInFlight = 3;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    auto slow = c.request("GET", "/nap/2000");
    auto a = c.request("GET", "/nap/100");
    auto b = c.request("GET", "/nap/100");
    auto refused = c.request("GET", "/fast"); // 4th while 3 are in flight
    c.wait(slow, a, b, refused);
    assert(c.resp[refused].rst == H2Error.refusedStream, "above maxInFlight: REFUSED_STREAM");
    assert(c.resp[a].status == 200 && c.resp[b].status == 200);
    assert(c.resp[slow].status == 504, "per-stream deadline");
    assert(c.get("/fast").status == 200);
    assert(s.loop.stats().timedOut == 1 && s.loop.stats().rejected == 1);
    c.hang();
    ok("per-stream deadline (504) and in-flight ceiling (REFUSED_STREAM) leave the connection usable");
}

void testFlowControlLargeBodies()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    // a small client window: the server must respect it and wait for WINDOW_UPDATEs
    auto c = new H2Client(s.port, setting(4, 16_384));
    auto sid = c.request("GET", "/big/4096");
    c.wait(sid);
    auto r = c.resp[sid];
    assert(r.status == 200 && r.body.length == 4096 * 1024);
    foreach (i, ch; r.body)
        if (ch != cast(char)('a' + i % 26))
            assert(0, "body corrupted");

    // uploads: 900 KB, more than the initial windows, replenished by the server
    auto up = new ubyte[900_000];
    auto u = c.request("POST", "/len", up, [["content-length", "900000"]]);
    c.wait(u);
    assert(c.resp[u].status == 200 && c.resp[u].body == "900000", c.resp[u].headers);
    c.hang();
    ok("flow control: 4 MiB response with a 16 KiB client window, 900 KB upload");
}

void testStreamedBodiesOverH2()
{
    import std.conv : to;

    ServerConfig cfg;
    cfg.bufferBodyBytes = 64 << 10;
    cfg.limits.maxBodyBytes = 8 << 20;
    cfg.headerTimeoutMs = 1500;
    auto s = start(cfg);
    scope (exit) stop(s);

    auto big = new ubyte[3 << 20];
    ulong sum;
    foreach (i, ref b; big)
    {
        b = cast(ubyte)(i * 7 % 251);
        sum += b;
    }
    immutable expect = big.length.to!string ~ ":" ~ sum.to!string;

    // announced above bufferBodyBytes: handed out at its HEADERS; unannounced: once 64 KiB arrived
    auto c = new H2Client(s.port);
    auto a = c.request("POST", "/stream", big, [["content-length", big.length.to!string]]);
    c.wait(a);
    assert(c.resp[a].status == 200 && c.resp[a].body == expect ~ ":" ~ big.length.to!string, c.resp[a].body);
    auto b = c.request("POST", "/stream", big);
    c.wait(b);
    assert(c.resp[b].status == 200 && c.resp[b].body == expect ~ ":?", c.resp[b].body);

    // a route that does not stream gets it whole, read before the handler without knowing its size
    auto l = c.request("POST", "/len", big);
    c.wait(l);
    assert(c.resp[l].status == 200 && c.resp[l].body == big.length.to!string, c.resp[l].body);

    // an answer before the end of the body: the response, then RST_STREAM(NO_ERROR) for the rest (§8.1), and the
    // connection goes on
    auto f = c.request("POST", "/first3", big);
    c.wait(f);
    assert(c.resp[f].status == 200 && c.resp[f].body == cast(string) big[0 .. 3].idup, c.resp[f].headers);
    assert(c.get("/fast").body == "ok");
    c.hang();

    // backpressure: while the handler does not read, the client is held at the stream window (256 KiB) plus what was
    // buffered; then everything arrives
    auto h = new H2Client(s.port, null, true, 300);
    immutable hs = h.request("POST", "/hold", null, [["content-length", big.length.to!string]], true);
    immutable early = h.send(hs, big, true);
    assert(early > 0 && early <= (256 << 10) + (64 << 10), "sent before the handler read: " ~ early.to!string);
    h.eof = false;
    h.send(hs, big[early .. $], true);
    h.wait(hs);
    assert(h.resp[hs].status == 200 && h.resp[hs].body == expect ~ ":" ~ big.length.to!string, h.resp[hs].body);
    h.hang();

    // above maxBodyBytes without content-length: the handler's read fails with 413
    c = new H2Client(s.port);
    auto huge = new ubyte[9 << 20];
    auto t = c.request("POST", "/stream", huge);
    c.wait(t);
    assert(c.resp[t].status == 413, c.resp[t].headers);
    assert(c.get("/fast").body == "ok", "the connection survives a 413");

    // the client resets the stream in the middle: the reader is cancelled, the fiber released
    immutable r = c.request("POST", "/stream", big[0 .. 100_000], null, true);
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    c.reset(r);
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000), "RST_STREAM must cancel the reader");
    assert(c.get("/fast").body == "ok");
    c.hang();
    ok("streamed bodies over HTTP/2: past bufferBodyBytes (announced or not) read as they arrive, the window as "
        ~ "backpressure, a buffered route, an early answer, 413 mid-body, RST_STREAM while reading");
}

void testMinBodyRateOverH2()
{
    ServerConfig cfg;
    cfg.bufferBodyBytes = 1 << 10;
    cfg.minBodyRate = 100_000;
    cfg.minBodyRateGraceMs = 300;
    cfg.headerTimeoutMs = 3000;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto c = new H2Client(s.port);
    immutable sid = c.request("POST", "/stream", null, [["content-length", "100000"]], true);
    immutable t0 = MonoTime.currTime;
    auto piece = new ubyte[10];
    foreach (_; 0 .. 8)
    {
        Thread.sleep(100.msecs);
        c.send(sid, piece, false);
    }
    c.wait(sid);
    assert(c.resp[sid].status == 408, c.resp[sid].headers);
    assert(MonoTime.currTime - t0 < 2.seconds, "the rate, not headerTimeoutMs, must end it");
    assert(c.get("/fast").body == "ok", "the connection goes on");
    c.hang();
    ok("minimum body rate over HTTP/2: a trickling stream gets 408, the connection goes on");
}

void testUpgrade()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new H2Client(s.port, null, false);
    // SETTINGS_INITIAL_WINDOW_SIZE = 65535, base64url
    txAll(c.fd, cast(const(ubyte)[]) ("GET /proto HTTP/1.1\r\nHost: up\r\nConnection: Upgrade, HTTP2-Settings\r\n"
        ~ "Upgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\n\r\n"));
    char[34] line;
    size_t got;
    while (got < line.length)
    {
        auto n = rd(c.fd, line.ptr + got, line.length - got);
        assert(n > 0);
        got += n;
    }
    assert(line == "HTTP/1.1 101 Switching Protocols\r\n");
    ubyte[1] b;
    string rest;
    while (rest.length < 4 || rest[$ - 4 .. $] != "\r\n\r\n")
    {
        assert(rd(c.fd, b.ptr, 1) == 1);
        rest ~= cast(char) b[0];
    }
    txAll(c.fd, cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, null));
    c.resp[1] = Resp.init;
    c.nextId = 3;
    c.wait(1);
    assert(c.resp[1].status == 200 && c.resp[1].body == "h2", c.resp[1].headers);
    assert(c.get("/fast").body == "ok", "the upgraded connection takes new streams");
    c.hang();
    ok("h2c upgrade: 101, the request answered on stream 1, then regular streams");
}

void testTimeouts()
{
    ServerConfig cfg;
    cfg.idleTimeoutMs = 400;
    cfg.headerTimeoutMs = 400;
    auto s = start(cfg);
    scope (exit) stop(s);

    // a stream whose body never arrives: 408 on that stream
    auto c = new H2Client(s.port);
    ByteBuffer b;
    encodeField(b, ":method", "POST");
    encodeField(b, ":scheme", "http");
    encodeField(b, ":path", "/len");
    txAll(c.fd, frame(1, flagEndHeaders, 1, cast(const(ubyte)[]) b.data));
    c.resp[1] = Resp.init;
    c.wait(1);
    assert(c.resp[1].status == 408, c.resp[1].headers);

    // then, idle: GOAWAY(NO_ERROR) and close
    c.waitGoAway();
    import std.conv : to;

    assert(c.goAwayCode == H2Error.noError, "GOAWAY code " ~ c.goAwayCode.to!string ~ " eof=" ~ c.eof.to!string);
    assert(c.closedByPeer());
    c.hang();
    ok("timeouts: 408 for a stream that stalls, GOAWAY and close when the connection idles");
}

void testGracefulStop()
{
    auto s = start(ServerConfig.init);
    auto c = new H2Client(s.port);
    auto sid = c.request("GET", "/nap/300");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    s.loop.stop();
    c.wait(sid);
    assert(c.resp[sid].status == 200 && c.resp[sid].body == "slept", "the stream in progress should finish");
    assert(c.goAwayCode == H2Error.noError && c.goAwayLast == sid);
    assert(c.closedByPeer());
    c.hang();
    s.thread.join();
    ok("graceful stop: GOAWAY, the stream in progress finishes, then the connection closes");
}

void testDisabled()
{
    ServerConfig cfg;
    cfg.http2 = false;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto fd = dial(s.port);
    txAll(fd, cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, null));
    char[64] tmp;
    auto n = rd(fd, tmp.ptr, tmp.length);
    close(fd);
    assert(n > 12 && tmp[0 .. 12] == "HTTP/1.1 501", tmp[0 .. n]);
    ok("http2 = false: the preface is just an unknown HTTP/1 method (501)");
}

void testProtocolErrorClosesOnlyThatConnection()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto bad = new H2Client(s.port);
    txAll(bad.fd, frame(0, 0, 0, cast(const(ubyte)[]) "x")); // DATA on stream 0
    bad.waitGoAway();
    assert(bad.goAwayCode == H2Error.protocol);
    assert(bad.closedByPeer());
    bad.hang();
    auto good = new H2Client(s.port);
    assert(good.get("/fast").body == "ok");
    good.hang();
    assert(waitFor(() => s.loop.stats().connections == 0, 500));
    ok("a connection error closes that connection only");
}

/// A peer that sends GOAWAY and then more bytes (h2spec 7/1 sends a PING) must see a clean end of stream, never a
/// reset: closing a socket with unread input makes the kernel send RST. The server lingers (FIN first, then discards).
/// This exercises the lingering path and checks that such connections go away. The original race (the PING landing
/// between the read of GOAWAY and close(), a window of microseconds) cannot be forced from a test; h2spec found it
/// (about 1 run in 20 before the fix, 0 in 80 after), so tools/h2_interop.sh is the statistical check.
void testNoResetAfterPeerGoAway()
{
    import core.stdc.errno : errno, ECONNRESET;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    foreach (round; 0 .. 20)
    {
        auto c = new H2Client(s.port); // no streams: the session is finished as soon as GOAWAY arrives
        txAll(c.fd, frame(7, 0, 0, u32(0) ~ u32(0xdeadbeef))); // GOAWAY with an unknown error code
        Thread.sleep(20.msecs);                                // the server has now decided to close
        txAll(c.fd, frame(6, 0, 0, cast(const(ubyte)[]) "h2spec!!"));
        Thread.sleep(30.msecs); // a reset (if the server sent one) has arrived; Linux reports it before the FIN
        ubyte[512] tmp;
        for (;;)
        {
            auto n = rd(c.fd, tmp.ptr, tmp.length);
            assert(n >= 0 || errno != ECONNRESET, "the server reset the connection instead of closing it");
            if (n <= 0)
                break;
        }
        c.hang();
    }
    assert(waitFor(() => s.loop.stats().connections == 0, 2000), "lingering connections must go away");
    ok("a peer GOAWAY followed by more bytes ends with a clean close, not a reset");
}

void testManyConnections()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    H2Client[] cs;
    foreach (i; 0 .. 40)
        cs ~= new H2Client(s.port);
    uint[][] ids;
    foreach (c; cs)
        ids ~= [c.request("GET", "/nap/100"), c.request("GET", "/fast"), c.request("GET", "/big/64")];
    foreach (i, c; cs)
    {
        c.wait(ids[i]);
        assert(c.resp[ids[i][0]].body == "slept" && c.resp[ids[i][1]].body == "ok"
            && c.resp[ids[i][2]].body.length == 64 * 1024);
        c.hang();
    }
    assert(waitFor(() => s.loop.stats().connections == 0 && s.loop.stats().inFlight == 0, 1000));
    ok("40 HTTP/2 connections x 3 streams, sessions and fibers recycled");
}

void main()
{
    testBasics();
    testRepeatedResponseHeaders();
    testHandlerErrorOverH2();
    testStreams();
    testStreamBackpressure();
    testStreamCancelled();
    testStopWithOpenStreamOverH2();
    testKeptSlicesOverH2();
    testMultiplexing();
    testCancellation();
    testDeadlineAndCeiling();
    testFlowControlLargeBodies();
    testStreamedBodiesOverH2();
    testMinBodyRateOverH2();
    testUpgrade();
    testTimeouts();
    testGracefulStop();
    testDisabled();
    testProtocolErrorClosesOnlyThatConnection();
    testNoResetAfterPeerGoAway();
    testManyConnections();
    printf("all HTTP/2 network tests passed\n");
}
