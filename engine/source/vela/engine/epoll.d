/// Linux event loop: edge-triggered epoll, one fiber per request.
///
/// Flow of a connection (`Conn.phase`):
///   reading -> (head+body complete) -> running -> writing -> reading ...
/// `running` is the handler inside a fiber; if it calls `sleep`/`awaitFd`,
/// the fiber is suspended and the loop moves on with the other connections. When the fiber
/// comes back (timer or ready fd), the loop resumes where it stopped.
///
/// Cancellation: if the client closes while the fiber is suspended (EPOLLRDHUP)
/// or the request deadline expires, the handler's next wait throws
/// `RequestCancelled`; the stack unwinds running `scope(exit)` and destructors.
///
/// Pools: idle fibers above `maxIdleWorkers` are torn down (the stack goes back
/// to the OS); network buffers go to the `BufferPool`, which has its own ceiling.
///
/// HTTP/2 (h2c): a connection that starts with the client preface, or upgrades with
/// `Upgrade: h2c`, moves to `Phase.h2`. From then on an `H2Session` (vela.http.h2, no I/O)
/// parses the frames; each request it reports gets its own fiber, exactly like an HTTP/1
/// request, and its response goes back to the session, which frames it with flow control.
/// Cancellation, deadlines and the in-flight ceiling apply per stream.
///
/// TLS (`ServerConfig.tls`): an accepted connection starts in `Phase.handshake`; once the
/// handshake completes, ALPN decides between HTTP/2 and HTTP/1.1, and every read and write goes
/// through `ioRead`/`ioSend`, which hide OpenSSL behind read(2)/send(2) semantics.
module vela.engine.epoll;

version (linux):

import core.thread : Fiber, Thread;
import core.time : MonoTime;
import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno;
import core.stdc.stdio : printf, fprintf, stderr, perror;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.netinet.tcp : TCP_NODELAY;
import core.sys.posix.arpa.inet : inet_pton;
import core.sys.posix.unistd : close, read, write, sysconf, _SC_NPROCESSORS_ONLN;
import core.sys.posix.signal;
import core.sys.linux.epoll;
import core.sys.linux.sys.eventfd : eventfd;

import vela.http;
import vela.http.h2;
import vela.engine.bufferpool;
import vela.engine.loop;
import vela.engine.fiberio;
import vela.engine.tls : SSL;
import vela.engine.tlsserver;

private extern (C) int accept4(int, sockaddr*, socklen_t*, int) nothrow @nogc;
version (CRuntime_Glibc)
    private extern (C) int malloc_trim(size_t) nothrow @nogc;
private void mallocTrim(size_t pad) nothrow @nogc
{
    version (CRuntime_Glibc)
        malloc_trim(pad);
}
private enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;

// ======================================================================= structures

/// Headers per request. Each fiber carries its own table (32 B per entry), so
/// the value weighs on every in-flight request; above it the parser answers 431.
private enum maxHeaders = 32;

private enum Kind : ubyte { listener, wake, conn, waiter }

private class Item
{
    immutable Kind kind;
    this(Kind k) nothrow @nogc @safe { kind = k; }
}

private enum Phase : ubyte { reading, running, writing, closed, h2, handshake }

private struct Stack(T)
{
    T[] a;
    size_t n;

    bool empty() const pure nothrow @nogc @safe => n == 0;
    void push(T v) nothrow
    {
        if (n == a.length)
            a.length = a.length ? a.length * 2 : 16;
        a[n++] = v;
    }
    T pop() nothrow
    {
        auto v = a[--n];
        a[n] = T.init;
        return v;
    }
}

private final class Conn : Item
{
    int fd = -1;
    Phase phase;
    Buffer buf;
    bool haveHead;
    bool sent100;          /// already answered 100 Continue to this request
    size_t headLen, total; /// geometry of the current request (valid with haveHead)
    Worker worker;         /// while running/writing
    size_t sent;           /// bytes of worker.output already sent
    long deadlineMs;       /// loop's monotonic clock; 0 = no deadline
    bool fresh;            /// no request served yet (HTTP/2 prior knowledge only at the start)
    // HTTP/2 (Phase.h2)
    H2Session h2;
    bool h2Paused;         /// stopped reading: too much output queued for a peer that does not read
    long blockedSinceMs;   /// output waiting for EPOLLOUT since then (0 = not blocked)
    // TLS
    SSL* ssl;              /// null on a cleartext connection
    bool tlsFatal;         /// the TLS session broke: close without close_notify

    this() nothrow @safe { super(Kind.conn); }
}

private final class WaitItem : Item
{
    Worker w;
    this() nothrow @safe { super(Kind.waiter); }
}

private struct Timer
{
    long dl;
    Worker w;
    uint gen;
}

private final class Worker : Fiber
{
    EpollLoop loop;
    RequestCallback cb;
    Conn conn;
    H2Stream stream;       /// set when the request is an HTTP/2 stream
    Request req;
    HeaderField[maxHeaders] store;
    ByteBuffer output;
    WaitItem item;

    bool done, cancelled, timedOut, failed, closeAfter, retiring;
    bool waiting, timerPending;
    uint waitGen;
    int waitFd = -1;
    uint wakeEvents;

    this(EpollLoop l, size_t stackBytes)
    {
        super(&run, stackBytes);
        loop = l;
        cb = l.factory();
        item = new WaitItem;
        item.w = this;
    }

    private void run()
    {
        for (;;)
        {
            if (retiring)
                return;
            done = false;
            try
                cb(req, output);
            catch (RequestCancelled)
                cancelled = true;
            catch (Throwable t)
            {
                failed = true;
                fprintf(stderr, "vela: unhandled error in handler: %.*s\n",
                    cast(int) t.msg.length, t.msg.ptr);
            }
            done = true;
            Fiber.yield();
        }
    }
}

// ======================================================================= the loop

final class EpollLoop : EventLoop, Scheduler
{
    private ServerConfig cfg;
    private HandlerFactory factory;

    private int ep = -1, listenFd = -1, wakeFd = -1;
    private Item listenItem, wakeItem;
    private BufferPool pool;
    private HeaderField[maxHeaders] scratch;
    private ByteBuffer errOut;

