/// Network tests of EpollLoop: starts the server on a thread and speaks raw
/// HTTP over blocking sockets. Covers what M2 promises: a fiber per
/// request, cancellation, the in-flight ceiling, deadlines, partial writes,
/// pool shrinking and graceful stop.
module epoll_net;

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
import core.sys.posix.unistd : close, read, write, pipe;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

// ---------------------------------------------------------------- test app

shared int cleanups; // shared: the handler runs on the server thread
__gshared int[2] stuckPipe;

@safe:

int stuckReadFd() @trusted => stuckPipe[0]; // __gshared: created before the server starts

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

string stuck()
{
    awaitFd(stuckReadFd, IoEvent.readable); // no deadline: only the request deadline saves it
    return "never";
}

string block()
{
    import core.thread : Thread;

    Thread.sleep(120.msecs); // blocking on purpose: stalls the worker
    return "bloqueou";
}

string off(int ms)
{
    import core.thread : Thread;

    return offload(() { Thread.sleep(ms.msecs); return "off"; });
}

string bodyLen(Context c)
{
    import std.conv : to;

    return c.request.body.length.to!string;
}

string big()
{
    auto s = new char[8 << 20];
    s[] = 'x';
    return s.idup;
}

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/stuck", stuck);
    app.get!("/big", big);
    app.get!("/block", block);
    app.get!("/off/{ms}", off);
    app.post!("/len", bodyLen);
    return app;
}

// ---------------------------------------------------------------- test server

@system: // harness: raw sockets, printf, threads

struct Server
{
    EpollLoop loop;
    Thread thread;
    ushort port;
}

Server start(ServerConfig cfg, ushort port = 0, bool reusePort = false)
{
    cfg.port = port;
    cfg.workers = 1;
    cfg.host = "127.0.0.1";
    cfg.reusePort = reusePort;
    auto loop = new EpollLoop;
    auto app = buildApp();
    auto factory = handlerFactory(app);
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

// ---------------------------------------------------------------- raw client

// D's GC suspends threads with signals, which interrupts blocking read/send
// with EINTR. The server already handles it; the test client has to as well.
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

struct Client
{
    int fd = -1;
    string pending;
}

Client dial(ushort port, int rcvTimeoutMs = 5000)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0, "connect failed");
    timeval tv = timeval(rcvTimeoutMs / 1000, (rcvTimeoutMs % 1000) * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return Client(fd);
}

void tx(ref Client c, string s)
{
    while (s.length)
    {
        auto n = sd(c.fd, s.ptr, s.length);
        assert(n > 0, "send failed");
        s = s[n .. $];
    }
}

void hang(ref Client c)
{
    close(c.fd);
    c.fd = -1;
}

struct Resp
{
    int status; /// 0 = connection closed/expired without a response
    string head, body;
    bool closed;
}

Resp rx(ref Client c)
{
    import std.algorithm : canFind;
    import std.string : indexOf;
    import std.conv : to;

    Resp r;
    char[65536] tmp;
    while (c.pending.indexOf("\r\n\r\n") < 0)
    {
        auto n = rd(c.fd, tmp.ptr, tmp.length);
        if (n <= 0)
        {
            r.closed = true;
            return r;
        }
        c.pending ~= tmp[0 .. n].idup;
    }
    auto he = c.pending.indexOf("\r\n\r\n") + 4;
    r.head = c.pending[0 .. he];
    r.status = r.head[9 .. 12].to!int;
    size_t want = 0;
    auto cl = r.head.indexOf("Content-Length: ");
    if (cl >= 0)
    {
        auto e = r.head.indexOf("\r\n", cl);
        want = r.head[cl + 16 .. e].to!size_t;
    }
    while (c.pending.length < he + want)
    {
        auto n = rd(c.fd, tmp.ptr, tmp.length);
        if (n <= 0)
        {
            r.closed = true;
            return r;
        }
        c.pending ~= tmp[0 .. n].idup;
    }
    r.body = c.pending[he .. he + want];
    c.pending = c.pending[he + want .. $];
    r.closed = r.head.canFind("Connection: close");
    return r;
}

