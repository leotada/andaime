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
import core.sys.posix.arpa.inet : inet_pton, inet_ntop;
import core.sys.posix.unistd : close, read, write, sysconf, _SC_NPROCESSORS_ONLN;
import core.sys.posix.signal;
import core.sys.linux.epoll;
import core.sys.linux.sys.eventfd : eventfd;

import vela.http;
import vela.http.h2;
import vela.http.chunked : ChunkedDecoder, ChunkResult;
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

/// A listening socket. `redirect`: the cleartext port next to a TLS listener (ACME + 308).
private final class ListenItem : Item
{
    int fd = -1;
    bool redirect;
    this(bool r) nothrow @safe { super(Kind.listener); redirect = r; }
}

/// `upgraded`: taken over after a 101 (a WebSocket); its bytes go through `Conn.port`, never back to HTTP.
private enum Phase : ubyte { reading, running, writing, closed, h2, handshake, upgraded }

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
    bool chunked;          /// the request body is `Transfer-Encoding: chunked` (decoded in place by `dec`)
    bool chunkDone;        /// the last chunk and the trailers were read
    ChunkedDecoder dec;
    size_t headLen, total; /// geometry of the current request (valid with haveHead)
    uint headSerial;       /// counts the heads parsed on this connection (tells `parsedHead` whose head it holds)
    Worker worker;         /// while running/writing
    size_t sent;           /// bytes of worker.output already sent
    ByteBuffer pending;    /// finished responses to pipelined requests, not sent yet (see `coalesce`); they go out first
    size_t pendingOff;     /// bytes of `pending` already sent
    bool pendingQueued;    /// in the loop's `pendingQ`
    bool closeWhenSent;    /// an error response ended the connection: close once `pending` is out
    long deadlineMs;       /// loop's monotonic clock; 0 = no deadline
    bool fresh;            /// no request served yet (HTTP/2 prior knowledge only at the start)
    bool redirect;         /// accepted on the redirect port: answered by the engine, never the app
    uint peerIp;           /// client IPv4 address (network order), recorded at accept for the logs
    ushort peerPort;       /// its port (host order)
    // HTTP/2 (Phase.h2)
    H2Session h2;
    bool h2Paused;         /// stopped reading: too much output queued for a peer that does not read
    uint writersWaiting;   /// HTTP/2: handlers suspended because their stream's output is above the high-water mark
    bool waking;           /// inside wakeH2Writers (not reentrant)
    bool lingering;        /// FIN sent, discarding what the peer still sends until it closes (see lingerClose)
    long blockedSinceMs;   /// output waiting for EPOLLOUT since then (0 = not blocked)
    // TLS
    SSL* ssl;              /// null on a cleartext connection
    bool tlsFatal;         /// the TLS session broke: close without close_notify
    // Taken over after a 101 (Phase.upgraded, see `sinkUpgrade`)
    WsPort port;           /// what the handler reads and writes through; null otherwise
    Buffer wsIn;           /// received and not consumed yet, from `wsInOff`
    size_t wsInOff;
    ByteBuffer wsOut;      /// written and not sent yet, from `wsOutOff`; any fiber of the worker may append
    size_t wsOutOff;
    Worker readWaiter;     /// the owner, while it waits for input
    Worker[] wsWriters;    /// fibers waiting for `wsOut` to drain
    bool wsEof;            /// the peer finished sending (a read returned 0)
    bool wsBroken;         /// the connection failed: reads report the end, writes throw
    bool wsClosing;        /// the owner is done: send what is left, then close
    bool wsStopSeen;       /// `fill` already reported the graceful stop

    this() nothrow @safe { super(Kind.conn); }

    bool hasPending() const nothrow @nogc @safe => pendingOff < pending.length;
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

private final class Worker : Fiber, ResponseSink
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
    bool upgraded;         /// the handler took the connection over (`upgrade`): it never goes back to HTTP

    // The response being written (see the sink methods): what the handler has done so far.
    ResponseHead h2head;   /// HTTP/2: the head, sent when the response is committed (its slices live in the App's Context)
    long remaining = -1;   /// known length: bytes still expected
    bool started, ended;   /// start() / end() were called
    bool chunked;          /// HTTP/1.1 framing for an unknown length
    bool noBody;           /// HEAD, 204, 304: writes are discarded
    bool committed;        /// HTTP/2: HEADERS (and possibly body) already handed to the session
    bool h2done;           /// HTTP/2: endResponse gave the stream back to the session
    bool flushedAny;       /// some response bytes already reached the transport: a 500 is no longer possible
    bool waitingWrite;     /// suspended until the connection (or the stream's output) can take more
    bool poisoned;        /// an `Error` escaped the handler: cleanup code may not have run, so this fiber is never reused
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

    // ResponseSink: small @trusted bodies; the work is in the loop (raw syscalls and fiber switches on this worker's
    // own state).
    override void start(ref const ResponseHead head) @trusted { loop.sinkStart(this, head); }
    override void write(scope const(char)[] data) @trusted { loop.sinkWrite(this, data); }
    override void flush() @trusted { loop.sinkFlush(this); }
    override void end() @trusted { loop.sinkEnd(this); }
    override UpgradedConn upgrade(ref const ResponseHead head, scope const(char)[] protocol) @trusted
    {
        return loop.sinkUpgrade(this, head, protocol);
    }

    void resetResponseState() nothrow @nogc
    {
        cancelled = timedOut = failed = closeAfter = upgraded = false;
        started = ended = chunked = noBody = committed = h2done = flushedAny = waitingWrite = false;
        remaining = -1;
        h2head = ResponseHead.init;
    }

    private void run()
    {
        for (;;)
        {
            if (retiring)
                return;
            done = false;
            try
                cb(req, this);
            catch (RequestCancelled)
                cancelled = true;
            catch (ResponseAborted)
                failed = true; // already logged by the web layer; the response is cut off
            catch (Throwable t)
            {
                failed = true;
                // An Exception that got this far came from the glue around the app; an Error (RangeError, AssertError,
                // a failed contract...) may have skipped cleanup code, so the fiber and its Context are thrown away.
                if (cast(Exception) t is null)
                    poisoned = true;
                loop.noteHandlerFailure(this, t);
            }
            done = true;
            Fiber.yield();
        }
    }
}

/// A connection taken over after `101 Switching Protocols` (a WebSocket): what `ResponseSink.upgrade` returns. One object
/// per upgrade, so a `WsConn` that outlives its connection finds `conn` null here, never a later connection that reuses
/// the same pooled `Conn`.
private final class WsPort : UpgradedConn
{
    EpollLoop loop;
    Conn conn;    /// null once the connection ended
    Worker owner; /// the fiber that upgraded it: the only one that reads

    this(EpollLoop l, Conn c, Worker w) nothrow @safe
    {
        loop = l;
        conn = c;
        owner = w;
    }

    // small @trusted bodies: the work is in the loop (syscalls and fiber switches on this worker's own state)
    override const(ubyte)[] buffered() @trusted { return loop.wsBuffered(this); }
    override FillResult fill(int timeoutMs) @trusted { return loop.wsFill(this, timeoutMs); }
    override void consume(size_t n) @trusted { loop.wsConsume(this, n); }
    override void write(scope const(ubyte)[] data) @trusted { loop.wsWrite(this, data); }
    override void close() @trusted { loop.wsClose(this); }
}

// ======================================================================= the loop

final class EpollLoop : EventLoop, Scheduler
{
    private ServerConfig cfg;
    private HandlerFactory factory;

    private int ep = -1, wakeFd = -1;
    private ListenItem mainListener, redirectListener;
    private Item wakeItem;
    private size_t redirectsN;
    private long lastConnLogMs = -1_000_000;
    private size_t suppressedConnLogs;
    private char[160] tlsReason;
    private BufferPool pool;
    private HeaderField[maxHeaders] scratch;
    // The head `parseHead` parsed last (its headers are in `scratch`) and whose it is; see `parsedHead`.
    private Request head;
    private Conn headOf;
    private uint headSerial;
    private const(ubyte)* headBase;
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
    private size_t handlerErrors, fibersPoisoned;
    private long failWindowMs = -1_000_000;
    private size_t failLogged, failSuppressed;
    private long quietSinceMs;      /// since when inFlight == 0 (0 = busy)
    private size_t createdAtTrim;  /// workersCreated at the last cleanup
    private size_t trims;
    private long maxStallMs, lastStallLogMs = -1_000_000;
    private bool stopping;
    private shared bool stopReq;
    private RequestCancelled cancelledEx;

