/// M2 spike: edge-triggered epoll + one fiber per request.
/// The handler "waits for an external API" (cooperative sleep) and responds.
///   spike server <port> <sleepMs> <maxInflight>
///   spike client <port> <connections> <rampMs> <expectedSleepMs>
module spike;

import core.thread, core.time;
import core.stdc.stdio, core.stdc.stdlib, core.stdc.string, core.stdc.errno;
import core.sys.posix.sys.socket, core.sys.posix.netinet.in_, core.sys.posix.unistd;
import core.sys.posix.arpa.inet, core.sys.linux.epoll;
import std.algorithm : sort;
import std.conv : to;

extern (C) void* memmem(const(void)*, size_t, const(void)*, size_t) nothrow @nogc;
extern (C) int accept4(int, sockaddr*, socklen_t*, int) nothrow @nogc;
enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;

sockaddr_in addr(ushort port)
{
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    return a;
}

size_t procKb(const(char)* key)
{
    auto f = fopen("/proc/self/status", "r");
    char[256] line;
    size_t v;
    while (fgets(line.ptr, 256, f))
        if (strncmp(line.ptr, key, strlen(key)) == 0)
        {
            sscanf(line.ptr + strlen(key), " %zu", &v);
            break;
        }
    fclose(f);
    return v;
}

// ======================================================================= server

enum bufSize = 4096;

struct Conn
{
    int fd = -1;
    char* buf;
    size_t len;
    bool busy;
}

struct Timer { MonoTime dl; Fiber f; }

__gshared int ep;
__gshared Conn[] conns;
__gshared char*[] freeBufs;
__gshared Timer[] ring;
__gshared size_t qHead, qTail;
__gshared Duration sleepFor;
__gshared size_t inflight, maxInflight, peakInflight, fibersCreated, rejected, served;

final class Worker : Fiber
{
    Conn* c;
    this() { super(&run, 64 * 1024); }

    void run()
    {
        for (;;)
        {
            handle(c);
            inflight--;
            freeList ~= this; // back to the pool; the loop can reuse it right away
            Fiber.yield();
        }
    }
}

__gshared Worker[] freeList;

/// suspends the current fiber until `d` passes; the loop wakes it from the timer queue
void awaitSleep(Duration d)
{
    ring[qTail++ & (ring.length - 1)] = Timer(MonoTime.currTime + d, Fiber.getThis());
    Fiber.yield();
}

void closeConn(Conn* c)
{
    close(c.fd);
    freeBufs ~= c.buf;
    *c = Conn.init;
}

static immutable resp200 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
static immutable resp503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

void handle(Conn* c)
{
    awaitSleep(sleepFor); // "database/external API": no thread blocked
    send(c.fd, resp200.ptr, resp200.length, 0x4000 /*MSG_NOSIGNAL*/);
    served++;
    closeConn(c);
}

void onReadable(Conn* c)
{
    for (;;)
    {
        auto n = read(c.fd, c.buf + c.len, bufSize - c.len);
        if (n > 0)
            c.len += n;
        else if (n == 0 || errno != EAGAIN)
        {
            if (!c.busy)
                closeConn(c);
            return;
        }
        else
            break;
    }
    if (c.busy || memmem(c.buf, c.len, "\r\n\r\n".ptr, 4) is null)
        return;
    c.busy = true;
    if (inflight >= maxInflight)
    {
        send(c.fd, resp503.ptr, resp503.length, 0x4000);
        rejected++;
        closeConn(c);
        return;
    }
    Worker w;
    if (freeList.length)
    {
        w = freeList[$ - 1];
        freeList.length--;
    }
    else
    {
        w = new Worker;
        fibersCreated++;
    }
    w.c = c;
    inflight++;
    if (inflight > peakInflight)
        peakInflight = inflight;
    w.call();
}

