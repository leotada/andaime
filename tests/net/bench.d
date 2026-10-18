/// Throughput benchmark client (a small wrk): keep-alive HTTP/1.1 connections spread over threads, each thread with its
/// own epoll loop. Every connection keeps `depth` requests outstanding (1 = no pipelining) and the client counts complete
/// responses (it understands Content-Length and chunked bodies).
///
/// Usage: bench <port> <path> [connections=64] [seconds=5] [threads=4] [depth=1]
/// Prints requests per second and the latency percentiles (depth 1 only). Exits with 1 if a response is not a 200.
module bench;

import core.thread, core.time, core.atomic;
import core.stdc.stdio, core.stdc.stdlib, core.stdc.string, core.stdc.errno;
import core.sys.posix.sys.socket, core.sys.posix.netinet.in_, core.sys.posix.netinet.tcp, core.sys.posix.unistd;
import core.sys.posix.arpa.inet, core.sys.linux.epoll;
import std.algorithm : sort;
import std.conv : to;

enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;

struct Conn
{
    int fd = -1;
    char[] inbuf;
    size_t have;
    size_t outstanding;
    long sentAt; // ticks, depth 1 only
}

struct Result
{
    ulong responses, errors, bad;
    long[] lat; // ns
}

shared bool stopFlag;

/// Length of the first complete response in `b`, 0 if it is incomplete, -1 if it is malformed. Sets `ok` to the status
/// being 200.
ptrdiff_t responseLength(const(char)[] b, out bool ok)
{
    auto p = cast(const(char)*) memmem(b.ptr, b.length, "\r\n\r\n".ptr, 4);
    if (p is null)
        return 0;
    immutable head = cast(size_t)(p - b.ptr) + 4;
    ok = b.length > 12 && b[9 .. 12] == "200";
    // Content-Length or chunked
    size_t i = 0;
    long cl = -1;
    bool chunked;
    while (i < head)
    {
        auto e = i;
        while (e < head && b[e] != '\n')
            e++;
        auto line = b[i .. e];
        if (line.length > 16 && (line[0] | 0x20) == 'c' && strncasecmp(line.ptr, "content-length:", 15) == 0)
        {
            cl = 0;
            foreach (ch; line[15 .. $])
                if (ch >= '0' && ch <= '9')
                    cl = cl * 10 + (ch - '0');
        }
        else if (line.length > 18 && strncasecmp(line.ptr, "transfer-encoding:", 18) == 0)
            chunked = true;
        i = e + 1;
    }
    if (!chunked)
    {
        if (cl < 0)
            return -1;
        return b.length >= head + cl ? cast(ptrdiff_t)(head + cl) : 0;
    }
    // chunked: walk the chunks
    size_t at = head;
    for (;;)
    {
        auto q = cast(const(char)*) memmem(b.ptr + at, b.length - at, "\r\n".ptr, 2);
        if (q is null)
            return 0;
        size_t n = 0;
        foreach (ch; b[at .. q - b.ptr])
        {
            immutable d = ch >= '0' && ch <= '9' ? ch - '0' : (ch | 0x20) >= 'a' && (ch | 0x20) <= 'f' ? (ch | 0x20) - 'a' + 10 : -1;
            if (d < 0)
                break;
            n = n * 16 + d;
        }
        at = cast(size_t)(q - b.ptr) + 2;
        if (n == 0)
            return b.length >= at + 2 ? cast(ptrdiff_t)(at + 2) : 0;
        if (b.length < at + n + 2)
            return 0;
        at += n + 2;
    }
}

extern (C) void* memmem(const(void)*, size_t, const(void)*, size_t) nothrow @nogc;

