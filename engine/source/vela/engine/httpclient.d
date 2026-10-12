/// Cliente HTTP/1.1 de saída, cooperativo: dentro de uma requisição toda
/// espera (DNS, conexão, TLS, envio, resposta) suspende só o fiber.
///
/// ```d
/// auto r = httpClient().get("https://api.exemplo.com/v1/cotacao?moeda=USD");
/// if (r.ok) use(r.body);
/// ```
///
/// - HTTP e HTTPS (OpenSSL carregada em tempo de execução, verificação do
///   certificado e do nome do host ligadas por padrão);
/// - conexões keep-alive reaproveitadas por host (um pool por worker);
/// - Content-Length, chunked e corpo até o fechamento; limite de tamanho;
/// - prazo total por requisição (`timeout`); cancelamento da requisição de
///   entrada fecha a conexão de saída;
/// - não segue redirecionamentos (3xx volta como resposta; leia `Location`).
module vela.engine.httpclient;

version (linux):

import core.stdc.errno : errno, EAGAIN, EINTR, EINPROGRESS, EWOULDBLOCK, ECONNRESET, EPIPE;
import core.stdc.string : memchr, memcmp, memcpy, memmove, strlen;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.netdb : addrinfo, getaddrinfo, freeaddrinfo, AI_ADDRCONFIG;
import core.sys.posix.netinet.in_ : IPPROTO_TCP;
import core.sys.posix.netinet.tcp : TCP_NODELAY;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close, read, write;
import core.time : Duration, MonoTime, seconds, msecs;

import vela.engine.fiberio : awaitFd, IoEvent;
import vela.engine.offload : offload;
import vela.engine.tls;

// ============================================================ tipos públicos

/// Falha de rede, protocolo ou prazo.
class HttpClientError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// O prazo da requisição terminou.
final class HttpClientTimeout : HttpClientError
{
    this(string what = "tempo esgotado", string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super("vela.http: " ~ what, file, line);
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

    /// Valor do primeiro header `name` (sem diferenciar maiúsculas), ou null.
    string header(const(char)[] name) const pure nothrow @safe
    {
        foreach (h; headers)
            if (eqFold(h.name, name))
                return h.value;
        return null;
    }
}

struct HttpClientConfig
{
    Duration timeout = 30.seconds;        /// prazo total de cada requisição
    Duration connectTimeout = 5.seconds;  /// DNS + TCP + TLS
    size_t maxBody = 8 << 20;             /// corpo maior que isto → erro
    size_t maxHead = 64 << 10;
    uint maxIdlePerHost = 8;
    Duration idleTimeout = 30.seconds;    /// conexão ociosa descartada depois disto
    bool verifyTls = true;                /// desligue só em testes
    string caFile;                        /// CA extra (PEM); vazio = CAs do sistema
    string userAgent = "vela";
}

// ============================================================ URL

struct ParsedUrl
{
    bool tls;
    string host;
    ushort port;
    string target; /// caminho + query, começa com '/'
}

ParsedUrl parseUrl(string url)
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
        throw new HttpClientError("vela.http: URL precisa começar com http:// ou https://: " ~ url);

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
            throw new HttpClientError("vela.http: URL com IPv6 mal formado: " ~ url);
        u.host = hostport[1 .. close_];
        hostport = hostport[close_ + 1 .. $];
        if (hostport.length)
        {
            if (hostport[0] != ':')
                throw new HttpClientError("vela.http: URL mal formada: " ~ url);
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
        throw new HttpClientError("vela.http: URL sem host: " ~ url);
    return u;
}

private ushort parsePort(string s, string url)
{
    if (s.length == 0 || s.length > 5)
        throw new HttpClientError("vela.http: porta inválida na URL: " ~ url);
    uint v;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            throw new HttpClientError("vela.http: porta inválida na URL: " ~ url);
        v = v * 10 + (ch - '0');
    }
    if (v == 0 || v > 65535)
        throw new HttpClientError("vela.http: porta inválida na URL: " ~ url);
    return cast(ushort) v;
}

// ============================================================ DNS

private struct Addr
{
    sockaddr_storage ss;
    socklen_t len;
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
        a.len = p.ai_addrlen;
        a.family = p.ai_family;
        out_ ~= a;
    }
    freeaddrinfo(res);
    return out_;
}

// ============================================================ conexão

private final class Conn
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
            close(fd);
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

/// Erro de transporte ANTES de qualquer byte da resposta: pode valer repetir em conexão nova.
private final class StaleConn : HttpClientError
{
    this() pure nothrow @safe { super("vela.http: conexão reaproveitada já estava fechada"); }
}

