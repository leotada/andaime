/// Outgoing WebSockets (RFC 6455), cooperative like the HTTP client: inside a request every wait suspends only the fiber;
/// outside one (a script, `main`) it blocks.
///
/// ```d
/// auto ws = wsConnect("wss://stream.example.com/v1/ticks");
/// scope (exit) ws.disconnect();
/// ws.send(`{"subscribe":"EURUSD"}`);
/// foreach (msg; ws)
///     handle(msg.text);
/// ```
///
/// - `ws://` and `wss://` (OpenSSL at run time, certificates and host names verified by `httpClient()`'s settings);
/// - permessage-deflate when `WsClientOptions.compression` is set and the server agrees;
/// - the connection belongs to the fiber that opened it (it receives); other fibers of the worker may `send`.
module andaime.engine.wsclient;

version (Posix)
    import core.stdc.errno : errno, EAGAIN, EINTR, EWOULDBLOCK;
else version (Windows)
{
    import core.stdc.errno : errno, EINTR;
    enum EAGAIN = 11;
    enum EWOULDBLOCK = EAGAIN;
}
import core.time : Duration, MonoTime, msecs, seconds;

import andaime.http.buffer : ByteBuffer;
import andaime.http.response : UpgradedConn, FillResult;
import andaime.http.websocket;
import andaime.http.sha1 : base64Encode;
import andaime.engine.fiberio : awaitFd, IoEvent;
import andaime.engine.httpclient;
import andaime.engine.os : sockRead, sockSend;
import andaime.engine.tls;
import andaime.engine.zlib : zlibDeflate;

@safe:

/// Options of `wsConnect`.
struct WsClientOptions
{
    /// DNS, TCP, TLS and the opening handshake together.
    Duration connectTimeout = 10.seconds;
    /// Largest message accepted (after decompression); a larger one closes the connection with 1009.
    size_t maxMessageBytes = 1 << 20;
    /// Ping after this long without input while `receive` waits; drop the connection after as long again.
    Duration pingInterval = 30.seconds;
    /// How long a blocked `send` waits for the server to read.
    Duration writeTimeout = 30.seconds;
    /// Offers permessage-deflate (zlib keeps about 300 KB per compressing connection).
    bool compression;
}

/// Opens a WebSocket to `url` (`ws://host[:port]/path` or `wss://...`). `headers` go with the handshake
/// (`Authorization`, `Sec-WebSocket-Protocol`...). Throws `HttpClientError` when the connection or the handshake fails
/// (`HttpClientTimeout` past `connectTimeout`). Call `disconnect()` when done.
// @trusted like HttpClient.request: it only calls the client's connection code, whose raw socket and OpenSSL calls are
// bounded by the slices passed with them, and hands out no pointer
WsConn wsConnect(string url, const(HeaderPair)[] headers = null, WsClientOptions opts = WsClientOptions.init) @trusted
{
    ParsedUrl u;
    if (url.length > 6 && url[0 .. 6] == "wss://")
        u = parseUrl("https://" ~ url[6 .. $]);
    else if (url.length > 5 && url[0 .. 5] == "ws://")
        u = parseUrl("http://" ~ url[5 .. $]);
    else
        throw new HttpClientError("andaime.http: a WebSocket URL starts with ws:// or wss://: " ~ url);

    immutable deadline = MonoTime.currTime + opts.connectTimeout;
    auto conn = httpClient().openConn(u, deadline);
    auto port = new ClientPort(conn, opts.writeTimeout);
    scope (failure)
        port.close();

    ubyte[16] nonce;
    randomBytes(nonce[]);
    char[24] key;
    base64Encode(nonce[], key[]);

    ByteBuffer req;
    req.put("GET ");
    req.put(u.target);
    req.put(" HTTP/1.1\r\nHost: ");
    req.put(u.host);
    if (u.port != (u.tls ? 443 : 80))
    {
        req.put(':');
        req.putUint(u.port);
    }
    req.put("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ");
    req.put(key[]);
    req.put("\r\n");
    if (opts.compression)
        req.put("Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n");
    foreach (ref h; headers)
    {
        foreach (ch; h.name ~ h.value)
            if (ch == '\r' || ch == '\n')
                throw new HttpClientError("andaime.http: header with CR/LF: " ~ h.name);
        req.put(h.name);
        req.put(": ");
        req.put(h.value);
        req.put("\r\n");
    }
    req.put("\r\n");
    port.write(cast(const(ubyte)[]) req.data);

    // the answer's head; whatever follows it is already WebSocket data
    size_t end;
    for (;;)
    {
        end = findHeadEnd(cast(const(char)[]) port.buffered());
        if (end != size_t.max)
            break;
        if (port.buffered().length > 64 << 10)
            throw new HttpClientError("andaime.http: WebSocket handshake answer too large");
        immutable left = (deadline - MonoTime.currTime).total!"msecs";
        if (left <= 0)
            throw new HttpClientTimeout("timed out in the WebSocket handshake");
        final switch (port.fill(cast(int) left))
        {
            case FillResult.data:
                break;
            case FillResult.timeout:
                throw new HttpClientTimeout("timed out in the WebSocket handshake");
            case FillResult.eof:
            case FillResult.stopping:
                throw new HttpClientError("andaime.http: the server closed the connection during the WebSocket handshake");
        }
    }
    ClientResponse r;
    parseHead(cast(const(char)[]) port.buffered()[0 .. end + 2], r);
    port.consume(end + 4);
    if (r.status != 101)
        throw new HttpClientError("andaime.http: the server did not accept the WebSocket (status " ~ statusString(r.status) ~ ")");
    if (!hasToken(r.header("upgrade"), "websocket") || !hasToken(r.header("connection"), "upgrade"))
        throw new HttpClientError("andaime.http: the server's 101 is not a WebSocket upgrade");
    if (r.header("sec-websocket-accept") != acceptKey(key[]))
        throw new HttpClientError("andaime.http: wrong Sec-WebSocket-Accept from the server");

    WsDeflate deflate;
    if (auto ext = r.header("sec-websocket-extensions"))
    {
        DeflateParams p;
        if (!opts.compression || !parseDeflate(ext, p))
            throw new HttpClientError("andaime.http: the server answered an extension that was not offered: " ~ ext);
        deflate = zlibDeflate(p.clientMaxWindowBits, p.clientNoContextTakeover);
        if (deflate is null)
            throw new HttpClientError("andaime.http: the server chose permessage-deflate, but zlib is not available");
    }

    WsOptions wo;
    wo.maxMessageBytes = opts.maxMessageBytes;
    wo.pingInterval = opts.pingInterval;
    ulong seed;
    randomBytes((cast(ubyte*) &seed)[0 .. seed.sizeof]);
    auto ws = new WsConn;
    ws.reset(port, true, wo, deflate, seed);
    return ws;
}

