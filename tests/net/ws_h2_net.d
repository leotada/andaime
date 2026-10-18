/// WebSockets over HTTP/2 (RFC 8441) on real sockets: the extended CONNECT on the wire, echo across stream windows,
/// WebSockets and requests multiplexed on one connection, a broadcast between streams and connections, a stream reset by
/// the peer (its handler sees 1006, the connection lives on), a connection that drops, a reader that stops reading, the
/// server closing first, a WsConn kept after its stream ended, pings, a graceful stop (1001) and `http2WebSockets = false`.
module ws_h2_net;

version (linux):

import andaime;
import andaime.engine;
import andaime.http;
import andaime.http.hpack : encodeField, HpackDecoder, HpackError;
import andaime.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import std.algorithm : canFind;
import std.conv : to;

// ---------------------------------------------------------------- app

shared int lastClose;     // close code the last handler saw
shared int handlersDone;
shared int lastProto;     // 2 when the last WebSocket handler ran on HTTP/2
WsConn[] room;            // per worker (module variables are thread-local)
WsConn stale;             // per worker

@safe:

WebSocket echo(Context ctx)
{
    atomicStore(lastProto, ctx.request.protocol == Protocol.http2 ? 2 : 1);
    auto w = WebSocket((scope WsConn ws) @system {
        scope (exit)
            atomicOp!"+="(handlersDone, 1);
        foreach (m; ws)
        {
            if (m.isText)
                ws.send(m.text);
            else
                ws.sendBinary(m.data);
        }
        atomicStore(lastClose, cast(int) ws.closeCode);
    });
    w.maxMessageBytes = 8 << 20;
    return w;
}

WebSocket chat()
{
    return WebSocket((scope WsConn ws) @system {
        room ~= ws;
        scope (exit)
        {
            foreach (i, x; room)
                if (x is ws)
                {
                    room = room[0 .. i] ~ room[i + 1 .. $];
                    break;
                }
            atomicOp!"+="(handlersDone, 1);
        }
        foreach (m; ws)
            foreach (peer; room.dup)
                if (peer !is ws)
                {
                    try
                        peer.send(m.text);
                    catch (WsClosed)
                    {
                    }
                }
        atomicStore(lastClose, cast(int) ws.closeCode);
    });
}

WebSocket flood()
{
    return WebSocket((scope WsConn ws) @system {
        scope (exit)
            atomicOp!"+="(handlersDone, 1);
        auto chunk = new char[64 << 10];
        chunk[] = 'x';
        for (;;)
            ws.send(chunk);
    });
}

WebSocket pinged()
{
    auto w = WebSocket((scope WsConn ws) @system {
        auto m = ws.receive();
        atomicStore(lastClose, cast(int) m.closeCode);
        atomicOp!"+="(handlersDone, 1);
    });
    w.pingInterval = 200.msecs;
    return w;
}

WebSocket bye() => WebSocket((scope WsConn ws) @system { ws.send("bye"); });

WebSocket keepStale() => WebSocket((scope WsConn ws) @system { stale = ws; });

WebSocket poke()
{
    return WebSocket((scope WsConn ws) @system {
        foreach (m; ws)
        {
            try
            {
                stale.send("are you there?");
                ws.send("sent");
            }
            catch (WsClosed)
                ws.send("WsClosed");
        }
    });
}

string plain() => "plain";

App buildApp()
{
    auto app = new App;
    app.ws!("/echo", echo);
    app.ws!("/chat", chat);
    app.ws!("/flood", flood);
    app.ws!("/pinged", pinged);
    app.ws!("/bye", bye);
    app.ws!("/stale", keepStale);
    app.ws!("/poke", poke);
    app.get!("/plain", plain);
    return app;
}

// ---------------------------------------------------------------- harness

@system:

struct Server
{
    EpollLoop loop;
    Thread thread;
    ushort port;
}

