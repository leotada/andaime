/// HTTPS network tests: the EpollLoop with a TLS listener, and a blocking OpenSSL client with
/// ALPN control. Covers ALPN selection (h2, http/1.1, none, http2 disabled), HTTP/1.1 and
/// HTTP/2 over TLS (keep-alive, pipelining, large bodies both ways, partial writes, cancellation),
/// handshake deadline, garbage instead of a handshake, h2c/prior knowledge refused over TLS,
/// certificate reload (good and bad files), configuration errors, and many connections.
///
/// The module sits in the `vela.engine` package only to reach the raw OpenSSL table, which is
/// package-protected (`vela.engine.tls`); nothing outside tests does this.
/// Skips itself (exit 0 with a warning) when OpenSSL 3 or the `openssl` command is missing.
module vela.engine.tls_net;

version (linux):

import vela;
import vela.engine;
import vela.engine.tls;
import vela.engine.tlsserver : TlsServer, TicketKeys;
import vela.http;
import vela.http.hpack : encodeField;
import vela.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad;
import core.thread : Thread;
import core.time;
import core.stdc.errno : errno, EINTR;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import std.conv : to;
import std.string : indexOf;

// ---------------------------------------------------------------- test app

shared int cleanups;

@safe:

string fast() => "ok";

string nap(int ms)
{
    sleep(msecs(ms));
    return "slept";
}

string cancelMe()
{
    scope (exit)
        atomicOp!"+="(cleanups, 1);
    sleep(seconds(10));
    return "never";
}

string big(int kib)
{
    auto s = new char[kib * 1024];
    foreach (i, ref ch; s)
        ch = cast(char)('a' + i % 26);
    return s.idup;
}

string bodyLen(Context c) => c.request.body.length.to!string;

string proto(Context c) => c.request.protocol == Protocol.http2 ? "h2" : "http/1.1";

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/big/{kib}", big);
    app.post!("/len", bodyLen);
    app.get!("/proto", proto);
    return app;
}

// ---------------------------------------------------------------- certificates

@system:

string dir;

/// Self-signed EC certificate for localhost/127.0.0.1, named `<name>.pem` / `<name>.key`.
bool makeCert(string name, string cn = "localhost")
{
    import std.process : execute;

    auto r = execute(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-keyout", dir ~ "/" ~ name ~ ".key", "-out", dir ~ "/" ~ name ~ ".pem", "-days", "2",
        "-subj", "/CN=" ~ cn, "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"]);
    return r.status == 0;
}

// ---------------------------------------------------------------- test server

struct Server
{
    EpollLoop loop;
    Thread thread;
    ushort port;
}

Server start(ServerConfig cfg, string cert = "a")
{
    cfg.port = 0;
    cfg.workers = 1;
    cfg.host = "127.0.0.1";
    cfg.reusePort = false;
    if (cfg.tls.certFile.length == 0)
    {
        cfg.tls.certFile = dir ~ "/" ~ cert ~ ".pem";
        cfg.tls.keyFile = dir ~ "/" ~ cert ~ ".key";
    }
    auto loop = new EpollLoop;
    auto factory = handlerFactory(buildApp());
    auto t = new Thread({ loop.run(cfg, factory); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(loop.ready))
            return Server(loop, t, loop.boundPort);
        Thread.sleep(5.msecs);
    }
    assert(0, "server did not become ready");
}

void stop(ref Server s)
{
    s.loop.stop();
    s.thread.join();
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 5)
    {
        if (cond())
            return true;
        Thread.sleep(5.msecs);
    }
    return cond();
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

// ---------------------------------------------------------------- blocking TLS client

