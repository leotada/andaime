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
import vela.engine.bufferpool;
import vela.engine.loop;
import vela.engine.fiberio;

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

private enum Phase : ubyte { reading, running, writing, closed }

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
            connCount, rejected, cancelledN, timedOutN, stalls, maxStallMs);
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
            flushDead();

            fireTimers();
            flushDead();

            if (nowMs >= nextSweepMs)
            {
                sweep();
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

    private bool openListener()
    {
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
            c.deadlineMs = nowMs + cfg.idleTimeoutMs;
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
        if ((events & EPOLLIN) && c.fd >= 0 && c.phase == Phase.reading)
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
            final switch (tryParse(c))
            {
                case Step.ready:
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
            immutable r = read(c.fd, c.buf.free_.ptr, c.buf.free_.length);
            if (r > 0)
            {
                if (wasEmpty)
                    c.deadlineMs = nowMs + cfg.headerTimeoutMs; // not extended on every byte
                c.buf.len += r;
                any = true;
                if (c.buf.free_.length != 0)
                    return true; // short read: the kernel drained it
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
            immutable n = send(c.fd, data.ptr + c.sent, data.length - c.sent, MSG_NOSIGNAL);
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
        w.cancelled = true;
        w.timedOut = timeout;
        if (w.waiting)
        {
            wake(w);
            resume(w); // the wait throws RequestCancelled; the stack unwinds and the fiber ends
        }
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
            if (c is null || c.fd < 0 || c.deadlineMs == 0 || c.deadlineMs > nowMs)
                continue;
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
                    break;
            }
        }
    }

    // ------------------------------------------------------------------ closing

    private void sendRaw(Conn c, const(char)[] data)
    {
        // error responses are short: one non-blocking send is enough
        send(c.fd, data.ptr, data.length, MSG_NOSIGNAL);
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
        close(c.fd); // the kernel removes the fd from epoll
        conns[c.fd] = null;
        c.fd = -1;
        connCount--;
        if (!c.buf.isNull)
            pool.release(c.buf);
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
            if (c !is null && c.fd >= 0 && c.phase == Phase.reading && (c.buf.isNull || c.buf.len == 0))
                closeConn(c);
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
    foreach (_; 0 .. n)
        gLoops ~= new EpollLoop;

    sigaction_t sa;
    sa.sa_handler = &onSignal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, null);
    sigaction(SIGTERM, &sa, null);

    printf("vela (epoll, %u worker%s) at http://%.*s:%d\n", n, n == 1 ? "".ptr : "s".ptr,
        cast(int) cfg.host.length, cfg.host.ptr, cast(int) cfg.port);

    Thread[] threads;
    foreach (i; 1 .. n)
        threads ~= startWorker(gLoops[i], cfg, factory);
    gLoops[0].run(cfg, factory); // worker 0 runs on the main thread
    foreach (t; threads)
        t.join();
}
