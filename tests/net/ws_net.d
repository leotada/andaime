/// WebSockets on real sockets: the handshake on the wire, echo, frames that arrive with the handshake, a message split over
/// many reads, an upgrade behind pipelined responses, a broadcast from another fiber, a peer that vanishes, a reader that
/// stops reading, pings and the idle limit, the server closing first, a graceful stop (1001) and the counters.
module ws_net 2025;

version (linux):

import andaime;
import andaime.engine;
import andaime.http;
import andaime.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import std.algorithm : canFind, startsWith;
import std.string : indexOf;
import std.conv : to;

// ---------------------------------------------------------------- app

shared int lastClose;   // close code the last handler saw
shared int handlersDone;
shared int writersClosed; // WsClosed caught by a broadcasting fiber
WsConn[] room;            // per worker (module variables are thread-local): the chat room

@safe:

WebSocket echo()
{
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
                        atomicOp!"+="(writersClosed, 1);
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

WsConn stale; // per worker

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

WebSocket echoZ()
{
    auto w = echo();
    w.compression = true;
    return w;
}

/// The WebSocket client inside a request: connects back to this same worker (so its waits must not block it), with
/// compression, and reports what came back.
string relay(int port, bool compression) @trusted
{
    WsClientOptions opts;
    opts.compression = compression;
    auto ws = wsConnect("ws://127.0.0.1:" ~ port.to!string ~ "/echo-z", null, opts);
    scope (exit)
        ws.disconnect();
    string got;
    auto text = new char[10_000];
    text[] = 'z';
    ws.send("one");
    ws.send(text);
    got ~= ws.receive().text.idup;
    got ~= " " ~ ws.receive().text.length.to!string;
    ws.close(4002, "done");
    auto m = ws.receive();
    got ~= " " ~ m.closeCode.to!string;
    return got;
}

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
    app.ws!("/echo-z", echoZ);
    app.get!("/relay", relay);
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

void tx(int fd, const(void)[] s)
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

/// A raw WebSocket client: the handshake by hand, frames through andaime's codec (masked, as a browser's).
struct Client
{
    int fd;
    ubyte[] buf; // received, not parsed yet
    string head; // the server's HTTP answer

    struct Frame
    {
        int opcode = -1; // -1: the connection ended
        ubyte[] payload;
        bool fin;

        ushort code() const => payload.length >= 2 ? cast(ushort)((payload[0] << 8) | payload[1]) : 0;
        string text() const => cast(string) payload.idup;
    }

    static string upgradeRequest(string path, string extra = null)
    {
        return "GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            ~ "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ~ extra ~ "\r\n";
    }

    /// Connects and upgrades; `before` is sent ahead of the upgrade request and `after` right behind it (same send).
    static Client open(ushort port, string path, string before = null, const(ubyte)[] after = null, int rcvMs = 5000)
    {
        Client c;
        c.fd = dial(port, rcvMs);
        tx(c.fd, cast(const(ubyte)[]) (before ~ upgradeRequest(path)) ~ after);
        c.readHead();
        return c;
    }

    void readHead()
    {
        for (;;)
        {
            auto s = cast(string) buf;
            auto e = s.indexOf("\r\n\r\n");
            if (e >= 0)
            {
                head = s[0 .. e + 4].idup;
                buf = buf[e + 4 .. $];
                return;
            }
            if (!more())
            {
                head = s.idup;
                buf = null;
                return;
            }
        }
    }

    bool more()
    {
        ubyte[65536] tmp;
        auto n = rd(fd, tmp.ptr, tmp.length);
        if (n <= 0)
            return false;
        buf ~= tmp[0 .. n];
        return true;
    }

    void send(ubyte opcode, const(void)[] payload, bool fin = true)
    {
        static immutable ubyte[4] key = [9, 8, 7, 6];
        ByteBuffer b;
        encodeFrame(b, opcode, fin, false, cast(const(ubyte)[]) payload, key[]);
        tx(fd, b.data);
    }

    void text(string s) { send(WsOpcode.text, s); }

    void closeFrame(ushort code)
    {
        ubyte[2] p = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
        send(WsOpcode.close, p[]);
    }

    Frame recv()
    {
        for (;;)
        {
            FrameHeader h;
            if (parseFrameHeader(buf, h) == FrameParse.ok && buf.length >= h.headerLength + h.length)
            {
                assert(!h.masked, "a server frame must not be masked");
                auto p = buf[h.headerLength .. h.headerLength + cast(size_t) h.length].dup;
                buf = buf[h.headerLength + cast(size_t) h.length .. $];
                return Frame(h.opcode, p, h.fin);
            }
            if (!more())
                return Frame.init;
        }
    }

    /// True once the server closed the TCP connection (EOF).
    bool eof()
    {
        ubyte[256] tmp;
        for (;;)
        {
            auto n = rd(fd, tmp.ptr, tmp.length);
            if (n == 0)
                return true;
            if (n < 0)
                return false;
        }
    }

    void hang() { close(fd); }
}

// ---------------------------------------------------------------- tests

void testHandshakeAndEcho()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = Client.open(s.port, "/echo");
    assert(c.head.startsWith("HTTP/1.1 101 Switching Protocols\r\n"), c.head);
    assert(c.head.canFind("\r\nUpgrade: websocket\r\n") && c.head.canFind("\r\nConnection: Upgrade\r\n"), c.head);
    assert(c.head.canFind("\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"), c.head);
    assert(!c.head.canFind("Content-Length") && !c.head.canFind("Transfer-Encoding"), c.head);
    assert(waitFor(() => s.loop.stats().webSockets == 1, 1000));

    c.text("hello");
    auto f = c.recv();
    assert(f.opcode == WsOpcode.text && f.fin && f.text == "hello");
    c.send(WsOpcode.binary, cast(ubyte[]) [0, 1, 2, 255]);
    f = c.recv();
    assert(f.opcode == WsOpcode.binary && f.payload == [0, 1, 2, 255]);
    c.send(WsOpcode.text, "frag", false);
    c.send(WsOpcode.ping, "are you there");
    c.send(WsOpcode.continuation, "mented");
    f = c.recv();
    assert(f.opcode == WsOpcode.pong && f.text == "are you there", "a ping inside a fragmented message is answered");
    f = c.recv();
    assert(f.text == "fragmented");

    atomicStore(handlersDone, 0);
    c.closeFrame(1000);
    f = c.recv();
    assert(f.opcode == WsOpcode.close && f.code == 1000, "the close is echoed");
    assert(c.eof(), "the server closes the TCP connection after the close handshake");
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 1000) && atomicLoad(lastClose) == 1000);
    assert(waitFor(() => s.loop.stats().webSockets == 0, 1000));
    assert(s.loop.stats().webSocketsTotal == 1 && s.loop.stats().inFlight == 0);
    c.hang();
    ok("handshake on the wire, echo of text, binary and a fragmented message, ping, the close handshake, counters");
}