int dial(ushort port, int rcvTimeoutMs = 5000)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0, "connect failed");
    timeval tv = timeval(rcvTimeoutMs / 1000, (rcvTimeoutMs % 1000) * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

final class TlsClient
{
    int fd = -1;
    SSL_CTX* ctx;
    SSL* ssl;
    string error; /// handshake failure, if any
    ubyte[] pending;

    /// `alpn`: protocols to offer (empty = no ALPN extension). `ca`: the certificate to trust.
    this(ushort port, string ca, string[] alpn = ["h2", "http/1.1"], int rcvTimeoutMs = 5000)
    {
        fd = dial(port, rcvTimeoutMs);
        ctx = tls.SSL_CTX_new(tls.TLS_client_method());
        tls.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
        auto caZ = ca ~ '\0';
        assert(tls.SSL_CTX_load_verify_locations(ctx, caZ.ptr, null) == 1, "cannot load " ~ ca);
        ssl = tls.SSL_new(ctx);
        tls.SSL_set_fd(ssl, fd);
        tls.SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, cast(void*) "localhost\0".ptr);
        tls.SSL_set1_host(ssl, "localhost\0".ptr);
        if (alpn.length)
        {
            ubyte[] wire;
            foreach (p; alpn)
                wire ~= cast(ubyte) p.length ~ cast(ubyte[]) p.dup;
            tls.SSL_set_alpn_protos(ssl, wire.ptr, cast(uint) wire.length);
        }
        tls.SSL_set_connect_state(ssl);
        for (;;)
        {
            tls.ERR_clear_error();
            immutable r = tls.SSL_connect(ssl);
            if (r == 1)
                break;
            immutable e = tls.SSL_get_error(ssl, r);
            if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) && errno == EINTR)
                continue;
            immutable code = tls.ERR_get_error();
            char[256] buf = 0;
            tls.ERR_error_string_n(code, buf.ptr, buf.length);
            error = "handshake failed: " ~ buf[0 .. indexOfZero(buf)].idup;
            tls.ERR_clear_error();
            return;
        }
    }

    bool ok() const => error is null;

    string alpn()
    {
        const(ubyte)* p;
        uint n;
        tls.SSL_get0_alpn_selected(ssl, &p, &n);
        return n ? (cast(const(char)[]) p[0 .. n]).idup : "";
    }

    void send(const(ubyte)[] b)
    {
        while (b.length)
        {
            tls.ERR_clear_error();
            immutable r = tls.SSL_write(ssl, b.ptr, cast(int) b.length);
            if (r > 0)
            {
                b = b[r .. $];
                continue;
            }
            immutable e = tls.SSL_get_error(ssl, r);
            if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) && errno == EINTR)
                continue;
            assert(0, "TLS send failed");
        }
    }

    void send(string s) => send(cast(const(ubyte)[]) s);

    /// Appends what arrives to `pending`. False on EOF, error or the receive timeout.
    bool more(size_t max = 65_536)
    {
        auto buf = new ubyte[max];
        for (;;)
        {
            tls.ERR_clear_error();
            immutable r = tls.SSL_read(ssl, buf.ptr, cast(int) buf.length);
            if (r > 0)
            {
                pending ~= buf[0 .. r];
                return true;
            }
            immutable e = tls.SSL_get_error(ssl, r);
            if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) && errno == EINTR)
                continue;
            tls.ERR_clear_error();
            return false;
        }
    }

    void hang()
    {
        if (ssl !is null)
            tls.SSL_free(ssl);
        if (ctx !is null)
            tls.SSL_CTX_free(ctx);
        if (fd >= 0)
            close(fd);
        ssl = null;
        ctx = null;
        fd = -1;
    }
}

size_t indexOfZero(const(char)[] b)
{
    foreach (i, c; b)
        if (c == 0)
            return i;
    return b.length;
}

// ---------------------------------------------------------------- HTTP/1.1 over the client

struct Resp
{
    int status;
    string head, body;
    bool closed;
}

Resp rx(TlsClient c)
{
    Resp r;
    while ((cast(string) c.pending).indexOf("\r\n\r\n") < 0)
        if (!c.more())
        {
            r.closed = true;
            return r;
        }
    auto all = cast(string) c.pending;
    auto he = all.indexOf("\r\n\r\n") + 4;
    r.head = all[0 .. he].idup;
    r.status = r.head[9 .. 12].to!int;
    size_t want = 0;
    auto cl = r.head.indexOf("Content-Length: ");
    if (cl >= 0)
        want = r.head[cl + 16 .. r.head.indexOf("\r\n", cl)].to!size_t;
    while (c.pending.length < he + want)
        if (!c.more())
        {
            r.closed = true;
            return r;
        }
    r.body = (cast(string) c.pending[he .. he + want]).idup;
    c.pending = c.pending[he + want .. $].dup;
    return r;
}