Server start(ServerConfig cfg = ServerConfig.init)
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

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

/// What one stream received.
struct Stream
{
    string headers;           /// "name=value;" in order
    int status;
    ubyte[] data;             /// DATA payloads not parsed yet (WebSocket frames)
    bool ended;               /// END_STREAM
    uint rst = uint.max;      /// RST_STREAM code
    size_t used;              /// bytes of `data` already parsed into frames
}

/// A minimal HTTP/2 client that opens WebSockets as streams (frames through andaime's codec, masked like a browser's).
final class H2Ws
{
    int fd;
    ubyte[] inbuf;
    HpackDecoder dec;
    Stream[uint] streams;
    uint nextId = 1;
    bool autoWindow = true;  /// give the server's DATA back with WINDOW_UPDATE (false: a reader that stopped reading)
    uint connectSetting = uint.max; /// the server's SETTINGS_ENABLE_CONNECT_PROTOCOL (max: not seen yet)
    uint goAway = uint.max;
    bool eof;
    // what the server lets us send (its flow control)
    long peerInitial = 65_535;
    long connSend = 65_535;
    long[uint] sendWin;

    this(ushort port)
    {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        a.sin_addr.s_addr = htonl(0x7f000001);
        assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0, "connect failed");
        timeval tv = timeval(5, 0);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
        dec.setMaxAllowed(4096);
        tx(cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, null));
        while (connectSetting == uint.max)
            assert(step(), "no SETTINGS from the server");
    }

    void tx(const(void)[] s)
    {
        import core.stdc.errno : errno, EINTR;

        auto b = cast(const(ubyte)[]) s;
        while (b.length)
        {
            auto n = send(fd, b.ptr, b.length, 0x4000);
            if (n < 0 && errno == EINTR)
                continue;
            assert(n > 0, "send failed");
            b = b[n .. $];
        }
    }

    void hang()
    {
        if (fd >= 0)
            close(fd);
        fd = -1;
    }

    uint open(string path, string protocol = "websocket")
    {
        ByteBuffer b;
        encodeField(b, ":method", "CONNECT");
        encodeField(b, ":protocol", protocol);
        encodeField(b, ":scheme", "http");
        encodeField(b, ":path", path);
        encodeField(b, ":authority", "t");
        encodeField(b, "sec-websocket-version", "13");
        immutable sid = nextId;
        nextId += 2;
        streams[sid] = Stream.init;
        sendWin[sid] = peerInitial;
        tx(frame(1, flagEndHeaders, sid, cast(const(ubyte)[]) b.data));
        return sid;
    }

    uint get(string path)
    {
        ByteBuffer b;
        encodeField(b, ":method", "GET");
        encodeField(b, ":scheme", "http");
        encodeField(b, ":path", path);
        encodeField(b, ":authority", "t");
        immutable sid = nextId;
        nextId += 2;
        streams[sid] = Stream.init;
        tx(frame(1, flagEndHeaders | flagEndStream, sid, cast(const(ubyte)[]) b.data));
        return sid;
    }

    /// Opens a WebSocket and waits for the answer.
    uint ws(string path)
    {
        auto sid = open(path);
        while (streams[sid].status == 0 && streams[sid].rst == uint.max)
            assert(step(), "no answer to the extended CONNECT");
        assert(streams[sid].status == 200, path ~ ": " ~ streams[sid].headers);
        return sid;
    }

    void wsSend(uint sid, ubyte opcode, const(void)[] payload)
    {
        static immutable ubyte[4] key = [9, 8, 7, 6];
        ByteBuffer b;
        encodeFrame(b, opcode, true, false, cast(const(ubyte)[]) payload, key[]);
        auto d = cast(const(ubyte)[]) b.data;
        while (d.length)
        {
            long n = d.length < 16_384 ? d.length : 16_384;
            if (n > connSend)
                n = connSend;
            if (n > sendWin[sid])
                n = sendWin[sid];
            if (n <= 0)
            {
                assert(step(), "the server never reopened its window (connection " ~ connSend.to!string ~ ", stream "
                    ~ sendWin[sid].to!string ~ ")");
                continue;
            }
            tx(frame(0, 0, sid, d[0 .. cast(size_t) n]));
            d = d[cast(size_t) n .. $];
            connSend -= n;
            sendWin[sid] -= n;
        }
    }

    void text(uint sid, string s) { wsSend(sid, WsOpcode.text, s); }

    void closeFrame(uint sid, ushort code)
    {
        ubyte[2] p = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
        wsSend(sid, WsOpcode.close, p[]);
    }

    void endStream(uint sid) { tx(frame(0, flagEndStream, sid, null)); }

    void reset(uint sid, uint code = 8) { tx(frame(3, 0, sid, u32(code))); }

    struct WsFrame
    {
        int opcode = -1; // -1: the stream ended or was reset first
        ubyte[] payload;

        ushort code() const => payload.length >= 2 ? cast(ushort)((payload[0] << 8) | payload[1]) : 0;
        string text() const => cast(string) payload.idup;
    }

    /// The next WebSocket frame on the stream.
    WsFrame recv(uint sid)
    {
        for (;;)
        {
            auto st = sid in streams;
            auto buf = st.data[st.used .. $];
            FrameHeader h;
            if (parseFrameHeader(buf, h) == FrameParse.ok && buf.length >= h.headerLength + h.length)
            {
                assert(!h.masked, "a server frame must not be masked");
                auto p = buf[h.headerLength .. h.headerLength + cast(size_t) h.length].dup;
                st.used += h.headerLength + cast(size_t) h.length;
                return WsFrame(h.opcode, p);
            }
            if (st.ended || st.rst != uint.max || !step())
                return WsFrame.init;
        }
    }

    /// Reads until the stream ends or is reset; false on EOF/timeout first.
    bool waitEnd(uint sid)
    {
        while (!streams[sid].ended && streams[sid].rst == uint.max)
            if (!step())
                return false;
        return true;
    }

    /// Reads one frame and applies it. False on EOF/timeout.
    bool step()
    {
        while (inbuf.length < 9 || inbuf.length < 9 + ((inbuf[0] << 16) | (inbuf[1] << 8) | inbuf[2]))
        {
            import core.stdc.errno : errno, EINTR;

            ubyte[65_536] tmp;
            auto n = read(fd, tmp.ptr, tmp.length);
            if (n < 0 && errno == EINTR)
                continue; // the server's collector stops this thread too (signals)
            if (n <= 0)
            {
                eof = n == 0;
                return false;
            }
            inbuf ~= tmp[0 .. n];
        }
        immutable len = (inbuf[0] << 16) | (inbuf[1] << 8) | inbuf[2];
        immutable type = inbuf[3], flags = inbuf[4];
        immutable sid = ((inbuf[5] & 0x7f) << 24) | (inbuf[6] << 16) | (inbuf[7] << 8) | inbuf[8];
        auto payload = inbuf[9 .. 9 + len].dup;
        inbuf = inbuf[9 + len .. $].dup;
        switch (type)
        {
            case FrameType.settings:
                if (!(flags & flagAck))
                {
                    if (connectSetting == uint.max)
                        connectSetting = 0;
                    for (size_t i = 0; i + 6 <= payload.length; i += 6)
                    {
                        immutable v = (payload[i + 2] << 24) | (payload[i + 3] << 16) | (payload[i + 4] << 8) | payload[i + 5];
                        if (payload[i] == 0 && payload[i + 1] == 8)
                            connectSetting = v;
                        if (payload[i] == 0 && payload[i + 1] == 4)
                            peerInitial = v;
                    }
                    tx(frame(4, flagAck, 0, null));
                }
                break;
            case FrameType.headers:
                auto st = sid in streams;
                assert(st, "HEADERS for an unknown stream");
                string got;
                assert(dec.decode(payload, (scope n, scope v, bool s) { got ~= n ~ "=" ~ v ~ ";"; }) == HpackError.none);
                st.headers ~= got;
                if (got.length > 11 && got[0 .. 8] == ":status=")
                    st.status = got[8 .. 11].to!int;
                if (flags & flagEndStream)
                    st.ended = true;
                break;
            case FrameType.data:
                auto st = sid in streams;
                assert(st, "DATA for an unknown stream");
                st.data ~= payload;
                if (flags & flagEndStream)
                    st.ended = true;
                if (autoWindow && payload.length)
                {
                    tx(frame(8, 0, 0, u32(cast(uint) payload.length)));
                    if (!(flags & flagEndStream))
                        tx(frame(8, 0, sid, u32(cast(uint) payload.length)));
                }
                break;
            case FrameType.rstStream:
                if (auto st = sid in streams)
                    st.rst = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
                break;
            case FrameType.windowUpdate:
                immutable inc = ((payload[0] & 0x7f) << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
                if (sid == 0)
                    connSend += inc;
                else if (auto w = sid in sendWin)
                    *w += inc;
                break;
            case FrameType.goAway:
                goAway = (payload[4] << 24) | (payload[5] << 16) | (payload[6] << 8) | payload[7];
                break;
            case FrameType.ping:
                if (!(flags & 1))
                    tx(frame(6, 1, 0, payload));
                break;
            default:
                break;
        }
        return true;
    }

    /// The whole body of an ordinary response.
    string body(uint sid)
    {
        assert(waitEnd(sid));
        return cast(string) streams[sid].data.idup;
    }
}