void server(ushort port, int sleepMs, size_t cap)
{
    sleepFor = msecs(sleepMs);
    maxInflight = cap;
    conns = new Conn[70_000];
    ring = new Timer[1 << 16];
    freeList.reserve(1024);

    int ls = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, 4);
    auto a = addr(port);
    if (bind(ls, cast(sockaddr*)&a, a.sizeof) < 0) { perror("bind"); exit(1); }
    listen(ls, 4096);

    ep = epoll_create1(0);
    epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = ls;
    epoll_ctl(ep, EPOLL_CTL_ADD, ls, &ev);

    printf("server :%d sleep=%dms maxInflight=%zu initial RSS=%zu KiB\n", port, sleepMs, cap, procKb("VmRSS:"));
    fflush(stdout);

    epoll_event[512] evs;
    auto nextStat = MonoTime.currTime + seconds(1);
    for (;;)
    {
        auto now = MonoTime.currTime;
        long timeout = 1000;
        if (qHead != qTail)
        {
            auto w = (ring[qHead & (ring.length - 1)].dl - now).total!"msecs" + 1;
            timeout = w < 0 ? 0 : (w > 1000 ? 1000 : w);
        }
        int n = epoll_wait(ep, evs.ptr, cast(int) evs.length, cast(int) timeout);

        now = MonoTime.currTime;
        while (qHead != qTail && ring[qHead & (ring.length - 1)].dl <= now)
            ring[qHead++ & (ring.length - 1)].f.call();

        foreach (i; 0 .. n)
        {
            int fd = evs[i].data.fd;
            if (fd == ls)
            {
                for (;;)
                {
                    int cfd = accept4(ls, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0)
                        break;
                    auto c = &conns[cfd];
                    c.fd = cfd;
                    c.len = 0;
                    c.busy = false;
                    if (freeBufs.length) { c.buf = freeBufs[$ - 1]; freeBufs.length--; }
                    else c.buf = cast(char*) malloc(bufSize);
                    epoll_event e;
                    e.events = EPOLLIN | EPOLLET;
                    e.data.fd = cfd;
                    epoll_ctl(ep, EPOLL_CTL_ADD, cfd, &e);
                    onReadable(c); // data may have arrived before the ADD (missed edge)
                }
            }
            else if (conns[fd].fd == fd)
                onReadable(&conns[fd]);
        }

        if (now >= nextStat)
        {
            nextStat = now + seconds(1);
            printf("in flight=%zu peak=%zu fibers=%zu served=%zu 503=%zu RSS=%zu KiB peak=%zu KiB\n",
                inflight, peakInflight, fibersCreated, served, rejected, procKb("VmRSS:"), procKb("VmHWM:"));
            fflush(stdout);
        }
    }
}

// ======================================================================= client

void client(ushort port, size_t total, long rampMs, long expectedMs)
{
    int cep = epoll_create1(0);
    auto a = addr(port);
    long[] start = new long[total];
    long[] lat;
    int[int] byFd; // fd -> index
    size_t opened, done, failed;
    immutable t0 = MonoTime.currTime;
    static immutable req = "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n";
    epoll_event[1024] evs;

    while (done + failed < total)
    {
        auto el = (MonoTime.currTime - t0).total!"msecs";
        if (el > 60_000) break;
        size_t target = rampMs > 0 ? cast(size_t)(total * (el > rampMs ? rampMs : el) / rampMs) : total;
        while (opened < target)
        {
            int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
            if (fd < 0) { failed++; opened++; continue; }
            connect(fd, cast(sockaddr*)&a, a.sizeof);
            byFd[fd] = cast(int) opened;
            epoll_event e;
            e.events = EPOLLOUT | EPOLLIN | EPOLLET;
            e.data.fd = fd;
            epoll_ctl(cep, EPOLL_CTL_ADD, fd, &e);
            opened++;
        }
        int n = epoll_wait(cep, evs.ptr, cast(int) evs.length, 5);
        foreach (i; 0 .. n)
        {
            int fd = evs[i].data.fd;
            auto p = fd in byFd;
            if (p is null) continue;
            int idx = *p;
            if (evs[i].events & EPOLLOUT && start[idx] == 0)
            {
                int err; socklen_t l = 4;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l);
                if (err) { failed++; byFd.remove(fd); close(fd); continue; }
                start[idx] = MonoTime.currTime.ticks;
                send(fd, req.ptr, req.length, 0x4000);
            }
            if (evs[i].events & EPOLLIN)
            {
                char[256] b;
                auto r = read(fd, b.ptr, 256);
                if (r > 0 && start[idx])
                {
                    lat ~= (MonoTime.currTime.ticks - start[idx]) * 1_000_000_000 / MonoTime.ticksPerSecond;
                    done++;
                    byFd.remove(fd);
                    close(fd);
                }
                else if (r == 0 || (r < 0 && errno != EAGAIN))
                {
                    failed++; byFd.remove(fd); close(fd);
                }
            }
        }
    }
    sort(lat);
    auto ms(long ns) { return ns / 1e6; }
    printf("client: %zu ok, %zu failures out of %zu\n", done, failed, total);
    if (lat.length)
        printf("total latency (ms): p50=%.1f p99=%.1f max=%.1f | overhead over the %ld ms: p50=%.1f p99=%.1f max=%.1f\n",
            ms(lat[$ / 2]), ms(lat[cast(size_t)(lat.length * 0.99)]), ms(lat[$ - 1]), expectedMs,
            ms(lat[$ / 2]) - expectedMs, ms(lat[cast(size_t)(lat.length * 0.99)]) - expectedMs, ms(lat[$ - 1]) - expectedMs);
}

int main(string[] args)
{
    if (args.length >= 5 && args[1] == "server")
        server(args[2].to!ushort, args[3].to!int, args[4].to!size_t);
    else if (args.length >= 6 && args[1] == "client")
        client(args[2].to!ushort, args[3].to!size_t, args[4].to!long, args[5].to!long);
    else
    {
        fprintf(stderr, "usage: spike server <port> <sleepMs> <maxInflight> | client <port> <n> <rampMs> <sleepMs>\n");
        return 2;
    }
    return 0;
}