Resp get1(TlsClient c, string path)
{
    c.send("GET " ~ path ~ " HTTP/1.1\r\nHost: localhost\r\n\r\n");
    return rx(c);
}

// ---------------------------------------------------------------- HTTP/2 over the client

ubyte[] frame(ubyte type, ubyte flags, uint sid, const(ubyte)[] payload)
{
    ubyte[] f = [cast(ubyte)(payload.length >> 16), cast(ubyte)(payload.length >> 8), cast(ubyte) payload.length,
        type, flags, cast(ubyte)(sid >> 24), cast(ubyte)(sid >> 16), cast(ubyte)(sid >> 8), cast(ubyte) sid];
    return f ~ payload;
}

ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

ubyte[] getBlock(string path)
{
    ByteBuffer b;
    encodeField(b, ":method", "GET");
    encodeField(b, ":scheme", "https");
    encodeField(b, ":path", path);
    encodeField(b, ":authority", "localhost");
    return cast(ubyte[]) b.data.dup;
}

/// Starts HTTP/2 on an ALPN-h2 connection and sends GETs on streams 1, 3, 5...
void h2Start(TlsClient c)
{
    c.send(cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, null));
}

/// Reads frames until every listed stream ended; returns each stream's DATA, or "RST" when reset.
string[uint] h2Collect(TlsClient c, uint[] sids, uint* goAway = null)
{
    string[uint] body;
    bool[uint] done;
    while (done.length < sids.length)
    {
        while (c.pending.length < 9 || c.pending.length < 9 + ((c.pending[0] << 16) | (c.pending[1] << 8) | c.pending[2]))
            if (!c.more())
                return body;
        auto p = c.pending;
        immutable len = (p[0] << 16) | (p[1] << 8) | p[2];
        immutable type = p[3], flags = p[4];
        immutable sid = ((p[5] & 0x7f) << 24) | (p[6] << 16) | (p[7] << 8) | p[8];
        auto payload = p[9 .. 9 + len].dup;
        c.pending = p[9 + len .. $].dup;
        if (type == 4 && !(flags & 1))
            c.send(frame(4, 1, 0, null));
        else if (type == 0)
        {
            body[sid] ~= cast(string) payload;
            if (len)
            {
                c.send(frame(8, 0, 0, u32(len)));
                if (!(flags & 1))
                    c.send(frame(8, 0, sid, u32(len)));
            }
            if (flags & 1)
                done[sid] = true;
        }
        else if (type == 1 && (flags & 1))
            done[sid] = true;
        else if (type == 3)
        {
            body[sid] = "RST";
            done[sid] = true;
        }
        else if (type == 7 && goAway !is null)
            *goAway = (payload[4] << 24) | (payload[5] << 16) | (payload[6] << 8) | payload[7];
    }
    return body;
}

// ---------------------------------------------------------------- tests

string ca(string name = "a") => dir ~ "/" ~ name ~ ".pem";

void testAlpn()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto c = new TlsClient(s.port, ca, ["h2", "http/1.1"]);
    assert(c.ok, c.error);
    assert(c.alpn == "h2");
    c.hang();
    c = new TlsClient(s.port, ca, ["http/1.1", "h2"]); // server preference wins
    assert(c.alpn == "h2");
    c.hang();
    c = new TlsClient(s.port, ca, ["http/1.1"]);
    assert(c.alpn == "http/1.1");
    assert(get1(c, "/proto").body == "http/1.1");
    c.hang();
    c = new TlsClient(s.port, ca, []); // no ALPN at all: HTTP/1.1
    assert(c.ok && c.alpn == "");
    assert(get1(c, "/proto").body == "http/1.1");
    c.hang();
    c = new TlsClient(s.port, ca, ["spdy/3", "foo"]); // nothing we speak: no ALPN, HTTP/1.1
    assert(c.ok && c.alpn == "");
    assert(get1(c, "/proto").body == "http/1.1");
    c.hang();

    ServerConfig noH2;
    noH2.http2 = false;
    auto s2 = start(noH2);
    scope (exit) stop(s2);
    c = new TlsClient(s2.port, ca, ["h2", "http/1.1"]);
    assert(c.alpn == "http/1.1", "http2 = false must not offer h2");
    c.hang();
    c = new TlsClient(s2.port, ca, ["h2"]);
    assert(c.ok && c.alpn == "");
    assert(get1(c, "/proto").body == "http/1.1");
    c.hang();
    ok("ALPN: h2 preferred, http/1.1, no ALPN and unknown protocols served as HTTP/1.1, h2 off when http2 = false");
}

