/// Supervisor on the epoll loop: one claimed job, GET /health, and a shutdown that releases
/// a job still inside `perform`. Run from `s_net` in tools/check.sh.
module jobs_worker_net;

version (linux):

import vela.engine.fiberio : sleep;
import vela.engine.loop : ServerConfig;
import vela.jobs;

import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime, msecs, seconds;

@safe:

shared int ran;
shared int entered;

@Job("default")
struct Ping
{
    int n;

    void perform(ref JobContext ctx)
    {
        import vela.log : logInfo;

        logInfo("ping ran");
        atomicStore(ran, 1);
    }
}

/// Sends stderr to a pipe until `stderrText` gives it back (the server's lines included).
struct StderrCapture
{
    int saved = -1;
    int[2] p;

    void start() @trusted
    {
        import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
        import core.sys.posix.unistd : dup, dup2, pipe;

        pipe(p);
        fcntl(p[0], F_SETFL, O_NONBLOCK);
        saved = dup(2);
        dup2(p[1], 2);
    }

    string stop() @trusted
    {
        import core.sys.posix.unistd : close, dup2, read;

        if (saved < 0)
            return null;
        dup2(saved, 2);
        close(saved);
        saved = -1;
        close(p[1]);
        char[] all;
        char[4096] buf;
        for (;;)
        {
            auto n = read(p[0], buf.ptr, buf.length);
            if (n <= 0)
                break;
            all ~= buf[0 .. n];
        }
        close(p[0]);
        return cast(string) all;
    }
}

@Job("default")
struct Slow
{
    int n;

    void perform(ref JobContext ctx)
    {
        atomicStore(entered, 1);
        sleep(30.seconds);
        atomicStore(entered, 2);
    }
}

int statusOf(string raw) pure nothrow @safe
{
    if (raw.length < 12 || raw[0 .. 5] != "HTTP/")
        return 0;
    int n = 0;
    foreach (k; 0 .. 3)
    {
        char c = raw[9 + k];
        if (c < '0' || c > '9')
            return 0;
        n = n * 10 + (c - '0');
    }
    return n;
}

string bodyOf(string raw) pure nothrow @safe
{
    foreach (size_t i; 0 .. raw.length)
    {
        if (i + 4 <= raw.length && raw[i .. i + 4] == "\r\n\r\n")
        {
            auto rest = raw[i + 4 .. $];
            auto n = contentLength(raw[0 .. i + 4]);
            if (n < 0 || cast(size_t) n > rest.length)
                return rest;
            return rest[0 .. n];
        }
    }
    return null;
}

long contentLength(string head) pure nothrow @safe
{
    enum string key = "Content-Length: ";
    foreach (size_t i; 0 .. head.length)
    {
        if (i + key.length > head.length || head[i .. i + key.length] != key)
            continue;
        size_t j = i + key.length;
        long n = 0;
        if (j >= head.length || head[j] < '0' || head[j] > '9')
            return -1;
        while (j < head.length && head[j] >= '0' && head[j] <= '9')
        {
            n = n * 10 + (head[j] - '0');
            j++;
        }
        return n;
    }
    return -1;
}

@system:

import core.stdc.errno : errno, EINTR;
import core.stdc.stdio : fflush, fprintf, printf, stderr, stdout;
import core.stdc.stdlib : exit;
import core.sys.posix.arpa.inet : htonl, htons, ntohs;
import core.sys.posix.netinet.in_ : sockaddr_in;
import core.sys.posix.signal : SIGTERM, kill;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, getpid;
import core.thread : Thread;

ptrdiff_t ioSend(int fd, const(void)* p, size_t n)
{
    while (true)
    {
        auto r = send(fd, p, n, 0);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

ptrdiff_t ioRecv(int fd, void* p, size_t n)
{
    while (true)
    {
        auto r = recv(fd, p, n, 0);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

ushort freePort()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0, "socket");
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0, "bind");
    socklen_t len = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &len) == 0, "getsockname");
    ushort p = ntohs(a.sin_port);
    close(fd);
    return p;
}

