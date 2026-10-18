/// Network tests of EpollLoop: starts the server on a thread and speaks raw
/// HTTP over blocking sockets. Covers what M2 promises: a fiber per
/// request, cancellation, the in-flight ceiling, deadlines, partial writes,
/// pool shrinking and graceful stop.
module epoll_net 2025;

version (linux):

import andaime;
import andaime.engine;
import andaime.server : handlerFactory;

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

string myIp(ClientIp ip) => ip.toString;

string echoBody(Context c) => (cast(const(char)[]) c.request.body).idup;

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

// Slices kept past the request, to prove they are memory-safe (see testKeptSlices). __gshared: the handler runs on the
// server thread and the test reads them afterwards.
__gshared const(char)[][] keptPath, keptHeaderA, keptBody, keptResponse;
__gshared string[] keptHeaderB;

void keep(const(char)[] path, const(char)[] a, string b, const(char)[] body_) @trusted
{
    keptPath ~= path;      // a const(char)[] path parameter: a zero-copy view
    keptHeaderA ~= a;      // ctx.request.header(...): a zero-copy view
    keptHeaderB ~= b;      // Header!"X-B": a copy
    keptBody ~= body_;     // the raw body: a zero-copy view (the 200 KiB ones are above the pool's classes)
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
    return a[i] > 0 ? "positive" : "zero"; // i >= 3: a RangeError (an Error, not an Exception), thrown from @safe code
}

string boomException() { throw new Exception("plain exception"); }

Response owned()
{
    return Response(200, "text/plain", "hello", [HeaderField("Content-Length", "999"),
        HeaderField("Connection", "upgrade"), HeaderField("Set-Cookie", "a=1"), HeaderField("Set-Cookie", "b=2")]);
}

Response splitting(string to) => Response.redirect(to);