void testEarlyFramesAndBigMessage()
{
    auto s = start();
    scope (exit) stop(s);
    // a frame in the same packet as the handshake belongs to the WebSocket
    ByteBuffer early;
    static immutable ubyte[4] key = [1, 2, 3, 4];
    encodeFrame(early, WsOpcode.text, true, false, cast(const(ubyte)[]) "early", key[]);
    auto c = Client.open(s.port, "/echo", null, cast(const(ubyte)[]) early.data);
    assert(c.head.startsWith("HTTP/1.1 101"));
    assert(c.recv().text == "early");

    // 4 MiB: arrives over many reads, unmasked across them, echoed whole
    auto big = new ubyte[4 << 20];
    foreach (i, ref b; big)
        b = cast(ubyte)(i * 7 + (i >> 9));
    auto sender = new Thread({ c.send(WsOpcode.binary, big); });
    sender.start();
    auto f = c.recv();
    sender.join();
    assert(f.opcode == WsOpcode.binary && f.payload.length == big.length && f.payload == big);
    c.closeFrame(1000);
    assert(c.recv().code == 1000);
    c.hang();
    ok("frames that arrive with the handshake; a 4 MiB message over many reads");
}

void testUpgradeBehindPipelined()
{
    auto s = start();
    scope (exit) stop(s);
    Client c;
    c.fd = dial(s.port);
    tx(c.fd, "GET /plain HTTP/1.1\r\nHost: t\r\n\r\nGET /plain HTTP/1.1\r\nHost: t\r\n\r\n" ~ Client.upgradeRequest("/echo"));
    // the two answers come first, in order, then the 101
    ptrdiff_t upgrade, headEnd = -1;
    while (headEnd < 0)
    {
        assert(c.more(), "the connection ended before the 101");
        auto all = cast(string) c.buf;
        upgrade = all.indexOf("HTTP/1.1 101 Switching Protocols");
        if (upgrade >= 0)
            headEnd = all.indexOf("\r\n\r\n", upgrade);
    }
    auto all = cast(string) c.buf.idup;
    auto first = all.indexOf("plain");
    auto second = all.indexOf("plain", first + 5);
    assert(all.startsWith("HTTP/1.1 200 OK") && first > 0 && second > first && upgrade > second, all);
    c.buf = c.buf[headEnd + 4 .. $];
    c.text("after");
    assert(c.recv().text == "after");
    c.hang();
    ok("an upgrade behind pipelined requests: their answers go first, then the 101");
}