    private Conn[] conns; /// by fd
    private Stack!Conn spare, dead;
    private Stack!Worker idle;
    private Stack!H2Session spareSessions;
    private Worker[] h2Scratch;     /// workers of one connection, collected before cancelling them
    private ByteBuffer upgradeSettings;
    private size_t h2Conns, h2Streams;
    private TlsServer tlsServer;
    private size_t tlsHandshakes, tlsFailures;
    /// Ticket keys shared by every worker (set by runEpollServer; random per loop otherwise).
    TicketKeys ticketKeys;
    private bool haveTicketKeys;
    private Timer[] heap;
    private size_t heapN, staleTimers;

    private MonoTime t0;
    private long nowMs;
    private long nextSweepMs;
    private long stopDeadlineMs;
    private size_t connCount, inFlight, peakInFlight, workersCreated, workersRetired;
    private size_t rejected, cancelledN, timedOutN, stalls;
    private long quietSinceMs;      /// since when inFlight == 0 (0 = busy)
    private size_t createdAtTrim;  /// workersCreated at the last cleanup
    private size_t trims;
    private long maxStallMs, lastStallLogMs = -1_000_000;
    private bool stopping;
    private shared bool stopReq;
    private RequestCancelled cancelledEx;

    /// Port this loop listens on (useful with `port = 0`); valid when `ready`.
    ushort boundPort;
    shared bool ready;

    this()
    {
        ep = epoll_create1(0);
        wakeFd = eventfd(0, 0x800 /*EFD_NONBLOCK*/ | 0x80000 /*EFD_CLOEXEC*/);
        wakeItem = new Item(Kind.wake);
        epoll_event ev;
        ev.events = EPOLLIN;
        ev.data.ptr = cast(void*) wakeItem;
        epoll_ctl(ep, EPOLL_CTL_ADD, wakeFd, &ev);
        cancelledEx = new RequestCancelled;
    }

    ~this()
    {
        if (ep >= 0) close(ep);
        if (wakeFd >= 0) close(wakeFd);
    }

    LoopStats stats() const nothrow @nogc
    {
        return LoopStats(inFlight, peakInFlight, workersCreated, workersRetired, idle.n,
            connCount, rejected, cancelledN, timedOutN, stalls, maxStallMs, h2Conns, h2Streams,
            tlsHandshakes, tlsFailures, tlsServer.reloads);
    }

    /// How many times the loop returned memory to the OS after a burst.
    size_t trimCount() const nothrow @nogc => trims;

    // @trusted overrides: the interfaces are @safe for callers; the bodies are this loop's own
    // syscalls and fiber switches, which touch only this worker's state.
    override void stop() nothrow @nogc @trusted
    {
        atomicStore(stopReq, true);
        ulong one = 1;
        write(wakeFd, &one, one.sizeof);
    }

    // ------------------------------------------------------------------ run

    override void run(ref const ServerConfig c, HandlerFactory f)
    {
        cfg = c;
        factory = f;
        t0 = MonoTime.currTime;
        currentScheduler = this;
        scope (exit)
        {
            currentScheduler = null;
            teardown();
        }
        if (!openListener())
            return;
        nowMs = elapsedMs();
        nextSweepMs = nowMs + sweepEveryMs;
        atomicStore(ready, true);

        epoll_event[256] evs;
        for (;;)
        {
            long timeout = nextSweepMs - nowMs;
            if (heapN)
            {
                immutable w = heap[0].dl - nowMs;
                if (w < timeout)
                    timeout = w;
            }
            if (stopping && timeout > 50)
                timeout = 50;
            if (timeout < 0)
                timeout = 0;

            immutable n = epoll_wait(ep, evs.ptr, cast(int) evs.length, cast(int) timeout);
            if (n < 0 && errno != EINTR)
                break;
            nowMs = elapsedMs();

            foreach (i; 0 .. (n < 0 ? 0 : n))
                onEvent(cast(Item) evs[i].data.ptr, evs[i].events);
            drainResumeQ();
            flushDead();

            fireTimers();
            drainResumeQ();
            flushDead();

            if (nowMs >= nextSweepMs)
            {
                sweep();
                drainResumeQ();
                flushDead();
                trimIfQuiet();
                nextSweepMs = nowMs + sweepEveryMs;
            }

            if (atomicLoad(stopReq) && !stopping)
                beginStop();
            if (stopping)
            {
                closeIdleConns();
                flushDead();
                if (inFlight == 0 && connCount == 0)
                    break;
                if (nowMs >= stopDeadlineMs)
                    break;
            }
        }
    }

    private enum sweepEveryMs = 250;

    private long elapsedMs() const nothrow @nogc
    {
        return (MonoTime.currTime - t0).total!"msecs";
    }

    // ------------------------------------------------------------------ listener

    /// Uses the same session ticket keys as other workers (call before `run`).
    void shareTicketKeys(ref const TicketKeys k) nothrow @nogc
    {
        ticketKeys = k;
        haveTicketKeys = true;
    }

    private bool openListener()
    {
        if (cfg.tls.enabled)
        {
            if (!haveTicketKeys)
                ticketKeys = TicketKeys.random();
            if (auto err = tlsServer.load(cfg.tls, cfg.http2, ticketKeys))
            {
                fprintf(stderr, "%.*s\n", cast(int) err.length, err.ptr);
                return false;
            }
        }
        listenFd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (listenFd < 0)
        {
            perror("vela: socket");
            return false;
        }
        int one = 1;
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);
        if (cfg.reusePort)
            setsockopt(listenFd, SOL_SOCKET, SO_REUSEPORT, &one, one.sizeof);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_port = htons(cfg.port);
        char[64] host = 0;
        if (cfg.host.length == 0 || cfg.host.length >= host.length)
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
        else
        {
            host[0 .. cfg.host.length] = cfg.host[];
            if (inet_pton(AF_INET, host.ptr, &addr.sin_addr) != 1)
            {
                fprintf(stderr, "vela: invalid host: %s\n", host.ptr);
                return false;
            }
        }
        if (bind(listenFd, cast(sockaddr*)&addr, addr.sizeof) < 0)
        {
            perror("vela: bind");
            return false;
        }
        if (listen(listenFd, cast(int) cfg.backlog) < 0)
        {
            perror("vela: listen");
            return false;
        }
        sockaddr_in got;
        socklen_t gl = got.sizeof;
        getsockname(listenFd, cast(sockaddr*)&got, &gl);
        boundPort = ntohs(got.sin_port);