App buildApp()
{
    auto app = new App;
    app.use((Context c, Next n) {
        n();
        if (c.request.path.length >= 5 && c.request.path[0 .. 5] == "/keep")
            keepResponse(c.response.body.data); // a view of the response buffer, kept after the handler returned
    });
    app.post!("/keep/{tag}", keepAll);
    app.get!("/oob/{i}", oob);
    app.get!("/boom", boomException);
    app.get!("/owned", owned);
    app.get!("/redirect", splitting);
    app.get!("/fast", fast);
    app.get!("/ip", myIp);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/stuck", stuck);
    app.get!("/big", big);
    app.get!("/block", block);
    app.get!("/off/{ms}", off);
    app.post!("/len", bodyLen);
    app.post!("/echo", echoBody);
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
    r = request(s.port, "/ip");
    assert(r.status == 200 && r.body == "127.0.0.1", "the client's address: " ~ r.body);
    ok("simple GET and 404; the peer address is visible to handlers");
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

/// The responses to pipelined requests are held back and sent together (EpollLoop.coalesce).
void testCoalescedPipelining()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    enum fastReq = "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n";

    // a batch: every response arrives, in order, the last one with a body read from the batch
    auto c = dial(s.port);
    string batch;
    foreach (_; 0 .. 50)
        batch ~= fastReq;
    batch ~= "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n\r\nlast";
    c.tx(batch);
    foreach (_; 0 .. 50)
    {
        auto r = c.rx();
        assert(r.status == 200 && r.body == "ok", r.head);
    }
    assert(c.rx().body == "last");
    c.hang();

    // a held-back response does not wait for a request behind it that suspends
    c = dial(s.port);
    immutable t0 = MonoTime.currTime;
    c.tx(fastReq ~ "GET /nap/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(c.rx().body == "ok");
    assert(MonoTime.currTime - t0 < 200.msecs, "a held-back response waited for the next request");
    assert(c.rx().body == "slept");
    c.hang();

    // a malformed request behind good ones: their responses arrive first, then the 400, then the close
    c = dial(s.port);
    c.tx(fastReq ~ fastReq ~ "BROKEN\r\n\r\n");
    assert(c.rx().body == "ok");
    assert(c.rx().body == "ok");
    auto r = c.rx();
    assert(r.status == 400 && r.closed, r.head);
    assert(c.rx().status == 0);
    c.hang();

    // the client half-closes right after its batch: every response arrives before the server closes
    c = dial(s.port);
    c.tx(fastReq ~ fastReq ~ fastReq);
    shutdown(c.fd, SHUT_WR);
    foreach (_; 0 .. 3)
        assert(c.rx().body == "ok");
    assert(c.rx().status == 0);
    c.hang();
    // ... also when the batch ends with an incomplete request (the server sees EOF in the middle of a head)
    c = dial(s.port);
    c.tx(fastReq ~ fastReq ~ "GET /fa");
    shutdown(c.fd, SHUT_WR);
    foreach (_; 0 .. 2)
        assert(c.rx().body == "ok");
    assert(c.rx().status == 0);
    c.hang();

    // Expect: 100-continue behind a held-back response: the response first, then the 100
    c = dial(s.port);
    c.tx(fastReq ~ "POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n");
    assert(c.rx().body == "ok");
    assert(c.rx().status == 100);
    c.tx("hello");
    assert(c.rx().body == "5");
    c.hang();

    // held-back responses ahead of a large one, to a client that is slow to read: all of it, in order
    c = dial(s.port, 10_000);
    batch = null;
    foreach (_; 0 .. 20)
        batch ~= fastReq;
    batch ~= "GET /big HTTP/1.1\r\nHost: t\r\n\r\n" ~ fastReq;
    c.tx(batch);
    Thread.sleep(200.msecs);
    foreach (_; 0 .. 20)
        assert(c.rx().body == "ok");
    r = c.rx();
    assert(r.status == 200 && r.body.length == (8 << 20), r.head);
    assert(c.rx().body == "ok");
    c.hang();
    ok("pipelined responses sent together: order, a suspended request, errors, half-close, 100-continue, a large body");
}

void testResponseHeaders()
{
    import std.algorithm : canFind, count;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    // andaime owns Content-Length and Connection; two Set-Cookie both reach the wire; no stray bytes follow the body
    auto c = dial(s.port);
    c.tx("GET /owned HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = c.rx();
    assert(r.status == 200 && r.body == "hello", r.head);
    assert(r.head.canFind("Content-Length: 5\r\n") && !r.head.canFind("999"), r.head);
    assert(!r.head.canFind("upgrade") && !r.head.canFind("Connection:"), r.head);
    assert(r.head.count("Set-Cookie: ") == 2, r.head);
    assert(r.head.canFind("Date: "), r.head);
    c.hang();
    // response splitting: the injected header never appears, the client gets a plain 500
    c = dial(s.port);
    c.tx("GET /redirect?to=/x%0d%0aSet-Cookie:%20pwned=1 HTTP/1.1\r\nHost: t\r\n\r\n");
    r = c.rx();
    assert(r.status == 500 && !r.head.canFind("pwned") && !r.head.canFind("Location"), r.head);
    c.hang();
    ok("response headers: andaime-owned ones dropped, duplicates kept, CR/LF injection answered with 500");
}

/// Request data handed to user code lives in GC memory: whatever a handler or middleware keeps after the request is
/// still readable (never freed or unmapped), and `Header!"X"` is a copy that keeps its content.
void testKeptSlices()
{
    import std.conv : to;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    keptPath = keptHeaderA = keptBody = keptResponse = null;
    keptHeaderB = null;
    enum connections = 20, perConnection = 100; // 2,000 requests
    size_t[] sentBodyLen;
    string[] sentB;
    foreach (ci; 0 .. connections)
    {
        auto c = dial(s.port);
        foreach (ri; 0 .. perConnection)
        {
            immutable n = ci * perConnection + ri;
            // a few 200 KiB bodies (above the 64 KiB pool classes), the rest small
            immutable len = (n % 67 == 0) ? 200 * 1024 : 50 + n % 300;
            auto body_ = new char[len];
            body_[] = cast(char)('a' + n % 26);
            immutable b = "b-" ~ n.to!string;
            c.tx("POST /keep/t" ~ n.to!string ~ " HTTP/1.1\r\nHost: t\r\nX-A: a-" ~ n.to!string ~ "\r\nX-B: " ~ b
                ~ "\r\nContent-Length: " ~ len.to!string ~ "\r\n\r\n" ~ body_.idup);
            auto r = c.rx();
            assert(r.status == 200 && r.body == "kept t" ~ n.to!string, r.head);
            sentBodyLen ~= len;
            sentB ~= b;
        }
        c.hang();
    }
    // every kept slice is still readable: touch each byte; nothing crashed, nothing changed length
    assert(keptPath.length == 2000 && keptHeaderA.length == 2000 && keptBody.length == 2000 && keptResponse.length == 2000);
    size_t sum;
    foreach (k; 0 .. 2000)
    {
        foreach (ch; keptPath[k]) sum += ch;
        foreach (ch; keptHeaderA[k]) sum += ch;
        foreach (ch; keptBody[k]) sum += ch;
        foreach (ch; keptResponse[k]) sum += ch;
        assert(keptBody[k].length == sentBodyLen[k], "a kept body slice must keep its length");
        assert(keptHeaderB[k] == sentB[k], "Header!\"X-B\" is a copy: it must still equal what was sent");
    }
    assert(sum > 0);
    ok("kept views are memory-safe (2,000 keep-alive requests, 200 KiB bodies included); Header!\"X\" keeps its content");
}

/// Runs `work` with stderr redirected to a file and returns what was written.
string captureStderr(scope void delegate() work)
{
    import core.sys.posix.unistd : dup, dup2;
    import core.stdc.stdio : tmpfile, fileno, rewind, fread, fflush, stderr;

    auto f = tmpfile();
    fflush(stderr);
    immutable saved = dup(2);
    dup2(fileno(f), 2);
    work();
    fflush(stderr);
    dup2(saved, 2);
    close(saved);
    rewind(f);
    char[] text;
    char[4096] tmp;
    for (;;)
    {
        auto n = fread(tmp.ptr, 1, tmp.length, f);
        if (n == 0)
            break;
        text ~= tmp[0 .. n];
    }
    return text.idup;
}

void testHandlerErrors()
{
    import std.algorithm : canFind, count;

    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    // an Error inside @safe code: 500, the connection is closed, the fiber is thrown away, the server carries on
    string log;
    Resp r;
    log = captureStderr({
        auto c = dial(s.port);
        c.tx("GET /oob/10 HTTP/1.1\r\nHost: t\r\n\r\n");
        r = c.rx();
        c.hang();
    });
    assert(r.status == 500 && r.closed, r.head);
    assert(log.canFind("unhandled core.exception.") && log.canFind("out of bounds") && log.canFind("epoll_net.d("), log); // type, message, file:line
    assert(log.canFind("GET /oob/10"), log);
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000));
    auto st = s.loop.stats();
    assert(st.handlerErrors == 1 && st.fibersPoisoned == 1, "the poisoned fiber must not go back to the pool");
    assert(st.idleWorkers == 0);
    // the next request runs on a new fiber
    auto c = dial(s.port);
    c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    r = c.rx();
    assert(r.status == 200 && r.body == "ok");
    c.hang();
    assert(waitFor(() => s.loop.stats().workersCreated == 2, 1000));

    // an ordinary Exception is caught by the app (500 with the app's own logging), and its fiber is reused
    log = captureStderr({ r = request(s.port, "/boom"); });
    assert(r.status == 500 && log.canFind("plain exception"), log);
    assert(s.loop.stats().fibersPoisoned == 1);

    // a burst of failures: at most 5 full traces in the second, then a summary line
    log = captureStderr({
        Client[50] cs;
        foreach (ref cl; cs)
        {
            cl = dial(s.port);
            cl.tx("GET /oob/9 HTTP/1.1\r\nHost: t\r\n\r\n");
        }
        foreach (ref cl; cs)
        {
            assert(cl.rx().status == 500);
            cl.hang();
        }
        Thread.sleep(1500.msecs); // the sweep reports what was suppressed
    });
    assert(log.count("unhandled core.exception.") <= 5, "traces are limited per second");
    assert(log.canFind("more handler failures in the last second (traces suppressed)"), log);
    assert(s.loop.stats().handlerErrors == 51 && s.loop.stats().fibersPoisoned == 51);
    ok("an Error in a handler: 500 and close, full trace logged (rate-limited), the fiber is retired, the server keeps serving");
}

