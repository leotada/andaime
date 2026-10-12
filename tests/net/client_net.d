/// Tests of the outgoing HTTP client against a Python upstream (tests/net/upstream.py).
/// Variables: VELA_UP_PLAIN, VELA_UP_TLS (ports) and VELA_UP_CERT (the upstream's certificate).
module client_net;

version (linux):

import vela;
import vela.engine;
import vela.server : handlerFactory;

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

string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}

void main()
{
    auto p = env("VELA_UP_PLAIN"), t = env("VELA_UP_TLS");
    certFile = env("VELA_UP_CERT");
    if (p is null || t is null || certFile is null)
    {
        printf("skipped: set VELA_UP_PLAIN, VELA_UP_TLS and VELA_UP_CERT (see tests/net/upstream.py)\n");
        return;
    }
    plainBase = "http://127.0.0.1:" ~ p;
    tlsBase = "https://localhost:" ~ t;
    configureOffload(2, 64);
    testBasic();
    testTls();
    testKeepAliveAndStale();
    testNonBlocking();
    testDeadlineAndLimit();
    testCancellation();
    printf("all HTTP client tests passed\n");
}