    /// Port this loop listens on (useful with `port = 0`); valid when `ready`.
    ushort boundPort;
    /// Port of the cleartext redirect listener (`tls.redirectPort`), 0 when there is none.
    ushort boundRedirectPort;
    shared bool ready;
    /// Set once the listener is open and never cleared (`ready` goes back to false at teardown).
    shared bool everListened;

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
            tlsHandshakes, tlsFailures, tlsServer.reloads, redirectsN, handlerErrors, fibersPoisoned, wsOpen, wsTotal);
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
        installCrashReport(cfg.fiberStackBytes);
        scope (exit)
        {
            removeCrashReportStack();
            currentScheduler = null;
            teardown();
        }
        if (!openListener())
            return;
        nowMs = elapsedMs();
        nextSweepMs = nowMs + sweepEveryMs;
        atomicStore(ready, true);
        atomicStore(everListened, true);

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
            drainWsWakes();
            flushPendingQ();
            flushDead();

            fireTimers();
            drainResumeQ();
            drainWsWakes();
            flushPendingQ();
            flushDead();

            if (nowMs >= nextSweepMs)
            {
                sweep();
                drainResumeQ();
                drainWsWakes();
                flushPendingQ();
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
        mainListener = listenOn(cfg.port, false, boundPort);
        if (mainListener is null)
            return false;
        if (cfg.tls.enabled && cfg.tls.redirectPort)
        {
            redirectListener = listenOn(cfg.tls.redirectPort, true, boundRedirectPort);
            if (redirectListener is null)
                return false;
        }
        return true;
    }

    /// Opens, binds and registers one listening socket. Null on failure (already reported).
    private ListenItem listenOn(ushort port, bool redirect, out ushort bound)
    {
        immutable fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0)
        {
            perror("vela: socket");
            return null;
        }
        auto li = new ListenItem(redirect);
        li.fd = fd;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);
        if (cfg.reusePort)
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, one.sizeof);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        char[64] host = 0;
        if (cfg.host.length == 0 || cfg.host.length >= host.length)
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
        else
        {
            host[0 .. cfg.host.length] = cfg.host[];
            if (inet_pton(AF_INET, host.ptr, &addr.sin_addr) != 1)
            {
                fprintf(stderr, "vela: invalid host: %s\n", host.ptr);
                close(fd);
                return null;
            }
        }
        if (bind(fd, cast(sockaddr*)&addr, addr.sizeof) < 0)
        {
            fprintf(stderr, "vela: bind to port %d: ", cast(int) port);
            perror(null);
            close(fd);
            return null;
        }
        if (listen(fd, cast(int) cfg.backlog) < 0)
        {
            perror("vela: listen");
            close(fd);
            return null;
        }
        sockaddr_in got;
        socklen_t gl = got.sizeof;
        getsockname(fd, cast(sockaddr*)&got, &gl);
        bound = ntohs(got.sin_port);

        epoll_event ev;
        ev.events = EPOLLIN; // level-triggered: if connections remain after the batch, the next wait reports them
        ev.data.ptr = cast(void*) li;
        epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
        return li;
    }

    private void closeListener(ref ListenItem li)
    {
        if (li is null || li.fd < 0)
            return;
        epoll_ctl(ep, EPOLL_CTL_DEL, li.fd, null);
        close(li.fd);
        li.fd = -1;
    }

    private void acceptSome(ListenItem li)
    {
        foreach (_; 0 .. 64)
        {
            sockaddr_in peer;
            socklen_t pl = peer.sizeof;
            immutable fd = accept4(li.fd, cast(sockaddr*)&peer, &pl, SOCK_NONBLOCK | SOCK_CLOEXEC);
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
            c.chunked = c.chunkDone = false;
            c.headLen = c.total = c.sent = 0;
            c.worker = null;
            clearPending(c);
            c.closeWhenSent = false;
            c.fresh = true;
            c.h2 = null;
            c.h2Paused = false;
            c.lingering = false;
            c.writersWaiting = 0;
            c.waking = false;
            c.blockedSinceMs = 0;
            c.ssl = null;
            c.tlsFatal = false;
            c.redirect = li.redirect;
            c.peerIp = peer.sin_addr.s_addr;
            c.peerPort = ntohs(peer.sin_port);
            c.deadlineMs = nowMs + cfg.idleTimeoutMs;
            if (cfg.tls.enabled && !li.redirect)
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
                    acceptSome(cast(ListenItem) cast(void*) it);
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
        if (c.phase == Phase.upgraded)
            return onUpgradedEvent(c, events);
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
                        closeAfterSend(c);
                    break;
                case Phase.closed:
                case Phase.h2:
                case Phase.handshake:
                case Phase.upgraded:
                    break;
            }
            return;
        }
        if (c.phase == Phase.running && c.worker !is null && c.worker.waitingWrite
            && (events & (EPOLLOUT | (c.ssl !is null ? EPOLLIN : 0))))
        {
            // a streamed response was waiting for the socket (over TLS a write can also wait on a read)
            auto w = c.worker;
            w.wakeEvents = events;
            wake(w);
            resume(w);
            if (c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
            return;
        }
        if ((events & EPOLLOUT) && c.phase == Phase.running && c.hasPending)
            pushPending(c); // held-back responses that did not fit before the next request started
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
            if (cfg.http2 && c.fresh && c.ssl is null && !c.redirect && !c.buf.isNull && c.buf.len >= 2 && c.buf.mem[0] == 'P'
                && c.buf.mem[1] == 'R' && !stopping)
            {
                // "PR": no HTTP/1 method starts like that; the session checks the full preface
                switchToH2(c);
                return driveH2(c);
            }
            final switch (tryParse(c))
            {
                case Step.ready:
                    if (c.redirect)
                    {
                        answerRedirectPort(c);
                        break;
                    }
                    // (an upgrade behind held-back responses is served as HTTP/1.1: the 101 must not overtake them)
                    if (cfg.http2 && !stopping && !c.hasPending && tryUpgrade(c))
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
                // Geometric growth: a chunked body (its size is not known up front) grew by one byte per read before,
                // copying the whole body every time. Capped at what the limits allow for it.
                size_t want = c.buf.mem.length * 2;
                if (c.haveHead && c.chunked)
                {
                    immutable cap = c.headLen + cfg.limits.maxBodyBytes + cfg.limits.maxHeadBytes;
                    if (want > cap)
                        want = cap > c.buf.mem.length ? cap : c.buf.mem.length + 1;
                }
                if (!pool.grow(c.buf, want))
                {
                    sendErrorAndClose(c, 431);
                    return false;
                }
            }
            immutable wasEmpty = c.buf.len == 0;
            immutable r = ioRead(c, c.buf.free_.ptr, c.buf.free_.length);
            if (r > 0)
            {
                if (wasEmpty || (c.haveHead && c.chunked))
                    c.deadlineMs = nowMs + cfg.headerTimeoutMs; // not extended on every byte, except while a chunked body makes progress
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
                closeAfterSend(c); // the peer is done sending; the answers to what it sent before still go out
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
            c.headSerial++;
            immutable h = parseHead(c);
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
            c.chunked = h.chunked;
            c.chunkDone = false;
            c.dec = ChunkedDecoder.init;
            if (!c.chunked && c.total > c.buf.mem.length && !pool.grow(c.buf, c.total))
            {
                sendErrorAndClose(c, 413);
                return Step.failed;
            }
        }
        if (c.chunked && !c.chunkDone)
        {
            // Decode what has arrived, in place: the body ends up contiguous right after the head, and the bytes still
            // undigested (a partial chunk header, or the next pipelined request) follow it.
            size_t avail = c.buf.len - c.headLen;
            final switch (c.dec.feed(c.buf.mem[c.headLen .. $], avail, cfg.limits.maxBodyBytes, cfg.limits.maxHeadBytes))
            {
                case ChunkResult.needMore:
                    c.buf.len = c.headLen + avail;
                    break;
                case ChunkResult.done:
                    c.buf.len = c.headLen + avail;
                    c.total = c.headLen + c.dec.decoded; // the body ends here; what follows is the next request
                    c.chunkDone = true;
                    break;
                case ChunkResult.badRequest:
                    sendErrorAndClose(c, 400);
                    return Step.failed;
                case ChunkResult.tooLarge:
                    sendErrorAndClose(c, 413);
                    return Step.failed;
            }
        }
        // Expect: 100-continue: the client waits for the go-ahead before sending the body.
        // The parser already refused (413/417) what is not worth receiving.
        if (!c.sent100 && (c.chunked ? !c.chunkDone : c.buf.len < c.total))
        {
            if (equalsIgnoreCase(parsedHead(c).header("expect"), "100-continue"))
            {
                c.sent100 = true;
                sendRaw(c, "HTTP/1.1 100 Continue\r\n\r\n");
            }
        }
        if (c.chunked)
            return c.chunkDone ? Step.ready : Step.needMore;
        return c.buf.len >= c.total ? Step.ready : Step.needMore;
    }

    /// Parses the head at the start of `c.buf` into `head` (headers in `scratch`) and remembers whose it is.
    private HeadResult parseHead(Conn c)
    {
        head = Request.init;
        headOf = null;
        auto h = parseRequestHead(cast(const(char)[]) c.buf.data, head, scratch[], cfg.limits);
        if (h.status == ParseStatus.complete)
        {
            headOf = c;
            headSerial = c.headSerial;
            headBase = c.buf.mem.ptr;
        }
        return h;
    }

    /// The parsed head of `c`'s current request (call only with `c.haveHead`). The head is parsed once per request:
    /// this parses again only when another connection's head was parsed since, or a grow moved the buffer.
    private ref Request parsedHead(Conn c) return
    {
        if (headOf !is c || headSerial != c.headSerial || headBase !is c.buf.mem.ptr)
            parseHead(c);
        return head;
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
            closeAfterSend(c);
            return;
        }
        c.fresh = false;
        Worker w = acquireWorker();
        // the head moves into the fiber's own structures: the loop's are reused by the next connection, while the
        // fiber may stay suspended
        auto r = &parsedHead(c);
        immutable n = r.headers.length;
        w.store[0 .. n] = r.headers[];
        w.req = *r;
        w.req.headers = w.store[0 .. n];
        w.req.body = c.buf.mem[c.headLen .. c.total];
        w.req.peer = IpAddress.fromNetworkOrderV4(c.peerIp, c.peerPort);
        if (stopping)
            w.req.keepAlive = false; // draining: the response announces Connection: close
        w.conn = c;
        w.output.clear();
        w.resetResponseState();
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
        // Its body/header slices would keep the (possibly huge) buffer alive in an idle worker: an interior pointer keeps a
        // whole GC block reachable.
        w.req = Request.init;
        w.store[] = HeaderField.init;
        inFlight--;
        w.output.shrinkTo(64 << 10); // a response peak does not stay pinned to the fiber
        if (w.poisoned)
            fibersPoisoned++;
        if (!w.poisoned && idle.n < cfg.maxIdleWorkers)
            idle.push(w);
        else
        {
            // really ends the fiber (the stack goes back to the OS) and releases the object, with its Context
            w.retiring = true;
            w.call();
            destroy(w);
            if (!w.poisoned)
                workersRetired++;
        }
    }

    // ------------------------------------------------------------------ the response sink
    //
    // `Worker` implements `ResponseSink` by calling these. A response is built in `w.output`; on HTTP/1.1 it is sent by
    // the loop after the handler returns (the usual, buffered case) or by the fiber itself as soon as `streamHighWaterBytes`
    // are buffered or `flush` is called, waiting on the socket when it is full. On HTTP/2 the same rules apply to the
    // stream's own buffer ("committing" hands HEADERS and the bytes so far to the session).

    private void sinkStart(Worker w, ref const ResponseHead head)
    {
        if (w.cancelled)
            throw cancelledEx;
        if (w.started)
            throw new Exception("vela: ResponseSink.start was called twice");
        w.started = true;
        w.noBody = w.req.method == Method.HEAD || statusHasNoBody(head.status);
        w.remaining = head.contentLength;
        // The time allowed to produce the response is over. From here on a blocked write has its own limit, and the
        // whole stream an optional one: a Server-Sent Events connection can live for hours.
        immutable limit = cfg.streamTimeoutMs ? nowMs + cfg.streamTimeoutMs : 0;
        if (w.stream !is null)
        {
            w.h2head = head;
            w.stream.deadlineMs = limit;
            return;
        }
        w.conn.deadlineMs = limit;
        bool keep = w.req.keepAlive && !stopping;
        if (head.contentLength < 0 && !w.noBody)
        {
            if (w.req.http11)
                w.chunked = true;
            else
                keep = false; // an HTTP/1.0 client cannot be sent a chunked body: the body ends when the connection closes
        }
        if (!keep)
            w.closeAfter = true;
        writeResponseHead(w.output, head, keep, w.chunked);
    }

    private void sinkWrite(Worker w, scope const(char)[] data)
    {
        if (w.cancelled)
            throw cancelledEx;
        if (!w.started)
            throw new Exception("vela: ResponseSink.write before start");
        if (w.ended)
            throw new Exception("vela: ResponseSink.write after end");
        if (w.noBody || data.length == 0)
            return;
        if (w.remaining >= 0)
        {
            if (data.length > w.remaining)
                throw new Exception("vela: the response body is longer than its Content-Length");
            w.remaining -= data.length;
        }
        if (w.stream !is null)
            return sinkWriteH2(w, data);
        if (w.chunked)
        {
            char[18] hex = void;
            size_t i = hex.length;
            ulong v = data.length;
            do
            {
                hex[--i] = "0123456789abcdef"[v & 15];
                v >>= 4;
            }
            while (v);
            w.output.put(hex[i .. $]);
            w.output.put("\r\n");
            w.output.put(data);
            w.output.put("\r\n");
        }
        else if (data.length >= cfg.streamHighWaterBytes)
        {
            // a big piece (a file chunk, a large JSON body): send it from the caller's memory, without copying it
            flushOutput(w);
            sendFully(w, data.ptr, data.length);
            return;
        }
        else
            w.output.put(data);
        if (w.output.length >= cfg.streamHighWaterBytes)
            flushOutput(w);
    }

    private void sinkFlush(Worker w)
    {
        if (w.cancelled)
            throw cancelledEx;
        if (!w.started || w.noBody && w.stream is null && w.output.length == 0)
            return;
        if (w.stream !is null)
            return sinkFlushH2(w);
        flushOutput(w);
    }

    private void sinkEnd(Worker w)
    {
        if (w.cancelled)
            throw cancelledEx;
        if (!w.started)
            throw new Exception("vela: ResponseSink.end before start");
        if (w.ended)
            return;
        w.ended = true;
        if (!w.noBody && w.remaining > 0)
            throw new Exception("vela: the response body is shorter than its Content-Length");
        if (w.stream !is null)
            return sinkEndH2(w);
        if (w.chunked && !w.noBody)
            w.output.put("0\r\n\r\n");
    }

    /// Sends everything buffered in `w.output`, waiting for the socket as needed.
    private void flushOutput(Worker w)
    {
        if (w.output.length)
        {
            sendFully(w, w.output.data.ptr, w.output.length);
            w.output.clear();
        }
    }

    private void sendFully(Worker w, const(char)* p, size_t len)
    {
        Conn c = w.conn;
        if (c.hasPending)
        {
            // the responses to earlier pipelined requests go first (they are not this response's bytes: flushedAny
            // stays as it is)
            sendFrom(w, c.pending.data.ptr, c.pending.length, c.pendingOff, false);
            clearPending(c);
        }
        size_t off;
        sendFrom(w, p, len, off, true);
    }

    /// Sends `p[off .. len]` from the fiber, waiting for the socket as needed; `off` follows the progress.
    private void sendFrom(Worker w, const(char)* p, size_t len, ref size_t off, bool ours)
    {
        Conn c = w.conn;
        while (off < len)
        {
            if (w.cancelled)
                throw cancelledEx;
            immutable n = ioSend(c, p + off, len - off);
            if (n > 0)
            {
                off += n;
                if (ours)
                    w.flushedAny = true;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
            {
                waitWritable(w);
                continue;
            }
            w.cancelled = true; // the peer is gone: unwind; finish() closes the connection
            throw cancelledEx;
        }
    }

    /// Suspends the fiber until the connection can take more bytes (EPOLLOUT edge), `writeTimeoutMs` at most.
    /// A reader that stopped reading gets its connection closed.
    private void waitWritable(Worker w) @trusted
    {
        w.waitingWrite = true;
        beginWait(w, cfg.writeTimeoutMs);
        Fiber.yield();
        w.waitingWrite = false;
        if (w.cancelled)
            throw cancelledEx;
        if (w.wakeEvents == 0)
        {
            w.cancelled = true; // the timer fired: the client does not read
            throw cancelledEx;
        }
    }

    // ---- HTTP/2

    private void sinkWriteH2(Worker w, scope const(char)[] data)
    {
        if (!w.committed)
        {
            w.output.put(data);
            if (w.output.length >= cfg.streamHighWaterBytes)
                commitH2(w);
            return;
        }
        w.conn.h2.sendData(w.stream, data);
        flushH2(w.conn);
        waitH2Drain(w);
    }

    private void sinkFlushH2(Worker w)
    {
        if (w.noBody)
            return;
        if (!w.committed)
            return commitH2(w);
        flushH2(w.conn);
        waitH2Drain(w);
    }

    private void sinkEndH2(Worker w)
    {
        if (!w.committed)
            return; // finishH2 sends head and body together
        w.conn.h2.endResponse(w.stream);
        w.h2done = true;
    }

    /// HEADERS and the body so far go to the session; from now on the stream is written to as it is produced.
    private void commitH2(Worker w)
    {
        Conn c = w.conn;
        auto s = c.h2;
        s.beginResponse(w.stream, w.h2head, false);
        w.committed = true;
        w.flushedAny = true;
        if (w.output.length)
        {
            s.sendData(w.stream, w.output.data);
            w.output.clear();
        }
        flushH2(c);
        waitH2Drain(w);
    }

    /// Suspends the handler while its stream has more than the high-water mark waiting to be sent.
    private void waitH2Drain(Worker w) @trusted
    {
        Conn c = w.conn;
        while (!w.cancelled && c.fd >= 0 && c.h2 !is null && w.stream !is null
            && c.h2.pendingBytes(w.stream) >= cfg.streamHighWaterBytes)
        {
            w.waitingWrite = true;
            c.writersWaiting++;
            beginWait(w, cfg.writeTimeoutMs);
            Fiber.yield();
            w.waitingWrite = false;
            if (c.writersWaiting)
                c.writersWaiting--;
            if (w.cancelled)
                throw cancelledEx;
            if (w.wakeEvents == 0)
            {
                w.cancelled = true; // the client does not read this stream
                throw cancelledEx;
            }
        }
        if (w.cancelled || c.fd < 0 || c.h2 is null)
            throw cancelledEx;
    }

    /// Resumes the handlers that were waiting for their stream to drain, once it has. Called after the output moved.
    private void wakeH2Writers(Conn c)
    {
        if (c.writersWaiting == 0 || c.waking)
            return;
        c.waking = true;
        scope (exit)
            c.waking = false;
        for (int round = 0; round < 8 && c.fd >= 0 && c.h2 !is null && c.writersWaiting; round++)
        {
            Worker[8] ready;
            size_t n;
            foreach (st; c.h2.activeStreams)
            {
                auto w = cast(Worker) st.task;
                if (w !is null && w.waitingWrite && w.waiting && c.h2.pendingBytes(st) <= cfg.streamHighWaterBytes / 2)
                {
                    if (n == ready.length)
                        break;
                    ready[n++] = w;
                }
            }
            if (n == 0)
                break;
            foreach (i; 0 .. n)
            {
                auto w = ready[i];
                if (w.waiting && w.waitingWrite)
                {
                    w.wakeEvents = EPOLLOUT;
                    wake(w);
                    resume(w);
                }
            }
        }
    }

    // ------------------------------------------------------------------ failures inside handlers

    /// Full traces are limited to this many per second; the rest are counted and summarized.
    private enum maxFailureTraces = 5;

    /// A handler (or the glue around it) threw something the app did not handle. Logs the whole thing -- type, message,
    /// file:line and stack trace -- with the request, at most `maxFailureTraces` times per second.
    private void noteHandlerFailure(Worker w, Throwable t)
    {
        handlerErrors++;
        flushFailureSummary();
        if (failLogged >= maxFailureTraces)
        {
            failSuppressed++;
            return;
        }
        failLogged++;
        auto m = methodName(w.req.method);
        string text;
        try
            text = t.toString();
        catch (Throwable)
            text = t.msg;
        immutable kind = typeid(t).name;
        fprintf(stderr, "vela: unhandled %.*s in %.*s %.*s:\n%.*s\n", cast(int) kind.length, kind.ptr,
            cast(int) m.length, m.ptr, cast(int) w.req.path.length, w.req.path.ptr, cast(int) text.length, text.ptr);
    }

    /// When the one-second window is over, reports what it suppressed and opens a new one. Also called by the sweep,
    /// so the summary appears even if no further failure arrives.
    private void flushFailureSummary()
    {
        immutable now = elapsedMs();
        if (now - failWindowMs < 1000)
            return;
        if (failSuppressed)
            fprintf(stderr, "vela: %zu more handler failures in the last second (traces suppressed)\n", failSuppressed);
        failWindowMs = now;
        failLogged = 0;
        failSuppressed = 0;
    }

    private void resume(Worker w)
    {
        immutable t = MonoTime.currTime;
        crashWorker = w;
        w.call();
        crashWorker = null;
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

    /// The handler returned (or was cancelled): decides what is left to send.
    private void finish(Worker w)
    {
        if (w.stream !is null)
            return finishH2(w);
        if (w.upgraded)
            return finishUpgraded(w);
        Conn c = w.conn;
        if (w.cancelled)
        {
            if (w.timedOut && !w.started)
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
                // the client is gone, or the response had already started and cannot be replaced by an error
                if (w.timedOut)
                    timedOutN++;
                else
                    cancelledN++;
                closeConn(c);
                return;
            }
        }
        else if (w.failed || !w.started || !w.ended)
        {
            if (!w.started && !w.failed)
            {
                auto m = methodName(w.req.method);
                fprintf(stderr, "vela: the handler returned without sending a response (%.*s %.*s)\n",
                    cast(int) m.length, m.ptr, cast(int) w.req.path.length, w.req.path.ptr);
            }
            if (w.flushedAny)
            {
                closeConn(c); // half of the response is out: it can only be cut off (the client sees a truncated body)
                return;
            }
            w.output.clear();
            writeResponseHead(w.output, 500, "text/plain; charset=utf-8", 21, null, false);
            w.output.put("Internal Server Error");
            w.closeAfter = true;
        }
        if (coalesce(c, w))
            return;
        c.phase = Phase.writing;
        c.sent = 0;
        c.deadlineMs = nowMs + cfg.writeTimeoutMs;
        trySend(c);
    }

    /// Most bytes of answered pipelined requests held back for one send.
    private enum maxCoalescedBytes = 16 << 10;

    /// Pipelining: when the next request is already in the buffer, the response is not sent now but appended to
    /// `c.pending`, so the responses to a batch of requests leave in one send instead of one each. `pendingQ` sends them
    /// at the end of the event batch at the latest; anything that writes to the connection before that sends them
    /// first, so the order on the wire is kept. Cleartext only: OpenSSL wants a retried write to repeat the same bytes.
    private bool coalesce(Conn c, Worker w)
    {
        if (c.ssl !is null || c.buf.len <= c.total || !w.req.keepAlive || w.closeAfter || stopping
            || c.pending.length - c.pendingOff + w.output.length > maxCoalescedBytes)
            return false;
        c.pending.put(w.output.data);
        queuePending(c);
        completeResponse(c);
        return true;
    }

    private void queuePending(Conn c)
    {
        if (c.pendingQueued)
            return;
        c.pendingQueued = true;
        pendingQ.push(c);
    }

    private Stack!Conn pendingQ;

    /// Sends what `coalesce` held back, at the end of an event batch.
    private void flushPendingQ()
    {
        while (!pendingQ.empty)
        {
            auto c = pendingQ.pop();
            c.pendingQueued = false;
            if (c.fd < 0 || !c.hasPending)
                continue;
            if (c.phase == Phase.reading)
                startPendingSend(c);
            else if (c.phase == Phase.running && !c.worker.waitingWrite)
                pushPending(c); // the next request is suspended; whatever does not fit goes out with its response
            // Phase.writing: trySend is already on it
        }
    }

    /// Sends `c.pending` from the loop, as a response of its own: the connection reads again once it is out.
    private void startPendingSend(Conn c)
    {
        c.phase = Phase.writing;
        c.deadlineMs = nowMs + cfg.writeTimeoutMs;
        trySend(c);
    }

    /// Sends `c.pending` without blocking: 1 = all of it is out, 0 = the socket is full, -1 = the connection broke.
    private int pushPending(Conn c)
    {
        while (c.hasPending)
        {
            immutable n = ioSend(c, c.pending.data.ptr + c.pendingOff, c.pending.length - c.pendingOff);
            if (n > 0)
            {
                c.pendingOff += n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            return n < 0 && errno == EAGAIN ? 0 : -1;
        }
        clearPending(c);
        return 1;
    }

    private static void clearPending(Conn c)
    {
        c.pending.clear();
        c.pendingOff = 0;
    }

    /// Sends the response of `c.worker` -- or, without a worker, only what `coalesce` held back -- until EAGAIN.
    private void trySend(Conn c)
    {
        immutable r = pushPending(c); // earlier responses first
        if (r <= 0)
        {
            if (r < 0)
                closeConn(c);
            return; // 0: wait for the next EPOLLOUT
        }
        auto w = c.worker;
        if (w is null)
            return completeResponse(c);
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
        if (w is null)
        {
            // only held-back responses were being sent: the request in progress (if any) is still being read
            if (c.closeWhenSent)
                return closeConn(c);
            c.phase = Phase.reading;
            c.deadlineMs = nowMs + (c.buf.len ? cfg.headerTimeoutMs : cfg.idleTimeoutMs);
            if (!c.buf.isNull && c.buf.len == 0)
                pool.release(c.buf);
            return;
        }
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
        c.chunked = c.chunkDone = false;
        c.headLen = c.total = c.sent = 0;
        if (c.buf.len == 0)
            pool.release(c.buf); // idle: do not hold the buffer
        c.phase = Phase.reading;
        c.deadlineMs = nowMs + cfg.idleTimeoutMs;
    }

    // ------------------------------------------------------------------ taken-over connections (WebSocket)
    //
    // `ResponseSink.upgrade` answers 101 and hands the connection to the handler through a `WsPort`. The loop never parses
    // HTTP on it again: input is read into `wsIn` when the owner asks for it (`wsFill`), output from any fiber of the
    // worker is appended to `wsOut` and sent as the socket allows (`wsFlush`). When the owner returns, what is left is
    // sent and the connection is closed (`finishUpgraded`). Fibers are only resumed from the loop: a wake-up decided
    // inside a fiber is deferred to the end of the event batch (`wsDefer`).

    private size_t wsOpen, wsTotal;
    private Worker[] wsWakes;  /// fibers to resume at the end of the batch, with the wait they were in
    private uint[] wsWakeGens;
    private size_t wsWakeN;

    private UpgradedConn sinkUpgrade(Worker w, ref const ResponseHead head, scope const(char)[] protocol)
    {
        if (w.cancelled)
            throw cancelledEx;
        if (w.started)
            throw new Exception("vela: ResponseSink.upgrade after the response started");
        if (w.stream !is null)
            return null; // HTTP/2 has no Upgrade (RFC 8441's extended CONNECT is not supported)
        Conn c = w.conn;
        w.started = w.ended = w.upgraded = true;
        c.wsOut.clear();
        c.wsOutOff = 0;
        if (c.hasPending)
        {
            // the answers to earlier pipelined requests go first
            c.wsOut.put(c.pending.data[c.pendingOff .. $]);
            clearPending(c);
        }
        c.wsOut.put("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ");
        c.wsOut.put(protocol);
        c.wsOut.put("\r\n");
        foreach (ref h; head.headers)
        {
            c.wsOut.put(h.name);
            c.wsOut.put(": ");
            c.wsOut.put(h.value);
            c.wsOut.put("\r\n");
        }
        c.wsOut.put("\r\n");
        // Bytes the client sent right behind the request already belong to the new protocol. The request itself stays in
        // `c.buf` until the connection closes: the handler's Request, and what it captured from it, points there.
        immutable early = c.buf.len - c.total;
        if (early)
        {
            c.wsIn = pool.acquire(early > 4096 ? early : 4096);
            c.wsIn.mem[0 .. early] = c.buf.mem[c.total .. c.buf.len];
            c.wsIn.len = early;
            c.buf.len = c.total;
        }
        c.wsInOff = 0;
        c.wsEof = c.wsBroken = c.wsClosing = c.wsStopSeen = false;
        c.readWaiter = null;
        c.phase = Phase.upgraded;
        c.deadlineMs = 0; // no request deadline any more: the protocol keeps its own (WsConn's pings)
        c.blockedSinceMs = 0;
        c.port = new WsPort(this, c, w);
        wsOpen++;
        wsTotal++;
        wsFlush(c);
        return c.port;
    }

    private const(ubyte)[] wsBuffered(WsPort p)
    {
        Conn c = p.conn;
        if (c is null || c.wsIn.isNull)
            return null;
        return c.wsIn.mem[c.wsInOff .. c.wsIn.len];
    }

    private void wsConsume(WsPort p, size_t n)
    {
        Conn c = p.conn;
        if (c is null || c.wsIn.isNull)
            return;
        assert(c.wsInOff + n <= c.wsIn.len, "vela: consumed more than was received");
        c.wsInOff += n;
        if (c.wsInOff == c.wsIn.len)
        {
            pool.release(c.wsIn); // an idle connection holds no input buffer
            c.wsInOff = 0;
        }
    }

    /// The owner waits for input (see `UpgradedConn.fill`).
    private FillResult wsFill(WsPort p, int timeoutMs)
    {
        auto w = p.owner;
        if (cast(Worker) Fiber.getThis() !is w)
            throw new Exception("vela: only the fiber that upgraded a connection can read from it");
        if (w.cancelled)
            throw cancelledEx;
        Conn c = p.conn;
        if (c is null || c.wsBroken || c.wsClosing)
            return FillResult.eof;
        auto r = wsRead(c);
        if (r != FillResult.timeout)
            return r;
        if (stopping && !c.wsStopSeen)
        {
            c.wsStopSeen = true;
            return FillResult.stopping;
        }
        if (timeoutMs == 0)
            return FillResult.timeout;
        c.readWaiter = w;
        beginWait(w, timeoutMs);
        Fiber.yield();
        if (c.readWaiter is w)
            c.readWaiter = null;
        if (w.cancelled)
            throw cancelledEx;
        if (p.conn !is c || c.wsBroken || c.wsClosing)
            return FillResult.eof;
        r = wsRead(c);
        if (r != FillResult.timeout)
            return r;
        if (stopping && !c.wsStopSeen)
        {
            c.wsStopSeen = true;
            return FillResult.stopping;
        }
        return FillResult.timeout; // the timer, or a wake-up with nothing to read: the caller looks at its clock
    }

    /// Reads what the socket has into `wsIn`: `data`, `eof`, or `timeout` meaning "nothing now".
    private FillResult wsRead(Conn c)
    {
        if (c.wsEof)
            return FillResult.eof;
        if (c.wsIn.isNull)
            c.wsIn = pool.acquire(4096);
        else if (c.wsInOff)
        {
            c.wsIn.compact(c.wsInOff);
            c.wsInOff = 0;
        }
        bool any;
        for (;;)
        {
            if (c.wsIn.free_.length == 0)
            {
                if (any)
                    break; // the rest waits in the socket: the next fill reads it (it always reads before waiting)
                pool.grow(c.wsIn, c.wsIn.mem.length * 2); // a frame header or a control frame across the end
            }
            immutable n = ioRead(c, c.wsIn.free_.ptr, c.wsIn.free_.length);
            if (n > 0)
            {
                c.wsIn.len += n;
                any = true;
                if (c.ssl is null && c.wsIn.free_.length)
                    break; // short read: the kernel is drained (TLS reads one record at a time)
                continue;
            }
            if (n == 0)
            {
                c.wsEof = true;
                break;
            }
            if (errno == EINTR)
                continue;
            if (errno != EAGAIN)
                wsBreak(c);
            break;
        }
        if (any)
            return FillResult.data;
        if (c.wsIn.len == 0)
            pool.release(c.wsIn);
        return c.wsEof || c.wsBroken ? FillResult.eof : FillResult.timeout;
    }

    /// Any fiber of the worker sends on the connection (see `UpgradedConn.write`).
    private void wsWrite(WsPort p, scope const(ubyte)[] data)
    {
        auto self = cast(Worker) Fiber.getThis();
        if (self is null)
            throw new Exception("vela: a WebSocket can only be written to from a request fiber");
        if (self.cancelled)
            throw cancelledEx;
        Conn c = p.conn;
        if (c is null || c.wsBroken || c.wsClosing)
            wsGone(p, self);
        c.wsOut.put(cast(const(char)[]) data); // whole, before any wait: frames of two fibers never interleave
        if (!wsFlush(c))
            wsGone(p, self);
        while (c.wsOut.length - c.wsOutOff > cfg.streamHighWaterBytes)
        {
            wsAddWriter(c, self);
            beginWait(self, cfg.writeTimeoutMs);
            Fiber.yield();
            wsRemoveWriter(c, self);
            if (self.cancelled)
                throw cancelledEx;
            if (p.conn !is c || c.wsBroken)
                wsGone(p, self);
            if (self.wakeEvents == 0)
            {
                wsBreak(c); // the peer has not read anything for writeTimeoutMs
                wsGone(p, self);
            }
        }
    }

    /// The connection behind `p` is gone: its owner unwinds like any request whose client left, other fibers get `WsClosed`.
    private void wsGone(WsPort p, Worker self)
    {
        if (self is p.owner)
        {
            self.cancelled = true;
            throw cancelledEx;
        }
        throw new WsClosed;
    }

    /// The owner is done with the connection; it closes once what was written is out (see `finishUpgraded`).
    private void wsClose(WsPort p)
    {
        if (p.conn !is null)
            p.conn.wsClosing = true;
    }

    /// Sends `wsOut` without blocking; false when the connection broke.
    private bool wsFlush(Conn c)
    {
        if (c.wsBroken || c.fd < 0)
            return false;
        while (c.wsOutOff < c.wsOut.length)
        {
            immutable n = ioSend(c, c.wsOut.data.ptr + c.wsOutOff, c.wsOut.length - c.wsOutOff);
            if (n > 0)
            {
                c.wsOutOff += n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
            {
                if (c.blockedSinceMs == 0)
                    c.blockedSinceMs = nowMs | 1;
                if (c.wsWriters.length && c.wsOut.length - c.wsOutOff <= cfg.streamHighWaterBytes / 2)
                    wsWakeWriters(c);
                return true;
            }
            wsBreak(c);
            return false;
        }
        c.wsOut.clear();
        c.wsOutOff = 0;
        c.wsOut.shrinkTo(cfg.streamHighWaterBytes * 2); // a big message does not stay pinned to the connection
        c.blockedSinceMs = 0;
        if (c.wsWriters.length)
            wsWakeWriters(c);
        return true;
    }

    private void wsAddWriter(Conn c, Worker w)
    {
        c.wsWriters ~= w;
    }

    private void wsRemoveWriter(Conn c, Worker w)
    {
        foreach (i, x; c.wsWriters)
            if (x is w)
            {
                c.wsWriters[i] = c.wsWriters[$ - 1];
                c.wsWriters[$ - 1] = null;
                c.wsWriters = c.wsWriters[0 .. $ - 1];
                c.wsWriters.assumeSafeAppend();
                return;
            }
    }

    private bool isWsWriter(Conn c, Worker w)
    {
        foreach (x; c.wsWriters)
            if (x is w)
                return true;
        return false;
    }

    private void wsWakeWriters(Conn c)
    {
        foreach (x; c.wsWriters)
            wsDefer(x);
    }

    /// Resumes `w` at the end of the event batch, if it is still in the wait it is in now.
    private void wsDefer(Worker w)
    {
        if (w is null || !w.waiting)
            return;
        if (wsWakeN == wsWakes.length)
        {
            wsWakes.length = wsWakes.length ? wsWakes.length * 2 : 16;
            wsWakeGens.length = wsWakes.length;
        }
        wsWakes[wsWakeN] = w;
        wsWakeGens[wsWakeN] = w.waitGen;
        wsWakeN++;
    }

    private void drainWsWakes()
    {
        for (size_t i = 0; i < wsWakeN; i++) // the list may grow while it is drained
        {
            auto w = wsWakes[i];
            wsWakes[i] = null;
            if (!w.waiting || w.waitGen != wsWakeGens[i])
                continue;
            w.wakeEvents = EPOLLOUT;
            wake(w);
            Conn c = w.conn;
            resume(w);
            if (c !is null && c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
        }
        wsWakeN = 0;
    }

    /// The connection failed (an error, a reset, a reader that stopped reading): reads end, writes throw. Its owner
    /// learns it at its next wait; if it is waiting on something else (sleep, a database) it is cancelled.
    private void wsBreak(Conn c)
    {
        if (c.wsBroken)
            return;
        c.wsBroken = true;
        c.wsOut.clear();
        c.wsOutOff = 0;
        wsDefer(c.readWaiter);
        wsWakeWriters(c);
        auto owner = c.worker;
        if (owner is null)
        {
            if (c.fd >= 0)
                closeConn(c); // closing already: nothing is waiting for it
            return;
        }
        if (owner.waiting && c.readWaiter !is owner && !isWsWriter(c, owner))
        {
            owner.cancelled = true; // its wait throws RequestCancelled when it resumes
            wsDefer(owner);
        }
    }

    private void onUpgradedEvent(Conn c, uint events)
    {
        if (c.lingering)
            return drainLingering(c, events);
        if (events & EPOLLERR)
            return wsBreak(c);
        // over TLS a write can wait on a read and a read on a write
        immutable outReady = (events & (EPOLLOUT | EPOLLHUP)) || (c.ssl !is null && (events & EPOLLIN));
        if (outReady && c.wsOutOff < c.wsOut.length)
        {
            wsFlush(c);
            if (c.fd < 0)
                return;
        }
        if (c.worker is null)
        {
            // the owner is done: close once the last bytes are out
            if (c.wsOutOff == c.wsOut.length)
                lingerClose(c);
            return;
        }
        immutable inReady = (events & (EPOLLIN | EPOLLHUP | EPOLLRDHUP)) || (c.ssl !is null && (events & EPOLLOUT));
        if (inReady && c.readWaiter !is null)
        {
            auto w = c.readWaiter;
            c.readWaiter = null;
            w.wakeEvents = events;
            wake(w);
            resume(w);
            return;
        }
        if (events & EPOLLHUP)
        {
            // the peer is gone and the owner is not reading (it sleeps, or waits on a database): unwind it like a request
            // whose client left
            auto owner = c.worker;
            if (owner.waiting && !isWsWriter(c, owner))
                cancelWorker(owner, false);
        }
    }

    /// The owner of a taken-over connection returned: send what is left, then close.
    private void finishUpgraded(Worker w)
    {
        Conn c = w.conn;
        if (c.port !is null)
        {
            c.port.conn = null; // a WsConn kept by another fiber now finds the connection closed
            c.port = null;
            wsOpen--;
        }
        c.readWaiter = null;
        wsWakeWriters(c); // they find `p.conn` null and get WsClosed
        if (!c.wsIn.isNull)
            pool.release(c.wsIn);
        c.wsInOff = 0;
        immutable cancelled = w.cancelled;
        if (cancelled)
        {
            if (w.timedOut)
                timedOutN++;
            else
                cancelledN++;
        }
        c.worker = null;
        releaseWorker(w);
        if (cancelled || c.wsBroken || c.fd < 0)
            return closeConn(c);
        c.wsClosing = true;
        wsFlush(c);
        if (c.fd < 0)
            return;
        if (c.wsOutOff < c.wsOut.length)
        {
            c.deadlineMs = nowMs + cfg.writeTimeoutMs; // the rest goes out on EPOLLOUT; sweep gives up after that
            return;
        }
        lingerClose(c);
    }

    /// Deadlines of a taken-over connection (called from `sweep`).
    private void sweepUpgraded(Conn c)
    {
        if (c.deadlineMs && nowMs >= c.deadlineMs)
            return closeConn(c); // lingering, or the last bytes did not go out
        if (c.blockedSinceMs && nowMs - c.blockedSinceMs > cfg.writeTimeoutMs)
            wsBreak(c); // the peer stopped reading
    }

    /// Forgets the taken-over state of a connection that closes.
    private void resetUpgraded(Conn c)
    {
        if (c.port !is null)
        {
            c.port.conn = null;
            c.port = null;
            wsOpen--;
        }
        if (!c.wsIn.isNull)
            pool.release(c.wsIn);
        c.wsInOff = 0;
        c.wsOut.clear();
        c.wsOutOff = 0;
        c.wsOut.shrinkTo(cfg.streamHighWaterBytes * 2);
        c.readWaiter = null;
        wsWakeWriters(c);
        c.wsWriters = null;
        c.wsEof = c.wsBroken = c.wsClosing = c.wsStopSeen = false;
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

    // ------------------------------------------------------------------ redirect port (cleartext next to TLS)

    /// Answers a complete request on the redirect port: an ACME HTTP-01 challenge from
    /// `tls.acmeWebroot`, or a 308 to the same host and target over HTTPS. Keep-alive is honored;
    /// the request never reaches the application.
    private void answerRedirectPort(Conn c)
    {
        const req = parsedHead(c);
        redirectsN++;
        errOut.clear();
        enum string acmePrefix = "/.well-known/acme-challenge/";
        if (cfg.tls.acmeWebroot.length && req.path.length > acmePrefix.length
            && req.path[0 .. acmePrefix.length] == acmePrefix)
        {
            serveChallenge(req, req.path[acmePrefix.length .. $]);
        }
        else
        {
            const(char)[] host;
            if (req.target == "*" || !hostForRedirect(req.header("host"), host))
                writeResponseHead(errOut, 400, null, 0, null, req.keepAlive);
            else
            {
                // "https://" host [":" port] target; the parser already rejected control characters
                char[512] loc = void;
                size_t n = 0;
                void add(scope const(char)[] s)
                {
                    immutable k = s.length < loc.length - n ? s.length : loc.length - n;
                    loc[n .. n + k] = s[0 .. k];
                    n += k;
                }
                add("https://");
                add(host);
                if (boundPort != 443)
                {
                    char[8] num = void;
                    size_t i = num.length;
                    uint p = boundPort;
                    do { num[--i] = cast(char)('0' + p % 10); p /= 10; } while (p);
                    add(":");
                    add(num[i .. $]);
                }
                add(req.target);
                if (n == loc.length)
                    writeResponseHead(errOut, 414, null, 0, null, req.keepAlive);
                else
                {
                    HeaderField[1] h = [HeaderField("Location", loc[0 .. n])];
                    writeResponseHead(errOut, 308, null, 0, h[], req.keepAlive);
                }
            }
        }
        sendRaw(c, errOut.data); // a few hundred bytes on a socket we have not written to yet
        if (!req.keepAlive || stopping)
            return closeConn(c);
        c.fresh = false;
        c.buf.compact(c.total);
        c.haveHead = false;
        c.sent100 = false;
        c.chunked = c.chunkDone = false;
        c.headLen = c.total = c.sent = 0;
        if (c.buf.len == 0)
            pool.release(c.buf);
        c.deadlineMs = nowMs + cfg.idleTimeoutMs;
    }

    /// `<webroot>/.well-known/acme-challenge/<token>`: the token is base64url (RFC 8555 §8.3), so
    /// it cannot climb out of the directory; symlinks are not followed; at most 8 KiB.
    private void serveChallenge(ref const Request req, const(char)[] token)
    {
        import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW, O_CLOEXEC;
        import core.sys.posix.sys.stat : fstat, stat_t, S_ISREG;

        bool valid = token.length >= 1 && token.length <= 255;
        foreach (ch; token)
            valid &= (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
        if (!valid || (req.method != Method.GET && req.method != Method.HEAD))
            return writeResponseHead(errOut, 404, null, 0, null, req.keepAlive);
        char[4096] path = void;
        enum string dirPart = "/.well-known/acme-challenge/";
        immutable root = cfg.tls.acmeWebroot;
        if (root.length + dirPart.length + token.length + 1 > path.length)
            return writeResponseHead(errOut, 404, null, 0, null, req.keepAlive);
        size_t n = 0;
        path[n .. n + root.length] = root[];
        n += root.length;
        path[n .. n + dirPart.length] = dirPart[];
        n += dirPart.length;
        path[n .. n + token.length] = token[];
        n += token.length;
        path[n] = 0;
        immutable fd = open(path.ptr, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0)
            return writeResponseHead(errOut, 404, null, 0, null, req.keepAlive);
        scope (exit) close(fd);
        stat_t st;
        char[8192] content = void;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > content.length)
            return writeResponseHead(errOut, 404, null, 0, null, req.keepAlive);
        size_t got = 0;
        while (got < st.st_size)
        {
            immutable r = read(fd, content.ptr + got, content.length - got);
            if (r <= 0)
                break;
            got += r;
        }
        writeResponseHead(errOut, 200, "text/plain", got, null, req.keepAlive);
        if (req.method == Method.GET)
            errOut.put(content[0 .. got]);
    }

    // ------------------------------------------------------------------ TLS

    /// One line per second per worker at most, with the client's address; the lines skipped in
    /// between are counted in the next one.
    private void logConnError(Conn c, const(char)[] what, const(char)[] detail)
    {
        if (!cfg.logConnectionErrors)
            return;
        if (nowMs - lastConnLogMs < 1000)
        {
            suppressedConnLogs++;
            return;
        }
        lastConnLogMs = nowMs;
        char[64] ip = 0;
        in_addr a;
        a.s_addr = c.peerIp;
        if (inet_ntop(AF_INET, &a, ip.ptr, cast(socklen_t) ip.length) is null)
            ip[0 .. 7] = "unknown";
        if (suppressedConnLogs)
            fprintf(stderr, "vela: %.*s from %s: %.*s (%zu similar messages suppressed)\n", cast(int) what.length,
                what.ptr, ip.ptr, cast(int) detail.length, detail.ptr, suppressedConnLogs);
        else
            fprintf(stderr, "vela: %.*s from %s: %.*s\n", cast(int) what.length, what.ptr, ip.ptr,
                cast(int) detail.length, detail.ptr);
        suppressedConnLogs = 0;
    }

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
            logConnError(c, "TLS handshake failed", "socket error");
            return closeConn(c);
        }
        const(char)[] why;
        final switch (tlsHandshake(c.ssl, tlsReason, why))
        {
            case Handshake.again:
                if (events & (EPOLLHUP | EPOLLRDHUP))
                {
                    tlsFailures++;
                    closeConn(c); // the client left halfway: counted, not logged
                }
                return;
            case Handshake.closed:
                tlsFailures++;
                c.tlsFatal = true;
                return closeConn(c);
            case Handshake.failed:
                tlsFailures++;
                c.tlsFatal = true;
                logConnError(c, "TLS handshake failed", why);
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
        hc.settingsTimeoutMs = cfg.headerTimeoutMs; // a client this slow to acknowledge is gone
        return new H2Session(hc);
    }

    private void switchToH2(Conn c, H2Session s = null)
    {
        c.h2 = s !is null ? s : acquireSession();
        c.h2.nowMs = nowMs;
        c.phase = Phase.h2;
        c.fresh = false;
        c.h2Paused = false;
        c.lingering = false;
        c.writersWaiting = 0;
        c.waking = false;
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
        const tmp = parsedHead(c);
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
        c.chunked = c.chunkDone = false;
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
        if (c.lingering)
            return drainLingering(c, events);
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
        wakeH2Writers(c); // a WINDOW_UPDATE may have let a streamed response move
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
        w.req.peer = IpAddress.fromNetworkOrderV4(c.peerIp, c.peerPort);
        w.conn = c;
        w.stream = st;
        w.output.clear();
        w.resetResponseState();
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
            if (!w.h2done)
                st.task = null;
            releaseWorker(w);
            return;
        }
        auto s = c.h2;
        if (w.h2done)
        {
            // the body was streamed and endResponse gave the stream back
            releaseWorker(w);
            return flushH2(c);
        }
        if (w.cancelled && !w.timedOut)
        {
            cancelledN++;
            if (st.resetByPeer)
                s.detach(st); // the peer reset it: nothing to send
            else
                s.cancelStream(st, H2Error.cancel); // we gave up on it (a reader that stopped reading)
            releaseWorker(w);
            return flushH2(c);
        }
        if (w.timedOut || w.failed || !w.started || !w.ended)
        {
            if (w.timedOut)
                timedOutN++;
            else if (!w.started && !w.failed)
            {
                auto m = methodName(w.req.method);
                fprintf(stderr, "vela: the handler returned without sending a response (%.*s %.*s)\n",
                    cast(int) m.length, m.ptr, cast(int) w.req.path.length, w.req.path.ptr);
            }
            if (w.committed)
            {
                // HEADERS are out: the status can no longer change, only the stream can be cut off
                s.cancelStream(st, w.timedOut ? H2Error.cancel : H2Error.internal);
                releaseWorker(w);
                return flushH2(c);
            }
            w.output.clear();
            if (w.timedOut)
            {
                static immutable body504 = `{"detail":"request time limit exceeded"}`;
                w.output.put(body504);
                w.h2head = ResponseHead(504, "application/json", null, body504.length);
            }
            else
            {
                w.output.put("Internal Server Error");
                w.h2head = ResponseHead(500, "text/plain; charset=utf-8", null, 21);
            }
        }
        s.respond(st, w.h2head, w.output); // swaps buffers: the body is not copied
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
            return lingerClose(c);
        wakeH2Writers(c);
        if (c.fd < 0 || c.h2 is null)
            return;
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

    /// How long a finished HTTP/2 connection keeps discarding input before it is closed anyway.
    private enum lingerMs = 1000;

    /// Closes a finished cleartext HTTP/2 connection without a reset. close(2) with unread bytes in the receive
    /// queue makes the kernel answer RST, and the peer may then lose the frames we just sent (GOAWAY) or see
    /// "connection reset" instead of a clean end (h2spec 7/1 failed about 1 run in 20 because of this). So: send
    /// FIN, keep the socket for up to `lingerMs` and discard what still arrives, and close on EOF or timeout.
    /// (TLS closes at once: its close_notify has its own protocol.)
    private void lingerClose(Conn c)
    {
        if (c.ssl !is null)
            return closeConn(c);
        if (c.lingering)
            return; // already waiting for the peer
        c.lingering = true;
        c.h2Paused = false;
        c.deadlineMs = nowMs + lingerMs;
        if (shutdown(c.fd, SHUT_WR) != 0)
            return closeConn(c);
        drainLingering(c, EPOLLIN);
    }

    /// Reads and discards until EAGAIN (keep waiting), EOF or error (close).
    private void drainLingering(Conn c, uint events)
    {
        char[1024] sink = void;
        for (;;)
        {
            immutable n = read(c.fd, sink.ptr, sink.length);
            if (n > 0)
                continue;
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
                break;
            return closeConn(c); // EOF (the peer closed too) or an error
        }
        if (events & (EPOLLHUP | EPOLLRDHUP))
            closeConn(c);
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
        if (c.lingering)
        {
            if (nowMs >= c.deadlineMs)
                closeConn(c);
            return;
        }
        auto s = c.h2;
        s.tick(nowMs);
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
        if (failSuppressed)
            flushFailureSummary();
        foreach (c; conns)
        {
            if (c is null || c.fd < 0 || c.deadlineMs == 0 || c.deadlineMs > nowMs || c.phase == Phase.h2
                || c.phase == Phase.upgraded)
                continue;
            if (c.phase == Phase.handshake)
            {
                tlsFailures++;
                logConnError(c, "TLS handshake failed", "timed out (headerTimeoutMs)");
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
                case Phase.upgraded:
                    break;
            }
        }
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.h2)
                sweepH2(c);
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.upgraded)
                sweepUpgraded(c);
        if (cfg.tls.enabled)
            if (auto msg = tlsServer.maybeReload(cfg.tls, nowMs))
                fprintf(stderr, "%.*s\n", cast(int) msg.length, msg.ptr);
    }

    // ------------------------------------------------------------------ closing

    private void sendRaw(Conn c, const(char)[] data)
    {
        if (c.hasPending)
        {
            // behind the held-back responses; what does not go out now is sent at the end of the batch
            c.pending.put(data);
            if (pushPending(c) == 0)
                queuePending(c);
            return;
        }
        // error responses are short: one non-blocking send is enough
        ioSend(c, data.ptr, data.length);
    }

    private void sendErrorAndClose(Conn c, int status)
    {
        errOut.clear();
        writeResponseHead(errOut, status, null, 0, null, false);
        sendRaw(c, errOut.data);
        closeAfterSend(c);
    }

    /// Closes `c`, but only once the responses `coalesce` held back are out (`writeTimeoutMs` at most): they answer
    /// requests that came before the one that ends the connection.
    private void closeAfterSend(Conn c)
    {
        if (c.fd >= 0 && c.hasPending && c.phase == Phase.reading)
        {
            c.closeWhenSent = true;
            return startPendingSend(c);
        }
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
        clearPending(c);
        c.pending.shrinkTo(maxCoalescedBytes * 2); // a pooled Conn does not pin a peak
        c.closeWhenSent = false;
        if (!c.buf.isNull)
            pool.release(c.buf);
        if (c.phase == Phase.upgraded)
            resetUpgraded(c);
        if (c.h2 !is null)
        {
            if (c.h2.fatal && c.h2.lastError != H2Error.noError)
                logConnError(c, "HTTP/2 connection error", h2ErrorName(c.h2.lastError));
            closeH2(c);
        }
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

        // The GC returns a pool to the OS only when it is entirely free. The idle workers (a Context is several KiB, a
        // page-sized block) and the cached buffers were allocated during the burst, between its big blocks, and would pin
        // those pools; the next burst recreates them in microseconds.
        while (idle.n)
        {
            auto w = idle.pop();
            w.retiring = true;
            w.call();
            destroy(w);
            workersRetired++;
        }
        pool.dropCache();
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
        closeListener(mainListener);
        closeListener(redirectListener);
        // taken-over connections waiting for input learn about the stop now (a WebSocket closes with 1001)
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.upgraded)
                wsDefer(c.readWaiter);
        drainWsWakes();
    }

    private void closeIdleConns()
    {
        foreach (c; conns)
        {
            if (c is null || c.fd < 0)
                continue;
            if (c.phase == Phase.handshake
                || (c.phase == Phase.reading && (c.buf.isNull || c.buf.len == 0) && !c.hasPending))
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
            if (c !is null && c.fd >= 0 && c.phase == Phase.upgraded && c.worker !is null)
                cancelWorker(c.worker, false);
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
        closeListener(mainListener);
        closeListener(redirectListener);
        atomicStore(ready, false);
    }
}

/// The host part of a Host header, validated for use in a redirect: a DNS name or IPv4 address
/// (letters, digits, '.', '-') or a bracketed IPv6 literal; the port, if any, is dropped.
private bool hostForRedirect(const(char)[] h, out const(char)[] host) pure nothrow @nogc @safe
{
    if (h.length == 0 || h.length > 255)
        return false;
    if (h[0] == '[')
    {
        size_t e = 1;
        while (e < h.length && h[e] != ']')
        {
            immutable ch = h[e];
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') || ch == ':' || ch == '.'))
                return false;
            e++;
        }
        if (e == h.length || e == 1)
            return false;
        host = h[0 .. e + 1];
        return e + 1 == h.length || h[e + 1] == ':';
    }
    size_t e = 0;
    while (e < h.length && h[e] != ':')
    {
        immutable ch = h[e];
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '-'))
            return false;
        e++;
    }
    if (e == 0)
        return false;
    foreach (ch; h[e .. $][e < h.length ? 1 : 0 .. $])
        if (ch < '0' || ch > '9')
            return false;
    host = h[0 .. e];
    return true;
}

