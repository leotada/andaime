/// Tests of the outgoing HTTP client against a Python upstream (tests/net/upstream.py).
/// Variables: ANDAIME_UP_PLAIN, ANDAIME_UP_TLS (ports) and ANDAIME_UP_CERT (the upstream's certificate).
module client_net 2025;

version (linux):

import andaime;
import andaime.engine;
import andaime.server : handlerFactory;

import core.atomic : atomicLoad;
import core.stdc.stdio : printf, fflush, stdout;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import core.thread : Thread;
import core.time;

__gshared string plainBase, tlsBase, certFile;

string plainBase_() @trusted => plainBase; // __gshared: written once before the workers start
string tlsBase_() @trusted => tlsBase;
string certFile_() @trusted => certFile;

@safe:

HttpClient cli()
{
    static HttpClient c; // per worker (thread-local)
    if (c is null)
    {
        HttpClientConfig cfg;
        cfg.timeout = 2.seconds;
        cfg.caFile = certFile_;
        c = httpClient(cfg);
    }
    return c;
}

string hello() => cli().get(plainBase_ ~ "/hello").body;
string chunked() => cli().get(plainBase_ ~ "/chunked").body;
string untilClose() => cli().get(plainBase_ ~ "/close").body;
string stale() => cli().get(plainBase_ ~ "/stale").body;
string viaTls() => cli().get(tlsBase_ ~ "/hello").body;

string tlsUntrusted()
{
    HttpClientConfig cfg; // no caFile: the self-signed certificate must be refused
    cfg.timeout = 2.seconds;
    auto c = new HttpClient(cfg);
    try
        return "accepted " ~ c.get(tlsBase_ ~ "/hello").body;
    catch (HttpClientError e)
        return "refused";
}

string post()
{
    auto r = cli().postJson(plainBase_ ~ "/echo", `{"a":1}`);
    return r.body;
}

/// Binary bodies (bytes that are not text, a NUL included) and a null body, through POST, PUT and request.
string binary()
{
    immutable(ubyte)[] bytes = [0, 1, 0x80, 0xff, '\r', '\n', 0];
    auto oct = [HeaderPair("Content-Type", "application/octet-stream")];
    auto expected = "echo:application/octet-stream:" ~ cast(string) bytes;
    if (cli().post(plainBase_ ~ "/echo", bytes, oct).body != expected)
        return "post failed";
    if (cli().put(plainBase_ ~ "/echo", bytes, oct).body != expected)
        return "put failed";
    if (cli().request("POST", plainBase_ ~ "/echo", oct, bytes).body != expected)
        return "request failed";
    if (cli().post(plainBase_ ~ "/echo", null).body != "echo:-:")
        return "null body failed";
    return "bytes ok";
}

/// A per-request timeout overrides the configured 2 s, both ways.
string perRequestTimeout()
{
    string r;
    try
        r ~= "short:" ~ cli().get(plainBase_ ~ "/slow/1500", null, 300.msecs).body;
    catch (HttpClientTimeout)
        r ~= "short:timeout";
    try
        r ~= " long:" ~ cli().get(plainBase_ ~ "/slow/2500", null, 5.seconds).body;
    catch (HttpClientTimeout)
        r ~= " long:timeout";
    return r;
}

string slow(int ms)
{
    try
        return cli().get(plainBase_ ~ "/slow/" ~ itoa(ms)).body;
    catch (HttpClientTimeout)
        return "timeout";
}

string big()
{
    try
        return cli().get(plainBase_ ~ "/big").body;
    catch (HttpClientError e)
        return "limit";
}

string refused()
{
    try
        return cli().get("http://127.0.0.1:1/").body;
    catch (HttpClientError e)
        return "recusada";
}