string httpGet(ushort port, string path)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return null;
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, cast(sockaddr*) &a, a.sizeof) != 0)
    {
        close(fd);
        return null;
    }
    timeval tv = timeval(1, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    string req = "GET " ~ path ~ " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    size_t off = 0;
    while (off < req.length)
    {
        auto n = ioSend(fd, req.ptr + off, req.length - off);
        if (n <= 0)
        {
            close(fd);
            return null;
        }
        off += n;
    }
    char[1024] buf;
    string acc;
    while (acc.length < 8192)
    {
        auto n = ioRecv(fd, buf.ptr, buf.length);
        if (n < 0)
            break;
        if (n == 0)
            break;
        acc ~= buf[0 .. n].idup;
        auto end = bodyOf(acc);
        if (statusOf(acc) != 0 && contentLength(acc) >= 0 && end.length == contentLength(acc))
            break;
    }
    close(fd);
    return acc;
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

bool waitFlag(shared int* slot, int want, int timeoutMs)
{
    foreach (_; 0 .. timeoutMs / 5)
    {
        if (atomicLoad(*slot) == want)
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

void testHealthAndJob()
{
    atomicStore(ran, 0);
    auto store = new InMemoryJobStore;
    immutable port = freePort();
    auto startup = parseStartup(["jobs_worker_net", "--role=worker", "--queues=default:2"]);
    ServerConfig cfg;
    cfg.host = "127.0.0.1";
    WorkerHooks hooks;
    hooks.extra = () {
        Ping job;
        job.n = 1;
        enqueue(store, job);
    };

    Exception failed;
    auto t = new Thread({
        try
            runJobs!Ping(store, startup, cfg, true, port, hooks);
        catch (Exception e)
            failed = e;
    });
    bool joined;
    StderrCapture cap;
    scope (failure)
    {
        if (!joined)
        {
            kill(getpid(), SIGTERM);
            t.join();
        }
        cap.stop();
    }
    cap.start();
    t.start();

    bool up;
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(ran) == 1)
        {
            auto health = httpGet(port, "/health");
            auto other = httpGet(port, "/nope");
            if (statusOf(health) == 200 && bodyOf(health) == "ok" && statusOf(other) == 404)
            {
                up = true;
                break;
            }
        }
        Thread.sleep(5.msecs);
    }
    if (!up)
    {
        auto why = failed is null ? "" : failed.msg;
        fprintf(stderr, "ran=%d err=%.*s\n", atomicLoad(ran), cast(int) why.length, why.ptr);
        assert(0, "worker did not run the job and serve /health");
    }

    kill(getpid(), SIGTERM);
    immutable t0 = MonoTime.currTime;
    t.join();
    joined = true;
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(failed is null, failed is null ? "" : failed.msg);
    assert(ms < 2500, "fibers should see stopping() and return before the 30s grace");
    auto rows = store.jobs();
    assert(rows.length == 1);
    assert(rows[0].state == JobState.completed);
    assert(rows[0].attempt == 1);
    assert(rows[0].queue == "default");
    // the line `perform` logged on the worker's fiber names the job
    immutable log = cap.stop();
    import std.algorithm : canFind;
    assert(log.canFind("ping ran job=jobs_worker_net.Ping job_id=1 attempt=1"), log);
    ok("worker role: GET /health, one job (its log line names it), stop does not wait out grace");
}

void testReleaseOnShutdown()
{
    atomicStore(entered, 0);
    auto store = new InMemoryJobStore;
    auto startup = parseStartup(["jobs_worker_net", "--role=worker", "--queues=default:1"]);
    ServerConfig cfg;
    cfg.host = "127.0.0.1";
    cfg.shutdownGraceMs = 400;
    WorkerHooks hooks;
    hooks.extra = () {
        Slow job;
        job.n = 1;
        enqueue(store, job);
    };

    Exception failed;
    auto t = new Thread({
        try
            runJobs!Slow(store, startup, cfg, true, 0, hooks);
        catch (Exception e)
            failed = e;
    });
    bool joined;
    scope (failure)
    {
        if (!joined)
        {
            kill(getpid(), SIGTERM);
            t.join();
        }
    }
    t.start();

    if (!waitFlag(&entered, 1, 2000))
    {
        auto why = failed is null ? "" : failed.msg;
        fprintf(stderr, "entered=%d err=%.*s\n", atomicLoad(entered), cast(int) why.length, why.ptr);
        assert(0, "slow job did not start");
    }
    kill(getpid(), SIGTERM);
    immutable t0 = MonoTime.currTime;
    t.join();
    joined = true;
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(failed is null, failed is null ? "" : failed.msg);
    assert(atomicLoad(entered) == 1, "the 30s sleep should be cancelled, not finish");
    assert(ms < 2000, "cancellation should follow the caller's 400ms grace, not the 30s default");
    auto rows = store.jobs();
    assert(rows.length == 1);
    assert(rows[0].state == JobState.retryable);
    assert(rows[0].attempt == 0);
    ok("worker role: shutdown releases a job cancelled inside perform");
}

void main()
{
    auto guard = new Thread({
        Thread.sleep(20.seconds);
        fprintf(stderr, "jobs_worker_net: timed out\n");
        exit(1);
    });
    guard.isDaemon = true;
    guard.start();

    testHealthAndJob();
    testReleaseOnShutdown();
    printf("all job-worker tests passed\n");
}
