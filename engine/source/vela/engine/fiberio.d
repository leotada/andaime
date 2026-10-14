/// Cooperative I/O for handlers.
///
/// Inside a request, `sleep` and `awaitFd` suspend the handler's fiber
/// and give the worker back to the loop, which keeps serving other connections. Outside
/// a vela fiber (tests, dev server) they fall back to blocking, so the
/// same code works in both worlds.
///
/// `spawn` runs work on a fiber of the same loop, with no connection. The development server has no
/// fibers: there the delegate runs inline, because background jobs need the epoll loop.
///
/// Golden rule: every I/O wait in a handler goes through here (or through a
/// library built on top of this). Any blocking call (a real
/// `sleep`, a synchronous C lib) stalls the whole worker.
module vela.engine.fiberio;

@safe:

import core.time : Duration;

/// Thrown INSIDE the handler when the request was cancelled (the client
/// disconnected or the deadline passed). It is not an `Exception` on purpose: a user's
/// `catch (Exception)` does not swallow it by accident, and `scope(exit)`
/// and destructors run normally as the stack unwinds. Whoever catches
/// `Throwable` and carries on only gets one more `awaitFd`, which throws again.
final class RequestCancelled : Throwable
{
    this() @nogc nothrow @safe
    {
        super("vela: request cancelled (client disconnected or deadline passed)");
    }
}

/// `awaitFd` events. The values match EPOLLIN/EPOLLOUT and POLLIN/POLLOUT.
enum IoEvent : uint
{
    readable = 0x1,
    writable = 0x4,
    error = 0x8,   /// result only
    hangup = 0x10, /// result only
}

/// Implemented by each worker's loop.
interface Scheduler
{
    /// True when called from inside a fiber of this loop (a request or a background fiber).
    bool inRequest() nothrow;
    /// Returns the mask of ready events, or 0 if the deadline passed. `timeoutMs < 0` = no deadline.
    uint awaitFd(int fd, uint events, long timeoutMs);
    void sleepMs(long ms);
    /// True once SIGINT/SIGTERM has begun a graceful stop on this loop.
    bool isStopping() nothrow @nogc;
    /// Queues `work` on a fiber of this loop. See the free function `spawn`.
    void spawn(void delegate() @safe work);
}

/// The scheduler of this thread's worker (module variable = thread-local).
Scheduler currentScheduler;

/// This thread's worker index, written by the engine before `WorkerInit`. 0 is the first worker, and the
/// development server's only thread. A D module variable is already thread-local, so this is a plain `int`.
int workerIndex;

private long toMs(Duration d) nothrow @nogc @safe
{
    immutable us = d.total!"usecs";
    return us <= 0 ? 0 : (us + 999) / 1000;
}

/// Waits `d` without blocking the worker (inside a request).
void sleep(Duration d)
{
    if (currentScheduler !is null && currentScheduler.inRequest)
        currentScheduler.sleepMs(toMs(d));
    else
    {
        import core.thread : Thread;

        Thread.sleep(d);
    }
}

/// Waits for `fd` to become ready for the requested `events` (`IoEvent.readable`,
/// `IoEvent.writable`). Returns the mask of ready events, or 0 if `timeout`
/// expired. The fd must be in non-blocking mode. Throws `RequestCancelled`
/// if the request was cancelled while waiting.
uint awaitFd(int fd, uint events, Duration timeout = Duration.max)
{
    immutable long ms = timeout == Duration.max ? -1 : toMs(timeout);
    if (currentScheduler !is null && currentScheduler.inRequest)
        return currentScheduler.awaitFd(fd, events, ms);

    // blocking fallback (outside the loop)
    import core.sys.posix.poll : poll, pollfd;

    pollfd p = pollfd(fd, cast(short) events, 0);
    immutable r = (() @trusted => poll(&p, 1, cast(int)(ms < 0 ? -1 : ms)))();
    return r > 0 ? cast(uint) p.revents : 0;
}

/// Set from the loop at `beginStop` and cleared when a new `run` starts. Stays set after the scheduler is
/// detached, so a fiber unwinding `RequestCancelled` still observes the stop.
private bool stopRequested;

/// True once this worker has begun a graceful stop (SIGINT/SIGTERM reached the loop). False outside a worker
/// that is running or shutting down. A background fiber checks this and stops taking work; the loop keeps
/// running until the fiber returns, or cancels it at `ServerConfig.shutdownGraceMs` if it is still sleeping.
bool stopping() nothrow @nogc
{
    if (stopRequested)
        return true;
    auto s = currentScheduler;
    return s !is null && s.isStopping();
}

package void setStopRequested(bool v) nothrow @nogc @safe
{
    stopRequested = v;
}

/// Runs `work` on a fiber of this thread's loop. It counts toward `inFlight`. There is no connection and no
/// HTTP/2 stream. From inside a request or background fiber the new one starts only after the caller yields:
/// the loop never resumes a fiber from inside another. During `WorkerInit`, before the loop polls, `work` is
/// queued and starts when `run` begins.
///
/// On the development server (no epoll scheduler) `work` runs on this thread. Background jobs need the epoll loop.
/// After the loop has shut down, a call on Linux does nothing: there is no scheduler left to attach the fiber to.
void spawn(void delegate() @safe work)
{
    if (work is null)
        return;
    if (currentScheduler !is null)
    {
        currentScheduler.spawn(work);
        return;
    }
    version (linux)
        return;
    else
        work();
}

/// ditto. A function with no captures is not a delegate; this overload wraps it so `spawn(&work)` compiles.
/// `null` does not match (it selects the delegate overload) so the two do not collide.
void spawn(F)(F work) if (is(F == void function() @safe))
{
    if (work is null)
        return;
    auto call = work; // captured, so the wrapper is a delegate rather than another function
    spawn(() { call(); });
}
