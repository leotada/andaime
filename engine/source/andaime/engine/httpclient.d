/// Outgoing, cooperative HTTP/1.1 client: inside a request, every
/// wait (DNS, connect, TLS, send, response) suspends only the fiber.
///
/// ```d
/// auto r = httpClient().get("https://api.example.com/v1/quote?currency=USD");
/// if (r.ok) use(r.body);
/// ```
///
/// - HTTP and HTTPS (OpenSSL loaded at run time, certificate and
///   host name verification on by default);
/// - keep-alive connections reused per host (one pool per worker);
/// - Content-Length, chunked and until-close bodies; size limit, or read in pieces (`open`, `BodySource`);
/// - total deadline per request (`timeout`); cancelling the incoming request
///   closes the outgoing connection;
/// - does not follow redirects (3xx comes back as a response; read `Location`).
module andaime.engine.httpclient 2025;

import core.stdc.string : memchr, memcmp, memcpy, memmove, strlen;
import core.time : Duration, MonoTime, seconds, msecs;

version (Posix)
{
    import core.stdc.errno : errno, EAGAIN, EINTR, EINPROGRESS, EWOULDBLOCK, ECONNRESET, EPIPE;
    import core.sys.posix.netdb : addrinfo, getaddrinfo, freeaddrinfo, AI_ADDRCONFIG;
    import core.sys.posix.sys.socket : AF_UNSPEC, SOCK_STREAM, sockaddr_storage;
}
else version (Windows)
{
    import core.stdc.errno : errno, EINTR;
    import core.sys.windows.winsock2 : addrinfo, getaddrinfo, freeaddrinfo, AI_ADDRCONFIG,
        AF_UNSPEC, SOCK_STREAM, sockaddr_storage;
    enum EAGAIN = 11;
    enum EWOULDBLOCK = EAGAIN;
    enum EINPROGRESS = 115;
    enum ECONNRESET = 104;
    enum EPIPE = 32;
}

import andaime.engine.fiberio : awaitFd, IoEvent;
import andaime.engine.offload : offload;
import andaime.engine.os : sockOpenNonBlock, sockRead, sockSend, sockClose, sockSetTcpNoDelay,
    sockGetError, sockConnectInProgress, sockConnect;
import andaime.engine.tls;

// ============================================================ public types

/// Network, protocol or deadline failure.
class HttpClientError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The request deadline ended.
final class HttpClientTimeout : HttpClientError
{
    this(string what = "timed out", string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super("andaime.http: " ~ what, file, line);
    }
}

struct HeaderPair
{
    string name, value;
}

struct ClientResponse
{
    int status;
    HeaderPair[] headers;
    string body;

    bool ok() const pure nothrow @safe @nogc => status >= 200 && status < 300;

    /// Value of the first header `name` (case-insensitive), or null.
    string header(const(char)[] name) const pure nothrow @safe
    {
        foreach (h; headers)
            if (eqFold(h.name, name))
                return h.value;
        return null;
    }
}

public import andaime.http.types : BodySource; // defined with the HTTP types, so andaime:web can make one too

private enum BodyMode : ubyte { none, length, chunked, eof, memory }

/// A response whose body is read as it arrives (see `HttpClient.open`). `close` it when done: the connection goes back
/// to the pool if the body was read to the end, and is closed otherwise.
final class ClientStream
{
    int status;
    HeaderPair[] headers;
    /// The body's size from `Content-Length`, or -1 when the server did not announce it (chunked, until close).
    long contentLength = -1;

    private HttpClient client;
    private Conn c;
    private BodyMode mode;
    private ulong left;          // bytes left of the body (length) or of the current chunk (chunked)
    private bool done, keepAlive, chunkEnd;
    private Duration step;       // each wait gets this much (zero: all share `deadline`)
    private MonoTime deadline;
    private string mem;          // the body, from a test transport
    private size_t memPos;

    private this() pure nothrow @safe {}

    bool ok() const pure nothrow @safe @nogc => status >= 200 && status < 300;

    /// Value of the first header `name` (case-insensitive), or null.
    string header(const(char)[] name) const pure nothrow @safe
    {
        foreach (h; headers)
            if (eqFold(h.name, name))
                return h.value;
        return null;
    }

    /// Reads the next piece of the body into `into` and returns its size: 0 at the end (or when `into` is empty). A
    /// server that closes before the end throws `HttpClientError`; a wait past the timeout, `HttpClientTimeout`.
    size_t read(scope ubyte[] into) @trusted
    {
        if (done || into.length == 0)
            return 0;
        final switch (mode)
        {
        case BodyMode.none:
            done = true;
            return 0;
        case BodyMode.memory:
            immutable n = into.length < mem.length - memPos ? into.length : mem.length - memPos;
            into[0 .. n] = cast(const(ubyte)[]) mem[memPos .. memPos + n];
            memPos += n;
            done = memPos == mem.length;
            return n;
        case BodyMode.length:
            immutable n = take(into[0 .. left < into.length ? cast(size_t) left : $]);
            if (n == 0)
                throw new HttpClientError("andaime.http: server closed in the middle of the body");
            left -= n;
            done = left == 0;
            return n;
        case BodyMode.eof:
            immutable n = take(into);
            done = n == 0;
            return n;
        case BodyMode.chunked:
            if (left == 0 && !nextChunk())
                return 0;
            immutable n = take(into[0 .. left < into.length ? cast(size_t) left : $]);
            if (n == 0)
                throw new HttpClientError("andaime.http: server closed in the middle of the body");
            left -= n;
            return n;
        }
    }