string itoa(int v)
{
    char[16] t;
    size_t n = t.length;
    do { t[--n] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return t[n .. $].idup;
}

string fast() => "ok";

// ------------------------------------------------------------ streamed bodies (open, BodySource)

/// The byte at `offset` of the upstream's /stream body.
ubyte patternAt(ulong offset) => cast(ubyte)(offset % 251);

ulong allocated() @trusted
{
    import core.memory : GC;

    return GC.allocatedInCurrentThread;
}

/// Reads /stream/<n><query> with `open`, checking every byte, in pieces that straddle the upstream's 64 KiB blocks.
string download(string query, size_t n, Duration timeout = Duration.zero)
{
    import std.conv : to;

    immutable before = allocated();
    auto s = cli().open("GET", plainBase_ ~ "/stream/" ~ itoa(cast(int) n) ~ query, null, BodySource.init, timeout);
    scope (exit)
        s.close();
    auto buf = new ubyte[10_007];
    ulong got;
    size_t k;
    while ((k = s.read(buf)) > 0)
    {
        foreach (i, b; buf[0 .. k])
            if (b != patternAt(got + i))
                return "wrong byte at " ~ (got + i).to!string;
        got += k;
    }
    if (got != n)
        return "got " ~ got.to!string ~ " bytes";
    immutable spent = allocated() - before;
    if (spent > 1 << 20)
        return "allocated " ~ spent.to!string ~ " bytes";
    return s.contentLength == n ? "length" : s.contentLength == -1 ? "chunked" : "contentLength?";
}

/// 64 MiB with Content-Length, 10 MiB chunked; read to the end, the connection goes back to the pool.
string downStreams()
{
    cli().closeIdle();
    auto r = download("", 64 << 20) ~ " " ~ download("?chunked", 10 << 20);
    return cli().idleCount == 1 ? r ~ " pooled" : r ~ " not pooled";
}

/// Closed before the end: the connection is closed, not pooled, and the next request works.
string downEarly()
{
    cli().closeIdle();
    auto s = cli().open("GET", plainBase_ ~ "/stream/" ~ itoa(8 << 20));
    auto buf = new ubyte[100_000];
    s.read(buf);
    s.close();
    s.close();
    if (cli().idleCount != 0)
        return "pooled a connection with a body left";
    return cli().get(plainBase_ ~ "/hello").body;
}

/// 8 blocks 250 ms apart: ~2 s in all, more than the 1 s timeout, which `open` applies to each wait and `get` to all.
string downPaced()
{
    enum query = "?pause=250";
    auto r = download(query, 8 << 16, 1.seconds);
    try
        r ~= " get:" ~ itoa(cast(int) cli().get(plainBase_ ~ "/stream/" ~ itoa(8 << 16) ~ query, null, 1.seconds)
            .body.length);
    catch (HttpClientTimeout)
        r ~= " get:timeout";
    return r;
}

/// A BodySource of `n` pattern bytes in 64 KiB pieces; counts how many times it was written.
BodySource patternSource(ulong n, ref int writes)
{
    auto counter = &writes;
    return BodySource(n, (scope sink) {
        (*counter)++;
        auto piece = new ubyte[64 << 10];
        for (ulong off = 0; off < n; off += piece.length)
        {
            immutable m = n - off < piece.length ? cast(size_t)(n - off) : piece.length;
            foreach (i, ref b; piece[0 .. m])
                b = patternAt(off + i);
            sink(piece[0 .. m]);
        }
    });
}

string sha256Hex(ulong n)
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : SHA256;

    SHA256 h;
    auto piece = new ubyte[64 << 10];
    for (ulong off = 0; off < n; off += piece.length)
    {
        immutable m = n - off < piece.length ? cast(size_t)(n - off) : piece.length;
        foreach (i, ref b; piece[0 .. m])
            b = patternAt(off + i);
        h.put(piece[0 .. m]);
    }
    return toHexString!(LetterCase.lower)(h.finish()).idup;
}

/// 64 MiB PUT in pieces: the upstream's SHA-256 matches, and the client buffered none of it.
string upStream()
{
    import std.conv : to;

    enum ulong n = 64 << 20;
    int writes;
    immutable before = allocated();
    auto r = cli().put(plainBase_ ~ "/sink", patternSource(n, writes));
    immutable spent = allocated() - before;
    if (r.body != n.to!string ~ ":" ~ sha256Hex(n))
        return "wrong body: " ~ r.body;
    return spent < 1 << 20 ? "sha ok" : "allocated " ~ spent.to!string;
}

/// A pooled connection the upstream closed: a PUT is retried on a new one, the source written again from the start;
/// a POST is not retried (not idempotent), as with a body in memory.
string upStale()
{
    cli().closeIdle();
    cli().get(plainBase_ ~ "/stale");
    int writes;
    auto r = cli().put(plainBase_ ~ "/sink", patternSource(300_000, writes));
    if (r.body != "300000:" ~ sha256Hex(300_000))
        return "wrong body: " ~ r.body;
    cli().get(plainBase_ ~ "/stale");
    try
        cli().post(plainBase_ ~ "/sink", patternSource(300_000, writes));
    catch (HttpClientError e)
        return e.msg == "andaime.http: reused connection was already closed" ? "retried ok" : e.msg;
    return "the POST was retried";
}

