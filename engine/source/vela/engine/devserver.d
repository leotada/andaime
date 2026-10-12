/// Servidor de DESENVOLVIMENTO: bloqueante, uma conexão por vez.
/// Existe para dar `curl` no exemplo antes do M2. Será substituído pelo
/// EpollLoop, mas já usa as peças definitivas: parser, BufferPool, Limits.
module vela.engine.devserver;

import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd : close, read;
import core.sys.posix.sys.time : timeval;
import core.stdc.errno : errno, EINTR;
import core.stdc.stdio : printf, perror;

import vela.http;
import vela.engine.bufferpool;
import vela.engine.loop : RequestCallback, ServerConfig;

void runDevServer(ref const ServerConfig cfg, RequestCallback onRequest)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return perror("socket");
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);

    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(cfg.port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, cast(sockaddr*)&addr, addr.sizeof) < 0)
        return perror("bind");
    if (listen(fd, cfg.backlog) < 0)
        return perror("listen");
    printf("vela (dev server, bloqueante) em http://localhost:%d\n", cast(int) cfg.port);

    BufferPool pool;
    ByteBuffer output;
    HeaderField[64] headerStore;

    while (true)
    {
        int c = accept(fd, null, null);
        if (c < 0)
        {
            if (errno == EINTR)
                continue;
            perror("accept");
            continue;
        }
        timeval tv = timeval(5, 0); // cliente travado não prende o dev server
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
        serveConnection(c, cfg, pool, output, headerStore[], onRequest);
        close(c);
        output.shrinkTo(64 << 10); // não segura o pico de uma resposta grande
    }
}

private void serveConnection(int c, ref const ServerConfig cfg, ref BufferPool pool,
    ref ByteBuffer output, HeaderField[] headerStore, RequestCallback onRequest)
{
    Buffer buf = pool.acquire(4096);
    scope (exit)
        pool.release(buf);

    while (true)
    {
        // ---- head
        Request req;
        HeadResult h;
        while (true)
        {
            h = parseRequestHead(cast(const(char)[]) buf.data, req, headerStore, cfg.limits);
            if (h.status != ParseStatus.incomplete)
                break;
            if (buf.free_.length == 0 && !pool.grow(buf, buf.mem.length + 1))
                return sendError(c, 431);
            auto n = read(c, buf.free_.ptr, buf.free_.length);
            if (n <= 0)
                return; // EOF, timeout ou erro: fecha sem resposta
            buf.len += n;
        }
        if (h.status == ParseStatus.error)
            return sendError(c, h.errorStatus);

        // ---- corpo
        immutable total = h.headLength + h.contentLength;
        if (total > buf.mem.length)
        {
            if (!pool.grow(buf, total))
                return sendError(c, 413);
            // o buffer mudou de lugar: refaz o parse para as fatias apontarem para ele
            parseRequestHead(cast(const(char)[]) buf.data, req, headerStore, cfg.limits);
        }
        while (buf.len < total)
        {
            auto n = read(c, buf.free_.ptr, total - buf.len);
            if (n <= 0)
                return;
            buf.len += n;
        }
        req.body = buf.mem[h.headLength .. total];

        // ---- resposta
        output.clear();
        onRequest(req, output);
        if (!sendAll(c, output.data))
            return;
        if (!req.keepAlive)
            return;
        buf.compact(total); // pipelining: o que sobrou é a próxima requisição
    }
}

private bool sendAll(int c, const(char)[] data)
{
    while (data.length)
    {
        auto n = send(c, data.ptr, data.length, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        data = data[n .. $];
    }
    return true;
}

private void sendError(int c, int status)
{
    ByteBuffer o;
    writeResponseHead(o, status, null, 0, null, false);
    sendAll(c, o.data);
}
