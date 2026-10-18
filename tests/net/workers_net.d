/// One App per worker: `serve(build)` calls the build function once per worker, each on its own thread; the Apps are
/// never shared, a build that returns the same App twice or throws is reported, and startup fails cleanly.
module workers_net;

version (linux):

import andaime;
import andaime.engine : ServerConfig;

import core.atomic : atomicOp, atomicLoad;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.signal : kill, SIGTERM;
import core.sys.posix.unistd : getpid, close, read;

// ---------------------------------------------------------------- the app under test

/// Per-worker state: created by the build function, so it belongs to one worker and needs no locking.
final class Worker
{
    Thread builtOn;
    int id;
    int hits;
}

shared int builds;
__gshared Mutex mutex;
__gshared Thread[] buildThreads;
shared int foreignAccess;

@system:

int nextId() { return atomicOp!"+="(builds, 1); }

App makeApp()
{
    auto w = new Worker;
    w.builtOn = Thread.getThis();
    w.id = nextId();
    synchronized (mutex)
        buildThreads ~= w.builtOn;
    auto app = new App;
    app.get!("/hit", (Context ctx) @system {
        if (Thread.getThis() !is w.builtOn)
            atomicOp!"+="(foreignAccess, 1); // an App used from a thread that did not build it
        w.hits++;
        return "worker " ~ cast(string) intToStr(w.id) ~ " hits " ~ cast(string) intToStr(w.hits);
    });
    return app;
}

string intToStr(int v)
{
    char[12] t;
    size_t n = t.length;
    do { t[--n] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return t[n .. $].idup;
}

// ---------------------------------------------------------------- tiny client

ushort freePort()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(0x7f000001);
    bind(fd, cast(sockaddr*)&a, a.sizeof);
    socklen_t len = a.sizeof;
    getsockname(fd, cast(sockaddr*)&a, &len);
    close(fd);
    return ntohs(a.sin_port);
}

string fetch(ushort port, string path) => fetchWith(port, path, "");

string fetchWith(ushort port, string path, string extraHeaders)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, cast(sockaddr*)&a, a.sizeof) != 0)
    {
        close(fd);
        return null;
    }
    string req = "GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n" ~ extraHeaders ~ "\r\n";
    send(fd, req.ptr, req.length, 0x4000);
    char[4096] buf;
    string all;
    for (;;)
    {
        auto n = read(fd, buf.ptr, buf.length);
        if (n <= 0)
            break;
        all ~= buf[0 .. n].idup;
    }
    close(fd);
    import std.string : indexOf;
    auto i = all.indexOf("\r\n\r\n");
    return i < 0 ? all : all[i + 4 .. $];
}

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

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

// ---------------------------------------------------------------- tests

