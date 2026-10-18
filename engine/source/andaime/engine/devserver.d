/// DEVELOPMENT server: blocking, one connection at a time.
/// It exists so you can `curl` the example before M2. It was replaced by
/// EpollLoop, but it already uses the final pieces: parser, BufferPool, Limits.
module andaime.engine.devserver;

import andaime.http;
import andaime.engine.bufferpool;
import andaime.engine.loop : RequestCallback, ServerConfig;
import andaime.engine.os : initSockets, sockRead, sockSend, sockClose;

version (Posix)
{
    import core.sys.posix.sys.socket;
    import core.sys.posix.netinet.in_;
    import core.sys.posix.sys.time : timeval;
    import core.stdc.errno : errno, EINTR;
}
else version (Windows)
{
    import core.sys.windows.winsock2;
    import core.stdc.errno : errno, EINTR;
}
import core.stdc.stdio : fprintf, stderr, printf, perror;

void runDevServer(ref const ServerConfig cfg, RequestCallback onRequest)
{
    if (!cfg.accept)
    {
        // No epoll loop here, so there is nothing to poll and no background fiber to park in `sleep`.
        // `spawn` already ran any delegate inline (jobs need the epoll engine). Do not block in accept().
        return;
    }
    if (cfg.tls.enabled)
    {
        fprintf(stderr, "andaime: TLS needs the event loop engine; the development server only speaks cleartext HTTP/1.1\n");
        return;
    }
    initSockets();
    version (Windows)
        int fd = cast(int) socket(AF_INET, SOCK_STREAM, 0);
    else
        int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return perror("socket");
    int one = 1;
    version (Windows)
        setsockopt(cast(SOCKET) fd, SOL_SOCKET, SO_REUSEADDR, cast(const(char)*)&one, one.sizeof);
    else
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);

    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(cfg.port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    version (Windows)
    {
        if (bind(cast(SOCKET) fd, cast(sockaddr*)&addr, addr.sizeof) < 0)
            return perror("bind");
        if (listen(cast(SOCKET) fd, cfg.backlog) < 0)
            return perror("listen");
    }
    else
    {
        if (bind(fd, cast(sockaddr*)&addr, addr.sizeof) < 0)
            return perror("bind");
        if (listen(fd, cfg.backlog) < 0)
            return perror("listen");
    }
    printf("andaime (dev server, blocking) at http://localhost:%d\n", cast(int) cfg.port);

    BufferPool pool;
    ByteBuffer output;
    HeaderField[64] headerStore;

    while (true)
    {
        version (Windows)
            int c = cast(int) accept(cast(SOCKET) fd, null, null);
        else
            int c = accept(fd, null, null);
        if (c < 0)
        {
            if (errno == EINTR)
                continue;
            perror("accept");
            continue;
        }
        version (Windows)
        {
            int tv = 5000;
            setsockopt(cast(SOCKET) c, SOL_SOCKET, SO_RCVTIMEO, cast(const(char)*)&tv, tv.sizeof);
        }
        else
        {
            timeval tv = timeval(5, 0); // a stuck client does not hold the dev server
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
        }
        serveConnection(c, cfg, pool, output, headerStore[], onRequest);
        sockClose(c);
        output.shrinkTo(64 << 10); // does not hold on to the peak of a large response
    }
}

private void serveConnection(int c, ref const ServerConfig cfg, ref BufferPool pool,
    ref ByteBuffer output, HeaderField[] headerStore, RequestCallback onRequest)
{
    Buffer buf = pool.acquire(4096);
    scope (exit)
        pool.release(buf);
    auto sink = new BufferedSink;

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
            auto n = sockRead(c, buf.free_.ptr, buf.free_.length);
            if (n <= 0)
                return; // EOF, timeout or error: close without a response
            buf.len += n;
        }
        if (h.status == ParseStatus.error)
            return sendError(c, h.errorStatus);

        // ---- body
        immutable total = h.headLength + h.contentLength;
        if (total > buf.mem.length)
        {
            if (!pool.grow(buf, total))
                return sendError(c, 413);
            // the buffer moved: redo the parse so the slices point into it
            parseRequestHead(cast(const(char)[]) buf.data, req, headerStore, cfg.limits);
        }
        while (buf.len < total)
        {
            auto n = sockRead(c, buf.free_.ptr, total - buf.len);
            if (n <= 0)
                return;
            buf.len += n;
        }
        req.body = buf.mem[h.headLength .. total];

        // ---- response (the whole thing is collected first: the development server does not stream)
        sink.reset();
        onRequest(req, sink);
        auto head = sink.head;
        head.contentLength = sink.body.length;
        output.clear();
        writeResponseHead(output, head, req.keepAlive, false);
        if (req.method != Method.HEAD && !statusHasNoBody(head.status))
            output.put(sink.body.data);
        if (!sendAll(c, output.data))
            return;
        if (!req.keepAlive)
            return;
        buf.compact(total); // pipelining: what is left over is the next request
    }
}

private bool sendAll(int c, const(char)[] data)
{
    while (data.length)
    {
        auto n = sockSend(c, data.ptr, data.length);
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