        listenItem = new Item(Kind.listener);
        epoll_event ev;
        ev.events = EPOLLIN; // level-triggered: if connections remain after the batch, the next wait reports them
        ev.data.ptr = cast(void*) listenItem;
        epoll_ctl(ep, EPOLL_CTL_ADD, listenFd, &ev);
        return true;
    }

    private void acceptSome()
    {
        foreach (_; 0 .. 64)
        {
            immutable fd = accept4(listenFd, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (fd < 0)
                return; // EAGAIN, EMFILE...: the next wait tries again
            if (connCount >= cfg.maxConnections || stopping)
            {
                close(fd);
                continue;
            }
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, one.sizeof);

            Conn c = spare.empty ? new Conn : spare.pop();
            c.fd = fd;
            c.phase = Phase.reading;
            c.buf = Buffer.init;
            c.haveHead = false;
            c.sent100 = false;
            c.headLen = c.total = c.sent = 0;
            c.worker = null;
            c.fresh = true;
            c.h2 = null;
            c.h2Paused = false;
            c.blockedSinceMs = 0;
            c.ssl = null;
            c.tlsFatal = false;
            c.deadlineMs = nowMs + cfg.idleTimeoutMs;
            if (cfg.tls.enabled)
            {
                c.ssl = tlsServer.accept(fd);
                if (c.ssl is null)
                {
                    close(fd);
                    spare.push(c);
                    continue;
                }
                c.phase = Phase.handshake;
                c.deadlineMs = nowMs + cfg.headerTimeoutMs; // the handshake counts as part of the head
            }
            if (fd >= conns.length)
                conns.length = fd + 1024;
            conns[fd] = c;
            connCount++;

            epoll_event ev;
            ev.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET;
            ev.data.ptr = cast(void*) c;
            epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
        }
    }

    // ------------------------------------------------------------------ events

    private void onEvent(Item it, uint events)
    {
        final switch (it.kind)
        {
            case Kind.listener:
                if (!stopping)
                    acceptSome();
                break;
            case Kind.wake:
                ulong v;
                read(wakeFd, &v, v.sizeof);
                break;
            case Kind.conn:
                onConnEvent(cast(Conn) cast(void*) it, events);
                break;
            case Kind.waiter:
                onWaiter((cast(WaitItem) cast(void*) it).w, events);
                break;
        }
    }

    private void onConnEvent(Conn c, uint events)
    {
        if (c.fd < 0)
            return; // closed in this same batch
        if (c.phase == Phase.h2)
            return onH2Event(c, events);
        if (c.phase == Phase.handshake)
            return continueHandshake(c, events);
        if (events & EPOLLERR)
        {
            if (c.phase == Phase.running)
                cancelRequest(c, false);
            else
                closeConn(c);
            return;
        }
        if (events & (EPOLLHUP | EPOLLRDHUP))
        {
            final switch (c.phase)
            {
                case Phase.running:
                    cancelRequest(c, false);
                    break;
                case Phase.writing:
                    closeConn(c);
                    break;
                case Phase.reading:
                    drive(c); // there may be a complete request before the FIN
                    if (c.fd >= 0 && c.phase == Phase.reading)
                        closeConn(c);
                    break;
                case Phase.closed:
                case Phase.h2:
                case Phase.handshake:
                    break;
            }
            return;
        }
        if ((events & EPOLLOUT) && c.phase == Phase.writing)
        {
            trySend(c);
            if (c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
        }
        // over TLS a read can wait on writability (OpenSSL answering the peer): EPOLLOUT resumes it too
        immutable readable = (events & EPOLLIN) || (c.ssl !is null && (events & EPOLLOUT));
        if (readable && c.fd >= 0 && c.phase == Phase.reading)
            drive(c);
    }

    private void onWaiter(Worker w, uint events)
    {
        if (!w.waiting)
            return; // late event from a wait that already ended
        w.wakeEvents = events;
        wake(w);
        Conn c = w.conn;
        resume(w);
        if (c.fd >= 0 && c.phase == Phase.reading)
            drive(c);
    }

    // ------------------------------------------------------------------ reading and parsing

    private enum Step : ubyte { needMore, ready, failed }

    /// Reads and processes whatever is on the connection, until it waits for more bytes,
    /// suspends in a handler or closes. Never recursive.
    private void drive(Conn c)
    {
        for (;;)
        {
            if (c.fd < 0 || c.phase != Phase.reading)
                return;
            // prior knowledge is a cleartext feature: over TLS, HTTP/2 is chosen by ALPN (RFC 9113 §3.3)
            if (cfg.http2 && c.fresh && c.ssl is null && !c.buf.isNull && c.buf.len >= 2 && c.buf.mem[0] == 'P'
                && c.buf.mem[1] == 'R' && !stopping)
            {
                // "PR": no HTTP/1 method starts like that; the session checks the full preface
                switchToH2(c);
                return driveH2(c);
            }
            final switch (tryParse(c))
            {
                case Step.ready:
                    if (cfg.http2 && !stopping && tryUpgrade(c))
                        return;
                    startRequest(c);
                    break; // back to the top: there may be another pipelined request
                case Step.needMore:
                    if (!fill(c))
                        return;
                    break;
                case Step.failed:
                    return;
            }
        }
    }

    /// Reads until EAGAIN. Returns false if there is nothing more to read right now (or it closed).
    private bool fill(Conn c)
    {
        if (c.buf.isNull)
            c.buf = pool.acquire(4096); // only borrows when the first byte arrives
        bool any = false;
        for (;;)
        {
            if (c.buf.free_.length == 0)
            {
                if (!pool.grow(c.buf, c.buf.mem.length + 1))
                {
                    sendErrorAndClose(c, 431);
                    return false;
                }
            }
            immutable wasEmpty = c.buf.len == 0;
            immutable r = ioRead(c, c.buf.free_.ptr, c.buf.free_.length);
            if (r > 0)
            {
                if (wasEmpty)
                    c.deadlineMs = nowMs + cfg.headerTimeoutMs; // not extended on every byte
                c.buf.len += r;
                any = true;
                // a full buffer goes to the parser first: once it knows the head, it sizes the
                // buffer for the whole body (growing here would only fit a head)
                if (c.buf.free_.length == 0)
                    return true;
                if (c.ssl is null)
                    return true; // short read: the kernel drained it (TLS reads one record at a time)
                continue;
            }
            if (r == 0)
            {
                closeConn(c);
                return false;
            }
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN)
            {
                if (c.buf.len == 0)
                    pool.release(c.buf); // nothing arrived: do not hold the buffer
                return any;
            }
            closeConn(c);
            return false;
        }
    }

    private Step tryParse(Conn c)
    {
        if (c.buf.isNull || c.buf.len == 0)
            return Step.needMore;
        if (!c.haveHead)
        {
            Request tmp;
            auto h = parseRequestHead(cast(const(char)[]) c.buf.data, tmp, scratch[], cfg.limits);
            if (h.status == ParseStatus.incomplete)
                return Step.needMore;
            if (h.status == ParseStatus.error)
            {
                sendErrorAndClose(c, h.errorStatus);
                return Step.failed;
            }
            c.haveHead = true;
            c.headLen = h.headLength;
            c.total = h.headLength + h.contentLength;
            if (c.total > c.buf.mem.length && !pool.grow(c.buf, c.total))
            {
                sendErrorAndClose(c, 413);
                return Step.failed;
            }
        }
        // Expect: 100-continue: the client waits for the go-ahead before sending the body.
        // The parser already refused (413/417) what is not worth receiving.
        if (!c.sent100 && c.buf.len < c.total)
        {
            Request tmp;
            parseRequestHead(cast(const(char)[]) c.buf.data, tmp, scratch[], cfg.limits);
            if (equalsIgnoreCase(tmp.header("expect"), "100-continue"))
            {
                c.sent100 = true;
                sendRaw(c, "HTTP/1.1 100 Continue\r\n\r\n");
            }
        }
        return c.buf.len >= c.total ? Step.ready : Step.needMore;
    }

    // ------------------------------------------------------------------ request

    private void startRequest(Conn c)
    {
        if (inFlight >= cfg.maxInFlight)
        {
            rejected++;
            static immutable HeaderField[1] retry = [HeaderField("Retry-After", "1")];
            errOut.clear();
            writeResponseHead(errOut, 503, null, 0, retry[], false);
            sendRaw(c, errOut.data);
            closeConn(c);
            return;
        }
        c.fresh = false;
        Worker w = acquireWorker();
        // second parse, now into the fiber's own structures (parsing is cheap;
        // the head stays alive while the fiber is suspended)
        parseRequestHead(cast(const(char)[]) c.buf.data, w.req, w.store[], cfg.limits);
        w.req.body = c.buf.mem[c.headLen .. c.total];
        if (stopping)
            w.req.keepAlive = false; // draining: the response announces Connection: close
        w.conn = c;
        w.output.clear();
        w.cancelled = w.timedOut = w.failed = w.closeAfter = false;
        c.worker = w;
        c.phase = Phase.running;
        c.deadlineMs = nowMs + cfg.requestTimeoutMs;
        resume(w);
    }

    private Worker acquireWorker()
    {
        Worker w;
        if (!idle.empty)
            w = idle.pop();
        else
        {
            w = new Worker(this, cfg.fiberStackBytes);
            workersCreated++;
        }
        inFlight++;
        if (inFlight > peakInFlight)
            peakInFlight = inFlight;
        return w;
    }

    private void releaseWorker(Worker w)
    {
        w.conn = null;
        w.stream = null;
        inFlight--;
        w.output.shrinkTo(64 << 10); // a response peak does not stay pinned to the fiber
        if (idle.n < cfg.maxIdleWorkers)
            idle.push(w);
        else
        {
            // really ends the fiber (the stack goes back to the OS) and releases the object
            w.retiring = true;
            w.call();
            destroy(w);
            workersRetired++;
        }
    }

    private void resume(Worker w)
    {
        immutable t = MonoTime.currTime;
        w.call();
        if (cfg.stallWarnMs)
        {
            immutable ms = (MonoTime.currTime - t).total!"msecs";
            if (ms >= cfg.stallWarnMs)
                noteStall(w, ms);
        }
        if (w.done)
            finish(w);
    }

    /// A handler went `ms` without giving the worker back to the loop: during that time no
    /// other connection of this worker made progress. Always counts; warns at most once per second.
    private void noteStall(Worker w, long ms)
    {
        stalls++;
        if (ms > maxStallMs)
            maxStallMs = ms;
        immutable now = elapsedMs();
        if (now - lastStallLogMs < 1000)
            return;
        lastStallLogMs = now;
        auto m = methodName(w.req.method);
        fprintf(stderr, "vela: warning: a handler held the worker for %ld ms without yielding (%.*s %.*s); "
            ~ "wait with sleep/awaitFd or move the heavy work out of the loop\n", ms,
            cast(int) m.length, m.ptr, cast(int) w.req.path.length, w.req.path.ptr);
    }

    /// The handler returned (or was cancelled): decides what to send.
    private void finish(Worker w)
    {
        if (w.stream !is null)
            return finishH2(w);
        Conn c = w.conn;
        if (w.cancelled)
        {
            if (w.timedOut)
            {
                timedOutN++;
                w.output.clear();
                static immutable body504 = `{"detail":"request time limit exceeded"}`;
                writeResponseHead(w.output, 504, "application/json", body504.length, null, false);
                w.output.put(body504);
                w.closeAfter = true;
            }
            else
            {
                cancelledN++;
                closeConn(c); // client already gone
                return;
            }
        }
        else if (w.failed)
        {
            w.output.clear();
            writeResponseHead(w.output, 500, "text/plain; charset=utf-8", 21, null, false);
            w.output.put("Internal Server Error");
            w.closeAfter = true;
        }
        c.phase = Phase.writing;
        c.sent = 0;
        c.deadlineMs = nowMs + cfg.writeTimeoutMs;
        trySend(c);
    }

    private void trySend(Conn c)
    {
        auto w = c.worker;
        auto data = w.output.data;
        while (c.sent < data.length)
        {
            immutable n = ioSend(c, data.ptr + c.sent, data.length - c.sent);
            if (n > 0)
            {
                c.sent += n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
                return; // wait for the next EPOLLOUT
            closeConn(c);
            return;
        }
        completeResponse(c);
    }

    private void completeResponse(Conn c)
    {
        auto w = c.worker;
        immutable keep = w.req.keepAlive && !w.closeAfter && !stopping;
        c.worker = null;
        releaseWorker(w);
        if (!keep)
        {
            closeConn(c);
            return;
        }
        c.buf.compact(c.total); // what is left over is the next request (pipelining)
        c.haveHead = false;
        c.sent100 = false;
        c.headLen = c.total = c.sent = 0;
        if (c.buf.len == 0)
            pool.release(c.buf); // idle: do not hold the buffer
        c.phase = Phase.reading;
        c.deadlineMs = nowMs + cfg.idleTimeoutMs;
    }

    // ------------------------------------------------------------------ cancellation

    /// Client went away (`timeout = false`) or the deadline expired (`true`).
    private void cancelRequest(Conn c, bool timeout)
    {
        auto w = c.worker;
        if (w is null || c.phase != Phase.running)
            return;
        cancelWorker(w, timeout);
    }

    private void cancelWorker(Worker w, bool timeout)
    {
        if (w.done || w.cancelled)
            return;
        w.cancelled = true;
        w.timedOut = timeout;
        if (w.waiting)
        {
            wake(w);
            resume(w); // the wait throws RequestCancelled; the stack unwinds and the fiber ends
        }
    }

    // ------------------------------------------------------------------ TLS

    /// read(2) on the connection, through TLS when there is a session.
    private ptrdiff_t ioRead(Conn c, void* p, size_t n)
    {
        if (c.ssl is null)
            return read(c.fd, p, n);
        return tlsRead(c.ssl, p, n, c.tlsFatal);
    }

    /// send(2) on the connection, through TLS when there is a session.
    private ptrdiff_t ioSend(Conn c, const(void)* p, size_t n)
    {
        if (c.ssl is null)
            return send(c.fd, p, n, MSG_NOSIGNAL);
        return tlsWrite(c.ssl, p, n, c.tlsFatal);
    }

    private void continueHandshake(Conn c, uint events)
    {
        if (events & EPOLLERR)
        {
            tlsFailures++;
            return closeConn(c);
        }
        final switch (tlsHandshake(c.ssl))
        {
            case Handshake.again:
                if (events & (EPOLLHUP | EPOLLRDHUP))
                {
                    tlsFailures++;
                    closeConn(c); // the client left halfway
                }
                return;
            case Handshake.failed:
                tlsFailures++;
                c.tlsFatal = true;
                return closeConn(c);
            case Handshake.done:
                break;
        }
        tlsHandshakes++;
        if (cfg.http2 && !stopping && tlsIsH2(c.ssl))
        {
            switchToH2(c);
            return driveH2(c); // the client preface may already be decrypted and waiting
        }
        c.phase = Phase.reading;
        c.deadlineMs = nowMs + cfg.idleTimeoutMs;
        drive(c);
    }

    // ------------------------------------------------------------------ HTTP/2

    private H2Session acquireSession()
    {
        if (!spareSessions.empty)
            return spareSessions.pop();
        H2Config hc;
        hc.maxConcurrentStreams = cfg.http2MaxStreams;
        hc.initialWindowSize = cfg.http2StreamWindowBytes;
        hc.connectionWindowSize = cfg.http2ConnectionWindowBytes;
        hc.maxHeaders = maxHeaders;
        hc.limits = cfg.limits;
        return new H2Session(hc);
    }

    private void switchToH2(Conn c, H2Session s = null)
    {
        c.h2 = s !is null ? s : acquireSession();
        c.h2.nowMs = nowMs;
        c.phase = Phase.h2;
        c.fresh = false;
        c.h2Paused = false;
        c.blockedSinceMs = 0;
        c.deadlineMs = 0;
        h2Conns++;
    }

    /// HTTP/1.1 request with `Upgrade: h2c`: answers 101 and continues as HTTP/2, the request
    /// becoming stream 1. Returns false to serve it as plain HTTP/1.1 (not an upgrade, or bad settings).
    private bool tryUpgrade(Conn c)
    {
        if (c.ssl !is null)
            return false; // "h2c" means cleartext; over TLS the token is ignored (RFC 9113 §3.1)
        Request tmp;
        parseRequestHead(cast(const(char)[]) c.buf.data, tmp, scratch[], cfg.limits);
        const(char)[] settings;
        if (!wantsH2cUpgrade(tmp, settings))
            return false;
        upgradeSettings.clear();
        if (!decodeBase64Url(settings, upgradeSettings))
            return false;
        auto s = acquireSession();
        s.nowMs = nowMs;
        if (!s.startUpgrade(tmp, c.buf.mem[c.headLen .. c.total], cast(const(ubyte)[]) upgradeSettings.data))
        {
            s.reset();
            spareSessions.push(s);
            return false;
        }
        // the session copied the request: what follows in the buffer is the client preface
        c.buf.compact(c.total);
        c.haveHead = false;
        c.sent100 = false;
        c.headLen = c.total = 0;
        switchToH2(c, s);
        dispatchH2(c); // stream 1 starts now; the client preface may already be in the buffer
        driveH2(c);
        return true;
    }

    private void onH2Event(Conn c, uint events)
    {
        if (events & EPOLLERR)
            return closeConn(c);
        if (events & EPOLLOUT)
        {
            flushH2(c);
            if (c.fd < 0)
                return;
        }
        if ((events & (EPOLLIN | EPOLLHUP | EPOLLRDHUP)) || (c.ssl !is null && (events & EPOLLOUT)))
            driveH2(c);
        if (c.fd >= 0 && (events & (EPOLLHUP | EPOLLRDHUP)))
            closeConn(c); // the peer stopped sending: whatever it asked for can no longer matter
    }

    /// Reads frames until EAGAIN, starting a fiber for each request that completes. Never
    /// recursive: flushing does not read, and reading pauses while output is backed up.
    private void driveH2(Conn c)
    {
        auto s = c.h2;
        for (;;)
        {
            if (c.fd < 0)
                return;
            if (!c.buf.isNull && c.buf.len)
            {
                s.nowMs = nowMs;
                immutable n = s.receive(c.buf.data);
                c.buf.compact(n);
                dispatchH2(c);
                if (c.fd < 0)
                    return;
            }
            if (s.fatal)
                break;
            if (!s.wantsRead)
            {
                flushH2(c);
                if (c.fd < 0)
                    return;
                if (!s.wantsRead)
                {
                    c.h2Paused = true; // EPOLLOUT resumes reading once the output drains
                    return;
                }
            }
            // room for at least the next frame (the buffer starts at a frame boundary)
            if (c.buf.isNull)
                c.buf = pool.acquire(4096);
            immutable want = s.needBytes > c.buf.len ? s.needBytes : c.buf.len + 1;
            if (want > c.buf.mem.length && !pool.grow(c.buf, want))
            {
                closeConn(c); // cannot happen with our 16 KiB frames; the session would have failed first
                return;
            }
            immutable r = ioRead(c, c.buf.free_.ptr, c.buf.free_.length);
            if (r > 0)
            {
                c.buf.len += r;
                continue;
            }
            if (r < 0 && errno == EINTR)
                continue;
            if (r < 0 && errno == EAGAIN)
            {
                if (c.buf.len == 0)
                    pool.release(c.buf); // an idle HTTP/2 connection holds no buffer either
                break;
            }
            closeConn(c); // EOF or error
            return;
        }
        flushH2(c);
    }

    /// Hands the session's events to fibers: cancellations first, then new requests.
    private void dispatchH2(Conn c)
    {
        auto s = c.h2;
        H2Stream st;
        while (s.popReset(st))
        {
            auto w = cast(Worker) st.task;
            if (w !is null && !w.done)
                cancelWorker(w, false); // its fiber unwinds; finishH2 gives the stream back
            else
                s.detach(st);
        }
        while (c.fd >= 0 && s.popReady(st))
            startStream(c, st);
    }

    private void startStream(Conn c, H2Stream st)
    {
        auto s = c.h2;
        if (inFlight >= cfg.maxInFlight)
        {
            rejected++;
            s.cancelStream(st, H2Error.refusedStream); // safe for the client to retry
            return;
        }
        h2Streams++;
        Worker w = acquireWorker();
        w.req = st.req;
        w.conn = c;
        w.stream = st;
        w.output.clear();
        w.cancelled = w.timedOut = w.failed = w.closeAfter = false;
        st.task = w;
        st.deadlineMs = nowMs + cfg.requestTimeoutMs;
        resume(w);
    }

    /// A stream's handler returned (or was cancelled).
    private void finishH2(Worker w)
    {
        Conn c = w.conn;
        auto st = w.stream;
        w.stream = null;
        if (c.fd < 0 || c.h2 is null)
        {
            // the connection is gone: closeH2 detaches every stream itself
            st.task = null;
            releaseWorker(w);
            return;
        }
        auto s = c.h2;
        if (w.cancelled && !w.timedOut)
        {
            cancelledN++;
            s.detach(st); // the peer reset it: nothing to send
            releaseWorker(w);
            return flushH2(c);
        }
        if (w.timedOut)
        {
            timedOutN++;
            w.output.clear();
            static immutable body504 = `{"detail":"request time limit exceeded"}`;
            writeResponseHead(w.output, 504, "application/json", body504.length, null, true);
            w.output.put(body504);
        }
        else if (w.failed)
        {
            w.output.clear();
            writeResponseHead(w.output, 500, "text/plain; charset=utf-8", 21, null, true);
            w.output.put("Internal Server Error");
        }
        s.respond(st, w.output); // swaps buffers: the body is not copied
        releaseWorker(w);
        flushH2(c);
    }

    /// Writes what the session has queued. Closes the connection once the session is done.
    private void flushH2(Conn c)
    {
        if (c.fd < 0)
            return;
        auto s = c.h2;
        for (;;)
        {
            auto data = s.pendingOutput;
            if (data.length == 0)
                break;
            immutable n = ioSend(c, data.ptr, data.length);
            if (n > 0)
            {
                c.blockedSinceMs = 0;
                s.sent(n); // may queue more DATA
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
            {
                if (c.blockedSinceMs == 0)
                    c.blockedSinceMs = nowMs;
                return; // EPOLLOUT continues
            }
            closeConn(c);
            return;
        }
        c.blockedSinceMs = 0;
        if (s.finished)
            return closeConn(c);
        // idle clock: starts when the last stream ends, stops while any stream is open
        if (s.busy)
            c.deadlineMs = 0;
        else if (c.deadlineMs == 0)
            c.deadlineMs = nowMs + cfg.idleTimeoutMs;
        if (c.h2Paused && s.wantsRead)
        {
            c.h2Paused = false;
            // resume from the loop, not from here: EPOLLIN will not fire again for bytes
            // that were already waiting, so read them now (the caller is never driveH2)
            driveH2Later(c);
        }
    }

    /// Connections whose reading was paused and can go on; drained by `onH2Event`/sweep.
    private void driveH2Later(Conn c)
    {
        resumeQ.push(c);
    }

    private Stack!Conn resumeQ;

    private void drainResumeQ()
    {
        while (!resumeQ.empty)
        {
            auto c = resumeQ.pop();
            if (c.fd >= 0 && c.phase == Phase.h2)
                driveH2(c);
        }
    }

    /// Deadlines of one HTTP/2 connection (called from `sweep`).
    private void sweepH2(Conn c)
    {
        auto s = c.h2;
        s.tick();
        if (c.blockedSinceMs && nowMs - c.blockedSinceMs > cfg.writeTimeoutMs)
            return closeConn(c); // the client does not read
        if (s.busy == 0 && c.deadlineMs && nowMs >= c.deadlineMs)
        {
            s.goAway(); // idle too long
            return flushH2(c);
        }
        // collect first: cancelling resumes fibers, which changes the session's stream list
        size_t n = 0;
        foreach (st; s.activeStreams)
        {
            if (st.task !is null)
            {
                if (st.deadlineMs && nowMs >= st.deadlineMs)
                {
                    if (n == h2Scratch.length)
                        h2Scratch.length = h2Scratch.length ? h2Scratch.length * 2 : 16;
                    h2Scratch[n++] = cast(Worker) st.task;
                }
            }
            else if (st.state == StreamState.open && nowMs - st.openedMs >= cfg.headerTimeoutMs)
                s.timeoutStream(st, 408); // headers or body too slow
        }
        foreach (i; 0 .. n)
        {
            cancelWorker(h2Scratch[i], true); // 504 through finishH2
            h2Scratch[i] = null;
        }
        if (c.fd >= 0)
            flushH2(c);
    }

    /// The socket is closed: cancels every handler still running on it, recycles the session.
    private void closeH2(Conn c)
    {
        auto s = c.h2;
        size_t n = 0;
        foreach (st; s.activeStreams)
            if (st.task !is null)
            {
                if (n == h2Scratch.length)
                    h2Scratch.length = h2Scratch.length ? h2Scratch.length * 2 : 16;
                h2Scratch[n++] = cast(Worker) st.task;
            }
        foreach (i; 0 .. n)
        {
            auto w = h2Scratch[i];
            h2Scratch[i] = null;
            if (!w.done)
            {
                cancelledN++;
                cancelWorker(w, false); // finishH2 sees the closed socket and only releases it
            }
        }
        c.h2 = null;
        if (spareSessions.n < 16)
        {
            s.reset();
            spareSessions.push(s);
        }
        else
            s.releaseMemory(); // the object goes to the GC; its buffers go back to the OS now
    }

    // ------------------------------------------------------------------ Scheduler

    override bool inRequest() nothrow
    {
        return cast(Worker) Fiber.getThis() !is null;
    }

    override uint awaitFd(int fd, uint events, long timeoutMs) @trusted
    {
        auto w = cast(Worker) Fiber.getThis();
        assert(w !is null, "vela: awaitFd outside a request fiber");
        if (w.cancelled)
            throw cancelledEx;

        epoll_event ev;
        ev.events = events | EPOLLONESHOT;
        ev.data.ptr = cast(void*) w.item;
        if (epoll_ctl(ep, EPOLL_CTL_MOD, fd, &ev) < 0)
        {
            if (errno != ENOENT || epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev) < 0)
                return IoEvent.error;
        }
        w.waitFd = fd;
        beginWait(w, timeoutMs);
        Fiber.yield();
        if (w.cancelled)
            throw cancelledEx;
        return w.wakeEvents;
    }

    override void sleepMs(long ms) @trusted
    {
        auto w = cast(Worker) Fiber.getThis();
        assert(w !is null, "vela: sleep outside a request fiber");
        if (w.cancelled)
            throw cancelledEx;
        beginWait(w, ms);
        Fiber.yield();
        if (w.cancelled)
            throw cancelledEx;
    }

    private void beginWait(Worker w, long timeoutMs)
    {
        w.waiting = true;
        w.wakeEvents = 0;
        w.timerPending = false;
        w.waitGen++;
        if (timeoutMs >= 0)
        {
            heapPush(Timer(nowMs + timeoutMs, w, w.waitGen));
            w.timerPending = true;
        }
    }

    /// Ends the wait of `w` (fd ready, timer or cancellation).
    private void wake(Worker w)
    {
        w.waiting = false;
        if (w.timerPending)
            staleTimers++; // the Timer stays in the heap until it expires; it no longer counts
        w.timerPending = false;
        w.waitGen++;
        w.waitFd = -1;
    }

    // ------------------------------------------------------------------ timers (min-heap)

    private void heapPush(Timer t)
    {
        if (heapN == heap.length)
            heap.length = heap.length ? heap.length * 2 : 64;
        size_t i = heapN++;
        heap[i] = t;
        while (i > 0)
        {
            immutable p = (i - 1) / 2;
            if (heap[p].dl <= heap[i].dl)
                break;
            auto tmp = heap[p]; heap[p] = heap[i]; heap[i] = tmp;
            i = p;
        }
    }

    private Timer heapPop()
    {
        auto top = heap[0];
        heap[0] = heap[--heapN];
        heap[heapN] = Timer.init;
        siftDown(0);
        return top;
    }

    private void siftDown(size_t i)
    {
        for (;;)
        {
            size_t l = 2 * i + 1, r = l + 1, m = i;
            if (l < heapN && heap[l].dl < heap[m].dl) m = l;
            if (r < heapN && heap[r].dl < heap[m].dl) m = r;
            if (m == i)
                return;
            auto tmp = heap[m]; heap[m] = heap[i]; heap[i] = tmp;
            i = m;
        }
    }

    private void fireTimers()
    {
        while (heapN && heap[0].dl <= nowMs)
        {
            auto t = heapPop();
            auto w = t.w;
            if (t.gen != w.waitGen || !w.waiting)
            {
                if (staleTimers) staleTimers--;
                continue;
            }
            w.timerPending = false;
            w.wakeEvents = 0;
            wake(w);
            Conn c = w.conn;
            resume(w);
            if (c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
        }
        // a wait that ends early leaves dead Timers in the heap: clean up when they pass half
        if (heapN > 1024 && staleTimers * 2 > heapN)
            compactHeap();
    }

    private void compactHeap()
    {
        size_t k = 0;
        foreach (i; 0 .. heapN)
            if (heap[i].gen == heap[i].w.waitGen && heap[i].w.waiting)
                heap[k++] = heap[i];
        foreach (i; k .. heapN)
            heap[i] = Timer.init;
        heapN = k;
        staleTimers = 0;
        if (k > 1)
            for (size_t i = k / 2; i-- > 0;)
                siftDown(i);
    }

    // ------------------------------------------------------------------ connection deadlines

    /// Sweeps the connections every 250 ms. With 10 thousand connections that is ~40 thousand
    /// comparisons per second; a timer wheel only comes in if the profile asks for it (M4).
    private void sweep()
    {
        foreach (c; conns)
        {
            if (c is null || c.fd < 0 || c.deadlineMs == 0 || c.deadlineMs > nowMs || c.phase == Phase.h2)
                continue;
            if (c.phase == Phase.handshake)
            {
                tlsFailures++;
                closeConn(c); // handshake too slow (or never started)
                continue;
            }
            final switch (c.phase)
            {
                case Phase.reading:
                    if (c.buf.isNull || c.buf.len == 0)
                        closeConn(c); // keep-alive idle for too long
                    else
                        sendErrorAndClose(c, 408); // head/body too slow
                    break;
                case Phase.running:
                    cancelRequest(c, true);
                    break;
                case Phase.writing:
                    closeConn(c); // client does not read
                    break;
                case Phase.closed:
                case Phase.h2:
                case Phase.handshake:
                    break;
            }
        }
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.h2)
                sweepH2(c);
        if (cfg.tls.enabled)
            if (auto msg = tlsServer.maybeReload(cfg.tls, nowMs))
                fprintf(stderr, "%.*s\n", cast(int) msg.length, msg.ptr);
    }

    // ------------------------------------------------------------------ closing

    private void sendRaw(Conn c, const(char)[] data)
    {
        // error responses are short: one non-blocking send is enough
        ioSend(c, data.ptr, data.length);
    }

    private void sendErrorAndClose(Conn c, int status)
    {
        errOut.clear();
        writeResponseHead(errOut, status, null, 0, null, false);
        sendRaw(c, errOut.data);
        closeConn(c);
    }

    private void closeConn(Conn c)
    {
        if (c.fd < 0)
            return;
        if (c.ssl !is null)
        {
            // close_notify only after a completed handshake on an intact session
            tlsClose(c.ssl, !c.tlsFatal && c.phase != Phase.handshake);
            c.ssl = null;
        }
        close(c.fd); // the kernel removes the fd from epoll
        conns[c.fd] = null;
        c.fd = -1;
        connCount--;
        if (!c.buf.isNull)
            pool.release(c.buf);
        if (c.h2 !is null)
            closeH2(c);
        if (c.worker !is null)
        {
            auto w = c.worker;
            c.worker = null;
            releaseWorker(w);
        }
        c.phase = Phase.closed;
        dead.push(c);
    }

    /// Closed Conn objects only go back to the pool at the end of the event batch: a
    /// late event from the same batch still points at them (and sees fd < 0).
    private void flushDead()
    {
        while (!dead.empty)
        {
            auto c = dead.pop();
            if (spare.n < 1024)
                spare.push(c);
        }
    }

    // ------------------------------------------------------------------ memory after a burst

    /// After a burst (>= trimBurst fibers created) and 1 s with no request in
    /// progress, returns memory to the OS: without it RSS stays at the peak, because the torn-down Contexts
    /// and Workers become garbage nobody collects while the server is idle.
    /// The collection stops the other workers for a few ms, once per burst.
    private void trimIfQuiet()
    {
        if (!cfg.trimAfterBurst)
            return;
        if (inFlight != 0)
        {
            quietSinceMs = 0;
            return;
        }
        if (quietSinceMs == 0)
        {
            quietSinceMs = nowMs;
            return;
        }
        if (nowMs - quietSinceMs < 1000 || workersCreated - createdAtTrim < trimBurst)
            return;
        createdAtTrim = workersCreated;
        trims++;
        import core.memory : GC;

        GC.collect();
        GC.minimize();
        version (CRuntime_Glibc)
        {
            mallocTrim(0);
        }
    }

    private enum trimBurst = 128;

    // ------------------------------------------------------------------ stop

    private void beginStop()
    {
        stopping = true;
        stopDeadlineMs = nowMs + cfg.shutdownGraceMs;
        if (listenFd >= 0)
        {
            epoll_ctl(ep, EPOLL_CTL_DEL, listenFd, null);
            close(listenFd);
            listenFd = -1;
        }
    }

    private void closeIdleConns()
    {
        foreach (c; conns)
        {
            if (c is null || c.fd < 0)
                continue;
            if (c.phase == Phase.handshake || (c.phase == Phase.reading && (c.buf.isNull || c.buf.len == 0)))
                closeConn(c);
            else if (c.phase == Phase.h2)
            {
                c.h2.goAway(); // streams already accepted finish; the connection closes after them
                flushH2(c);
            }
        }
    }

    private void teardown()
    {
        // tears down whatever is still suspended: each handler receives RequestCancelled
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.running)
                cancelRequest(c, false);
        foreach (c; conns)
            if (c !is null && c.fd >= 0)
                closeConn(c);
        flushDead();
        while (!idle.empty)
        {
            auto w = idle.pop();
            w.retiring = true;
            w.call();
            destroy(w);
        }
        if (listenFd >= 0)
        {
            close(listenFd);
            listenFd = -1;
        }
        atomicStore(ready, false);
    }
}