Resp request(ushort port, string path)
{
    auto c = dial(port);
    c.tx("GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = c.rx();
    c.hang();
    return r;
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

// ---------------------------------------------------------------- tests

void testBasic()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto r = request(s.port, "/fast");
    assert(r.status == 200 && r.body == "ok", r.head);
    r = request(s.port, "/does-not-exist");
    assert(r.status == 404, r.head);
    ok("simple GET and 404");
}

void testKeepAliveAndPipelining()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto c = dial(s.port);
    foreach (_; 0 .. 3)
    {
        c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
        auto r = c.rx();
        assert(r.status == 200 && !r.closed, r.head);
    }
    ok("keep-alive: 3 requests on the same connection");

    // pipelining with a handler that suspends midway: the order is kept
    c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\nGET /nap/50 HTTP/1.1\r\nHost: t\r\n\r\n"
        ~ "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(c.rx().body == "ok");
    assert(c.rx().body == "slept");
    assert(c.rx().body == "ok");
    c.hang();
    ok("pipelining with a handler suspended midway, order preserved");
}

void testSlowHead()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = dial(s.port);
    foreach (ch; "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n")
    {
        c.tx([ch].idup);
        Thread.sleep(2.msecs);
    }
    auto r = c.rx();
    assert(r.status == 200 && r.body == "ok", r.head);
    c.hang();
    ok("head arriving byte by byte");
}

void testConcurrency()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    enum N = 300;
    Client[N] cs;
    immutable t0 = MonoTime.currTime;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /nap/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    }
    foreach (ref c; cs)
    {
        auto r = c.rx();
        assert(r.status == 200 && r.body == "slept", r.head);
        c.hang();
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    auto st = s.loop.stats();
    assert(ms < 1500, "300 requests of 300 ms should take ~300 ms, took longer");
    assert(st.peakInFlight >= 250, "there should be ~300 requests in flight at the same time");
    printf("ok  %d requests of 300 ms in %ld ms on one thread (peak in flight: %zu)\n", N, ms, st.peakInFlight);
}

void testCancellation()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto c = dial(s.port);
    c.tx("GET /cancel HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000), "handler did not start");
    c.hang(); // the client goes away with the fiber suspended
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000), "fiber was not cancelled");
    assert(atomicLoad(cleanups) == 1, "the handler's scope(exit) did not run");
    assert(s.loop.stats().cancelled == 1);
    ok("client disconnects with a suspended fiber: RequestCancelled, scope(exit) runs, fiber returns to the pool");
}

void testRequestCeiling()
{
    ServerConfig cfg;
    cfg.maxInFlight = 4;
    auto s = start(cfg);
    scope (exit) stop(s);

    Client[6] cs;
    foreach (ref c; cs)
    {
        c = dial(s.port);
        c.tx("GET /nap/400 HTTP/1.1\r\nHost: t\r\n\r\n");
        Thread.sleep(2.msecs); // arrival in order
    }
    int n200, n503;
    bool retryAfter;
    foreach (ref c; cs)
    {
        auto r = c.rx();
        if (r.status == 200) n200++;
        if (r.status == 503) { n503++; retryAfter = r.head.indexOfS("Retry-After: 1"); }
        c.hang();
    }
    assert(n200 == 4 && n503 == 2, "esperava 4x200 e 2x503");
    assert(retryAfter, "503 without Retry-After");
    assert(s.loop.stats().rejected == 2);
    ok("ceiling of 4 in flight: 4x200 and 2x503 with Retry-After");
}

bool indexOfS(string h, string needle)
{
    import std.string : indexOf;

    return h.indexOf(needle) >= 0;
}

void testRequestDeadline()
{
    pipe(stuckPipe);
    fcntl(stuckPipe[0], F_SETFL, O_NONBLOCK);
    scope (exit) { close(stuckPipe[0]); close(stuckPipe[1]); }

    ServerConfig cfg;
    cfg.requestTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);

    immutable t0 = MonoTime.currTime;
    auto r = request(s.port, "/stuck");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(r.status == 504, r.head);
    assert(ms >= 250 && ms < 1500, "300 ms deadline");
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500));
    assert(s.loop.stats().timedOut == 1);
    ok("handler stuck in awaitFd with no deadline: 504 by the request deadline");
}