@safe unittest
{
    const(char)[] h;
    assert(hostForRedirect("example.com", h) && h == "example.com");
    assert(hostForRedirect("example.com:80", h) && h == "example.com");
    assert(hostForRedirect("127.0.0.1:8080", h) && h == "127.0.0.1");
    assert(hostForRedirect("[::1]:80", h) && h == "[::1]");
    assert(hostForRedirect("[2001:db8::1]", h) && h == "[2001:db8::1]");
    assert(!hostForRedirect("", h));
    assert(!hostForRedirect("evil.com/path", h));
    assert(!hostForRedirect("a b", h));
    assert(!hostForRedirect("x.com:80x", h));
    assert(!hostForRedirect("[::1", h));
    assert(!hostForRedirect("user@host", h));
}

// ======================================================================= multiple workers

private __gshared EpollLoop[] gLoops;

// ---- crash report: a stack overflow in a fiber is a SIGSEGV that ends the whole process with no hint of the cause.
// Each worker thread gets an alternate signal stack (the faulting stack is the one that is full) and this handler
// writes one line saying which request was running, then returns: SA_RESETHAND restored the default action, so the
// faulting instruction runs again and the process dies as usual, with its core dump.

private Worker crashWorker;   // thread-local: the fiber running right now (null while the loop itself runs)
private uint crashStackKiB;   // thread-local: ServerConfig.fiberStackBytes of this worker