void worker(ushort port, string path, size_t nconns, size_t depth, Result* res)
{
    auto req = "GET " ~ path ~ " HTTP/1.1\r\nHost: localhost\r\nUser-Agent: andaime-bench\r\nAccept: */*\r\n\r\n";
    char[] batch;
    foreach (_; 0 .. depth)
        batch ~= req;
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    int ep = epoll_create1(0);
    auto conns = new Conn[nconns];
    foreach (i, ref c; conns)
    {
        c.fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        int one = 1;
        setsockopt(c.fd, IPPROTO_TCP, TCP_NODELAY, &one, one.sizeof);
        if (connect(c.fd, cast(sockaddr*)&a, a.sizeof) != 0)
        {
            perror("connect");
            exit(2);
        }
        auto fl = fcntl(c.fd, F_GETFL);
        fcntl(c.fd, F_SETFL, fl | O_NONBLOCK);
        c.inbuf = new char[64 << 10];
        epoll_event e;
        e.events = EPOLLIN;
        e.data.u64 = i;
        epoll_ctl(ep, EPOLL_CTL_ADD, c.fd, &e);
        c.sentAt = MonoTime.currTime.ticks;
        send(c.fd, batch.ptr, batch.length, MSG_NOSIGNAL);
        c.outstanding = depth;
    }
    epoll_event[256] evs;
    while (!atomicLoad(stopFlag))
    {
        immutable n = epoll_wait(ep, evs.ptr, cast(int) evs.length, 50);
        foreach (k; 0 .. n < 0 ? 0 : n)
        {
            auto c = &conns[cast(size_t) evs[k].data.u64];
            for (;;)
            {
                if (c.have == c.inbuf.length)
                    c.inbuf.length *= 2;
                auto r = read(c.fd, c.inbuf.ptr + c.have, c.inbuf.length - c.have);
                if (r <= 0)
                {
                    if (r < 0 && errno == EAGAIN)
                        break;
                    res.errors++;
                    epoll_ctl(ep, EPOLL_CTL_DEL, c.fd, null);
                    close(c.fd);
                    c.fd = -1;
                    break;
                }
                c.have += r;
            }
            if (c.fd < 0)
                continue;
            size_t at = 0, got = 0;
            for (;;)
            {
                bool ok;
                auto len = responseLength(c.inbuf[at .. c.have], ok);
                if (len < 0)
                {
                    fprintf(stderr, "bench: malformed response\n");
                    exit(1);
                }
                if (len == 0)
                    break;
                if (!ok)
                    res.bad++;
                at += len;
                got++;
            }
            if (at)
            {
                memmove(c.inbuf.ptr, c.inbuf.ptr + at, c.have - at);
                c.have -= at;
            }
            if (got)
            {
                res.responses += got;
                c.outstanding -= got;
                if (depth == 1)
                    res.lat ~= (MonoTime.currTime.ticks - c.sentAt) * 1_000_000_000 / MonoTime.ticksPerSecond;
                if (c.outstanding == 0)
                {
                    c.sentAt = MonoTime.currTime.ticks;
                    send(c.fd, batch.ptr, batch.length, MSG_NOSIGNAL);
                    c.outstanding = depth;
                }
            }
        }
    }
    foreach (ref c; conns)
        if (c.fd >= 0)
            close(c.fd);
    close(ep);
}

int main(string[] args)
{
    if (args.length < 3)
    {
        fprintf(stderr, "usage: bench <port> <path> [connections=64] [seconds=5] [threads=4] [depth=1]\n");
        return 2;
    }
    immutable port = args[1].to!ushort;
    immutable path = args[2];
    immutable conns = args.length > 3 ? args[3].to!size_t : 64;
    immutable secs = args.length > 4 ? args[4].to!double : 5;
    immutable threads = args.length > 5 ? args[5].to!size_t : 4;
    immutable depth = args.length > 6 ? args[6].to!size_t : 1;

    auto results = new Result[threads];
    Thread[] ts;
    foreach (t; 0 .. threads)
    {
        immutable mine = conns / threads + (t < conns % threads ? 1 : 0);
        auto r = &results[t];
        ts ~= new Thread(() { worker(port, path, mine, depth, r); }).start();
    }
    // warm-up second, then measure
    Thread.sleep(1.seconds);
    ulong startCount;
    foreach (ref r; results)
        startCount += atomicLoad(*cast(shared ulong*)&r.responses);
    foreach (ref r; results)
        r.lat.length = 0; // racy but harmless: latencies are only a sample
    immutable t0 = MonoTime.currTime;
    Thread.sleep(dur!"msecs"(cast(long)(secs * 1000)));
    ulong endCount;
    foreach (ref r; results)
        endCount += atomicLoad(*cast(shared ulong*)&r.responses);
    immutable el = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    atomicStore(stopFlag, true);
    foreach (t; ts)
        t.join();

    ulong errors, bad;
    long[] lat;
    foreach (ref r; results)
    {
        errors += r.errors;
        bad += r.bad;
        lat ~= r.lat;
    }
    printf("%.*s: %.0f req/s (%zu conns, %zu threads, depth %zu, %.1f s)", cast(int) path.length, path.ptr, (endCount - startCount) / el, conns,
        threads, depth, el);
    if (lat.length)
    {
        sort(lat);
        printf(" | latency us p50=%.0f p99=%.0f max=%.0f", lat[$ / 2] / 1e3, lat[cast(size_t)(lat.length * 0.99)] / 1e3,
            lat[$ - 1] / 1e3);
    }
    printf("\n");
    if (errors || bad)
    {
        fprintf(stderr, "bench: %llu connection errors, %llu non-200 responses\n", errors, bad);
        return 1;
    }
    return 0;
}

import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.strings : strncasecmp;