    /// The rest of the body, at most `max` bytes (more is an error).
    package string readAll(size_t max) @trusted
    {
        if (mode == BodyMode.memory)
        {
            done = true;
            return mem;
        }
        if (mode == BodyMode.length)
        {
            if (left > max)
                throw new HttpClientError("andaime.http: response body larger than maxBody");
            auto out_ = new ubyte[cast(size_t) left];
            size_t got;
            while (got < out_.length)
                got += read(out_[got .. $]);
            return cast(string) out_;
        }
        ubyte[] out_;
        ubyte[8192] tmp;
        for (;;)
        {
            immutable n = read(tmp[]);
            if (n == 0)
                break;
            if (out_.length + n > max)
                throw new HttpClientError("andaime.http: response body larger than maxBody");
            out_ ~= tmp[0 .. n];
        }
        return cast(string) out_;
    }

    /// Ends the response: the connection goes back to the pool when the body was read to the end, else it is closed.
    /// Calling it again does nothing.
    void close() @trusted
    {
        if (c is null)
            return;
        auto conn = c;
        c = null;
        if (done && keepAlive && conn.rpos == conn.rend)
            client.giveBack(conn);
        else
            conn.closeNow();
    }

    /// Bytes already buffered, else what the socket has (waiting for it).
    private size_t take(scope ubyte[] into)
    {
        immutable have = c.rend - c.rpos;
        if (have == 0)
            return client.recvSome(c, into, HttpClient.nextWait(deadline, step));
        immutable n = have < into.length ? have : into.length;
        memcpy(into.ptr, c.rbuf.ptr + c.rpos, n);
        c.rpos += n;
        return n;
    }

    /// Reads the next chunk's size line (after the CRLF that ends the previous chunk); false at the last chunk, with
    /// its trailers skipped.
    private bool nextChunk()
    {
        if (chunkEnd && client.readLine(c, HttpClient.nextWait(deadline, step)).length != 0)
            throw new HttpClientError("andaime.http: malformed chunk");
        chunkEnd = true;
        auto line = client.readLine(c, HttpClient.nextWait(deadline, step));
        size_t semi = line.length;
        foreach (i, ch; line)
            if (ch == ';')
            {
                semi = i;
                break;
            }
        left = parseHex(line[0 .. semi]);
        if (left)
            return true;
        while (client.readLine(c, HttpClient.nextWait(deadline, step)).length)
        {
        }
        done = true;
        return false;
    }
}

struct HttpClientConfig
{
    Duration timeout = 30.seconds;        /// total deadline of each request
    Duration connectTimeout = 5.seconds;  /// DNS + TCP + TLS
    size_t maxBody = 8 << 20;             /// body larger than this → error
    size_t maxHead = 64 << 10;
    uint maxIdlePerHost = 8;
    Duration idleTimeout = 30.seconds;    /// idle connection discarded after this
    bool verifyTls = true;                /// turn off only in tests
    string caFile;                        /// extra CA (PEM); empty = system CAs
    string userAgent = "andaime";
}

// ============================================================ URL

struct ParsedUrl
{
    bool tls;
    string host;
    ushort port;
    string target; /// path + query, starts with '/'
}

ParsedUrl parseUrl(string url) @safe
{
    ParsedUrl u;
    string rest;
    if (url.length > 8 && url[0 .. 8] == "https://")
    {
        u.tls = true;
        u.port = 443;
        rest = url[8 .. $];
    }
    else if (url.length > 7 && url[0 .. 7] == "http://")
    {
        u.port = 80;
        rest = url[7 .. $];
    }
    else
        throw new HttpClientError("andaime.http: URL must start with http:// or https://: " ~ url);

    size_t slash = rest.length;
    foreach (i, ch; rest)
        if (ch == '/' || ch == '?' || ch == '#')
        {
            slash = i;
            break;
        }
    auto hostport = rest[0 .. slash];
    auto tail = rest[slash .. $];
    foreach (i, ch; tail)
        if (ch == '#')
        {
            tail = tail[0 .. i];
            break;
        }
    u.target = tail.length == 0 ? "/" : (tail[0] == '/' ? tail : "/" ~ tail);

    if (hostport.length && hostport[0] == '[') // IPv6 literal
    {
        size_t close_;
        foreach (i, ch; hostport)
            if (ch == ']')
            {
                close_ = i;
                break;
            }
        if (close_ == 0)
            throw new HttpClientError("andaime.http: malformed IPv6 URL: " ~ url);
        u.host = hostport[1 .. close_];
        hostport = hostport[close_ + 1 .. $];
        if (hostport.length)
        {
            if (hostport[0] != ':')
                throw new HttpClientError("andaime.http: malformed URL: " ~ url);
            u.port = parsePort(hostport[1 .. $], url);
        }
    }
    else
    {
        size_t colon = hostport.length;
        foreach (i, ch; hostport)
            if (ch == ':')
            {
                colon = i;
                break;
            }
        u.host = hostport[0 .. colon];
        if (colon < hostport.length)
            u.port = parsePort(hostport[colon + 1 .. $], url);
    }
    if (u.host.length == 0)
        throw new HttpClientError("andaime.http: URL without host: " ~ url);
    return u;
}

