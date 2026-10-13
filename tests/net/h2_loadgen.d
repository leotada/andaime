/// HTTP/2 load for the memory test (tools/check.sh): opens `connections` h2c connections,
/// starts `streams` concurrent `GET /slow` on each, and checks every one is answered once.
/// Usage: h2_loadgen <port> <connections> <streams per connection> <expected wait in ms>
/// Exits with code 1 on any failure.
module h2_loadgen;

import core.time;
import core.stdc.stdio : printf;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : read, close;
import std.conv : to;

enum string preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

// :method GET (indexed 2), :scheme http (indexed 6), :path "/slow" (literal, name index 4)
immutable ubyte[] getSlow = [0x82, 0x86, 0x04, 5, '/', 's', 'l', 'o', 'w'];

int dial(ushort port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, cast(sockaddr*)&a, a.sizeof) != 0)
        return -1;
    timeval tv = timeval(30, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

bool sendAll(int fd, const(ubyte)[] b)
{
    while (b.length)
    {
        auto n = send(fd, b.ptr, b.length, 0x4000);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        b = b[n .. $];
    }
    return true;
}

int main(string[] args)
{
    immutable port = args[1].to!ushort;
    immutable conns = args[2].to!uint;
    immutable streams = args[3].to!uint;
    immutable waitMs = args[4].to!long;

    auto t0 = MonoTime.currTime;
    int[] fds;
    foreach (c; 0 .. conns)
    {
        auto fd = dial(port);
        if (fd < 0)
        {
            printf("connect failed\n");
            return 1;
        }
        ubyte[] out_ = cast(ubyte[]) preface.dup ~ frame(4, 0, 0, null);
        foreach (i; 0 .. streams)
            out_ ~= frame(1, 0x5, 1 + 2 * i, getSlow);
        if (!sendAll(fd, out_))
        {
            printf("send failed\n");
            return 1;
        }
        fds ~= fd;
    }

    size_t ok, bad;
    foreach (fd; fds)
    {
        ubyte[] buf;
        bool[uint] done;
        while (done.length < streams)
        {
            while (buf.length < 9 || buf.length < 9 + ((buf[0] << 16) | (buf[1] << 8) | buf[2]))
            {
                ubyte[65_536] tmp;
                auto n = read(fd, tmp.ptr, tmp.length);
                if (n < 0 && errno == EINTR)
                    continue;
                if (n <= 0)
                {
                    printf("connection ended with %zu of %u streams answered\n", done.length, streams);
                    return 1;
                }
                buf ~= tmp[0 .. n];
            }
            immutable len = (buf[0] << 16) | (buf[1] << 8) | buf[2];
            immutable type = buf[3], flags = buf[4];
            immutable sid = ((buf[5] & 0x7f) << 24) | (buf[6] << 16) | (buf[7] << 8) | buf[8];
            if (type == 4 && !(flags & 1))
                sendAll(fd, frame(4, 1, 0, null));
            else if (type == 0 && (flags & 1))
            {
                done[sid] = true;
                ok += buf[9 .. 9 + len] == cast(const(ubyte)[]) "ok";
            }
            else if (type == 3 || type == 7)
            {
                bad++;
                done[sid] = true;
            }
            buf = buf[9 + len .. $].dup;
        }
        close(fd);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("%zu streams answered over %u HTTP/2 connections in %ld ms (handler waits %ld ms); %zu errors\n",
        ok, conns, ms, waitMs, bad);
    return ok == conns * streams && bad == 0 ? 0 : 1;
}
