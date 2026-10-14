/// Load generator for the WebSocket memory test (tools/check.sh): opens N WebSockets on `/ws`, sends a message on each
/// and reads the echo, holds them all open for `holdMs`, then closes them with a close handshake.
/// Usage: ws_loadgen <port> <connections> <holdMs>
/// Exits with code 1 if any connection fails.
module ws_loadgen;

import core.thread, core.time;
import core.stdc.stdio, core.stdc.string;
import core.sys.posix.sys.socket, core.sys.posix.netinet.in_, core.sys.posix.unistd;
import core.sys.posix.sys.time : timeval;
import std.conv : to;

int dial(ushort port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, cast(sockaddr*)&a, a.sizeof) != 0)
        return -1;
    timeval tv = timeval(10, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

bool sendAll(int fd, const(void)[] b)
{
    while (b.length)
    {
        auto n = send(fd, b.ptr, b.length, 0x4000);
        if (n <= 0)
            return false;
        b = b[n .. $];
    }
    return true;
}

/// Reads until `want` bytes (or the end of a head with want == 0).
bool readExact(int fd, ubyte[] into)
{
    size_t got;
    while (got < into.length)
    {
        auto n = read(fd, into.ptr + got, into.length - got);
        if (n <= 0)
            return false;
        got += n;
    }
    return true;
}

bool readHead(int fd)
{
    char[1024] b;
    size_t got;
    while (got < b.length)
    {
        auto n = read(fd, b.ptr + got, 1);
        if (n <= 0)
            return false;
        got++;
        if (got >= 4 && b[got - 4 .. got] == "\r\n\r\n")
            return strncmp(b.ptr, "HTTP/1.1 101", 12) == 0;
    }
    return false;
}

int main(string[] args)
{
    immutable port = args[1].to!ushort;
    immutable n = args[2].to!int;
    immutable holdMs = args[3].to!int;
    enum upgrade = "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        ~ "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    // "hi", masked with 0x01020304; the echo is unmasked
    static immutable ubyte[8] hi = [0x81, 0x82, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2];
    static immutable ubyte[8] closeFrame = [0x88, 0x82, 1, 2, 3, 4, 0x03 ^ 1, 0xE8 ^ 2];
    int[] fds;
    int failures;
    auto t0 = MonoTime.currTime;
    foreach (i; 0 .. n)
    {
        auto fd = dial(port);
        ubyte[4] echo;
        if (fd < 0 || !sendAll(fd, upgrade) || !readHead(fd) || !sendAll(fd, hi) || !readExact(fd, echo)
            || echo != [0x81, 0x02, 'h', 'i'])
        {
            failures++;
            if (fd >= 0)
                close(fd);
            continue;
        }
        fds ~= fd;
    }
    immutable openMs = (MonoTime.currTime - t0).total!"msecs";
    Thread.sleep(holdMs.msecs);
    foreach (fd; fds)
    {
        ubyte[4] answer;
        if (!sendAll(fd, closeFrame) || !readExact(fd, answer) || answer[0] != 0x88)
            failures++;
        close(fd);
    }
    printf("%d WebSockets opened in %ld ms, held %d ms, closed; %d failures\n", cast(int) fds.length, openMs, holdMs,
        failures);
    return failures ? 1 : 0;
}