private extern (C) void onCrash(int sig, siginfo_t* info, void*) nothrow @nogc @system
{
    auto w = crashWorker;
    if (w is null)
        return; // not in a handler: nothing useful to add
    char[512] buf = void;
    size_t n;
    void put(scope const(char)[] t) nothrow @nogc
    {
        foreach (c; t)
            if (n < buf.length)
                buf[n++] = c;
    }
    void putNum(ulong v, uint base) nothrow @nogc
    {
        char[20] d = void;
        size_t k = d.length;
        do
        {
            d[--k] = "0123456789abcdef"[v % base];
            v /= base;
        }
        while (v);
        put(d[k .. $]);
    }
    put("vela: segmentation fault (address 0x");
    putNum(cast(ulong) info.si_addr, 16);
    put(") while running ");
    put(methodName(w.req.method));
    put(" ");
    put(w.req.path.length > 120 ? w.req.path[0 .. 120] : w.req.path);
    put(". If the handler recurses deeply or keeps large arrays on the stack, raise ServerConfig.fiberStackBytes (now ");
    putNum(crashStackKiB, 10);
    put(" KiB).\n");
    write(2, buf.ptr, n);
}

/// Alternate stack for this thread plus the process-wide handler (installed once).
private void installCrashReport(uint stackBytes) nothrow @nogc @system
{
    import core.stdc.stdlib : malloc;
    import core.atomic : cas;

    crashStackKiB = stackBytes >> 10;
    enum altBytes = 64 * 1024;
    stack_t ss;
    ss.ss_sp = malloc(altBytes);
    ss.ss_size = altBytes;
    ss.ss_flags = 0;
    if (ss.ss_sp is null || sigaltstack(&ss, null) != 0)
        return;
    static shared bool installed;
    if (cas(&installed, false, true))
    {
        sigaction_t sa;
        sa.sa_sigaction = &onCrash;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
        sigaction(SIGSEGV, &sa, null);
        sigaction(SIGBUS, &sa, null);
    }
}

