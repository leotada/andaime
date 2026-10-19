/// Cooperative I/O for handlers.
///
/// Inside a request, `sleep` and `awaitFd` suspend the handler's fiber
/// and give the worker back to the loop, which keeps serving other connections. Outside
/// an andaime fiber (tests, dev server) they fall back to blocking, so the
/// same code works in both worlds.
///
/// `spawn` runs work on a fiber of the same loop, with no connection. The development server has no
/// fibers: there the delegate runs inline, because background jobs need the epoll loop.
///
/// Golden rule: every I/O wait in a handler goes through here (or through a
/// library built on top of this). Any blocking call (a real
/// `sleep`, a synchronous C lib) stalls the whole worker.
module andaime.engine.fiberio 2025;

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
        super("andaime: request cancelled (client disconnected or deadline passed)");
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

import core.thread.fiber : Fiber;

/// The values the layers above the engine keep with one fiber: one per class type, found by `typeid` (see `fiberLocal`).
/// Four types fit without allocating; more go to a heap array.
struct FiberLocals
{
    private static struct Slot
    {
        TypeInfo_Class key;
        Object value;
    }

    private Slot[4] fixed;
    private Slot[] more;

    /// The value kept for `key`, or null.
    Object get(scope const TypeInfo_Class key) nothrow @nogc
    {
        foreach (ref s; fixed)
            if (s.key is key)
                return s.value;
        foreach (ref s; more)
            if (s.key is key)
                return s.value;
        return null;
    }

    /// Keeps `value` for `key` (null removes it) and returns the previous value.
    Object put(TypeInfo_Class key, Object value) nothrow
    {
        foreach (ref s; fixed)
            if (s.key is key)
                return swap(s, value);
        foreach (ref s; more)
            if (s.key is key)
                return swap(s, value);
        if (value is null)
            return null;
        foreach (ref s; fixed)
            if (s.key is null)
            {
                s = Slot(key, value);
                return null;
            }
        foreach (ref s; more)
            if (s.key is null)
            {
                s = Slot(key, value);
                return null;
            }
        more ~= Slot(key, value);
        return null;
    }

    /// Forgets every value (the fiber goes back to the pool).
    void clear() nothrow @nogc
    {
        fixed[] = Slot.init;
        more[] = Slot.init;
    }

    private static Object swap(ref Slot s, Object value) nothrow @nogc
    {
        auto old = s.value;
        if (value is null)
            s = Slot.init;
        else
            s.value = value;
        return old;
    }
}

/// A fiber that carries `FiberLocals` for the layers above the engine: the engine's request and background fibers are
/// `LocalFiber`s. The server keeps the request's `Context` there (the logger reads the request id from it), andaime:jobs
/// a job's `LogScope`, andaime:pg the open transaction. Per fiber, not per thread: many requests interleave on one thread.
class LocalFiber : Fiber
{
    package FiberLocals locals;

    this(void delegate() dg, size_t stackSize) nothrow @trusted
    {
        // @trusted: Fiber's constructor only stores the delegate and maps the stack
        super(dg, stackSize);
    }

    /// Forgets every fiber-local value. The engine calls it when the fiber goes back to its pool, so a reused fiber
    /// starts empty.
    final void clearLocals() nothrow @nogc
    {
        locals.clear();
    }
}

/// The table used outside a `LocalFiber`: tests, the development server (one request at a time per thread),
/// `WorkerInit`, an offload thread (which therefore never sees the values of the fiber that sent it work).
private FiberLocals threadLocals;

private FiberLocals* localsHere() nothrow @trusted
{
    // @trusted: Fiber.getThis only reads the running fiber of this thread; the pointer is to that fiber's own table
    // (or this thread's) and every caller uses it before the fiber can yield
    if (auto f = cast(LocalFiber) Fiber.getThis())
        return &f.locals;
    return &threadLocals;
}

/// This fiber's `T`, or null. Outside a `LocalFiber` it is this thread's. Allocates nothing.
T fiberLocal(T)() nothrow if (is(T == class))
{
    return reinterpret!T(localsHere().get(typeid(T)));
}

/// Keeps `value` as this fiber's `T` (this thread's outside a `LocalFiber`) and returns the previous one, so a caller
/// can restore it. Null removes it. Allocates only past four types on one fiber.
T setFiberLocal(T)(T value) nothrow if (is(T == class))
{
    return reinterpret!T(localsHere().put(typeid(T), value));
}

/// Removes this fiber's `T`.
void clearFiberLocal(T)() nothrow if (is(T == class))
{
    localsHere().put(typeid(T), null);
}

/// True when running in a `LocalFiber` (a request or background fiber of the engine).
bool inLocalFiber() nothrow @trusted
{
    // @trusted: Fiber.getThis only reads the running fiber of this thread
    return cast(LocalFiber) Fiber.getThis() !is null;
}