void testPartialWrite()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = dial(s.port, 10_000);
    c.tx("GET /big HTTP/1.1\r\nHost: t\r\n\r\n");
    Thread.sleep(300.msecs); // the client does not read: the server's send fills up and gives EAGAIN
    assert(s.loop.stats().inFlight == 1, "the large response should be pending (EPOLLOUT)");
    auto r = c.rx();
    assert(r.status == 200 && r.body.length == (8 << 20), "incomplete body");
    foreach (ch; r.body)
        assert(ch == 'x');
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500));
    ok("8 MiB response with a slow client (partial write + EPOLLOUT)");
}

void testPoolShrink()
{
    ServerConfig cfg;
    cfg.maxIdleWorkers = 8;
    auto s = start(cfg);
    scope (exit) stop(s);

    enum N = 200;
    Client[N] cs;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /nap/100 HTTP/1.1\r\nHost: t\r\n\r\n");
    }
    foreach (ref c; cs)
    {
        assert(c.rx().status == 200);
        c.hang();
    }
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000));
    auto st = s.loop.stats();
    assert(st.workersCreated >= 150, "the burst should have created ~200 fibers");
    assert(st.idleWorkers <= 8, "idle fibers above the ceiling were not torn down");
    assert(st.workersRetired >= st.workersCreated - 8);
    assert(waitFor(() => s.loop.trimCount() == 1, 3500), "the post-burst memory cleanup did not run");
    printf("ok  burst of %d: %zu fibers created, %zu torn down, %zu idle in the pool\n",
        N, st.workersCreated, st.workersRetired, st.idleWorkers);
}

void testInvalidInput()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    static struct Case { string raw; int status; }
    static immutable cases = [
        Case("FOO / HTTP/1.1\r\nHost: t\r\n\r\n", 501),
        Case("GET / HTTP/2.0\r\nHost: t\r\n\r\n", 505),
        Case("POST /x HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
        Case("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 501),
        Case("GET /x HTTP/1.1\r\nA: b\r\n c\r\n\r\n", 400),
    ];
    foreach (cs; cases)
    {
        auto c = dial(s.port);
        c.tx(cs.raw);
        auto r = c.rx();
        assert(r.status == cs.status, cs.raw);
        c.hang();
    }
    // head larger than the limit
    auto c = dial(s.port);
    string h = "GET /fast HTTP/1.1\r\nHost: t\r\nX: ";
    foreach (_; 0 .. 9000)
        h ~= 'a';
    c.tx(h ~ "\r\n\r\n");
    assert(c.rx().status == 431);
    c.hang();
    // too many headers (above the fiber's table of 32)
    c = dial(s.port);
    string many = "GET /fast HTTP/1.1\r\nHost: t\r\n";
    foreach (i; 0 .. 40)
        many ~= "X-H" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26) ~ ": v\r\n";
    c.tx(many ~ "\r\n");
    assert(c.rx().status == 431);
    c.hang();
    // body larger than the limit (Limits.maxBodyBytes)
    c = dial(s.port);
    c.tx("POST /fast HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n");
    assert(c.rx().status == 413);
    c.hang();
    ok("invalid inputs: 501, 505, 400 (smuggling and obs-fold), 431, 413");
}

void testConnectionDeadlines()
{
    ServerConfig cfg;
    cfg.headerTimeoutMs = 300;
    cfg.idleTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);

    // slowloris: starts the head and stops
    auto c = dial(s.port);
    c.tx("GET /fast HTTP/1.1\r\nHost");
    auto r = c.rx();
    assert(r.status == 408 || r.closed, "slow head should be cut off");
    c.hang();

    // idle keep-alive: connects and sends nothing
    c = dial(s.port);
    r = c.rx();
    assert(r.closed && r.status == 0, "idle connection should be closed");
    c.hang();
    assert(waitFor(() => s.loop.stats().connections == 0, 500));
    ok("deadlines: slow head (408) and idle connection closed");
}