void testBroadcastAndVanishingPeer()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    atomicStore(writersClosed, 0);
    auto a = Client.open(s.port, "/chat");
    auto b = Client.open(s.port, "/chat");
    assert(waitFor(() => s.loop.stats().webSockets == 2, 1000));
    a.text("hi from a");
    assert(b.recv().text == "hi from a", "another fiber's handler sends on this connection");
    b.text("hi from b");
    assert(a.recv().text == "hi from b");

    // a vanishes without a close frame: its handler sees 1006; nothing else breaks
    linger l = linger(1, 0);
    setsockopt(a.fd, SOL_SOCKET, SO_LINGER, &l, l.sizeof); // close with RST
    a.hang();
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 2000), "the vanished peer's handler ends");
    assert(atomicLoad(lastClose) == 1006);
    b.text("anyone?");
    b.text("still here");
    b.closeFrame(1000);
    assert(b.recv().code == 1000);
    assert(waitFor(() => atomicLoad(handlersDone) == 2, 2000));
    assert(waitFor(() => s.loop.stats().webSockets == 0 && s.loop.stats().inFlight == 0, 1000));
    b.hang();
    ok("a broadcast from another fiber; a peer that vanishes (its handler sees 1006, the room goes on)");
}

void testWriteToClosedFromOtherFiber()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    atomicStore(writersClosed, 0);
    // /stale keeps its WsConn after its handler returned; /poke then writes to it from another fiber
    auto a = Client.open(s.port, "/stale");
    assert(a.recv().code == 1000);
    a.closeFrame(1000);
    assert(a.eof());
    auto b = Client.open(s.port, "/poke");
    b.text("go");
    assert(b.recv().text == "WsClosed", "a write to a connection that ended throws WsClosed in the writing fiber");
    b.closeFrame(1000);
    assert(b.recv().code == 1000);
    assert(waitFor(() => s.loop.stats().webSockets == 0, 1000));
    a.hang();
    b.hang();
    ok("a fiber writing to a connection that ended gets WsClosed (never a later connection), the server goes on");
}

void testReaderStopsReading()
{
    ServerConfig cfg;
    cfg.writeTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = Client.open(s.port, "/flood");
    // never read: the socket buffers fill, the handler waits, then the connection is dropped
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 3000), "the flooding handler is cancelled");
    assert(waitFor(() => s.loop.stats().inFlight == 0 && s.loop.stats().webSockets == 0, 1000));
    c.hang();
    ok("a reader that stops reading: the writer waits writeTimeoutMs, then the connection is dropped");
}