// ---------------------------------------------------------------- tests

void testHandshakeAndEcho()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = new H2Ws(s.port);
    assert(c.connectSetting == 1, "SETTINGS_ENABLE_CONNECT_PROTOCOL = 1");
    auto sid = c.ws("/echo");
    assert(!c.streams[sid].headers.canFind("sec-websocket-accept") && !c.streams[sid].ended);
    assert(waitFor(() => s.loop.stats().webSockets == 1, 1000) && atomicLoad(lastProto) == 2);
    c.text(sid, "hello");
    assert(c.recv(sid).text == "hello");
    // 1 MiB: several of the server's stream windows (256 KiB) in, several of ours (64 KiB) out
    auto big = new ubyte[1 << 20];
    foreach (i, ref x; big)
        x = cast(ubyte)(i * 7);
    c.wsSend(sid, WsOpcode.binary, big[0 .. 60_000]); // under our own window
    auto f = c.recv(sid);
    assert(f.opcode == WsOpcode.binary && f.payload == big[0 .. 60_000]);
    c.closeFrame(sid, 1000);
    assert(c.recv(sid).code == 1000);
    c.endStream(sid);
    assert(c.waitEnd(sid) && c.streams[sid].rst == uint.max, "the server ends its side with END_STREAM");
    assert(waitFor(() => atomicLoad(handlersDone) == 1 && s.loop.stats().webSockets == 0, 1000));
    assert(atomicLoad(lastClose) == 1000);
    auto g = c.get("/plain");
    assert(c.body(g) == "plain", "the connection goes on");
    c.hang();
    ok("an extended CONNECT: 200 without Sec-WebSocket-Accept, echo, close handshake, END_STREAM, connection reused");
}

