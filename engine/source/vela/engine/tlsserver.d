/// TLS for the server's listener: one OpenSSL context per worker (no locks between workers),
/// non-blocking handshakes driven by the epoll loop, ALPN choosing HTTP/2 or HTTP/1.1, and
/// certificate reload when the files change on disk.
///
/// Reads and writes follow read(2)/send(2): a positive count, 0 at end of stream, or -1 with
/// `errno` set (EAGAIN when OpenSSL needs the socket to become readable or writable again), so
/// the loop's HTTP/1 and HTTP/2 paths treat a TLS connection exactly like a plain one.
///
/// Settings: TLS 1.2 and 1.3 only; for TLS 1.2, ECDHE with AEAD ciphers only (Mozilla's
/// "intermediate" list, which also satisfies RFC 9113 §9.2.2); no compression, no
/// renegotiation. OpenSSL's per-connection read/write buffers are released while a connection
/// is idle (SSL_MODE_RELEASE_BUFFERS). The server-side session cache is off (it can hold 20,480
/// sessions per context); resumption uses stateless tickets whose keys are shared by all workers.
module vela.engine.tlsserver;

@safe:

import core.stdc.errno : errno, EAGAIN, EPROTO;
import vela.engine.tls;
import vela.engine.loop : TlsConfig;

/// Mozilla "intermediate" (TLS 1.2 part). TLS 1.3 suites are all AEAD; OpenSSL's defaults stay.
private enum string tls12Ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
    ~ "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
    ~ "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305\0";

/// Session ticket keys (name 16 + HMAC 32 + AES 32 bytes), the same for every worker so a client
/// can resume on any of them. Generated once per process.
struct TicketKeys
{
    ubyte[80] bytes;

    static TicketKeys random() @trusted
    {
        import vela.engine.random : randomBytes;

        TicketKeys k;
        randomBytes(k.bytes[]);
        return k;
    }
}

/// Identity of a file on disk, to notice renewals (certbot swaps symlinks: the inode changes).
private struct Stamp
{
    long mtime, ctime, size;
    ulong ino;
    bool exists;
}