// ============================================================ cliente

final class HttpClient
{
    private HttpClientConfig cfg;
    private SSL_CTX* ctx;
    private Conn[][string] idle;
    private Addr[][string] dnsCache;
    private MonoTime[string] dnsExpiry;

    this(HttpClientConfig cfg = HttpClientConfig.init) { this.cfg = cfg; }

    /// Fecha tudo e libera o contexto TLS. (Sem destrutor: o cliente de um worker vive até o fim.)
    void shutdown()
    {
        closeIdle();
        if (ctx !is null)
        {
            tls.SSL_CTX_free(ctx);
            ctx = null;
        }
    }

    /// Fecha as conexões ociosas.
    void closeIdle() nothrow
    {
        foreach (k, list; idle)
            foreach (c; list)
                c.closeNow();
        idle = null;
    }

    size_t idleCount() const nothrow
    {
        size_t n;
        foreach (list; idle)
            n += list.length;
        return n;
    }

    ClientResponse get(string url, const(HeaderPair)[] headers = null)
        => request("GET", url, headers, null);

    ClientResponse post(string url, const(char)[] body_, const(HeaderPair)[] headers = null)
        => request("POST", url, headers, body_);

    ClientResponse put(string url, const(char)[] body_, const(HeaderPair)[] headers = null)
        => request("PUT", url, headers, body_);

    ClientResponse del(string url, const(HeaderPair)[] headers = null)
        => request("DELETE", url, headers, null);

    /// POST de JSON já serializado.
    ClientResponse postJson(string url, const(char)[] json, const(HeaderPair)[] headers = null)
        => request("POST", url, headers ~ HeaderPair("Content-Type", "application/json"), json);