void testBigMessagesBothWays()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = new H2Ws(s.port);
    auto sid = c.ws("/echo");
    // 4 MiB: the server's stream window (256 KiB) reopens only as its WebSocket consumes, ours as the test reads
    auto text = new char[4 << 20];
    foreach (i, ref x; text)
        x = cast(char)('a' + i % 26);
    c.text(sid, cast(string) text);
    auto f = c.recv(sid);
    assert(f.opcode == WsOpcode.text && f.payload.length == text.length && cast(char[]) f.payload == text,
        "4 MiB text echoed: got " ~ f.payload.length.to!string ~ " bytes, RST " ~ c.streams[sid].rst.to!string);
    c.closeFrame(sid, 1000);
    assert(c.recv(sid).code == 1000);
    c.hang();
    ok("a 4 MiB message each way across many stream windows");
}

void testMultiplexAndBroadcast()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = new H2Ws(s.port);
    auto other = new H2Ws(s.port);
    auto a = c.ws("/chat");
    auto b = c.ws("/chat");
    auto x = other.ws("/chat");
    assert(waitFor(() => s.loop.stats().webSockets == 3, 1000));
    auto g = c.get("/plain");
    c.text(a, "from a");
    assert(c.recv(b).text == "from a" && other.recv(x).text == "from a",
        "a broadcast reaches a stream of the same connection and one of another connection");
    assert(c.body(g) == "plain", "an ordinary request between them");
    other.text(x, "from x");
    assert(c.recv(a).text == "from x" && c.recv(b).text == "from x");

    // the peer resets one stream: its handler sees 1006, the others and the connection go on
    c.reset(a);
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 2000), "the reset stream's handler ends");
    assert(atomicLoad(lastClose) == 1006, atomicLoad(lastClose).to!string);
    other.text(x, "after the reset");
    assert(c.recv(b).text == "after the reset");
    assert(waitFor(() => s.loop.stats().webSockets == 2, 1000));

    // the whole connection drops: its handler is cancelled, the other connection is untouched
    c.hang();
    assert(waitFor(() => atomicLoad(handlersDone) == 2, 2000), "the dropped connection's handler ends");
    other.text(x, "alone");
    other.closeFrame(x, 1000);
    assert(other.recv(x).code == 1000);
    assert(waitFor(() => atomicLoad(handlersDone) == 3, 2000));
    assert(waitFor(() => s.loop.stats().webSockets == 0 && s.loop.stats().inFlight == 0, 1000));
    other.hang();
    ok("WebSockets and requests on one connection; a broadcast across streams and connections; reset (1006); a drop");
}