void testGracefulStop()
{
    auto s = start(ServerConfig.init);
    auto c = dial(s.port);
    c.tx("GET /nap/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    s.loop.stop(); // requests a stop with a request in progress
    auto r = c.rx();
    assert(r.status == 200 && r.body == "slept", "the in-progress request should finish");
    char[1] b;
    assert(rd(c.fd, b.ptr, 1) == 0, "during the stop, the server closes the connection after the response");
    c.hang();
    s.thread.join();
    ok("graceful stop: finishes the in-progress request and ends the loop");
}

void testTwoWorkers()
{
    // two loops on the same port (SO_REUSEPORT), sharing the same App
    auto a = start(ServerConfig.init, 0, true);
    auto b = start(ServerConfig.init, a.port, true);
    scope (exit) { stop(a); stop(b); }
    foreach (i; 0 .. 60)
    {
        auto r = request(a.port, "/nap/20");
        assert(r.status == 200 && r.body == "slept");
    }
    ok("two workers with SO_REUSEPORT on the same port");
}

void testDateAndDetector()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto r = request(s.port, "/fast");
    import std.string : indexOf;

    auto d = r.head.indexOf("Date: ");
    assert(d >= 0, "response without a Date header");
    auto line = r.head[d + 6 .. d + 6 + 29];
    assert(line[$ - 4 .. $] == " GMT" && line[3] == ',' && line[7] == ' ', line);

    // waiting with sleep does NOT stall the worker; Thread.sleep does
    assert(request(s.port, "/nap/200").status == 200);
    assert(s.loop.stats().stalls == 0, "cooperative sleep was treated as a stall");
    assert(request(s.port, "/block").status == 200);
    auto st = s.loop.stats();
    assert(st.stalls == 1 && st.maxStallMs >= 100, "the blocking handler should be detected");
    ok("Date header present; stall detector counts only the handler that blocks");
}

void testExpectContinue()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    // the client sends only the head and waits for the 100 before sending the body
    auto c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n");
    auto r = c.rx();
    assert(r.status == 100, r.head);
    c.tx("hello");
    r = c.rx();
    assert(r.status == 200 && r.body == "5", r.head);

    // the same connection (keep-alive) serves another request with Expect
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n");
    assert(c.rx().status == 100);
    c.tx("abc");
    r = c.rx();
    assert(r.status == 200 && r.body == "3");

    // body already together with the head: no 100 needed
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\nhi");
    r = c.rx();
    assert(r.status == 200 && r.body == "2", r.head);
    c.hang();

    // other expectations: 417; body too large: 413 without promising 100
    c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nExpect: algo-estranho\r\n\r\n");
    assert(c.rx().status == 417);
    c.hang();
    c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 99999999\r\nExpect: 100-continue\r\n\r\n");
    assert(c.rx().status == 413);
    c.hang();
    ok("Expect: 100-continue: go-ahead before the body, 417 for other expectations, 413 without 100");
}

void testOffload()
{
    // pool configured in main: 2 threads, queue of 2
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    Client[4] cs;
    immutable t0 = MonoTime.currTime;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /off/200 HTTP/1.1\r\nHost: t\r\n\r\n");
        Thread.sleep(20.msecs); // gives a pool thread time to take the task off the queue
    }
    assert(waitFor(() => s.loop.stats().inFlight == 4, 1000));

    // with the whole pool busy, the worker stays free
    immutable t1 = MonoTime.currTime;
    auto f = request(s.port, "/fast");
    assert(f.status == 200 && (MonoTime.currTime - t1).total!"msecs" < 50, "the worker got stuck on offload");

    // 5th task: 2 running + 2 in the queue = full
    auto sat = request(s.port, "/off/200");
    assert(sat.status == 500, sat.head);

    foreach (ref c; cs)
    {
        auto r = c.rx();
        assert(r.status == 200 && r.body == "off", r.head);
        c.hang();
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 380 && ms < 900, "4 tasks of 200 ms on 2 threads should take ~400 ms");
    ok("offload: pool of 2 threads, queue of 2, worker free during the work, saturation becomes an error");

    // client goes away while the work runs: the fiber is cancelled at once, the work finishes by itself
    auto c = dial(s.port);
    c.tx("GET /off/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 200), "fiber should be cancelled without waiting for the work");
    Thread.sleep(400.msecs); // the job finishes and closes the eventfd without breaking anything
    auto again = request(s.port, "/off/10");
    assert(again.status == 200, again.head);
    ok("offload: cancellation releases the fiber and the work finishes by itself");
}

void main()
{
    configureOffload(2, 2);
    testBasic();
    testKeepAliveAndPipelining();
    testSlowHead();
    testConcurrency();
    testCancellation();
    testRequestCeiling();
    testRequestDeadline();
    testPartialWrite();
    testPoolShrink();
    testInvalidInput();
    testConnectionDeadlines();
    testGracefulStop();
    testTwoWorkers();
    testDateAndDetector();
    testOffload();
    testExpectContinue();
    printf("all network tests passed\n");
}