    ClientResponse request(string method, string url, const(HeaderPair)[] headers, const(char)[] body_)
    {
        auto u = parseUrl(url);
        immutable deadline = MonoTime.currTime + cfg.timeout;
        immutable idempotent = method == "GET" || method == "HEAD" || method == "PUT" || method == "DELETE"
            || method == "OPTIONS";

        foreach (attempt; 0 .. 2)
        {
            auto c = takeIdle(u);
            if (c is null)
                c = openConn(u, deadline);
            bool good;
            scope (exit)
            {
                if (!good)
                    c.closeNow();
            }
            try
            {
                auto r = exchange(c, u, method, headers, body_, deadline, good);
                if (good)
                    giveBack(c);
                return r;
            }
            catch (StaleConn e)
            {
                if (attempt == 0 && c.reused && idempotent)
                    continue; // uma conexão velha do pool: tenta de novo, numa nova
                throw new HttpClientError("vela.http: " ~ e.msg);
            }
        }
        assert(0);
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

    // ------------------------------------------------------------ conectar

    private Conn openConn(ref const ParsedUrl u, MonoTime requestDeadline)
    {
        immutable cd = MonoTime.currTime + cfg.connectTimeout;
        immutable deadline = cd < requestDeadline ? cd : requestDeadline;

        auto addrs = resolve(u.host, u.port, deadline);
        auto c = new Conn;
        c.key = keyOf(u);

        string lastErr = "sem endereços";
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
        throw new HttpClientError("vela.http: não conectou a " ~ u.host ~ ": " ~ lastErr);
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
        auto res = offload(() => resolveBlocking(host, port));
        if (res.length == 0)
            throw new HttpClientError("vela.http: não resolveu o host " ~ host);
        dnsCache[k] = res;
        dnsExpiry[k] = MonoTime.currTime + 30.seconds;
        return res;
    }

    private void connectTcp(Conn c, ref Addr a, MonoTime deadline)
    {
        int fd = socket(a.family, SOCK_STREAM | 0x80000 /*SOCK_CLOEXEC*/ | O_NONBLOCK, 0);
        if (fd < 0)
            throw new HttpClientError("vela.http: socket falhou");
        c.fd = fd;
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, one.sizeof);

        auto r = connect(fd, cast(sockaddr*)&a.ss, a.len);
        if (r < 0 && errno != EINPROGRESS)
            throw new HttpClientError("vela.http: connect falhou");
        if (r < 0)
        {
            if (awaitFd(fd, IoEvent.writable, left(deadline)) == 0)
                throw new HttpClientTimeout("tempo esgotado ao conectar");
            int err;
            socklen_t len = err.sizeof;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
            if (err != 0)
                throw new HttpClientError("vela.http: conexão recusada ou inalcançável");
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
            throw new HttpClientError("vela.http: SSL_new falhou");
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
                    throw new HttpClientTimeout("tempo esgotado no handshake TLS");
                continue;
            }
            throw new HttpClientError("vela.http: falha no handshake TLS: " ~ tlsError());
        }
    }

    private SSL_CTX* makeCtx()
    {
        auto x = tls.SSL_CTX_new(tls.TLS_client_method());
        if (x is null)
            throw new HttpClientError("vela.http: SSL_CTX_new falhou");
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
                    throw new HttpClientError("vela.http: não consegui ler caFile: " ~ cfg.caFile);
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
            return "erro desconhecido";
        char[256] buf;
        tls.ERR_error_string_n(e, buf.ptr, buf.length);
        return buf[0 .. strlen(buf.ptr)].idup;
    }

    // ------------------------------------------------------------ E/S

    /// Lê o que houver; devolve 0 em EOF. Espera cooperativamente.
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
                    return 0; // EOF sem close_notify
                throw new HttpClientError("vela.http: erro TLS ao ler: " ~ tlsError());
            }
            immutable n = read(c.fd, buf.ptr, buf.length);
            if (n > 0)
                return n;
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
            throw new HttpClientError("vela.http: erro de leitura");
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
                throw staleOr(c, "erro TLS ao escrever: " ~ tlsError());
            }
            immutable n = send(c.fd, data.ptr, data.length, 0x4000 /*MSG_NOSIGNAL*/);
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
            throw staleOr(c, "erro de escrita");
        }
    }

    /// Conexão reaproveitada que falha ao escrever = provavelmente velha.
    private static HttpClientError staleOr(Conn c, string msg)
    {
        if (c.reused)
            return new StaleConn;
        return new HttpClientError("vela.http: " ~ msg);
    }

    /// Garante pelo menos um byte novo no buffer; false se o servidor fechou.
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

    // ------------------------------------------------------------ requisição/resposta

    private ClientResponse exchange(Conn c, ref const ParsedUrl u, string method, const(HeaderPair)[] headers,
        const(char)[] body_, MonoTime deadline, ref bool reusable)
    {
        // ---- monta e envia
        char[] req;
        req.reserve(256 + body_.length);
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
        if (body_.length || method == "POST" || method == "PUT" || method == "PATCH")
        {
            if (!hasCL)
            {
                req ~= "Content-Length: ";
                req ~= utoa(body_.length);
                req ~= "\r\n";
            }
        }
        req ~= "\r\n";
        req ~= body_;
        sendAll(c, req, deadline);

        // ---- cabeçalho
        size_t headEnd;
        for (;;)
        {
            headEnd = findHeadEnd(c.rbuf[c.rpos .. c.rend]);
            if (headEnd != size_t.max)
                break;
            if (c.rend - c.rpos > cfg.maxHead)
                throw new HttpClientError("vela.http: cabeçalho da resposta grande demais");
            if (!fill(c, deadline))
            {
                if (c.rend == c.rpos && c.reused)
                    throw new StaleConn;
                throw new HttpClientError("vela.http: servidor fechou antes de responder");
            }
        }
        auto head = c.rbuf[c.rpos .. c.rpos + headEnd];
        c.rpos += headEnd + 4;

        ClientResponse r;
        parseHead(head, r);

        // ---- corpo
        bool chunked, hasLen, closeDelim;
        size_t length;
        bool keepAlive = true;
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
                keepAlive = false;
        }
        immutable noBody = method == "HEAD" || r.status == 204 || r.status == 304 || (r.status >= 100 && r.status < 200);

        if (noBody)
        {
        }
        else if (chunked)
            r.body = readChunked(c, deadline);
        else if (hasLen)
        {
            if (length > cfg.maxBody)
                throw new HttpClientError("vela.http: corpo da resposta maior que maxBody");
            r.body = readExact(c, length, deadline);
        }
        else
        {
            closeDelim = true;
            r.body = readToEof(c, deadline);
        }
        reusable = keepAlive && !closeDelim && c.rpos == c.rend;
        return r;
    }

    private string readExact(Conn c, size_t n, MonoTime deadline)
    {
        auto out_ = new char[n];
        size_t got;
        immutable have = c.rend - c.rpos;
        immutable take = have < n ? have : n;
        memcpy(out_.ptr, c.rbuf.ptr + c.rpos, take);
        c.rpos += take;
        got = take;
        while (got < n)
        {
            immutable m = recvSome(c, out_[got .. $], deadline);
            if (m == 0)
                throw new HttpClientError("vela.http: servidor fechou no meio do corpo");
            got += m;
        }
        return cast(string) out_;
    }

    private string readToEof(Conn c, MonoTime deadline)
    {
        char[] out_;
        out_ ~= c.rbuf[c.rpos .. c.rend];
        c.rpos = c.rend = 0;
        char[8192] tmp;
        for (;;)
        {
            immutable m = recvSome(c, tmp[], deadline);
            if (m == 0)
                break;
            if (out_.length + m > cfg.maxBody)
                throw new HttpClientError("vela.http: corpo da resposta maior que maxBody");
            out_ ~= tmp[0 .. m];
        }
        return cast(string) out_;
    }

    private string readChunked(Conn c, MonoTime deadline)
    {
        char[] out_;
        for (;;)
        {
            auto line = readLine(c, deadline);
            size_t semi = line.length;
            foreach (i, ch; line)
                if (ch == ';')
                {
                    semi = i;
                    break;
                }
            immutable size = parseHex(line[0 .. semi]);
            if (size == 0)
            {
                // trailers até a linha vazia
                for (;;)
                    if (readLine(c, deadline).length == 0)
                        break;
                return cast(string) out_;
            }
            if (out_.length + size > cfg.maxBody)
                throw new HttpClientError("vela.http: corpo da resposta maior que maxBody");
            auto chunk = readExact(c, size, deadline);
            out_ ~= chunk;
            if (readLine(c, deadline).length != 0)
                throw new HttpClientError("vela.http: chunk mal formado");
        }
    }

    private const(char)[] readLine(Conn c, MonoTime deadline)
    {
        for (;;)
        {
            // linhas são curtas: varrer de novo a partir de rpos é barato e imune à compactação do buffer
            for (size_t i = c.rpos; i + 1 < c.rend; i++)
                if (c.rbuf[i] == '\r' && c.rbuf[i + 1] == '\n')
                {
                    auto line = c.rbuf[c.rpos .. i].idup;
                    c.rpos = i + 2;
                    return line;
                }
            if (c.rend - c.rpos > cfg.maxHead)
                throw new HttpClientError("vela.http: linha grande demais na resposta");
            if (!fill(c, deadline))
                throw new HttpClientError("vela.http: servidor fechou no meio do corpo");
        }
    }
}