void testReaderStopsReading()
{
    ServerConfig cfg;
    cfg.writeTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = new H2Ws(s.port);
    c.autoWindow = false; // never give the window back: the server's stream (and connection) window runs out
    auto sid = c.ws("/flood");
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 3000), "the flooding handler is cancelled");
    assert(c.waitEnd(sid) && c.streams[sid].rst == 8, "its stream is reset with CANCEL");
    assert(waitFor(() => s.loop.stats().inFlight == 0 && s.loop.stats().webSockets == 0, 1000));
    c.hang();
    ok("a reader that stops reading: the writer waits writeTimeoutMs, then the stream is reset (CANCEL)");
}

void testServerClosesFirst()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = new H2Ws(s.port);
    auto sid = c.ws("/bye");
    assert(c.recv(sid).text == "bye");
    auto f = c.recv(sid);
    assert(f.opcode == WsOpcode.close && f.code == 1000, "the handler returned: close 1000");
    c.closeFrame(sid, 1000);
    assert(c.waitEnd(sid) && c.streams[sid].ended && c.streams[sid].rst == uint.max);
    c.endStream(sid);

    // a client that never answers the close nor ends its side: END_STREAM after a second, a reset after another
    auto d = c.ws("/bye");
    assert(c.recv(d).text == "bye" && c.recv(d).code == 1000);
    auto t0 = MonoTime.currTime;
    assert(c.waitEnd(d) && c.streams[d].ended);
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 800 && ms < 2500, ms.to!string);
    while (c.streams[d].rst == uint.max)
        assert(c.step(), "the half-closed stream is reset");
    assert(c.streams[d].rst == 0, "NO_ERROR");
    assert(c.body(c.get("/plain")) == "plain");
    c.hang();
    ok("the handler returns: close 1000 and END_STREAM; a silent peer: END_STREAM after a second, then RST(NO_ERROR)");
}