private string statusString(int s) pure nothrow
{
    char[3] d = [cast(char)('0' + s / 100 % 10), cast(char)('0' + s / 10 % 10), cast(char)('0' + s % 10)];
    return d.idup;
}

/// Bytes from the kernel's random source (masking keys and handshake nonces), as an `HttpClientError` on failure.
private void randomBytes(ubyte[] b)
{
    import random = andaime.engine.random;

    try
        random.randomBytes(b);
    catch (Exception e)
        throw new HttpClientError("andaime.http: getrandom failed");
}

/// The client side of a WebSocket's connection. The owner (the fiber that connected) waits on the socket; another fiber
/// that sends only appends and tries a non-blocking send, so two fibers never wait on the same descriptor. Whatever it
/// could not send goes out with the owner's next wait.
///
/// Its @trusted methods make read(2)/send(2)/SSL_read/SSL_write calls whose pointer and length both come from one D slice
/// (`inBuf`, `outBuf`), and compare fiber identities as opaque pointers; no raw pointer leaves the class.
private final class ClientPort : UpgradedConn
{
    private Conn conn;
    private ubyte[] inBuf;
    private size_t inOff, inLen;
    private ByteBuffer outBuf;
    private size_t outOff;
    private int writeTimeoutMs;
    private void* owner;  // the fiber that connected (null: a plain thread)
    private bool waiting; // the owner is inside awaitFd
    private bool eof, broken, closed;

    /// Bytes a non-owner may leave queued before `send` gives up.
    enum maxQueued = 4 << 20;

    this(Conn c, Duration writeTimeout) @trusted
    {
        import core.thread : Fiber;

        conn = c;
        inBuf = new ubyte[16 << 10];
        writeTimeoutMs = cast(int) writeTimeout.total!"msecs";
        owner = cast(void*) Fiber.getThis();
    }

    private bool isOwner() @trusted
    {
        import core.thread : Fiber;

        return cast(void*) Fiber.getThis() is owner;
    }

    override const(ubyte)[] buffered() => inBuf[inOff .. inLen];

    override void consume(size_t n)
    {
        inOff += n;
        if (inOff == inLen)
            inOff = inLen = 0;
    }

    override FillResult fill(int timeoutMs) @trusted
    {
        if (!isOwner())
            throw new Exception("andaime: only the fiber that opened a WebSocket can read from it");
        if (closed || broken || eof)
            return FillResult.eof;
        immutable deadline = timeoutMs < 0 ? MonoTime.max : MonoTime.currTime + timeoutMs.msecs;
        for (;;)
        {
            if (!flush())
                return FillResult.eof;
            uint ev;
            immutable n = readSome(ev);
            if (n > 0)
                return FillResult.data;
            if (n == 0)
            {
                eof = true;
                return FillResult.eof;
            }
            if (n < -1)
            {
                broken = true;
                return FillResult.eof;
            }
            if (outOff < outBuf.length)
                ev |= IoEvent.writable; // a queued send from another fiber goes out while we wait
            long ms = -1;
            if (deadline != MonoTime.max)
            {
                ms = (deadline - MonoTime.currTime).total!"msecs";
                if (ms <= 0)
                    return FillResult.timeout;
            }
            waiting = true;
            immutable got = awaitFd(conn.fd, ev, ms < 0 ? Duration.max : ms.msecs);
            waiting = false;
            if (got == 0)
                return FillResult.timeout;
        }
    }