private void removeCrashReportStack() nothrow @nogc @system
{
    import core.stdc.stdlib : free;

    stack_t cur;
    if (sigaltstack(null, &cur) == 0 && cur.ss_sp !is null)
    {
        stack_t off;
        off.ss_flags = SS_DISABLE;
        sigaltstack(&off, null);
        free(cur.ss_sp);
    }
}

private extern (C) void onSignal(int) nothrow @nogc
{
    foreach (l; gLoops)
        l.stop();
}

/// Set when a worker's `WorkerInit` threw or a worker could not start; read after the threads are joined.
private shared bool gStartupFailed;

private void stopAllLoops() nothrow @nogc
{
    foreach (l; gLoops)
        l.stop();
}

/// Runs `init` and reports a failure in one line. Returns null on failure.
private HandlerFactory buildWorker(WorkerInit init) nothrow
{
    try
        return init();
    catch (Throwable t)
    {
        fprintf(stderr, "vela: building the app failed: %.*s (%.*s:%d)\n", cast(int) t.msg.length, t.msg.ptr,
            cast(int) t.file.length, t.file.ptr, cast(int) t.line);
        return null;
    }
}

private Thread startWorker(EpollLoop lp, ServerConfig cfg, WorkerInit init)
{
    auto t = new Thread({
        // the App (and everything the build function creates) is born on this worker's own thread
        auto f = buildWorker(init);
        if (f is null)
        {
            atomicStore(gStartupFailed, true);
            stopAllLoops(); // the other workers cannot serve a half-started server
            return;
        }
        lp.run(cfg, f);
    });
    t.start();
    return t;
}