// ============================================================ auxiliares

private size_t findHeadEnd(const(char)[] b) pure nothrow @safe @nogc
{
    if (b.length < 4)
        return size_t.max;
    foreach (i; 0 .. b.length - 3)
        if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
            return i;
    return size_t.max;
}

private void parseHead(const(char)[] head, ref ClientResponse r)
{
    // "HTTP/1.1 200 OK"
    if (head.length < 12 || head[0 .. 5] != "HTTP/")
        throw new HttpClientError("vela.http: resposta HTTP inválida");
    size_t sp = 0;
    while (sp < head.length && head[sp] != ' ')
        sp++;
    if (sp + 4 > head.length)
        throw new HttpClientError("vela.http: linha de status inválida");
    int st;
    foreach (i; 0 .. 3)
    {
        immutable ch = head[sp + 1 + i];
        if (ch < '0' || ch > '9')
            throw new HttpClientError("vela.http: status inválido");
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
            throw new HttpClientError("vela.http: nome de header inválido: " ~ h.name);
    foreach (ch; h.value)
        if (ch == '\r' || ch == '\n')
            throw new HttpClientError("vela.http: valor de header com quebra de linha (" ~ h.name ~ ")");
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

private size_t parseSize(string s)
{
    if (s.length == 0 || s.length > 18)
        throw new HttpClientError("vela.http: Content-Length inválido");
    size_t v;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            throw new HttpClientError("vela.http: Content-Length inválido");
        v = v * 10 + (ch - '0');
    }
    return v;
}

private size_t parseHex(const(char)[] s)
{
    if (s.length == 0 || s.length > 12)
        throw new HttpClientError("vela.http: tamanho de chunk inválido");
    size_t v;
    foreach (ch; s)
    {
        int d;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        else throw new HttpClientError("vela.http: tamanho de chunk inválido");
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

// ============================================================ cliente do worker

private HttpClient tlsClient; // thread-local: um por worker

/// O cliente deste worker (criado no primeiro uso). Para outra configuração,
/// use `httpClient(cfg)` uma vez na inicialização do worker.
HttpClient httpClient()
{
    if (tlsClient is null)
        tlsClient = new HttpClient;
    return tlsClient;
}

HttpClient httpClient(HttpClientConfig cfg)
{
    return tlsClient = new HttpClient(cfg);
}

unittest
{
    auto u = parseUrl("https://api.exemplo.com/v1/x?a=1#frag");
    assert(u.tls && u.host == "api.exemplo.com" && u.port == 443 && u.target == "/v1/x?a=1");
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