void testHttp1OverTls()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new TlsClient(s.port, ca, ["http/1.1"]);
    foreach (i; 0 .. 3)
        assert(get1(c, "/fast").body == "ok", "keep-alive over TLS");
    // pipelining: three requests in one write, a slow one in the middle
    c.send("GET /fast HTTP/1.1\r\nHost: l\r\n\r\nGET /nap/50 HTTP/1.1\r\nHost: l\r\n\r\nGET /fast HTTP/1.1\r\nHost: l\r\n\r\n");
    assert(rx(c).body == "ok" && rx(c).body == "slept" && rx(c).body == "ok");
    // upload above the buffer classes, then a large response read slowly (partial writes)
    auto body = new char[900_000];
    body[] = 'u';
    c.send("POST /len HTTP/1.1\r\nHost: l\r\nContent-Length: 900000\r\n\r\n" ~ body.idup);
    assert(rx(c).body == "900000");
    c.send("GET /big/8192 HTTP/1.1\r\nHost: l\r\n\r\n");
    Thread.sleep(300.msecs); // the server fills the socket and waits for EPOLLOUT
    auto r = rx(c);
    assert(r.status == 200 && r.body.length == 8192 * 1024);
    foreach (i, ch; r.body)
        if (ch != cast(char)('a' + i % 26))
            assert(0, "body corrupted over TLS");
    c.hang();
    ok("HTTP/1.1 over TLS: keep-alive, pipelining, 900 KB upload, 8 MiB response with partial writes");
}

void testHttp2OverTls()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = new TlsClient(s.port, ca);
    assert(c.alpn == "h2");
    h2Start(c);
    uint[] ids;
    foreach (i; 0 .. 30)
    {
        immutable sid = cast(uint)(1 + 2 * i);
        c.send(frame(1, 0x5, sid, getBlock(i == 29 ? "/big/2048" : i % 2 ? "/nap/200" : "/proto")));
        ids ~= sid;
    }
    immutable t0 = MonoTime.currTime;
    auto got = h2Collect(c, ids);
    assert((MonoTime.currTime - t0).total!"msecs" < 1500, "streams over TLS should run concurrently");
    foreach (i, sid; ids[0 .. $ - 1])
        assert(got[sid] == (i % 2 ? "slept" : "h2"), got[sid]);
    assert(got[ids[$ - 1]].length == 2048 * 1024);
    c.hang();
    assert(s.loop.stats().http2Connections == 1);
    ok("HTTP/2 over TLS (ALPN h2): 30 multiplexed streams, 2 MiB response");
}

void testCancellationOverTls()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    immutable before = atomicLoad(cleanups);
    auto c = new TlsClient(s.port, ca, ["http/1.1"]);
    c.send("GET /cancel HTTP/1.1\r\nHost: l\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    c.hang();
    assert(waitFor(() => atomicLoad(cleanups) == before + 1 && s.loop.stats().inFlight == 0, 1000),
        "HTTP/1.1 over TLS: disconnect should cancel the handler");

    c = new TlsClient(s.port, ca);
    h2Start(c);
    c.send(frame(1, 0x5, 1, getBlock("/cancel")) ~ frame(1, 0x5, 3, getBlock("/cancel")));
    assert(waitFor(() => s.loop.stats().inFlight == 2, 1000));
    c.send(frame(3, 0, 1, u32(8))); // RST_STREAM on one of them
    assert(waitFor(() => atomicLoad(cleanups) == before + 2, 1000), "RST_STREAM over TLS");
    c.hang();
    assert(waitFor(() => atomicLoad(cleanups) == before + 3 && s.loop.stats().inFlight == 0, 1000));
    assert(waitFor(() => s.loop.stats().connections == 0, 500));

    // a client that leaves in the middle of a large response: OpenSSL's write(2) hits a reset
    // socket; SIGPIPE must not kill the server (it once did)
    foreach (alpn; [["http/1.1"], ["h2"]])
    {
        c = new TlsClient(s.port, ca, alpn);
        if (c.alpn == "h2")
        {
            h2Start(c);
            c.send(frame(1, 0x5, 1, getBlock("/big/8192")));
        }
        else
            c.send("GET /big/8192 HTTP/1.1\r\nHost: l\r\n\r\n");
        c.more(); // the first bytes arrived: the server is writing
        import core.sys.posix.sys.socket : linger, SO_LINGER;

        linger lg = linger(1, 0); // close with RST
        setsockopt(c.fd, SOL_SOCKET, SO_LINGER, &lg, lg.sizeof);
        c.hang();
    }
    Thread.sleep(200.msecs);
    auto after = new TlsClient(s.port, ca, ["http/1.1"]);
    assert(get1(after, "/fast").body == "ok", "the server must survive clients resetting mid-response");
    after.hang();
    ok("cancellation over TLS: disconnect (HTTP/1.1), RST_STREAM and disconnect (HTTP/2), reset mid-response");
}