private T reinterpret(T)(Object o) nothrow @trusted
{
    // @trusted: a slot keyed by typeid(T) is only ever written by setFiberLocal!T, which takes a T, so `o` is a T (or
    // null); this skips the dynamic cast
    return cast(T) cast(void*) o;
}

version (unittest)
{
    private final class LayerA { int v; this(int v) { this.v = v; } }
    private final class LayerB { string v; this(string v) { this.v = v; } }
    private class Base { }
    private final class Derived : Base { }
    private final class K1 { }
    private final class K2 { }
    private final class K3 { }
    private final class K4 { }
    private final class K5 { }
}

// two layers keep their own value; set returns the previous one; null and clear remove
@safe unittest
{
    assert(fiberLocal!LayerA is null);
    auto a = new LayerA(1);
    assert(setFiberLocal(a) is null);
    assert(setFiberLocal(new LayerB("b")) is null);
    assert(fiberLocal!LayerA is a && fiberLocal!LayerB.v == "b");
    auto a2 = new LayerA(2);
    assert(setFiberLocal(a2) is a);
    assert(fiberLocal!LayerA.v == 2);
    clearFiberLocal!LayerA;
    assert(fiberLocal!LayerA is null && fiberLocal!LayerB !is null);
    setFiberLocal!LayerB(null);
    assert(fiberLocal!LayerB is null);

    // keyed by the static type: a Derived stored as Base is found as Base only
    Base d = new Derived;
    setFiberLocal(d);
    assert(fiberLocal!Base is d && fiberLocal!Derived is null);
    clearFiberLocal!Base;

    // past the four fixed slots, and a freed slot is reused
    setFiberLocal(new K1);
    setFiberLocal(new K2);
    setFiberLocal(new K3);
    setFiberLocal(new K4);
    auto k5 = new K5;
    setFiberLocal(k5);
    assert(fiberLocal!K5 is k5 && fiberLocal!K1 !is null);
    clearFiberLocal!K2;
    setFiberLocal(new LayerA(3));
    assert(fiberLocal!LayerA.v == 3 && fiberLocal!K5 is k5);
    threadLocals.clear();
    assert(fiberLocal!K5 is null && fiberLocal!LayerA is null);
}

// a LocalFiber has its own table, apart from the thread's; clearLocals empties it
@system unittest
{
    auto outside = new LayerA(10);
    setFiberLocal(outside);
    LayerA seenInside;
    LocalFiber f;
    f = new LocalFiber({
        seenInside = fiberLocal!LayerA;
        setFiberLocal(new LayerA(20));
        assert(inLocalFiber());
        Fiber.yield();
        assert(fiberLocal!LayerA is null, "clearLocals empties the fiber's table");
    }, 64 << 10);
    f.call();
    assert(seenInside is null, "a fiber does not see the thread's values");
    assert(fiberLocal!LayerA is outside, "nor the thread the fiber's");
    assert(!inLocalFiber());
    f.clearLocals();
    f.call();
    clearFiberLocal!LayerA;
}

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
    version (Posix)
    {
        import core.sys.posix.poll : poll, pollfd;

        pollfd p = pollfd(fd, cast(short) events, 0);
        immutable r = (() @trusted => poll(&p, 1, cast(int)(ms < 0 ? -1 : ms)))();
        return r > 0 ? cast(uint) p.revents : 0;
    }
    else version (Windows)
    {
        import core.sys.windows.winsock2 : SOCKET;
        import andaime.engine.os : WSAPOLLFD, WSAPoll, POLLRDNORM, POLLWRNORM, POLLERR, POLLHUP;

        WSAPOLLFD p;
        p.fd = cast(SOCKET) fd;
        p.events = cast(short)((events & IoEvent.readable ? POLLRDNORM : 0) | (events & IoEvent.writable ? POLLWRNORM : 0));
        immutable r = (() @trusted => WSAPoll(&p, 1, cast(int)(ms < 0 ? -1 : ms)))();
        if (r <= 0)
            return 0;
        uint rev;
        if (p.revents & POLLRDNORM)
            rev |= IoEvent.readable;
        if (p.revents & POLLWRNORM)
            rev |= IoEvent.writable;
        if (p.revents & POLLERR)
            rev |= IoEvent.error;
        if (p.revents & POLLHUP)
            rev |= IoEvent.hangup;
        return rev;
    }
    else
    {
        return 0;
    }
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
/// After the loop has shut down, a call does nothing: there is no scheduler left to attach the fiber to.
void spawn(void delegate() @safe work)
{
    if (work is null)
        return;
    if (currentScheduler !is null)
    {
        currentScheduler.spawn(work);
        return;
    }
    return;
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
