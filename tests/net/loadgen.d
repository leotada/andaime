/// Gerador de carga do teste de memória (tools/check.sh) e dos spikes.
/// Abre N conexões em `rampaMs`, manda `GET /slow` em cada uma e mede a latência.
/// Uso: loadgen <porta> <conexoes> <rampaMs> <espera esperada em ms>
/// Sai com código 1 se alguma conexão falhar.
module loadgen;

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

// ======================================================================= cliente

int client(ushort port, size_t total, long rampMs, long expectedMs)
{
    int cep = epoll_create1(0);
    auto a = addr(port);
    long[] start = new long[total];
    long[] lat;
    int[int] byFd; // fd -> índice
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
    printf("cliente: %zu ok, %zu falhas de %zu\n", done, failed, total);
    if (lat.length)
        printf("latência total (ms): p50=%.1f p99=%.1f max=%.1f | sobrecusto sobre os %ld ms: p50=%.1f p99=%.1f max=%.1f\n",
            ms(lat[$ / 2]), ms(lat[cast(size_t)(lat.length * 0.99)]), ms(lat[$ - 1]), expectedMs,
            ms(lat[$ / 2]) - expectedMs, ms(lat[cast(size_t)(lat.length * 0.99)]) - expectedMs, ms(lat[$ - 1]) - expectedMs);
    return failed == 0 && done == total ? 0 : 1;
}

int main(string[] args)
{
    if (args.length < 5)
    {
        fprintf(stderr, "uso: loadgen <porta> <conexoes> <rampaMs> <esperaMs>\n");
        return 2;
    }
    return client(args[1].to!ushort, args[2].to!size_t, args[3].to!long, args[4].to!long);
}