void testHandshakeFailures()
{
    ServerConfig cfg;
    cfg.headerTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);

    // connects and never starts the handshake: closed by the deadline
    immutable t0 = MonoTime.currTime;
    auto fd = dial(s.port);
    ubyte[16] b;
    auto n = read(fd, b.ptr, b.length);
    close(fd);
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(n <= 0 && ms >= 250 && ms < 1500, "idle handshake should be closed after headerTimeoutMs");

    // cleartext HTTP to the TLS port: refused, the server goes on
    fd = dial(s.port);
    auto req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    send(fd, req.ptr, req.length, 0);
    n = read(fd, b.ptr, b.length);
    close(fd);
    assert(n <= 0 || b[0] == 0x15, "plain HTTP must not be answered as HTTP"); // 0x15 = TLS alert

    // a client that does not trust the certificate: the handshake fails on its side
    auto bad = new TlsClient(s.port, ca("b"));
    assert(!bad.ok && bad.error.indexOf("certificate verify failed") >= 0, bad.error);
    bad.hang();

    // prior knowledge and h2c are cleartext features: over TLS they are plain HTTP/1.1
    auto c = new TlsClient(s.port, ca, ["http/1.1"]);
    c.send(cast(const(ubyte)[]) clientPreface ~ frame(4, 0, 0, null));
    auto r = rx(c);
    assert(r.status == 501, "PRI over TLS without ALPN h2 is not HTTP/2: " ~ r.head);
    c.hang();
    c = new TlsClient(s.port, ca, ["http/1.1"]);
    c.send("GET /proto HTTP/1.1\r\nHost: l\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABk\r\n\r\n");
    r = rx(c);
    assert(r.status == 200 && r.body == "http/1.1", "Upgrade: h2c must be ignored over TLS");
    c.hang();

    assert(waitFor(() => s.loop.stats().connections == 0, 1000));
    assert(s.loop.stats().tlsFailures >= 3, s.loop.stats().tlsFailures.to!string);
    assert(get1(new TlsClient(s.port, ca, ["http/1.1"]), "/fast").body == "ok", "server still healthy");
    ok("handshake: deadline, cleartext and untrusted clients refused; prior knowledge and h2c ignored over TLS");
}

void testReload()
{
    import std.file : copy, rename, write;

    // live files the server watches, starting as certificate "a"
    copy(ca("a"), dir ~ "/live.pem");
    copy(dir ~ "/a.key", dir ~ "/live.key");
    ServerConfig cfg;
    cfg.tls.certFile = dir ~ "/live.pem";
    cfg.tls.keyFile = dir ~ "/live.key";
    cfg.tls.reloadCheckMs = 50;
    auto s = start(cfg);
    scope (exit) stop(s);

    auto old = new TlsClient(s.port, ca("a"), ["http/1.1"]);
    assert(old.ok, old.error);

    // renewal: new files written next to the old ones and renamed into place (like certbot)
    copy(ca("b"), dir ~ "/live.pem.new");
    copy(dir ~ "/b.key", dir ~ "/live.key.new");
    rename(dir ~ "/live.key.new", dir ~ "/live.key");
    rename(dir ~ "/live.pem.new", dir ~ "/live.pem");
    assert(waitFor(() => s.loop.stats().tlsReloads == 1, 2000), "the certificate should be reloaded");
    auto fresh = new TlsClient(s.port, ca("b"), ["http/1.1"]);
    assert(fresh.ok, "new connections get the new certificate: " ~ fresh.error);
    auto stale = new TlsClient(s.port, ca("a"), ["http/1.1"]);
    assert(!stale.ok, "the old certificate is no longer served");
    stale.hang();
    assert(get1(old, "/fast").body == "ok", "a connection made before the reload keeps working");
    old.hang();
    fresh.hang();

    // a broken file is logged and the current certificate stays
    write(dir ~ "/live.pem", "not a certificate");
    Thread.sleep(600.msecs);
    assert(s.loop.stats().tlsReloads == 1);
    auto still = new TlsClient(s.port, ca("b"), ["http/1.1"]);
    assert(still.ok, "a failed reload must keep serving the previous certificate");
    still.hang();
    ok("certificate reload: renamed files picked up, old connections unaffected, a broken file keeps the old one");
}