// ======================================================================= multiple workers

private __gshared EpollLoop[] gLoops;

private extern (C) void onSignal(int) nothrow @nogc
{
    foreach (l; gLoops)
        l.stop();
}

private Thread startWorker(EpollLoop lp, ServerConfig cfg, HandlerFactory f)
{
    auto t = new Thread({ lp.run(cfg, f); });
    t.start();
    return t;
}

/// Starts `cfg.workers` loops (one per core if 0) and blocks until SIGINT/SIGTERM.
void runEpollServer(ServerConfig cfg, HandlerFactory factory)
{
    uint n = cfg.workers;
    if (n == 0)
    {
        immutable cpus = sysconf(_SC_NPROCESSORS_ONLN);
        n = cpus > 0 ? cast(uint) cpus : 1;
    }
    TicketKeys keys;
    if (cfg.tls.enabled)
    {
        // fail before starting any worker, with one message (each worker loads its own context)
        TlsServer probe;
        keys = TicketKeys.random();
        if (auto err = probe.load(cfg.tls, cfg.http2, keys))
        {
            fprintf(stderr, "%.*s\n", cast(int) err.length, err.ptr);
            return;
        }
    }
    foreach (_; 0 .. n)
    {
        auto l = new EpollLoop;
        if (cfg.tls.enabled)
            l.shareTicketKeys(keys);
        gLoops ~= l;
    }

    sigaction_t sa;
    sa.sa_handler = &onSignal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, null);
    sigaction(SIGTERM, &sa, null);

    printf("vela (epoll, %u worker%s) at %s://%.*s:%d\n", n, n == 1 ? "".ptr : "s".ptr,
        cfg.tls.enabled ? "https".ptr : "http".ptr,
        cast(int) cfg.host.length, cfg.host.ptr, cast(int) cfg.port);

    Thread[] threads;
    foreach (i; 1 .. n)
        threads ~= startWorker(gLoops[i], cfg, factory);
    gLoops[0].run(cfg, factory); // worker 0 runs on the main thread
    foreach (t; threads)
        t.join();
}