void testPingAndIdle()
{
    auto s = start();
    scope (exit) stop(s);
    atomicStore(handlersDone, 0);
    auto c = Client.open(s.port, "/pinged");
    auto t0 = MonoTime.currTime;
    auto f = c.recv();
    assert(f.opcode == WsOpcode.ping, "a ping after pingInterval without input");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 150 && ms < 1000, ms.to!string);
    c.send(WsOpcode.pong, f.payload); // alive: the clock starts again
    f = c.recv();
    assert(f.opcode == WsOpcode.ping, "pinged again");
    // no answer this time: dropped after another interval
    assert(c.eof(), "an unanswered ping drops the connection");
    assert(waitFor(() => atomicLoad(handlersDone) == 1, 1000) && atomicLoad(lastClose) == 1006);
    c.hang();
    ok("pings while the handler waits; an unanswered ping drops the connection (1006)");
}

void testServerClosesFirst()
{
    auto s = start();
    scope (exit) stop(s);
    auto c = Client.open(s.port, "/bye");
    assert(c.recv().text == "bye");
    auto f = c.recv();
    assert(f.opcode == WsOpcode.close && f.code == 1000, "the handler returned: close 1000");
    c.closeFrame(1000);
    assert(c.eof());
    c.hang();

    // a client that never answers the close: the server gives up after a second
    auto d = Client.open(s.port, "/bye");
    assert(d.recv().text == "bye" && d.recv().code == 1000);
    auto t0 = MonoTime.currTime;
    assert(d.eof());
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 800 && ms < 2500, ms.to!string);
    d.hang();
    ok("the handler returns: close 1000, the TCP connection closes after the answer (or a second without one)");
}

void testGracefulStop()
{
    auto s = start();
    atomicStore(handlersDone, 0);
    auto c = Client.open(s.port, "/echo");
    c.text("x");
    assert(c.recv().text == "x");
    auto stopper = new Thread({ stop(s); });
    auto t0 = MonoTime.currTime;
    stopper.start();
    auto f = c.recv();
    assert(f.opcode == WsOpcode.close && f.code == 1001, "graceful stop: close 1001 (going away)");
    c.closeFrame(1001);
    stopper.join();
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms < 2000, ms.to!string);
    assert(atomicLoad(handlersDone) == 1 && atomicLoad(lastClose) == 1001);
    c.hang();
    ok("graceful stop: open WebSockets get close 1001 and the server stops once they answer");
}

void testNotAnUpgrade()
{
    auto s = start();
    scope (exit) stop(s);
    auto fd = dial(s.port);
    tx(fd, "GET /echo HTTP/1.1\r\nHost: t\r\n\r\n");
    char[4096] b;
    auto n = rd(fd, b.ptr, b.length);
    assert(n > 0 && (cast(string) b[0 .. n]).startsWith("HTTP/1.1 426"), b[0 .. n].idup);
    close(fd);
    ok("a plain GET on a WebSocket route: 426");
}

void testClientInsideRequest()
{
    auto s = start();
    scope (exit) stop(s);
    foreach (compression; ["false", "true"])
    {
        auto fd = dial(s.port);
        tx(fd, "GET /relay?port=" ~ s.port.to!string ~ "&compression=" ~ compression ~ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
        string all;
        char[4096] b;
        for (;;)
        {
            auto n = rd(fd, b.ptr, b.length);
            if (n <= 0)
                break;
            all ~= b[0 .. n].idup;
        }
        close(fd);
        assert(all.startsWith("HTTP/1.1 200") && all.canFind("\r\n\r\none 10000 4002"), all);
    }
    assert(waitFor(() => s.loop.stats().webSockets == 0, 1000));
    ok("wsConnect inside a request, to the same worker (cooperative waits), with and without compression");
}

void main()
{
    testHandshakeAndEcho();
    testEarlyFramesAndBigMessage();
    testUpgradeBehindPipelined();
    testBroadcastAndVanishingPeer();
    testWriteToClosedFromOtherFiber();
    testReaderStopsReading();
    testPingAndIdle();
    testServerClosesFirst();
    testGracefulStop();
    testNotAnUpgrade();
    testClientInsideRequest();
    printf("all WebSocket tests passed\n");
}