string chunkify(string data, size_t piece)
{
    import std.conv : to;
    import std.format : format;

    string r;
    for (size_t i = 0; i < data.length; i += piece)
    {
        auto p = data[i .. (i + piece < data.length ? i + piece : data.length)];
        r ~= format("%x\r\n", p.length) ~ p ~ "\r\n";
    }
    return r ~ "0\r\n\r\n";
}

void testChunkedUploads()
{
    import std.algorithm : canFind;

    ServerConfig cfg;
    cfg.limits.maxBodyBytes = 1 << 20;
    cfg.headerTimeoutMs = 400;
    auto s = start(cfg);
    scope (exit) stop(s);
    enum head = "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n";

    // basic: the body is the concatenation of the chunks; extensions and trailers are accepted and dropped
    auto c = dial(s.port);
    c.tx(head ~ "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: v\r\n\r\n");
    auto r = c.rx();
    assert(r.status == 200 && r.body == "hello world", r.head ~ r.body);

    // keep-alive and a pipelined request right behind the body, in one write
    c.tx(head ~ chunkify("abc", 1) ~ "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    r = c.rx();
    assert(r.status == 200 && r.body == "abc", r.body);
    r = c.rx();
    assert(r.status == 200 && r.body == "ok", "the request after a chunked body must be served: " ~ r.head);

    // byte by byte
    auto raw = head ~ chunkify("slow and steady", 4);
    foreach (ch; raw)
    {
        c.tx([ch].idup);
    }
    r = c.rx();
    assert(r.status == 200 && r.body == "slow and steady", r.body);

    // a big upload (above the pool classes) in 16 KiB chunks
    auto big = new char[700_000];
    foreach (i, ref x; big)
        x = cast(char)('a' + i % 23);
    immutable t0 = MonoTime.currTime;
    c.tx(head ~ chunkify(big.idup, 16 << 10));
    r = c.rx();
    assert(r.status == 200 && r.body == big.idup, "a 700 KB chunked body arrives intact");
    // the buffer grows geometrically (it once grew by one byte per read, copying the body each time: minutes)
    assert(MonoTime.currTime - t0 < 3.seconds, "a 700 KB chunked upload took too long");
    c.hang();

    // Expect: 100-continue is answered before the chunks are sent
    c = dial(s.port);
    c.tx("POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n");
    r = c.rx();
    assert(r.status == 100, r.head);
    c.tx(chunkify("go", 2));
    r = c.rx();
    assert(r.status == 200 && r.body == "go");
    c.hang();

    // slow chunks keep the request alive: 8 chunks, 120 ms apart (960 ms) with a 400 ms limit that counts without progress
    c = dial(s.port);
    c.tx(head);
    foreach (i; 0 .. 8)
    {
        c.tx("1\r\nx\r\n");
        Thread.sleep(120.msecs);
    }
    c.tx("0\r\n\r\n");
    r = c.rx();
    assert(r.status == 200 && r.body == "xxxxxxxx", "progress must extend the deadline: " ~ r.head);
    c.hang();

    // ... but a stall does not
    c = dial(s.port);
    c.tx(head ~ "5\r\nhel");
    r = c.rx(); // no progress for 400 ms: 408
    assert(r.status == 408, r.head);
    c.hang();

    // too big: refused as soon as a chunk announces more than the limit allows
    c = dial(s.port);
    c.tx(head ~ "200000\r\n");
    r = c.rx();
    assert(r.status == 413 && r.closed, r.head);
    c.hang();
    c = dial(s.port);
    c.tx(head ~ chunkify(new char[2 << 20].idup, 64 << 10));
    r = c.rx();
    assert(r.status == 413, r.head);
    c.hang();

    // malformed framing: 400 and the connection is closed
    foreach (bad; ["zz\r\nhi\r\n0\r\n\r\n", "5\r\nhelloXX0\r\n\r\n", "5\nhello\r\n0\r\n\r\n", "-1\r\n"])
    {
        c = dial(s.port);
        c.tx(head ~ bad);
        r = c.rx();
        assert(r.status == 400 && r.closed, bad ~ " -> " ~ r.head);
        c.hang();
    }

    // anything but plain `chunked` is refused before the body
    foreach (te; ["gzip, chunked", "chunked, identity", "identity"])
    {
        c = dial(s.port);
        c.tx("POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: " ~ te ~ "\r\n\r\n");
        r = c.rx();
        assert(r.status == 501, te ~ " -> " ~ r.head);
        c.hang();
    }
    ok("chunked request bodies: decoded in place, pipelining, 100-continue, progress deadline, limits, malformed framing");
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
        Case("POST /x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", 501), // chunked itself is supported now
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

void testErrorBodies()
{
    import std.algorithm : canFind;

    ServerConfig cfg;
    cfg.errorBodies = jsonErrorBodies() ~ [ErrorBody(413, "too big", "text/plain")]; // the first entry for a status wins
    cfg.maxInFlight = 1;
    auto s = start(cfg);
    scope (exit) stop(s);

    auto c = dial(s.port);
    c.tx("GET /x HTTP/1.1\r\nA: b\r\n c\r\n\r\n");
    auto r = c.rx();
    assert(r.status == 400 && r.body == `{"detail":"bad request"}` && r.head.canFind("Content-Type: application/json")
        && r.head.canFind("Content-Length: 24"), r.head);
    c.hang();
    c = dial(s.port);
    c.tx("POST /fast HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n");
    r = c.rx();
    assert(r.status == 413 && r.body == `{"detail":"request body too large"}`, r.body);
    c.hang();
    c = dial(s.port);
    c.tx("GET / HTTP/2.0\r\nHost: t\r\n\r\n");
    assert(c.rx().body == `{"detail":"http version not supported"}`);
    c.hang();

    // the in-flight ceiling keeps its Retry-After
    auto slow = dial(s.port);
    slow.tx("GET /nap/400 HTTP/1.1\r\nHost: t\r\n\r\n");
    Thread.sleep(50.msecs);
    c = dial(s.port);
    c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    r = c.rx();
    assert(r.status == 503 && r.body == `{"detail":"service unavailable"}` && r.head.canFind("Retry-After: 1"), r.head);
    c.hang();
    slow.hang();

    // without entries the answers keep no body
    auto plain = start(ServerConfig.init);
    scope (exit) stop(plain);
    c = dial(plain.port);
    c.tx("GET /x HTTP/1.1\r\nA: b\r\n c\r\n\r\n");
    r = c.rx();
    assert(r.status == 400 && r.body.length == 0 && r.head.canFind("Content-Length: 0"), r.head);
    c.hang();
    ok("errorBodies: the engine's own 400, 413, 505 and 503 carry the configured body; none by default");
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

void testLargeBodies()
{
    // bodies above the buffer pool's largest class (64 KiB) up to Limits.maxBodyBytes (1 MiB);
    // they once got a 413 from 64 KiB on
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    import std.conv : to;

    foreach (n; [60_000, 70_000, 300_000, 1 << 20])
    {
        auto c = dial(s.port);
        auto body = new char[n];
        body[] = 'b';
        c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: " ~ n.to!string ~ "\r\n\r\n" ~ body.idup);
        auto r = c.rx();
        assert(r.status == 200 && r.body == n.to!string, n.to!string ~ ": " ~ r.head);
        // the same connection serves the next request (the large buffer went back)
        c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
        assert(c.rx().body == "ok");
        c.hang();
    }
    auto c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: " ~ ((1 << 20) + 1).to!string ~ "\r\n\r\n");
    assert(c.rx().status == 413);
    c.hang();
    ok("request bodies from 60 KB to the 1 MiB limit (above the buffer classes), 413 above it");
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
    testCoalescedPipelining();
    testResponseHeaders();
    testChunkedUploads();
    testHandlerErrors();
    testKeptSlices();
    testSlowHead();
    testConcurrency();
    testCancellation();
    testRequestCeiling();
    testRequestDeadline();
    testPartialWrite();
    testPoolShrink();
    testInvalidInput();
    testErrorBodies();
    testConnectionDeadlines();
    testGracefulStop();
    testTwoWorkers();
    testDateAndDetector();
    testOffload();
    testExpectContinue();
    testLargeBodies();
    printf("all network tests passed\n");
}