/// A source that writes fewer bytes than it announced, or more: the request fails.
string upWrongLength()
{
    string r;
    foreach (written; [500, 1500])
    {
        try
        {
            cli().put(plainBase_ ~ "/sink", BodySource(1000, (scope sink) {
                auto b = new ubyte[written];
                sink(b);
            }));
            r ~= " accepted";
        }
        catch (HttpClientError e)
            r ~= " refused";
    }
    return r[1 .. $];
}

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/hello", hello);
    app.get!("/chunked", chunked);
    app.get!("/close", untilClose);
    app.get!("/stale", stale);
    app.get!("/tls", viaTls);
    app.get!("/untrusted", tlsUntrusted);
    app.get!("/post", post);
    app.get!("/slow/{ms}", slow);
    app.get!("/big", big);
    app.get!("/refused", refused);
    app.get!("/binary", binary);
    app.get!("/per-request-timeout", perRequestTimeout);
    app.get!("/down/streams", downStreams);
    app.get!("/down/early", downEarly);
    app.get!("/down/paced", downPaced);
    app.get!("/up/stream", upStream);
    app.get!("/up/stale", upStale);
    app.get!("/up/wrong-length", upWrongLength);
    return app;
}

// ------------------------------------------------------------ infrastructure

@system: // test harness: raw sockets, printf, threads

struct Server { EpollLoop loop; Thread thread; ushort port; }

Server start()
{
    ServerConfig sc;
    sc.port = 0;
    sc.workers = 1;
    sc.host = "127.0.0.1";
    sc.reusePort = false;
    auto loop = new EpollLoop;
    auto factory = handlerFactory(buildApp());
    auto t = new Thread({ loop.run(sc, factory); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(loop.ready))
            return Server(loop, t, loop.boundPort);
        Thread.sleep(5.msecs);
    }
    assert(0, "server did not become ready");
}

void stop(ref Server s) { s.loop.stop(); s.thread.join(); }

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

int dial(ushort port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0);
    timeval tv = timeval(10, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

void sendReq(int fd, string path)
{
    import core.sys.posix.sys.socket : send;
    auto s = "GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n";
    send(fd, s.ptr, s.length, 0x4000);
}

struct Resp { int status; string body; }

Resp recvResp(int fd)
{
    import std.string : indexOf;
    import std.conv : to;
    string all;
    char[4096] tmp;
    for (;;)
    {
        auto n = rd(fd, tmp.ptr, tmp.length);
        if (n <= 0)
            break;
        all ~= tmp[0 .. n].idup;
    }
    close(fd);
    Resp r;
    if (all.length < 12)
        return r;
    r.status = all[9 .. 12].to!int;
    auto i = all.indexOf("\r\n\r\n");
    r.body = i < 0 ? "" : all[i + 4 .. $];
    return r;
}

Resp fetch(ushort port, string path)
{
    auto fd = dial(port);
    sendReq(fd, path);
    return recvResp(fd);
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 10)
    {
        if (cond())
            return true;
        Thread.sleep(10.msecs);
    }
    return cond();
}

void ok(string name) { printf("ok  %.*s\n", cast(int) name.length, name.ptr); fflush(stdout); }

string env(const(char)* name)
{
    auto p = getenv(name);
    return p is null ? null : p[0 .. strlen(p)].idup;
}

// ------------------------------------------------------------ tests

void testBasic()
{
    auto s = start();
    scope (exit) stop(s);
    assert(fetch(s.port, "/hello").body == "hello");
    assert(fetch(s.port, "/chunked").body == "abc" ~ "defgh" ~ ("i".replicate(300)));
    assert(fetch(s.port, "/close").body == "until-close");
    assert(fetch(s.port, "/post").body == `echo:application/json:{"a":1}`);
    assert(fetch(s.port, "/refused").body == "recusada");
    ok("GET, chunked body, until-close body, JSON POST, connection refused");
}

void testTls()
{
    auto s = start();
    scope (exit) stop(s);
    auto r = fetch(s.port, "/tls");
    assert(r.status == 200 && r.body == "hello", r.body);
    r = fetch(s.port, "/untrusted");
    assert(r.body == "refused", r.body);
    ok("HTTPS with a verified certificate; a self-signed certificate without a CA is refused");
}

void testKeepAliveAndStale()
{
    auto s = start();
    scope (exit) stop(s);
    auto before = fetch(s.port, "/hello"); // opens the connection
    foreach (_; 0 .. 20)
        assert(fetch(s.port, "/hello").body == "hello");
    // the upstream counts accepted connections: 21 requests should have reused the connection
    import std.conv : to;
    auto n0 = cast(int) getUpstreamConns();
    foreach (_; 0 .. 20)
        assert(fetch(s.port, "/hello").body == "hello");
    auto n1 = cast(int) getUpstreamConns();
    assert(n1 - n0 <= 2, "20 requests should reuse the keep-alive connection");

    // stale connection in the pool: the upstream closed the socket after responding
    assert(fetch(s.port, "/stale").body == "stale-ok");
    assert(fetch(s.port, "/stale").body == "stale-ok", "should retry on a new connection");
    ok("keep-alive reuses the connection; a stale pooled connection is retried automatically");
}

