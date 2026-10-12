/// Cooperative I/O for handlers.
///
/// Inside a request, `sleep` and `awaitFd` suspend the handler's fiber
/// and give the worker back to the loop, which keeps serving other connections. Outside
/// a vela fiber (tests, dev server) they fall back to blocking, so the
/// same code works in both worlds.
///
/// Golden rule: every I/O wait in a handler goes through here (or through a
/// library built on top of this). Any blocking call (a real
/// `sleep`, a synchronous C lib) stalls the whole worker.
module vela.engine.fiberio;

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
    /// True when called from inside a request's fiber.
    bool inRequest() nothrow;
    /// Returns the mask of ready events, or 0 if the deadline passed. `timeoutMs < 0` = no deadline.
    uint awaitFd(int fd, uint events, long timeoutMs);
    void sleepMs(long ms);
}

/// The scheduler of this thread's worker (module variable = thread-local).
Scheduler currentScheduler;

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
    immutable r = poll(&p, 1, cast(int)(ms < 0 ? -1 : ms));
    return r > 0 ? cast(uint) p.revents : 0;
}
