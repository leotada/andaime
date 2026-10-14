/// Streamed responses over HTTP/1.1 on real sockets: exact chunked framing, early delivery, backpressure with a slow
/// reader (bounded memory), a client that disappears or stops reading, HTTP/1.0, HEAD, a failure after the head, keep-alive
/// and pipelining behind a stream.
module stream_net;

version (linux):

import vela;
import vela.engine;
import vela.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import std.algorithm : canFind, startsWith, endsWith;
import std.string : indexOf;
import std.conv : to;

// ---------------------------------------------------------------- app

shared int cleanups, started;
__gshared string staticDir; // set by a test before its server starts; read-only afterwards

@safe:

Stream chunks()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("hello");
        w.write(" ");
        w.write("world");
    });
}

EventStream slowEvents()
{
    return EventStream((scope EventWriter w) @system {
        w.send("first");
        sleep(msecs(400));
        w.send("second");
    });
}

/// `mib` MiB in 64 KiB writes.
Stream big(int mib)
{
    return Stream("application/octet-stream", (scope StreamWriter w) @system {
        auto piece = new char[64 << 10];
        piece[] = 'z';
        foreach (i; 0 .. mib * 16)
            w.write(piece);
    });
}

Stream forever()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        atomicOp!"+="(started, 1);
        scope (exit)
            atomicOp!"+="(cleanups, 1);
        for (;;)
        {
            w.write("tick\n");
            w.flush();
            sleep(msecs(20));
        }
    });
}

Stream failAfterHead()
{
    return Stream("text/plain", (scope StreamWriter w) @system {
        w.write("abc");
        w.flush();
        throw new Exception("boom after the head");
    });
}

string fast() => "ok";

string staticDirNow() @trusted => staticDir; // set before the server starts, read-only afterwards