private Stamp stampOf(string path) @trusted
{
    auto z = path ~ '\0';
    version (Posix)
    {
        import core.sys.posix.sys.stat : stat, stat_t;

        stat_t st;
        if (stat(z.ptr, &st) != 0)
            return Stamp.init;
        return Stamp(st.st_mtime, st.st_ctime, st.st_size, st.st_ino, true);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : WIN32_FILE_ATTRIBUTE_DATA, GetFileAttributesExA, GET_FILEEX_INFO_LEVELS;

        WIN32_FILE_ATTRIBUTE_DATA data;
        if (!GetFileAttributesExA(z.ptr, GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, &data))
            return Stamp.init;
        ulong size = (cast(ulong) data.nFileSizeHigh << 32) | data.nFileSizeLow;
        ulong mtime = (cast(ulong) data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
        return Stamp(cast(long) mtime, 0, cast(long) size, 0, true);
    }
    else
    {
        return Stamp.init;
    }
}

/// The TLS context of one worker.
struct TlsServer
{
    @disable this(this);

    private SSL_CTX* ctx;
    private Stamp certStamp, keyStamp;
    private long nextCheckMs;
    private bool allowH2;
    private TicketKeys keys;

    /// Successful reloads since the start.
    size_t reloads;

    ~this() @trusted
    {
        if (ctx !is null)
            tls.SSL_CTX_free(ctx); // live connections hold their own reference
    }

    bool loaded() const pure nothrow @nogc => ctx !is null;

    /// Loads the certificate and key. Returns null, or a `vela: TLS: ...` message.
    string load(ref const TlsConfig cfg, bool http2, ref const TicketKeys ticketKeys)
    {
        if (auto e = loadOpenSsl())
            return "vela: TLS: " ~ e;
        allowH2 = http2;
        keys = ticketKeys;
        certStamp = stampOf(cfg.certFile);
        keyStamp = stampOf(cfg.keyFile);
        string err;
        auto c = makeContext(cfg, err);
        if (c is null)
            return err;
        replace(c);
        return null;
    }

    /// Called from the loop's sweep: reloads when either file changed. Returns a message to log
    /// (success or failure) or null when nothing happened.
    string maybeReload(ref const TlsConfig cfg, long nowMs)
    {
        if (cfg.reloadCheckMs == 0 || nowMs < nextCheckMs)
            return null;
        nextCheckMs = nowMs + cfg.reloadCheckMs;
        auto c = stampOf(cfg.certFile), k = stampOf(cfg.keyFile);
        if (c == certStamp && k == keyStamp)
            return null;
        // remember the new stamps even on failure: retry only when the files change again
        certStamp = c;
        keyStamp = k;
        string err;
        auto fresh = makeContext(cfg, err);
        if (fresh is null)
            return err ~ " (keeping the previous certificate)";
        replace(fresh);
        reloads++;
        return "vela: TLS: certificate reloaded from " ~ cfg.certFile;
    }

    /// A new server-side TLS object for an accepted socket, or null (out of memory).
    SSL* accept(int fd) @trusted nothrow @nogc
    {
        auto s = tls.SSL_new(ctx);
        if (s is null)
            return null;
        if (tls.SSL_set_fd(s, fd) != 1)
        {
            tls.SSL_free(s);
            return null;
        }
        tls.SSL_set_accept_state(s);
        return s;
    }

    private void replace(SSL_CTX* c) @trusted
    {
        if (ctx !is null)
            tls.SSL_CTX_free(ctx);
        ctx = c;
    }

    private SSL_CTX* makeContext(ref const TlsConfig cfg, out string err) @trusted
    {
        tls.ERR_clear_error();
        auto c = tls.SSL_CTX_new(tls.TLS_server_method());
        if (c is null)
        {
            err = "vela: TLS: SSL_CTX_new failed: " ~ lastError();
            return null;
        }
        tls.SSL_CTX_ctrl(c, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);
        tls.SSL_CTX_set_options(c, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION | SSL_OP_CIPHER_SERVER_PREFERENCE);
        tls.SSL_CTX_ctrl(c, SSL_CTRL_MODE,
            SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_RELEASE_BUFFERS, null);
        tls.SSL_CTX_ctrl(c, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_OFF, null);
        tls.SSL_CTX_ctrl(c, SSL_CTRL_SET_TLSEXT_TICKET_KEYS, keys.bytes.length, cast(void*) keys.bytes.ptr);
        if (tls.SSL_CTX_set_cipher_list(c, tls12Ciphers.ptr) != 1)
            return fail(c, err, "vela: TLS: no usable cipher: ");
        auto certZ = cfg.certFile ~ '\0';
        if (tls.SSL_CTX_use_certificate_chain_file(c, certZ.ptr) != 1)
            return fail(c, err, "vela: TLS: cannot load the certificate chain " ~ cfg.certFile ~ ": ");
        auto keyZ = cfg.keyFile ~ '\0';
        if (tls.SSL_CTX_use_PrivateKey_file(c, keyZ.ptr, SSL_FILETYPE_PEM) != 1)
        {
            // OpenSSL compares the key with the certificate while loading it
            auto why = lastError();
            tls.SSL_CTX_free(c);
            err = (why.indexOf("values mismatch") >= 0
                ? "vela: TLS: the private key " ~ cfg.keyFile ~ " does not match the certificate " ~ cfg.certFile ~ ": "
                : "vela: TLS: cannot load the private key " ~ cfg.keyFile ~ ": ") ~ why;
            return null;
        }
        if (tls.SSL_CTX_check_private_key(c) != 1)
            return fail(c, err, "vela: TLS: the private key does not match the certificate: ");
        tls.SSL_CTX_set_alpn_select_cb(c, allowH2 ? &selectH2 : &selectHttp1, null);
        return c;
    }

    private static SSL_CTX* fail(SSL_CTX* c, out string err, string what) @trusted
    {
        err = what ~ lastError();
        tls.SSL_CTX_free(c);
        return null;
    }
}

private ptrdiff_t indexOf(string hay, string needle) pure nothrow @nogc
{
    if (needle.length > hay.length)
        return -1;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return i;
    return -1;
}

/// The OpenSSL error queue as text (and empties it).
private string lastError() @trusted
{
    auto e = tls.ERR_get_error();
    if (e == 0)
        return "unknown error";
    char[256] buf = 0;
    tls.ERR_error_string_n(e, buf.ptr, buf.length);
    size_t n = 0;
    while (n < buf.length && buf[n])
        n++;
    tls.ERR_clear_error();
    return buf[0 .. n].idup;
}

// ----------------------------------------------------------------------------- ALPN

private static immutable ubyte[2] protoH2 = ['h', '2'];
private static immutable ubyte[8] protoH1 = ['h', 't', 't', 'p', '/', '1', '.', '1'];

/// Server preference: h2 when allowed and offered, then http/1.1. A client offering neither gets
/// no ALPN (not an alert) and is served HTTP/1.1.
private int pick(const(ubyte)** out_, ubyte* outLen, const(ubyte)* in_, uint inLen, bool h2) @system nothrow @nogc
{
    auto list = in_[0 .. inLen];
    bool hasH2, hasH1;
    size_t i = 0;
    while (i < list.length)
    {
        immutable n = list[i];
        if (n == 0 || i + 1 + n > list.length)
            break; // malformed list: OpenSSL already validated it, but stay in bounds
        auto p = list[i + 1 .. i + 1 + n];
        hasH2 |= p == protoH2[];
        hasH1 |= p == protoH1[];
        i += 1 + n;
    }
    if (h2 && hasH2)
    {
        *out_ = protoH2.ptr;
        *outLen = cast(ubyte) protoH2.length;
        return SSL_TLSEXT_ERR_OK;
    }
    if (hasH1)
    {
        *out_ = protoH1.ptr;
        *outLen = cast(ubyte) protoH1.length;
        return SSL_TLSEXT_ERR_OK;
    }
    return SSL_TLSEXT_ERR_NOACK;
}

private extern (C) int selectH2(SSL*, const(ubyte)** out_, ubyte* outLen, const(ubyte)* in_, uint inLen,
    void*) @system nothrow @nogc
{
    return pick(out_, outLen, in_, inLen, true);
}

private extern (C) int selectHttp1(SSL*, const(ubyte)** out_, ubyte* outLen, const(ubyte)* in_, uint inLen,
    void*) @system nothrow @nogc
{
    return pick(out_, outLen, in_, inLen, false);
}

// ----------------------------------------------------------------------------- connections

/// `closed`: the client went away mid-handshake (port scanners, TCP health checks, abandoned
/// speculative connections): counted, but not worth a log line.
enum Handshake : ubyte { done, again, failed, closed }

private enum uint unexpectedEof = 294; // SSL_R_UNEXPECTED_EOF_WHILE_READING
private enum uint reasonMask = 0x7fffff; // ERR_REASON_MASK

/// Advances the handshake as far as the socket allows. On failure `reason` holds OpenSSL's
/// explanation (for the log) and `why` the slice of it that was filled.
Handshake tlsHandshake(SSL* s, ref char[160] reason, out const(char)[] why) @system nothrow @nogc
{
    tls.ERR_clear_error();
    immutable r = tls.SSL_do_handshake(s);
    if (r == 1)
        return Handshake.done;
    immutable e = tls.SSL_get_error(s, r);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
        return Handshake.again;
    immutable code = tls.ERR_get_error();
    if (code == 0 || (code & reasonMask) == unexpectedEof)
    {
        tls.ERR_clear_error();
        return Handshake.closed;
    }
    else
    {
        reason[] = 0;
        tls.ERR_error_string_n(code, reason.ptr, reason.length);
        size_t n = 0;
        while (n < reason.length && reason[n])
            n++;
        why = reason[0 .. n];
    }
    tls.ERR_clear_error();
    return Handshake.failed;
}

/// The protocol ALPN settled on was HTTP/2.
bool tlsIsH2(SSL* s) @system nothrow @nogc
{
    const(ubyte)* p;
    uint n;
    tls.SSL_get0_alpn_selected(s, &p, &n);
    return n == 2 && p[0] == 'h' && p[1] == '2';
}

/// Like read(2). `fatal` is set when the TLS session is broken (no close_notify may follow).
ptrdiff_t tlsRead(SSL* s, void* p, size_t n, ref bool fatal) @system nothrow @nogc
{
    if (n > int.max)
        n = int.max;
    tls.ERR_clear_error();
    immutable r = tls.SSL_read(s, p, cast(int) n);
    if (r > 0)
        return r;
    return ioError(s, r, fatal);
}

/// Like send(2). Partial writes are enabled; retries may pass a longer buffer or a moved one.
ptrdiff_t tlsWrite(SSL* s, const(void)* p, size_t n, ref bool fatal) @system nothrow @nogc
{
    if (n == 0)
        return 0;
    if (n > int.max)
        n = int.max;
    tls.ERR_clear_error();
    immutable r = tls.SSL_write(s, p, cast(int) n);
    if (r > 0)
        return r;
    return ioError(s, r, fatal);
}

private ptrdiff_t ioError(SSL* s, int r, ref bool fatal) @system nothrow @nogc
{
    immutable saved = errno;
    immutable e = tls.SSL_get_error(s, r);
    switch (e)
    {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            errno = EAGAIN;
            return -1;
        case SSL_ERROR_ZERO_RETURN:
            return 0; // close_notify
        case SSL_ERROR_SYSCALL:
            // the socket BIO already turns EINTR/EAGAIN into WANT_READ/WANT_WRITE: this is fatal
            tls.ERR_clear_error();
            fatal = true;
            if (r == 0 || saved == 0)
                return 0; // TCP closed without close_notify: treated as end of stream
            errno = saved;
            return -1;
        default:
            tls.ERR_clear_error();
            fatal = true;
            errno = EPROTO;
            return -1;
    }
}

/// Frees the TLS object; sends close_notify first when the session is intact (best effort,
/// non-blocking: a full socket buffer just drops it).
void tlsClose(SSL* s, bool notify) @system nothrow @nogc
{
    if (notify)
    {
        tls.ERR_clear_error();
        tls.SSL_shutdown(s);
    }
    tls.ERR_clear_error();
    tls.SSL_free(s);
}