void testWriteToEndedFromOtherFiber()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = new H2Ws(s.port);
    auto a = c.ws("/stale");
    assert(c.recv(a).code == 1000);
    c.closeFrame(a, 1000);
    c.endStream(a);
    assert(c.waitEnd(a));
    auto b = c.ws("/poke");
    c.text(b, "go");
    assert(c.recv(b).text == "WsClosed", "a write to a stream that ended throws WsClosed in the writing fiber");
    c.closeFrame(b, 1000);
    assert(c.recv(b).code == 1000);
    assert(waitFor(() => s.loop.stats().webSockets == 0, 1000));
    c.hang();
    ok("a fiber writing to a WebSocket whose stream ended gets WsClosed (never a later stream)");
}

void testPings()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = new H2Ws(s.port);
    auto sid = c.ws("/pinged");
    auto f = c.recv(sid);
    assert(f.opcode == WsOpcode.ping, "a ping after pingInterval without input");
    c.wsSend(sid, WsOpcode.pong, f.payload);
    assert(c.recv(sid).opcode == WsOpcode.ping, "pinged again");
    // no answer: the server gives up after another interval and resets the stream
    assert(c.waitEnd(sid));
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 1000) && atomicLoad(lastClose) == 1006);
    assert(c.body(c.get("/plain")) == "plain");
    c.hang();
    ok("pings on an HTTP/2 WebSocket; an unanswered ping ends the stream (1006), not the connection");
}

void testGracefulStop()
{
    auto s = start();
    atomicStore(handlersDone, 0);
    auto c = new H2Ws(s.port);
    auto sid = c.ws("/echo");
    c.text(sid, "x");
    assert(c.recv(sid).text == "x");
    auto stopper = new Thread({ stop(s); });
    auto t0 = MonoTime.currTime;
    stopper.start();
    auto f = c.recv(sid);
    assert(f.opcode == WsOpcode.close && f.code == 1001, "graceful stop: close 1001 (going away)");
    c.closeFrame(sid, 1001);
    c.endStream(sid);
    stopper.join();
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms < 2000, ms.to!string);
    assert(atomicLoad(handlersDone) == 1 && atomicLoad(lastClose) == 1001);
    c.hang();
    ok("graceful stop: HTTP/2 WebSockets get close 1001 and the server stops once they answer");
}

void testRefusals()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = new H2Ws(s.port);
    auto p = c.open("/plain");
    assert(c.waitEnd(p) && c.streams[p].status == 400, "an ordinary route refuses an extended CONNECT");
    auto t = c.open("/echo", "webtransport");
    assert(c.waitEnd(t) && c.streams[t].status == 501, "another protocol: 501");
    auto g = c.get("/echo");
    assert(c.waitEnd(g) && c.streams[g].status == 426, "a plain HTTP/2 GET on a WebSocket route: 426");
    c.hang();

    ServerConfig off;
    off.http2WebSockets = false;
    auto s2 = start(off);
    scope (exit) stop(s2);
    auto d = new H2Ws(s2.port);
    assert(d.connectSetting == 0, "not announced");
    auto r = d.open("/echo");
    assert(d.waitEnd(r) && d.streams[r].rst == 1, "an extended CONNECT the server did not offer: PROTOCOL_ERROR");
    d.hang();
    ok("refusals: 400 on an ordinary route, 501 for another protocol, 426 for a GET; http2WebSockets = false");
}

void main()
{
    testHandshakeAndEcho();
    testBigMessagesBothWays();
    testMultiplexAndBroadcast();
    testReaderStopsReading();
    testServerClosesFirst();
    testWriteToEndedFromOtherFiber();
    testPings();
    testGracefulStop();
    testRefusals();
    printf("all HTTP/2 WebSocket tests passed\n");
}