App buildApp()
{
    auto app = new App;
    app.get!("/chunks", chunks);
    app.get!("/events", slowEvents);
    app.get!("/big/{mib}", big);
    app.get!("/forever", forever);
    app.get!("/fail", failAfterHead);
    app.get!("/fast", fast);
    if (staticDirNow.length)
        app.serveStatic("/files", staticDirNow);
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

void tx(int fd, string s)
{
    import core.stdc.errno : errno, EINTR;

    while (s.length)
    {
        auto n = send(fd, s.ptr, s.length, 0x4000);
        if (n < 0 && errno == EINTR)
            continue;
        assert(n > 0, "send failed");
        s = s[n .. $];
    }
}

/// Reads until `done(all)` is true, EOF or timeout. Returns what arrived.
string readUntil(int fd, scope bool delegate(string) done)
{
    string all;
    char[16384] buf;
    for (;;)
    {
        if (done(all))
            return all;
        auto n = rd(fd, buf.ptr, buf.length);
        if (n <= 0)
            return all;
        all ~= buf[0 .. n].idup;
    }
}

string readAll(int fd) => readUntil(fd, (string) => false);

/// The response with the Date line removed, so it can be compared byte for byte.
string withoutDate(string r)
{
    auto i = r.indexOf("Date: ");
    if (i < 0)
        return r;
    auto e = r.indexOf("\r\n", i);
    return r[0 .. i] ~ r[e + 2 .. $];
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

size_t rssKb()
{
    import core.stdc.stdio : fopen, fgets, fclose, sscanf;
    import core.stdc.string : strncmp;

    auto f = fopen("/proc/self/status", "r");
    char[256] line;
    size_t v;
    while (fgets(line.ptr, 256, f))
        if (strncmp(line.ptr, "VmRSS:", 6) == 0)
        {
            sscanf(line.ptr + 6, " %zu", &v);
            break;
        }
    fclose(f);
    return v;
}

// ---------------------------------------------------------------- tests

void testFraming()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto fd = dial(s.port);
    scope (exit) close(fd);
    tx(fd, "GET /chunks HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = readUntil(fd, (string a) => a.endsWith("0\r\n\r\n"));
    assert(withoutDate(r) == "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n"
        ~ "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n", r);

    // keep-alive: the same connection serves the next request after the stream ended
    tx(fd, "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r2 = readUntil(fd, (string a) => a.endsWith("ok"));
    assert(r2.startsWith("HTTP/1.1 200 OK") && r2.canFind("Content-Length: 2"), r2);

    // pipelined: two requests in one write, answered in order, the second only after the stream ended
    tx(fd, "GET /chunks HTTP/1.1\r\nHost: t\r\n\r\nGET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r3 = readUntil(fd, (string a) => a.endsWith("ok"));
    auto firstEnd = r3.indexOf("0\r\n\r\n");
    assert(firstEnd > 0 && r3.indexOf("HTTP/1.1 200 OK", firstEnd) > firstEnd, r3);

    // pipelined the other way round: the held-back response to /fast goes out before the stream's first event
    tx(fd, "GET /fast HTTP/1.1\r\nHost: t\r\n\r\nGET /events HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r4 = readUntil(fd, (string a) => a.canFind("data: first"));
    assert(r4.startsWith("HTTP/1.1 200 OK") && r4.indexOf("\r\n\r\nok") > 0
        && r4.indexOf("text/event-stream") > r4.indexOf("\r\n\r\nok"), r4);
    readUntil(fd, (string a) => a.endsWith("0\r\n\r\n")); // the rest of the stream, before the connection closes
    ok("chunked framing is byte-exact, keep-alive and pipelining work behind a stream and before one");
}

void testHeadAndHttp10()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    // HEAD: the head only, and the connection is still usable
    auto fd = dial(s.port);
    tx(fd, "HEAD /chunks HTTP/1.1\r\nHost: t\r\n\r\nGET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = readUntil(fd, (string a) => a.endsWith("ok"));
    assert(r.startsWith("HTTP/1.1 200 OK") && r.indexOf("hello") < 0, r);
    close(fd);

    // HTTP/1.0 cannot be sent chunks: no Transfer-Encoding, Connection: close, the body ends with the connection
    fd = dial(s.port);
    tx(fd, "GET /chunks HTTP/1.0\r\n\r\n");
    r = readAll(fd);
    close(fd);
    assert(r.startsWith("HTTP/1.1 200 OK") && !r.canFind("Transfer-Encoding") && r.canFind("Connection: close"), r);
    assert(r.endsWith("\r\n\r\nhello world"), r);
    ok("HEAD returns the head only; HTTP/1.0 gets a close-delimited body");
}

void testEarlyDelivery()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto fd = dial(s.port);
    scope (exit) close(fd);
    immutable t0 = MonoTime.currTime;
    tx(fd, "GET /events HTTP/1.1\r\nHost: t\r\n\r\n");
    auto first = readUntil(fd, (string a) => a.canFind("data: first\n\n"));
    immutable firstMs = (MonoTime.currTime - t0).total!"msecs";
    assert(first.canFind("Content-Type: text/event-stream") && first.canFind("Cache-Control: no-cache"), first);
    assert(!first.canFind("second"), "the second event is written 400 ms later");
    assert(firstMs < 300, "the first event must arrive before the handler finishes (" ~ firstMs.to!string ~ " ms)");
    auto rest = readUntil(fd, (string a) => a.endsWith("0\r\n\r\n"));
    assert(rest.canFind("data: second\n\n"));
    ok("an event reaches the client when it is flushed, not when the handler returns");
}

void testSlowReader()
{
    ServerConfig cfg;
    cfg.writeTimeoutMs = 5000;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto fd = dial(s.port, 20_000);
    scope (exit) close(fd);
    int rcv = 64 << 10;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, rcv.sizeof);
    immutable before = rssKb();
    tx(fd, "GET /big/40 HTTP/1.1\r\nHost: t\r\n\r\n");
    // read slowly: 40 MiB, with the server blocked on the socket most of the time
    size_t total, peak;
    char[32768] buf;
    long lastPause = 0;
    string tail;
    for (;;)
    {
        auto n = rd(fd, buf.ptr, buf.length);
        if (n <= 0)
            break;
        total += n;
        tail = (tail ~ buf[0 .. n].idup);
        if (tail.length > 16)
            tail = tail[$ - 16 .. $];
        if (total / (4 << 20) > lastPause)
        {
            lastPause = total / (4 << 20);
            Thread.sleep(25.msecs);
            immutable now = rssKb();
            if (now > peak)
                peak = now;
        }
        if (tail.endsWith("0\r\n\r\n"))
            break;
    }
    assert(total > 40 << 20, "the whole 40 MiB arrives");
    assert(peak < before + 12_000, "memory must stay bounded while a slow reader drains 40 MiB (before "
        ~ before.to!string ~ " KiB, peak " ~ peak.to!string ~ " KiB)");
    ok("40 MiB streamed to a slow reader: memory bounded by the high-water mark, not by the size");
}

/// A 50 MiB file to a slow reader: streamed in pieces with its Content-Length; memory stays bounded.
void testBigFile()
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write, exists;
    import std.path : buildPath;
    import core.sys.posix.unistd : getpid;

    auto dir = buildPath(tempDir, "vela_stream_net_" ~ getpid().to!string);
    if (exists(dir))
        rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    {
        auto data = new ubyte[1 << 20];
        foreach (i, ref b; data)
            b = cast(ubyte)(i * 31);
        import std.stdio : File;
        auto f = File(buildPath(dir, "big.bin"), "wb");
        foreach (_; 0 .. 50)
            f.rawWrite(data);
    }
    staticDir = dir;
    scope (exit) staticDir = null;
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto fd = dial(s.port, 20_000);
    scope (exit) close(fd);
    int rcv = 64 << 10;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, rcv.sizeof);
    immutable before = rssKb();
    tx(fd, "GET /files/big.bin HTTP/1.1\r\nHost: t\r\n\r\n");
    // the head first: Content-Length of the file, no chunking
    auto head = readUntil(fd, (string a) => a.canFind("\r\n\r\n"));
    auto he = head.indexOf("\r\n\r\n") + 4;
    assert(head.canFind("Content-Length: 52428800") && !head.canFind("Transfer-Encoding"), head);
    size_t total = head.length - he, peak, mark;
    char[32768] buf;
    while (total < 50 << 20)
    {
        auto n = rd(fd, buf.ptr, buf.length);
        assert(n > 0, "the connection ended early at " ~ total.to!string);
        total += n;
        if (total / (5 << 20) > mark)
        {
            mark = total / (5 << 20);
            Thread.sleep(20.msecs);
            immutable now = rssKb();
            if (now > peak)
                peak = now;
        }
    }
    assert(total == 50 << 20);
    assert(peak < before + 12_000, "a 50 MiB download must not grow memory (before " ~ before.to!string ~ " KiB, peak "
        ~ peak.to!string ~ " KiB)");
    ok("50 MiB static file streamed to a slow reader: Content-Length announced, memory bounded");
}

void testClientGoesAway()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    atomicOp!"-="(cleanups, atomicLoad(cleanups));
    atomicOp!"-="(started, atomicLoad(started));
    auto fd = dial(s.port);
    tx(fd, "GET /forever HTTP/1.1\r\nHost: t\r\n\r\n");
    readUntil(fd, (string a) => a.canFind("tick\n"));
    close(fd); // vanishes mid-stream
    assert(waitFor(() => atomicLoad(cleanups) == 1, 2000), "the handler must be cancelled and its scope(exit) must run");
    assert(waitFor(() => s.loop.stats().inFlight == 0 && s.loop.stats().connections == 0, 1000));
    ok("a client that disconnects mid-stream cancels the handler (RequestCancelled), scope(exit) runs");
}

