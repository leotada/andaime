/// HTTPS load for the memory test (tools/check.sh): opens `connections` TLS connections
/// (handshakes one after another), sends `GET /slow` on each (HTTP/1.1, or HTTP/2 when the last
/// argument is "h2"), then reads every response.
/// Usage: tls_loadgen <port> <connections> <ca.pem> [h2]
/// Exits with code 1 on any failure.
///
/// In the `andaime.engine` package only to reach the raw OpenSSL table (package-protected).
module andaime.engine.tls_loadgen;

import andaime.engine.tls;
import core.time;
import core.stdc.errno : errno, EINTR;
import core.stdc.stdio : printf;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close;
import std.conv : to;

enum string preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
// HEADERS (END_STREAM | END_HEADERS) on stream 1: GET, https, :path /slow
immutable ubyte[] h2Request = [0, 0, 9, 1, 5, 0, 0, 0, 1, 0x82, 0x87, 0x04, 5, '/', 's', 'l', 'o', 'w'];

int main(string[] args)
{
    immutable port = args[1].to!ushort;
    immutable n = args[2].to!uint;
    auto caZ = args[3] ~ '\0';
    immutable h2 = args.length > 4 && args[4] == "h2";
    if (auto e = loadOpenSsl())
    {
        printf("%.*s\n", cast(int) e.length, e.ptr);
        return 1;
    }
    auto ctx = tls.SSL_CTX_new(tls.TLS_client_method());
    tls.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
    tls.SSL_CTX_load_verify_locations(ctx, caZ.ptr, null);

    auto t0 = MonoTime.currTime;
    SSL*[] conns;
    int[] fds;
    immutable(ubyte)[] alpn = h2 ? cast(immutable(ubyte)[]) "\x02h2" : cast(immutable(ubyte)[]) "\x08http/1.1";
    foreach (i; 0 .. n)
    {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        a.sin_addr.s_addr = htonl(0x7f000001);
        if (connect(fd, cast(sockaddr*)&a, a.sizeof) != 0)
        {
            printf("connect %u failed\n", i);
            return 1;
        }
        timeval tv = timeval(60, 0);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
        auto s = tls.SSL_new(ctx);
        tls.SSL_set_fd(s, fd);
        tls.SSL_ctrl(s, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, cast(void*) "localhost\0".ptr);
        tls.SSL_set_alpn_protos(s, alpn.ptr, cast(uint) alpn.length);
        int r;
        while ((r = tls.SSL_connect(s)) != 1)
        {
            immutable e = tls.SSL_get_error(s, r);
            if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) && errno == EINTR)
                continue;
            printf("handshake %u failed\n", i);
            return 1;
        }
        ubyte[] req = h2 ? cast(ubyte[]) preface.dup ~ cast(ubyte[])[0, 0, 0, 4, 0, 0, 0, 0, 0] ~ h2Request.dup
            : cast(ubyte[]) "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n".dup;
        if (tls.SSL_write(s, req.ptr, cast(int) req.length) != req.length)
        {
            printf("write %u failed\n", i);
            return 1;
        }
        conns ~= s;
        fds ~= fd;
    }
    immutable handshakeMs = (MonoTime.currTime - t0).total!"msecs";

    size_t ok;
    ubyte[16_384] buf;
    foreach (i, s; conns)
    {
        ubyte[] got;
        for (;;)
        {
            immutable r = tls.SSL_read(s, buf.ptr, cast(int) buf.length);
            if (r <= 0)
            {
                immutable e = tls.SSL_get_error(s, r);
                if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) && errno == EINTR)
                    continue;
                break;
            }
            got ~= buf[0 .. r];
            if (h2 ? endsStream1(got) : endsWithOk(got))
            {
                ok++;
                break;
            }
        }
        tls.SSL_free(s);
        close(fds[i]);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("%zu of %u HTTPS requests (%s) answered in %ld ms (%ld ms of handshakes)\n", ok, n,
        h2 ? "h2".ptr : "HTTP/1.1".ptr, ms, handshakeMs);
    return ok == n ? 0 : 1;
}

bool endsWithOk(const(ubyte)[] b) => b.length >= 2 && b[$ - 2 .. $] == cast(const(ubyte)[]) "ok"
    && (cast(const(char)[]) b).length > 12 && b[0 .. 12] == cast(const(ubyte)[]) "HTTP/1.1 200";

/// A DATA frame with END_STREAM on stream 1 carrying "ok" is somewhere in `b`.
bool endsStream1(const(ubyte)[] b)
{
    size_t p = 0;
    while (p + 9 <= b.length)
    {
        immutable len = (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];
        if (p + 9 + len > b.length)
            return false;
        if (b[p + 3] == 0 && (b[p + 4] & 1) && b[p + 8] == 1)
            return b[p + 9 .. p + 9 + len] == cast(const(ubyte)[]) "ok";
        p += 9 + len;
    }
    return false;
}