private ushort parsePort(string s, string url) @safe
{
    if (s.length == 0 || s.length > 5)
        throw new HttpClientError("andaime.http: invalid port in URL: " ~ url);
    uint v;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            throw new HttpClientError("andaime.http: invalid port in URL: " ~ url);
        v = v * 10 + (ch - '0');
    }
    if (v == 0 || v > 65535)
        throw new HttpClientError("andaime.http: invalid port in URL: " ~ url);
    return cast(ushort) v;
}

// ============================================================ DNS

private struct Addr
{
    sockaddr_storage ss;
    uint len;
    int family;
}

private Addr[] resolveBlocking(string host, ushort port) nothrow
{
    import core.stdc.stdio : snprintf;

    char[16] sport;
    snprintf(sport.ptr, sport.length, "%u", cast(uint) port);
    auto zhost = (host ~ '\0');

    addrinfo hints;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_ADDRCONFIG;
    addrinfo* res;
    if (getaddrinfo(zhost.ptr, sport.ptr, &hints, &res) != 0 || res is null)
        return null;
    Addr[] out_;
    for (auto p = res; p !is null; p = p.ai_next)
    {
        if (p.ai_addrlen > sockaddr_storage.sizeof)
            continue;
        Addr a;
        memcpy(&a.ss, p.ai_addr, p.ai_addrlen);
        a.len = cast(uint) p.ai_addrlen;
        a.family = p.ai_family;
        out_ ~= a;
    }
    freeaddrinfo(res);
    return out_;
}

// ============================================================ connection

package final class Conn // package: the WebSocket client (andaime.engine.wsclient) opens its connection here
{
    int fd = -1;
    SSL* ssl;
    string key;
    char[] rbuf;
    size_t rpos, rend;
    MonoTime lastUsed;
    bool reused;

    this() { rbuf = new char[4096]; }

    void closeNow() nothrow
    {
        if (ssl !is null)
        {
            tls.SSL_free(ssl);
            ssl = null;
        }
        if (fd >= 0)
        {
            sockClose(fd);
            fd = -1;
        }
    }

    bool alive() const nothrow => fd >= 0;
}

private Duration left(MonoTime deadline)
{
    immutable d = deadline - MonoTime.currTime;
    if (d <= Duration.zero)
        throw new HttpClientTimeout;
    return d;
}

/// Transport error BEFORE any byte of the response: may be worth retrying on a new connection.
private final class StaleConn : HttpClientError
{
    this() pure nothrow @safe { super("andaime.http: reused connection was already closed"); }
}

// ============================================================ client

final class HttpClient
{
    private HttpClientConfig cfg;
    private SSL_CTX* ctx;
    private Conn[][string] idle;
    private Addr[][string] dnsCache;
    private MonoTime[string] dnsExpiry;

    this(HttpClientConfig cfg = HttpClientConfig.init) @trusted { this.cfg = cfg; }

    /// Closes everything and releases the TLS context. (No destructor: a worker's client lives until the end.)
    void shutdown() @trusted
    {
        closeIdle();
        if (ctx !is null)
        {
            tls.SSL_CTX_free(ctx);
            ctx = null;
        }
    }

    /// Closes the idle connections.
    void closeIdle() nothrow @trusted // sound: closes connections this pool owns and forgets them
    {
        // byValue instead of foreach over the AA: older druntime's _aaApply is not nothrow
        foreach (list; idle.byValue)
            foreach (c; list)
                c.closeNow();
        idle = null;
    }

    size_t idleCount() const nothrow @trusted // sound: only counts
    {
        size_t n;
        foreach (list; idle.byValue)
            n += list.length;
        return n;
    }

    // Every call takes an optional `timeout`: the whole request's deadline for this call only (zero: the configured
    // `HttpClientConfig.timeout`). Bodies are text or bytes (`const(ubyte)[]`: an image, a protobuf, an encrypted
    // Web Push message); a `null` body is no body.

    ClientResponse get(string url, scope const(HeaderPair)[] headers = null, Duration timeout = Duration.zero) @trusted
        => request("GET", url, headers, null, timeout);