void testReaderStopsReading()
{
    ServerConfig cfg;
    cfg.writeTimeoutMs = 400;
    auto s = start(cfg);
    scope (exit) stop(s);
    auto fd = dial(s.port, 10_000);
    scope (exit) close(fd);
    int rcv = 4096;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, rcv.sizeof);
    tx(fd, "GET /big/200 HTTP/1.1\r\nHost: t\r\n\r\n");
    // ... and never read
    assert(waitFor(() => s.loop.stats().inFlight == 1, 2000), "the request must start first");
    assert(waitFor(() => s.loop.stats().inFlight == 0 && s.loop.stats().connections == 0, 4000),
        "a reader that stops reading is dropped after writeTimeoutMs");
    assert(s.loop.stats().cancelled >= 1);
    ok("a reader that stops reading is closed after writeTimeoutMs");
}

void testFailureAfterHead()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto fd = dial(s.port);
    scope (exit) close(fd);
    tx(fd, "GET /fail HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = readAll(fd); // reads until the server closes
    assert(r.startsWith("HTTP/1.1 200 OK"), r);
    assert(r.canFind("3\r\nabc\r\n"), r);
    assert(!r.canFind("0\r\n\r\n"), "no terminating chunk: the client must see a truncated body");
    ok("a failure after the head cuts the response off: chunked body without its last chunk");
}

void testStopWithOpenStream()
{
    ServerConfig cfg;
    cfg.shutdownGraceMs = 300;
    auto s = start(cfg);
    atomicOp!"-="(cleanups, atomicLoad(cleanups));
    auto fd = dial(s.port);
    scope (exit) close(fd);
    tx(fd, "GET /forever HTTP/1.1\r\nHost: t\r\n\r\n");
    readUntil(fd, (string a) => a.canFind("tick\n"));
    immutable t0 = MonoTime.currTime;
    stop(s); // joins: must not wait for a stream that never ends
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms < 1500, "stop must give up on open streams after the grace period (" ~ ms.to!string ~ " ms)");
    assert(atomicLoad(cleanups) == 1, "the open stream's handler is cancelled and unwinds");
    ok("graceful stop does not wait forever for an open stream: cancelled after shutdownGraceMs");
}

void main()
{
    testFraming();
    testHeadAndHttp10();
    testEarlyDelivery();
    testSlowReader();
    testBigFile();
    testClientGoesAway();
    testReaderStopsReading();
    testFailureAfterHead();
    testStopWithOpenStream();
    printf("all HTTP/1.1 streaming tests passed\n");
}