void testConfigErrors()
{
    TlsServer t;
    auto keys = TicketKeys.random();
    TlsConfig bad;
    bad.certFile = dir ~ "/missing.pem";
    bad.keyFile = dir ~ "/a.key";
    auto e = t.load(bad, true, keys);
    assert(e.indexOf("vela: TLS: cannot load the certificate chain") == 0, e);
    bad.certFile = ca("a");
    bad.keyFile = dir ~ "/b.key";
    e = t.load(bad, true, keys);
    assert(e.indexOf("vela: TLS: the private key " ~ dir ~ "/b.key does not match the certificate") == 0, e);
    bad.keyFile = dir ~ "/missing.key";
    e = t.load(bad, true, keys);
    assert(e.indexOf("vela: TLS: cannot load the private key") == 0, e);
    TlsServer good;
    bad.keyFile = dir ~ "/a.key";
    assert(good.load(bad, true, keys) is null);

    // EpollLoop.run refuses to start with a bad configuration
    ServerConfig cfg;
    cfg.tls.certFile = dir ~ "/missing.pem";
    cfg.tls.keyFile = dir ~ "/a.key";
    cfg.port = 0;
    cfg.workers = 1;
    cfg.host = "127.0.0.1";
    auto loop = new EpollLoop;
    loop.run(cfg, handlerFactory(buildApp())); // returns at once, after printing the error
    assert(!atomicLoad(loop.ready));
    ok("configuration errors: missing certificate, missing key, mismatched key; the loop does not start");
}

void testManyConnections()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    TlsClient[] cs;
    foreach (i; 0 .. 100)
    {
        auto c = new TlsClient(s.port, ca, i % 2 ? ["h2"] : ["http/1.1"]);
        assert(c.ok, c.error);
        if (c.alpn == "h2")
        {
            h2Start(c);
            c.send(frame(1, 0x5, 1, getBlock("/nap/300")));
        }
        else
            c.send("GET /nap/300 HTTP/1.1\r\nHost: l\r\n\r\n");
        cs ~= c;
    }
    assert(waitFor(() => s.loop.stats().inFlight == 100, 2000), "100 TLS requests in flight at once");
    foreach (c; cs)
    {
        if (c.alpn == "h2")
            assert(h2Collect(c, [1])[1] == "slept");
        else
            assert(rx(c).body == "slept");
        c.hang();
    }
    assert(waitFor(() => s.loop.stats().connections == 0 && s.loop.stats().inFlight == 0, 1000));
    assert(s.loop.stats().tlsHandshakes >= 100);
    ok("100 TLS connections (half h2, half HTTP/1.1) with requests in flight at once, all recycled");
}

void main()
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.process : thisProcessID;

    if (auto e = loadOpenSsl())
    {
        printf("warning: %.*s; skipping the TLS tests\n", cast(int) e.length, e.ptr);
        return;
    }
    dir = tempDir ~ "/vela_tls_" ~ thisProcessID.to!string;
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    if (!makeCert("a") || !makeCert("b", "other"))
    {
        printf("warning: the openssl command is missing; skipping the TLS tests\n");
        return;
    }
    testAlpn();
    testHttp1OverTls();
    testHttp2OverTls();
    testCancellationOverTls();
    testHandshakeFailures();
    testReload();
    testConfigErrors();
    testManyConnections();
    printf("all TLS network tests passed\n");
}
