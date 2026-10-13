/// HTTP/2 network tests: the EpollLoop on a thread, a minimal blocking HTTP/2 client over a
/// real socket. Covers what the engine adds on top of the session: one fiber per stream
/// (multiplexing), cancellation by RST_STREAM and by disconnect, per-stream deadlines, the
/// in-flight ceiling, flow control with large bodies, h2c upgrade, idle and header timeouts,
/// graceful stop, and HTTP/1.1 still served on the same port.
module h2_net;

version (linux):

import vela;
import vela.engine;
import vela.http;
import vela.http.hpack : encodeField, encodeInt;
import vela.server : handlerFactory;

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

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/big/{kib}", big);
    app.post!("/len", bodyLen);
    app.get!("/proto", proto);
    app.get!("/host", host);
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

    /// Sends a request; returns its stream id.
    uint request(string method, string path, const(ubyte)[] body = null, string[2][] extra = null)
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
        txAll(fd, frame(1, flagEndHeaders | (body.length ? 0 : flagEndStream), sid, blk));
        while (body.length)
        {
            auto n = body.length < 16_384 ? body.length : 16_384;
            txAll(fd, frame(0, n == body.length ? flagEndStream : 0, sid, body[0 .. n]));
            body = body[n .. $];
        }
        resp[sid] = Resp.init;
        return sid;
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
                    txAll(fd, frame(4, flagAck, 0, null));
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
    testMultiplexing();
    testCancellation();
    testDeadlineAndCeiling();
    testFlowControlLargeBodies();
    testUpgrade();
    testTimeouts();
    testGracefulStop();
    testDisabled();
    testProtocolErrorClosesOnlyThatConnection();
    testManyConnections();
    printf("all HTTP/2 network tests passed\n");
}