    ClientResponse post(string url, const(char)[] body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("POST", url, headers, body_, timeout);

    /// ditto, with a binary body.
    ClientResponse post(string url, const(ubyte)[] body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("POST", url, headers, cast(const(char)[]) body_, timeout);

    /// ditto, with no body (`post(url, null)`; without this overload `null` would match both of the above).
    ClientResponse post(string url, typeof(null), scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("POST", url, headers, null, timeout);

    ClientResponse put(string url, const(char)[] body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("PUT", url, headers, body_, timeout);

    /// ditto, with a binary body.
    ClientResponse put(string url, const(ubyte)[] body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("PUT", url, headers, cast(const(char)[]) body_, timeout);

    /// ditto, with no body.
    ClientResponse put(string url, typeof(null), scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("PUT", url, headers, null, timeout);

    ClientResponse del(string url, scope const(HeaderPair)[] headers = null, Duration timeout = Duration.zero) @trusted
        => request("DELETE", url, headers, null, timeout);

    /// POST of already-serialized JSON.
    ClientResponse postJson(string url, const(char)[] json, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("POST", url, headers ~ HeaderPair("Content-Type", "application/json"), json, timeout);

    /// Any method, with a binary body.
    ClientResponse request(string method, string url, scope const(HeaderPair)[] headers, const(ubyte)[] body_,
        Duration timeout = Duration.zero) @trusted
        => request(method, url, headers, cast(const(char)[]) body_, timeout);

    /// Any method, with no body.
    ClientResponse request(string method, string url, scope const(HeaderPair)[] headers, typeof(null),
        Duration timeout = Duration.zero) @trusted
        => request(method, url, headers, cast(const(char)[]) null, timeout);

    /// Any method, with a text body.
    ClientResponse request(string method, string url, scope const(HeaderPair)[] headers, const(char)[] body_,
        Duration timeout = Duration.zero) @trusted
    {
        parseUrl(url);
        if (transportOverride !is null)
            return transportOverride.send(method, url, headers, cast(const(ubyte)[]) body_, timeout);
        auto s = start(method, url, headers, body_, BodySource.init, timeout, false);
        scope (exit)
            s.close();
        ClientResponse r;
        r.status = s.status;
        r.headers = s.headers;
        r.body = s.readAll(cfg.maxBody);
        return r;
    }

    /// Any method, with a body sent in pieces (a file): see `BodySource`. The connection gets `timeout` as in the other
    /// calls; after it, each wait (a piece sent, the head, a piece of the response) gets `timeout` of its own, so a
    /// large body is not cut by a deadline sized for a small one.
    ClientResponse request(string method, string url, scope const(HeaderPair)[] headers, BodySource body_,
        Duration timeout = Duration.zero) @trusted
    {
        auto s = open(method, url, headers, body_, timeout);
        scope (exit)
            s.close();
        ClientResponse r;
        r.status = s.status;
        r.headers = s.headers;
        r.body = s.readAll(cfg.maxBody);
        return r;
    }

    /// ditto, `PUT`.
    ClientResponse put(string url, BodySource body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("PUT", url, headers, body_, timeout);

    /// ditto, `POST`.
    ClientResponse post(string url, BodySource body_, scope const(HeaderPair)[] headers = null,
        Duration timeout = Duration.zero) @trusted
        => request("POST", url, headers, body_, timeout);

    /// A request whose response body is read in pieces, as it arrives (a download passed on to a browser, a file
    /// written to disk): the status and headers are ready when this returns; `read` hands the body over. `maxBody`
    /// does not apply. `timeout` bounds the connection, the request and the wait for the head; then each wait (for a
    /// piece of the body to send or to arrive) has a `timeout` of its own, since the pace may be a slow reader's.
    /// Always `close` it:
    ///
    ///     auto s = httpClient().open("GET", url);
    ///     scope (exit) s.close();
    ///     ubyte[64 << 10] buf;
    ///     size_t n;
    ///     while ((n = s.read(buf[])) > 0)
    ///         out_.write(buf[0 .. n]);
    ClientStream open(string method, string url, scope const(HeaderPair)[] headers = null,
        BodySource body_ = BodySource.init, Duration timeout = Duration.zero) @trusted
    {
        parseUrl(url);
        if (transportOverride !is null)
            return fakeStream(method, url, headers, body_, timeout);
        return start(method, url, headers, null, body_, timeout, true);
    }

    /// Connects (or reuses a connection), sends the request and reads the response head; the body is left to the
    /// stream. `stepped`: each wait after the head is sent gets `timeout` of its own instead of sharing one deadline.
    private ClientStream start(string method, string url, scope const(HeaderPair)[] headers, const(char)[] inline,
        BodySource source, Duration timeout, bool stepped)
    {
        auto u = parseUrl(url);
        immutable wait = timeout > Duration.zero ? timeout : cfg.timeout;
        immutable deadline = MonoTime.currTime + wait;
        immutable step = stepped ? wait : Duration.zero;
        immutable idempotent = method == "GET" || method == "HEAD" || method == "PUT" || method == "DELETE"
            || method == "OPTIONS";

        foreach (attempt; 0 .. 2)
        {
            auto c = takeIdle(u);
            if (c is null)
                c = openConn(u, deadline);
            bool handedOver;
            scope (exit)
            {
                if (!handedOver)
                    c.closeNow();
            }
            try
            {
                sendRequest(c, u, method, headers, inline, source, deadline, step);
                auto s = readHead(c, method, step > Duration.zero ? MonoTime.currTime + step : deadline);
                s.step = step;
                s.deadline = deadline;
                handedOver = true;
                return s;
            }
            catch (StaleConn e)
            {
                if (attempt == 0 && c.reused && idempotent)
                    continue; // a stale pooled connection: try again, on a new one
                throw new HttpClientError(e.msg); // StaleConn's message has the prefix already
            }
        }
        assert(0);
    }

    /// `open` through a test transport: the body source is drained into one buffer and the reply is read from memory.
    private ClientStream fakeStream(string method, string url, scope const(HeaderPair)[] headers, BodySource source,
        Duration timeout)
    {
        ubyte[] sent;
        if (source.write !is null)
            source.write((scope const(ubyte)[] piece) { sent ~= piece; });
        auto r = transportOverride.send(method, url, headers, sent, timeout);
        auto s = new ClientStream;
        s.status = r.status;
        s.headers = r.headers;
        s.mode = BodyMode.memory;
        s.mem = r.body;
        s.contentLength = cast(long) r.body.length;
        return s;
    }

    // ------------------------------------------------------------ pool

    private static string keyOf(ref const ParsedUrl u)
    {
        import core.stdc.stdio : snprintf;

        char[8] p;
        auto n = snprintf(p.ptr, p.length, "%u", cast(uint) u.port);
        return (u.tls ? "s:" : "p:") ~ u.host ~ ":" ~ p[0 .. n].idup;
    }

    private Conn takeIdle(ref const ParsedUrl u)
    {
        auto k = keyOf(u);
        auto list = k in idle;
        if (list is null)
            return null;
        while ((*list).length)
        {
            auto c = (*list)[$ - 1];
            *list = (*list)[0 .. $ - 1];
            if (c.alive && MonoTime.currTime - c.lastUsed < cfg.idleTimeout)
            {
                c.reused = true;
                return c;
            }
            c.closeNow();
        }
        return null;
    }

    private void giveBack(Conn c)
    {
        auto list = c.key in idle;
        if (list !is null && (*list).length >= cfg.maxIdlePerHost)
        {
            c.closeNow();
            return;
        }
        c.lastUsed = MonoTime.currTime;
        idle[c.key] ~= c;
    }

    // ------------------------------------------------------------ connect

    package Conn openConn(ref const ParsedUrl u, MonoTime requestDeadline)
    {
        immutable cd = MonoTime.currTime + cfg.connectTimeout;
        immutable deadline = cd < requestDeadline ? cd : requestDeadline;

        auto addrs = resolve(u.host, u.port, deadline);
        auto c = new Conn;
        c.key = keyOf(u);

        string lastErr = "no addresses";
        foreach (ref a; addrs)
        {
            try
            {
                connectTcp(c, a, deadline);
                if (u.tls)
                    handshake(c, u.host, deadline);
                return c;
            }
            catch (HttpClientTimeout t)
            {
                c.closeNow();
                throw t;
            }
            catch (HttpClientError e)
            {
                lastErr = e.msg;
                c.closeNow();
            }
        }
        throw new HttpClientError("andaime.http: could not connect to " ~ u.host ~ ": " ~ lastErr);
    }

    private Addr[] resolve(string host, ushort port, MonoTime deadline)
    {
        import core.stdc.stdio : snprintf;

        char[8] p;
        auto n = snprintf(p.ptr, p.length, "%u", cast(uint) port);
        auto k = host ~ ":" ~ p[0 .. n].idup;
        if (auto e = k in dnsExpiry)
            if (MonoTime.currTime < *e)
                return dnsCache[k];
        left(deadline);
        auto res = offload(() @trusted => resolveBlocking(host, port));
        if (res.length == 0)
            throw new HttpClientError("andaime.http: could not resolve host " ~ host);
        dnsCache[k] = res;
        dnsExpiry[k] = MonoTime.currTime + 30.seconds;
        return res;
    }

    private void connectTcp(Conn c, ref Addr a, MonoTime deadline)
    {
        int fd = sockOpenNonBlock(a.family);
        if (fd < 0)
            throw new HttpClientError("andaime.http: socket failed");
        c.fd = fd;
        sockSetTcpNoDelay(fd);

        auto r = sockConnect(fd, &a.ss, a.len);
        if (r < 0 && !sockConnectInProgress())
            throw new HttpClientError("andaime.http: connect failed");
        if (r < 0)
        {
            if (awaitFd(fd, IoEvent.writable, left(deadline)) == 0)
                throw new HttpClientTimeout("timed out while connecting");
            int err = sockGetError(fd);
            if (err != 0)
                throw new HttpClientError("andaime.http: connection refused or unreachable");
        }
    }

    private void handshake(Conn c, string host, MonoTime deadline)
    {
        if (auto err = loadOpenSsl())
            throw new HttpClientError(err);
        if (ctx is null)
            ctx = makeCtx();

        c.ssl = tls.SSL_new(ctx);
        if (c.ssl is null)
            throw new HttpClientError("andaime.http: SSL_new failed");
        tls.SSL_set_fd(c.ssl, c.fd);
        auto zhost = host ~ '\0';
        tls.SSL_ctrl(c.ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, cast(void*) zhost.ptr);
        if (cfg.verifyTls)
            tls.SSL_set1_host(c.ssl, zhost.ptr);
        tls.SSL_set_connect_state(c.ssl);

        for (;;)
        {
            tls.ERR_clear_error();
            immutable r = tls.SSL_connect(c.ssl);
            if (r == 1)
                return;
            immutable e = tls.SSL_get_error(c.ssl, r);
            if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
            {
                immutable ev = e == SSL_ERROR_WANT_READ ? IoEvent.readable : IoEvent.writable;
                if (awaitFd(c.fd, ev, left(deadline)) == 0)
                    throw new HttpClientTimeout("timed out in the TLS handshake");
                continue;
            }
            throw new HttpClientError("andaime.http: TLS handshake failed: " ~ tlsError());
        }
    }

    private SSL_CTX* makeCtx()
    {
        auto x = tls.SSL_CTX_new(tls.TLS_client_method());
        if (x is null)
            throw new HttpClientError("andaime.http: SSL_CTX_new failed");
        tls.SSL_CTX_ctrl(x, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);
        if (cfg.verifyTls)
        {
            tls.SSL_CTX_set_verify(x, SSL_VERIFY_PEER, null);
            if (cfg.caFile.length)
            {
                auto z = cfg.caFile ~ '\0';
                if (tls.SSL_CTX_load_verify_locations(x, z.ptr, null) != 1)
                {
                    tls.SSL_CTX_free(x);
                    throw new HttpClientError("andaime.http: could not read caFile: " ~ cfg.caFile);
                }
            }
            else
                tls.SSL_CTX_set_default_verify_paths(x);
        }
        else
            tls.SSL_CTX_set_verify(x, SSL_VERIFY_NONE, null);
        return x;
    }

    private static string tlsError() nothrow
    {
        auto e = tls.ERR_get_error();
        if (e == 0)
            return "unknown error";
        char[256] buf;
        tls.ERR_error_string_n(e, buf.ptr, buf.length);
        return buf[0 .. strlen(buf.ptr)].idup;
    }

    // ------------------------------------------------------------ I/O

    /// Reads what is available; returns 0 on EOF. Waits cooperatively.
    private size_t recvSome(Conn c, void[] buf, MonoTime deadline)
    {
        for (;;)
        {
            if (c.ssl !is null)
            {
                tls.ERR_clear_error();
                immutable n = tls.SSL_read(c.ssl, buf.ptr, cast(int) buf.length);
                if (n > 0)
                    return n;
                immutable e = tls.SSL_get_error(c.ssl, n);
                if (e == SSL_ERROR_ZERO_RETURN)
                    return 0;
                if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
                {
                    immutable ev = e == SSL_ERROR_WANT_READ ? IoEvent.readable : IoEvent.writable;
                    if (awaitFd(c.fd, ev, left(deadline)) == 0)
                        throw new HttpClientTimeout;
                    continue;
                }
                if (e == SSL_ERROR_SYSCALL && n == 0)
                    return 0; // EOF without close_notify
                throw new HttpClientError("andaime.http: TLS error while reading: " ~ tlsError());
            }
            immutable n = sockRead(c.fd, buf.ptr, buf.length);
            if (n > 0)
                return cast(size_t) n;
            if (n == 0)
                return 0;
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                if (awaitFd(c.fd, IoEvent.readable, left(deadline)) == 0)
                    throw new HttpClientTimeout;
                continue;
            }
            if (errno == ECONNRESET)
                return 0;
            throw new HttpClientError("andaime.http: read error");
        }
    }

    private void sendAll(Conn c, const(char)[] data, MonoTime deadline)
    {
        while (data.length)
        {
            if (c.ssl !is null)
            {
                tls.ERR_clear_error();
                immutable n = tls.SSL_write(c.ssl, data.ptr, cast(int) data.length);
                if (n > 0)
                {
                    data = data[n .. $];
                    continue;
                }
                immutable e = tls.SSL_get_error(c.ssl, n);
                if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
                {
                    immutable ev = e == SSL_ERROR_WANT_READ ? IoEvent.readable : IoEvent.writable;
                    if (awaitFd(c.fd, ev, left(deadline)) == 0)
                        throw new HttpClientTimeout;
                    continue;
                }
                throw staleOr(c, "TLS error while writing: " ~ tlsError());
            }
            immutable n = sockSend(c.fd, data.ptr, data.length);
            if (n >= 0)
            {
                data = data[n .. $];
                continue;
            }
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                if (awaitFd(c.fd, IoEvent.writable, left(deadline)) == 0)
                    throw new HttpClientTimeout;
                continue;
            }
            throw staleOr(c, "write error");
        }
    }

    /// A reused connection that fails to write = probably stale.
    private static HttpClientError staleOr(Conn c, string msg)
    {
        if (c.reused)
            return new StaleConn;
        return new HttpClientError("andaime.http: " ~ msg);
    }

    /// Ensures at least one new byte in the buffer; false if the server closed.
    private bool fill(Conn c, MonoTime deadline)
    {
        if (c.rpos == c.rend)
            c.rpos = c.rend = 0;
        if (c.rend == c.rbuf.length)
        {
            if (c.rpos > 0)
            {
                memmove(c.rbuf.ptr, c.rbuf.ptr + c.rpos, c.rend - c.rpos);
                c.rend -= c.rpos;
                c.rpos = 0;
            }
            else
                c.rbuf.length = c.rbuf.length * 2;
        }
        immutable n = recvSome(c, c.rbuf[c.rend .. $], deadline);
        if (n == 0)
            return false;
        c.rend += n;
        return true;
    }

    // ------------------------------------------------------------ request/response

    /// Sends the request: the head, then the body (`inline`, or the pieces of `source`, each with `step` to be sent
    /// when it is set).
    private void sendRequest(Conn c, ref const ParsedUrl u, string method, scope const(HeaderPair)[] headers,
        const(char)[] inline, BodySource source, MonoTime deadline, Duration step)
    {
        immutable streamed = source.write !is null;
        immutable size = streamed ? cast(size_t) source.length : inline.length;
        char[] req;
        req.reserve(256 + (streamed ? 0 : inline.length));
        req ~= method;
        req ~= ' ';
        req ~= u.target;
        req ~= " HTTP/1.1\r\nHost: ";
        req ~= u.host;
        if (!((u.tls && u.port == 443) || (!u.tls && u.port == 80)))
        {
            import core.stdc.stdio : snprintf;

            char[8] p;
            auto n = snprintf(p.ptr, p.length, ":%u", cast(uint) u.port);
            req ~= p[0 .. n];
        }
        req ~= "\r\nUser-Agent: ";
        req ~= cfg.userAgent;
        req ~= "\r\nAccept: */*\r\n";
        bool hasCT, hasCL;
        foreach (h; headers)
        {
            checkHeader(h);
            if (eqFold(h.name, "content-type")) hasCT = true;
            if (eqFold(h.name, "content-length")) hasCL = true;
            req ~= h.name;
            req ~= ": ";
            req ~= h.value;
            req ~= "\r\n";
        }
        if (size || streamed || method == "POST" || method == "PUT" || method == "PATCH")
        {
            if (!hasCL)
            {
                req ~= "Content-Length: ";
                req ~= utoa(size);
                req ~= "\r\n";
            }
        }
        req ~= "\r\n";
        if (!streamed)
        {
            req ~= inline;
            sendAll(c, req, deadline);
            return;
        }
        sendAll(c, req, nextWait(deadline, step));
        ulong sent;
        source.write((scope const(ubyte)[] piece) @trusted {
            if (piece.length > source.length - sent)
                throw new HttpClientError("andaime.http: the body source wrote more than its length");
            sendAll(c, cast(const(char)[]) piece, nextWait(deadline, step));
            sent += piece.length;
        });
        if (sent != source.length)
            throw new HttpClientError("andaime.http: the body source wrote less than its length");
    }

    /// The deadline of the next wait: its own `step` from now when set, else the request's.
    private static MonoTime nextWait(MonoTime deadline, Duration step)
        => step > Duration.zero ? MonoTime.currTime + step : deadline;

    /// Reads the response head; the body is left to the returned stream.
    private ClientStream readHead(Conn c, string method, MonoTime deadline)
    {
        size_t headEnd;
        for (;;)
        {
            headEnd = findHeadEnd(c.rbuf[c.rpos .. c.rend]);
            if (headEnd != size_t.max)
                break;
            if (c.rend - c.rpos > cfg.maxHead)
                throw new HttpClientError("andaime.http: response head too large");
            if (!fill(c, deadline))
            {
                if (c.rend == c.rpos && c.reused)
                    throw new StaleConn;
                throw new HttpClientError("andaime.http: server closed before responding");
            }
        }
        auto head = c.rbuf[c.rpos .. c.rpos + headEnd];
        c.rpos += headEnd + 4;

        ClientResponse r;
        parseHead(head, r);

        auto s = new ClientStream;
        s.client = this;
        s.c = c;
        s.status = r.status;
        s.headers = r.headers;
        bool chunked, hasLen;
        size_t length;
        s.keepAlive = true;
        foreach (h; r.headers)
        {
            if (eqFold(h.name, "transfer-encoding") && containsFold(h.value, "chunked"))
                chunked = true;
            else if (eqFold(h.name, "content-length"))
            {
                hasLen = true;
                length = parseSize(h.value);
            }
            else if (eqFold(h.name, "connection") && containsFold(h.value, "close"))
                s.keepAlive = false;
        }
        s.contentLength = hasLen && !chunked ? cast(long) length : -1;
        immutable noBody = method == "HEAD" || r.status == 204 || r.status == 304 || (r.status >= 100 && r.status < 200);
        if (noBody)
        {
            s.mode = BodyMode.none;
            s.done = true;
        }
        else if (chunked)
            s.mode = BodyMode.chunked;
        else if (hasLen)
        {
            s.mode = BodyMode.length;
            s.left = length;
            s.done = length == 0;
        }
        else
        {
            s.mode = BodyMode.eof;
            s.keepAlive = false;
        }
        return s;
    }

    private const(char)[] readLine(Conn c, MonoTime deadline)
    {
        for (;;)
        {
            // lines are short: scanning again from rpos is cheap and immune to buffer compaction
            for (size_t i = c.rpos; i + 1 < c.rend; i++)
                if (c.rbuf[i] == '\r' && c.rbuf[i + 1] == '\n')
                {
                    auto line = c.rbuf[c.rpos .. i].idup;
                    c.rpos = i + 2;
                    return line;
                }
            if (c.rend - c.rpos > cfg.maxHead)
                throw new HttpClientError("andaime.http: line too large in the response");
            if (!fill(c, deadline))
                throw new HttpClientError("andaime.http: server closed in the middle of the body");
        }
    }
}

// ============================================================ helpers

package size_t findHeadEnd(const(char)[] b) pure nothrow @safe @nogc
{
    if (b.length < 4)
        return size_t.max;
    foreach (i; 0 .. b.length - 3)
        if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
            return i;
    return size_t.max;
}

package void parseHead(const(char)[] head, ref ClientResponse r) @safe
{
    // "HTTP/1.1 200 OK"
    if (head.length < 12 || head[0 .. 5] != "HTTP/")
        throw new HttpClientError("andaime.http: invalid HTTP response");
    size_t sp = 0;
    while (sp < head.length && head[sp] != ' ')
        sp++;
    if (sp + 4 > head.length)
        throw new HttpClientError("andaime.http: invalid status line");
    int st;
    foreach (i; 0 .. 3)
    {
        immutable ch = head[sp + 1 + i];
        if (ch < '0' || ch > '9')
            throw new HttpClientError("andaime.http: invalid status");
        st = st * 10 + (ch - '0');
    }
    r.status = st;

    size_t i = 0;
    while (i < head.length && head[i] != '\n')
        i++;
    i++;
    while (i < head.length)
    {
        size_t e = i;
        while (e < head.length && head[e] != '\r')
            e++;
        auto line = head[i .. e];
        i = e + 2;
        if (line.length == 0)
            break;
        size_t colon = 0;
        while (colon < line.length && line[colon] != ':')
            colon++;
        if (colon == line.length)
            continue;
        size_t vs = colon + 1;
        while (vs < line.length && (line[vs] == ' ' || line[vs] == '\t'))
            vs++;
        size_t ve = line.length;
        while (ve > vs && (line[ve - 1] == ' ' || line[ve - 1] == '\t'))
            ve--;
        r.headers ~= HeaderPair(line[0 .. colon].idup, line[vs .. ve].idup);
    }
}

private void checkHeader(ref const HeaderPair h)
{
    foreach (ch; h.name)
        if (ch <= ' ' || ch == ':' || ch >= 0x7f)
            throw new HttpClientError("andaime.http: invalid header name: " ~ h.name);
    foreach (ch; h.value)
        if (ch == '\r' || ch == '\n')
            throw new HttpClientError("andaime.http: header value with line break (" ~ h.name ~ ")");
}

private string utoa(size_t v) pure nothrow @safe
{
    char[24] tmp;
    size_t n = tmp.length;
    do
    {
        tmp[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    return tmp[n .. $].idup;
}

private size_t parseSize(string s) @safe
{
    if (s.length == 0 || s.length > 18)
        throw new HttpClientError("andaime.http: invalid Content-Length");
    size_t v;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            throw new HttpClientError("andaime.http: invalid Content-Length");
        v = v * 10 + (ch - '0');
    }
    return v;
}

private size_t parseHex(const(char)[] s) @safe
{
    if (s.length == 0 || s.length > 12)
        throw new HttpClientError("andaime.http: invalid chunk size");
    size_t v;
    foreach (ch; s)
    {
        int d;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        else throw new HttpClientError("andaime.http: invalid chunk size");
        v = v * 16 + d;
    }
    return v;
}

private bool eqFold(const(char)[] a, const(char)[] b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y)
            return false;
    }
    return true;
}

private bool containsFold(const(char)[] hay, const(char)[] needle) pure nothrow @safe @nogc
{
    if (needle.length > hay.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (eqFold(hay[i .. i + needle.length], needle))
            return true;
    return false;
}

// ============================================================ transport override (tests)

/// Answers the requests of every `HttpClient` of this thread instead of the network: `FakeHttpClient`
/// (`andaime.engine.httpfake`) implements it. The URL has been checked (`parseUrl`) before `send` is called.
interface HttpTransport
{
    ClientResponse send(string method, string url, const(HeaderPair)[] headers, const(ubyte)[] body_,
        Duration timeout) @safe;
}

private HttpTransport transportOverride; // thread-local, like the worker's client

/// Routes every `HttpClient` request made on this thread to `t` (null: the network again) and returns
/// the previous one. Meant for tests; in a server, call it from the build function (it runs on each
/// worker's thread).
HttpTransport setHttpTransport(HttpTransport t) @safe nothrow @nogc
{
    auto prev = transportOverride;
    transportOverride = t;
    return prev;
}

// ============================================================ worker client

private HttpClient tlsClient; // thread-local: one per worker

/// This worker's client (created on first use). For a different configuration,
/// call `httpClient(cfg)` once when the worker starts.
HttpClient httpClient() @trusted
{
    if (tlsClient is null)
        tlsClient = new HttpClient;
    return tlsClient;
}

HttpClient httpClient(HttpClientConfig cfg) @trusted
{
    return tlsClient = new HttpClient(cfg);
}

unittest
{
    auto u = parseUrl("https://api.example.com/v1/x?a=1#frag");
    assert(u.tls && u.host == "api.example.com" && u.port == 443 && u.target == "/v1/x?a=1");
    u = parseUrl("http://localhost:8080");
    assert(!u.tls && u.host == "localhost" && u.port == 8080 && u.target == "/");
    u = parseUrl("http://[::1]:9000/p");
    assert(u.host == "::1" && u.port == 9000 && u.target == "/p");
    u = parseUrl("http://h?q=1");
    assert(u.host == "h" && u.target == "/?q=1");
    bool threw;
    try parseUrl("ftp://x"); catch (HttpClientError) threw = true;
    assert(threw);
    threw = false;
    try parseUrl("http://h:99999/"); catch (HttpClientError) threw = true;
    assert(threw);

    ClientResponse r;
    parseHead("HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nX-A:  b c \r\n", r);
    assert(r.status == 201 && r.header("content-type") == "text/plain" && r.header("x-a") == "b c");
    assert(parseHex("1aF") == 0x1af);
    assert(eqFold("Content-LENGTH", "content-length"));
    assert(containsFold("gzip, Chunked", "chunked"));
}
