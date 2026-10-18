/// Load generator for the WebSocket memory test (tools/check.sh): opens N WebSockets on `/ws`, sends a message on each
/// and reads the echo, holds them all open for `holdMs`, then closes them with a close handshake. With `h2`, the
/// WebSockets are HTTP/2 streams (RFC 8441), `perConn` of them on each connection.
/// Usage: ws_loadgen <port> <websockets> <holdMs> [h2 <perConn>]
/// Exits with code 1 if any WebSocket fails.
module ws_loadgen 2025;

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

// ---------------------------------------------------------------- HTTP/2 (RFC 8441)

ubyte[] h2frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

/// HPACK literal fields without indexing (names and values under 127 bytes, no Huffman).
ubyte[] literal(string[2][] fields...)
{
    ubyte[] b;
    foreach (f; fields)
        b ~= cast(ubyte[]) [0, cast(ubyte) f[0].length] ~ cast(const(ubyte)[]) f[0] ~ cast(ubyte) f[1].length
            ~ cast(const(ubyte)[]) f[1];
    return b;
}

/// One connection with `streams` WebSockets: what each stream has received so far.
struct H2Conn
{
    int fd;
    ubyte[] inbuf;
    ubyte[][uint] got; // DATA payloads per stream
}

/// Reads frames until `done` holds; answers SETTINGS, gives every DATA back (WINDOW_UPDATE). False on EOF/timeout.
bool pump(ref H2Conn c, scope bool delegate() done)
{
    while (!done())
    {
        while (c.inbuf.length < 9 || c.inbuf.length < 9 + ((c.inbuf[0] << 16) | (c.inbuf[1] << 8) | c.inbuf[2]))
        {
            ubyte[16_384] tmp;
            auto n = read(c.fd, tmp.ptr, tmp.length);
            if (n <= 0)
                return false;
            c.inbuf ~= tmp[0 .. n];
        }
        immutable len = (c.inbuf[0] << 16) | (c.inbuf[1] << 8) | c.inbuf[2];
        immutable type = c.inbuf[3], flags = c.inbuf[4];
        immutable sid = ((c.inbuf[5] & 0x7f) << 24) | (c.inbuf[6] << 16) | (c.inbuf[7] << 8) | c.inbuf[8];
        auto payload = c.inbuf[9 .. 9 + len].dup;
        c.inbuf = c.inbuf[9 + len .. $].dup;
        if (type == 4 && !(flags & 1) && !sendAll(c.fd, h2frame(4, 1, 0, null)))
            return false;
        if (type == 0 && payload.length)
        {
            c.got[sid] ~= payload;
            ubyte[4] inc = [0, 0, cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length];
            if (!sendAll(c.fd, h2frame(8, 0, 0, inc[]) ~ h2frame(8, 0, sid, inc[])))
                return false;
        }
        if (type == 3 || type == 7)
            return false; // RST_STREAM or GOAWAY: something went wrong
    }
    return true;
}

int mainH2(ushort port, int n, int holdMs, int perConn)
{
    static immutable ubyte[8] hi = [0x81, 0x82, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2];
    static immutable ubyte[8] closeFrame = [0x88, 0x82, 1, 2, 3, 4, 0x03 ^ 1, 0xE8 ^ 2];
    auto connect_ = literal([":method", "CONNECT"], [":protocol", "websocket"], [":scheme", "http"], [":path", "/ws"],
        [":authority", "t"], ["sec-websocket-version", "13"]);
    H2Conn[] conns;
    int failures, opened;
    auto t0 = MonoTime.currTime;
    for (int left = n; left > 0; left -= perConn)
    {
        immutable k = left < perConn ? left : perConn;
        H2Conn c;
        c.fd = dial(port);
        ubyte[] burst = cast(ubyte[]) "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".dup ~ h2frame(4, 0, 0, null);
        foreach (i; 0 .. k)
        {
            immutable sid = cast(uint)(1 + 2 * i);
            burst ~= h2frame(1, 0x4, sid, connect_) ~ h2frame(0, 0, sid, hi[]);
            c.got[sid] = null;
        }
        // every stream's echo is the 4 bytes 81 02 'h' 'i'
        bool echoed()
        {
            foreach (sid, b; c.got)
                if (b.length < 4)
                    return false;
            return true;
        }
        if (c.fd < 0 || !sendAll(c.fd, burst) || !pump(c, &echoed))
        {
            failures += k;
            if (c.fd >= 0)
                close(c.fd);
            continue;
        }
        foreach (sid, b; c.got)
            if (b[0 .. 4] != [0x81, 0x02, 'h', 'i'])
                failures++;
        opened += k;
        conns ~= c;
    }
    immutable openMs = (MonoTime.currTime - t0).total!"msecs";
    Thread.sleep(holdMs.msecs);
    foreach (ref c; conns)
    {
        ubyte[] burst;
        foreach (sid, ref b; c.got)
        {
            b = null;
            burst ~= h2frame(0, 0, sid, closeFrame[]);
        }
        bool answered()
        {
            foreach (sid, b; c.got)
                if (b.length < 4 || b[0] != 0x88)
                    return false;
            return true;
        }
        if (!sendAll(c.fd, burst) || !pump(c, &answered))
            failures += cast(int) c.got.length;
        close(c.fd);
    }
    printf("%d WebSockets over HTTP/2 (%d connections) opened in %ld ms, held %d ms, closed; %d failures\n", opened,
        cast(int) conns.length, openMs, holdMs, failures);
    return failures ? 1 : 0;
}

int main(string[] args)
{
    immutable port = args[1].to!ushort;
    immutable n = args[2].to!int;
    immutable holdMs = args[3].to!int;
    if (args.length > 5 && args[4] == "h2")
        return mainH2(port, n, holdMs, args[5].to!int);
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