    override void write(scope const(ubyte)[] data) @trusted
    {
        if (closed || broken)
        {
            if (isOwner())
                throw new HttpClientError("andaime.http: the WebSocket connection is closed");
            throw new WsClosed;
        }
        outBuf.put(cast(const(char)[]) data); // whole: frames of two fibers never interleave
        if (!flush())
            throw new WsClosed("andaime.http: the WebSocket connection failed");
        if (outOff == outBuf.length)
            return;
        if (!isOwner())
        {
            // never wait on the owner's descriptor: what is left goes out with the owner's next wait
            if (outBuf.length - outOff > maxQueued)
                throw new WsClosed("andaime.http: the WebSocket server is not reading (too much queued)");
            return;
        }
        immutable deadline = MonoTime.currTime + writeTimeoutMs.msecs;
        while (outOff < outBuf.length)
        {
            immutable left = (deadline - MonoTime.currTime).total!"msecs";
            if (left <= 0 || awaitFd(conn.fd, wantFor(true), left.msecs) == 0)
            {
                broken = true;
                throw new HttpClientTimeout("the WebSocket server did not read for writeTimeout");
            }
            if (!flush())
                throw new HttpClientError("andaime.http: the WebSocket connection failed while sending");
        }
    }

    override void close() @trusted
    {
        if (closed)
            return;
        // the close frame is usually still queued: give it a moment to go out
        if (!broken && isOwner() && outOff < outBuf.length)
        {
            immutable deadline = MonoTime.currTime + 1.seconds;
            while (outOff < outBuf.length && flush())
            {
                immutable left = (deadline - MonoTime.currTime).total!"msecs";
                if (left <= 0 || awaitFd(conn.fd, wantFor(true), left.msecs) == 0)
                    break;
            }
        }
        closed = true;
        if (conn.ssl !is null && !broken)
            tls.SSL_shutdown(conn.ssl);
        conn.closeNow();
    }

    private uint tlsWant; // what OpenSSL waits for after WANT_READ/WANT_WRITE

    private uint wantFor(bool writing) => conn.ssl !is null && tlsWant ? tlsWant : (writing ? IoEvent.writable : IoEvent.readable);

    /// Sends the queue without blocking; false when the connection broke.
    private bool flush() @trusted
    {
        while (outOff < outBuf.length)
        {
            auto p = outBuf.data[outOff .. $];
            ptrdiff_t n;
            if (conn.ssl !is null)
            {
                tls.ERR_clear_error();
                n = tls.SSL_write(conn.ssl, p.ptr, cast(int)(p.length > int.max ? int.max : p.length));
                if (n <= 0)
                {
                    immutable e = tls.SSL_get_error(conn.ssl, cast(int) n);
                    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
                    {
                        tlsWant = e == SSL_ERROR_WANT_READ ? IoEvent.readable : IoEvent.writable;
                        return true;
                    }
                    broken = true;
                    return false;
                }
            }
            else
            {
                n = sockSend(conn.fd, p.ptr, p.length);
                if (n < 0)
                {
                    if (errno == EINTR)
                        continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        return true;
                    broken = true;
                    return false;
                }
            }
            outOff += n;
        }
        outBuf.clear();
        outOff = 0;
        outBuf.shrinkTo(256 << 10);
        return true;
    }

    /// Reads into `inBuf`: > 0 bytes, 0 end of stream, -1 would block (`ev` says on what), < -1 error.
    private ptrdiff_t readSome(out uint ev) @trusted
    {
        if (inOff && inOff == inLen)
            inOff = inLen = 0;
        if (inLen == inBuf.length)
        {
            if (inOff)
            {
                import core.stdc.string : memmove;

                memmove(inBuf.ptr, inBuf.ptr + inOff, inLen - inOff); // overlapping move within the slice
                inLen -= inOff;
                inOff = 0;
            }
            else
                inBuf.length = inBuf.length * 2;
        }
        for (;;)
        {
            auto space = inBuf[inLen .. $];
            if (conn.ssl !is null)
            {
                tls.ERR_clear_error();
                immutable n = tls.SSL_read(conn.ssl, space.ptr, cast(int) space.length);
                if (n > 0)
                {
                    inLen += n;
                    return n;
                }
                immutable e = tls.SSL_get_error(conn.ssl, n);
                if (e == SSL_ERROR_ZERO_RETURN || (e == SSL_ERROR_SYSCALL && n == 0))
                    return 0;
                if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
                {
                    ev = e == SSL_ERROR_WANT_READ ? IoEvent.readable : IoEvent.writable;
                    return -1;
                }
                return -2;
            }
            immutable n = sockRead(conn.fd, space.ptr, space.length);
            if (n > 0)
            {
                inLen += n;
                return n;
            }
            if (n == 0)
                return 0;
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                ev = IoEvent.readable;
                return -1;
            }
            return -2;
        }
    }
}