/// Starts `cfg.workers` loops (one per core if 0), each building its own handler with `init` on its own thread, and
/// blocks until SIGINT/SIGTERM. Returns false if the server could not start (TLS configuration, `init` threw, a
/// listener could not bind); the caller decides what to do about it.
bool runEpollServer(ServerConfig cfg, WorkerInit init)
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
            return false;
        }
    }
    gLoops = null;
    atomicStore(gStartupFailed, false);
    foreach (_; 0 .. n)
    {
        auto l = new EpollLoop;
        if (cfg.tls.enabled)
            l.shareTicketKeys(keys);
        gLoops ~= l;
    }

    // Worker 0 builds first, here on the main thread, before any other thread exists: a bad build function is
    // reported once, and nothing else starts.
    auto factory0 = buildWorker(init);
    if (factory0 is null)
        return false;

    sigaction_t sa;
    sa.sa_handler = &onSignal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, null);
    sigaction(SIGTERM, &sa, null);

    printf("vela (epoll, %u worker%s) at %s://%.*s:%d\n", n, n == 1 ? "".ptr : "s".ptr,
        cfg.tls.enabled ? "https".ptr : "http".ptr,
        cast(int) cfg.host.length, cfg.host.ptr, cast(int) cfg.port);
    if (cfg.tls.enabled && cfg.tls.redirectPort)
        printf("vela: port %d redirects to https%s\n", cast(int) cfg.tls.redirectPort,
            cfg.tls.acmeWebroot.length ? " and serves ACME challenges".ptr : "".ptr);

    Thread[] threads;
    foreach (i; 1 .. n)
        threads ~= startWorker(gLoops[i], cfg, init);
    gLoops[0].run(cfg, factory0); // worker 0 runs on the main thread
    foreach (t; threads)
        t.join();
    // a loop that never became ready did not manage to listen (port in use, bad address...)
    bool ok = !atomicLoad(gStartupFailed);
    foreach (l; gLoops)
        ok = ok && atomicLoad(l.everListened);
    return ok;
}