void testOneAppPerWorker()
{
    import std.algorithm : canFind, map, sum;
    import std.conv : to;
    import std.string : split;

    atomicOp!"-="(builds, atomicLoad(builds));
    buildThreads = null;
    immutable port = freePort();
    ServerConfig cfg;
    cfg.port = port;
    cfg.host = "127.0.0.1";
    cfg.workers = 4;
    bool result;
    auto t = new Thread({ result = tryServe(&makeApp, cfg); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (fetch(port, "/hit").length)
            break;
        Thread.sleep(10.msecs);
    }
    // many connections: SO_REUSEPORT spreads them over the workers
    int[int] last; // worker id -> highest hit count seen
    enum N = 80;
    foreach (_; 0 .. N)
    {
        auto body_ = fetch(port, "/hit");
        auto p = body_.split(" "); // "worker <id> hits <n>"
        assert(p.length == 4, body_);
        last[p[1].to!int] = p[3].to!int;
    }
    kill(getpid(), SIGTERM); // the server stops gracefully, like on Ctrl-C
    t.join();
    assert(result, "a clean stop returns true");

    assert(atomicLoad(builds) == 4, "the build function runs once per worker");
    synchronized (mutex)
    {
        assert(buildThreads.length == 4);
        foreach (i, a; buildThreads)
            foreach (b; buildThreads[i + 1 .. $])
                assert(a !is b, "each worker builds on its own thread");
    }
    assert(atomicLoad(foreignAccess) == 0, "an App was used from a thread that did not build it");
    assert(last.length > 1, "connections should reach more than one worker");
    // +1: the readiness probe above also counted one hit
    assert(last.values.sum == N + 1 || last.values.sum == N, "each worker counted its own requests: " ~ last.to!string);
    ok("4 workers: the build function runs 4 times on 4 threads, each App is only touched by its own thread");
}

void testSameAppTwice()
{
    import std.algorithm : canFind;

    auto shared_ = new App;
    ServerConfig cfg;
    cfg.port = freePort();
    cfg.host = "127.0.0.1";
    cfg.workers = 2;
    bool result = true;
    auto log = captureStderr({ result = tryServe(() => shared_, cfg); });
    assert(!result);
    assert(log.canFind("andaime: building the app failed: andaime: the build function must create a new App for each worker "
        ~ "(it returned the same object twice); move `new App` and the route registration inside it"), log);
    ok("a build function that returns the same App twice fails with a clear message");
}

void testBuildThrows()
{
    import std.algorithm : canFind, count;

    ServerConfig cfg;
    cfg.port = freePort();
    cfg.host = "127.0.0.1";
    cfg.workers = 3;
    bool result = true;
    // worker 0 fails: one line, nothing else starts
    auto log = captureStderr({
        result = tryServe(() { throw new Exception("boom"); return cast(App) null; }, cfg);
    });
    assert(!result && log.count("andaime: building the app failed: boom") == 1, log);

    // a later worker fails: the server stops instead of running half-built
    shared int calls;
    result = true;
    log = captureStderr({
        result = tryServe(() {
            if (atomicOp!"+="(calls, 1) == 2)
                throw new Exception("second build failed");
            auto a = new App;
            return a;
        }, cfg);
    });
    assert(!result && log.canFind("andaime: building the app failed: second build failed"), log);
    ok("a build that throws: one line on stderr and a false result, whether it is the first worker or a later one");
}

/// `ServerConfig.trustedProxies` reaches every worker's App: behind a trusted proxy the header is believed.
void testTrustedProxies()
{
    import std.algorithm : canFind;

    // a bad entry fails startup with one line, before any worker builds
    ServerConfig bad;
    bad.port = freePort();
    bad.host = "127.0.0.1";
    bad.workers = 1;
    bad.trustedProxies = ["10.0.0.0/8", "nonsense"];
    bool result = true;
    auto log = captureStderr({ result = tryServe(() => new App, bad); });
    assert(!result && log.canFind("trustedProxies: 'nonsense' is not an address or a CIDR"), log);

    foreach (trusted; [true, false])
    {
        ServerConfig cfg;
        immutable port = freePort();
        cfg.port = port;
        cfg.host = "127.0.0.1";
        cfg.workers = 2;
        if (trusted)
            cfg.trustedProxies = ["127.0.0.1"];
        bool served;
        auto t = new Thread({
            served = tryServe(() {
                auto app = new App;
                app.get!("/who", (ClientIp ip) => ip.toString);
                return app;
            }, cfg);
        });
        t.start();
        foreach (_; 0 .. 400)
        {
            if (fetch(port, "/who").length)
                break;
            Thread.sleep(10.msecs);
        }
        auto got = fetchWith(port, "/who", "X-Forwarded-For: 198.51.100.7\r\n");
        kill(getpid(), SIGTERM);
        t.join();
        assert(served);
        assert(got == (trusted ? "198.51.100.7" : "127.0.0.1"), got);
    }
    ok("ServerConfig.trustedProxies: the forwarding header is believed only from a trusted peer; a bad entry fails startup");
}

void testPortInUse()
{
    import std.algorithm : canFind;

    immutable port = freePort();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    bind(fd, cast(sockaddr*)&a, a.sizeof);
    listen(fd, 1);
    ServerConfig cfg;
    cfg.port = port;
    cfg.host = "127.0.0.1";
    cfg.workers = 1;
    cfg.reusePort = false;
    bool result = true;
    captureStderr({ result = tryServe(() => new App, cfg); });
    close(fd);
    assert(!result, "a listener that cannot bind is a failed start");
    ok("a port already in use makes tryServe return false");
}

void main()
{
    mutex = new Mutex;
    testOneAppPerWorker();
    testSameAppTwice();
    testBuildThrows();
    testTrustedProxies();
    testPortInUse();
    printf("all worker tests passed\n");
}