int getUpstreamConns()
{
    import std.conv : to;
    import std.string : split;
    // direct query, outside the loop (blocking fallback)
    auto c = new HttpClient;
    scope (exit) c.shutdown();
    return c.get(plainBase ~ "/stats").body.to!int;
}

void testNonBlocking()
{
    auto s = start();
    scope (exit) stop(s);

    enum N = 200;
    int[N] fds;
    immutable t0 = MonoTime.currTime;
    foreach (ref fd; fds)
    {
        fd = dial(s.port);
        sendReq(fd, "/slow/300");
    }
    Thread.sleep(150.msecs);
    immutable t1 = MonoTime.currTime;
    auto f = fetch(s.port, "/fast");
    immutable fastMs = (MonoTime.currTime - t1).total!"msecs";
    assert(f.body == "ok" && fastMs < 50, "the worker got stuck waiting for the upstream");
    foreach (fd; fds)
    {
        auto r = recvResp(fd);
        assert(r.status == 200 && r.body == "slow-done", r.body);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("ok  %d calls of 300 ms to the upstream in %ld ms on one thread (/fast meanwhile: %ld ms)\n", N, ms, fastMs);
    assert(ms < 2500);
}

void testDeadlineAndLimit()
{
    auto s = start();
    scope (exit) stop(s);
    immutable t0 = MonoTime.currTime;
    auto r = fetch(s.port, "/slow/5000");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(r.body == "timeout" && ms < 3000, r.body);
    ok("outgoing request deadline: HttpClientTimeout in ~2 s (the upstream took 5 s)");
}

void testBinaryAndPerRequestTimeout()
{
    auto s = start();
    scope (exit) stop(s);
    assert(fetch(s.port, "/binary").body == "bytes ok", fetch(s.port, "/binary").body);
    immutable t0 = MonoTime.currTime;
    auto r = fetch(s.port, "/per-request-timeout");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(r.body == "short:timeout long:slow-done", r.body);
    assert(ms < 3500, "the short timeout fired at ~300 ms, then the long call took ~2.5 s");
    ok("binary bodies (post, put, request, null) and a per-request timeout shorter and longer than the configured one");
}

void testCancellation()
{
    auto s = start();
    scope (exit) stop(s);
    auto fd = dial(s.port);
    sendReq(fd, "/slow/3000");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    Thread.sleep(100.msecs);
    close(fd);
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500), "fiber was not cancelled");
    assert(fetch(s.port, "/hello").body == "hello"); // the worker carries on normally
    ok("client goes away during the outgoing call: fiber cancelled, worker carries on normally");
}

void testStreamedBodies()
{
    auto s = start();
    scope (exit) stop(s);
    Resp r;
    r = fetch(s.port, "/down/streams");
    assert(r.body == "length chunked pooled", r.body);
    r = fetch(s.port, "/down/early");
    assert(r.body == "hello", r.body);
    r = fetch(s.port, "/down/paced");
    assert(r.body == "length get:timeout", r.body);
    ok("open: 64 MiB (Content-Length) and 10 MiB (chunked) read in pieces, under 1 MiB allocated, the connection "
        ~ "pooled; closed early it is not; each wait has its own timeout");
    r = fetch(s.port, "/up/stream");
    assert(r.body == "sha ok", r.body);
    r = fetch(s.port, "/up/stale");
    assert(r.body == "retried ok", r.body);
    r = fetch(s.port, "/up/wrong-length");
    assert(r.body == "refused refused", r.body);
    ok("BodySource: a 64 MiB PUT in pieces (the upstream's SHA-256 matches, under 1 MiB allocated), retried on a "
        ~ "stale pooled connection; a source shorter or longer than its length is refused");
}

string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}

void main()
{
    auto p = env("ANDAIME_UP_PLAIN"), t = env("ANDAIME_UP_TLS");
    certFile = env("ANDAIME_UP_CERT");
    if (p is null || t is null || certFile is null)
    {
        import core.stdc.stdio : fprintf, stderr;
        import core.stdc.stdlib : exit;

        fprintf(stderr, "skip: set ANDAIME_UP_PLAIN, ANDAIME_UP_TLS and ANDAIME_UP_CERT (see tests/net/upstream.py)\n");
        exit(77);
    }
    plainBase = "http://127.0.0.1:" ~ p;
    tlsBase = "https://localhost:" ~ t;
    configureOffload(2, 64);
    testBasic();
    testTls();
    testKeepAliveAndStale();
    testNonBlocking();
    testDeadlineAndLimit();
    testBinaryAndPerRequestTimeout();
    testCancellation();
    testStreamedBodies();
    printf("all HTTP client tests passed\n");
}
