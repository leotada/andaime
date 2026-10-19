/// Bounded thread pool for what can NOT be done cooperatively:
/// DNS (`getaddrinfo`), heavy CPU, synchronous C libraries.
///
/// `offload(() => heavyWork())` runs the delegate on a pool thread and
/// suspends only the calling fiber: the worker keeps serving other connections.
/// The result comes back through an eventfd that the fiber waits on with `awaitFd`.
///
/// Limits (nothing grows without a ceiling): fixed `threads` and a queue of `queueMax`
/// tasks; when full, `offload` throws `PoolSaturated` right away (the handler decides
/// whether it becomes a 503). If the request is cancelled while the work runs, the
/// work finishes by itself and the result is discarded.
///
/// Outside an andaime fiber (tests, dev server) the delegate runs inline.
module andaime.engine.offload 2025;

@safe:

import core.atomic : atomicFetchSub, atomicStore, atomicLoad;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import andaime.engine.os : NotifyFd, usableCpuCount;
import andaime.engine.fiberio : awaitFd, currentScheduler, IoEvent;
version (assert)
    import andaime.engine.fiberio : copyLocalsHere, FiberLocals, offloadSender;

/// The pool queue is full: too much pending work.
final class PoolSaturated : Exception
{
    this() @safe pure nothrow { super("andaime: thread pool saturated (queue full)"); }
}

private alias Job = void delegate() @safe;

/// Pool with fixed threads and a fixed-size circular queue.
final class ThreadPool
{
    private Mutex mu;
    private Condition cv;
    private Job[] ring;
    private size_t head, count;
    private bool closing;
    private Thread[] threads;

    // @trusted: druntime's Thread/Mutex/Condition are @system, but they are used here in the plain, sound way
    this(uint nThreads, uint queueMax) @trusted
    {
        assert(nThreads > 0 && queueMax > 0, "andaime: ThreadPool needs threads and a queue > 0");
        mu = new Mutex;
        cv = new Condition(mu);
        ring = new Job[queueMax];
        foreach (i; 0 .. nThreads)
        {
            auto t = new Thread(&loop);
            t.isDaemon = true;
            t.start();
            threads ~= t;
        }
    }

    /// Enqueues; returns false if the queue is full.
    bool submit(Job j) @trusted
    {
        synchronized (mu)
        {
            if (closing || count == ring.length)
                return false;
            ring[(head + count) % ring.length] = j;
            count++;
        }
        cv.notify();
        return true;
    }

    /// Tasks waiting for a free thread (metric).
    size_t pending() @trusted
    {
        synchronized (mu)
            return count;
    }

    /// Finishes the already-enqueued tasks and stops the threads.
    void shutdown() @trusted
    {
        synchronized (mu)
            closing = true;
        cv.notifyAll();
        foreach (t; threads)
            t.join();
        threads = null;
    }

    private void loop() @trusted
    {
        for (;;)
        {
            Job j;
            synchronized (mu)
            {
                while (count == 0 && !closing)
                    cv.wait();
                if (count == 0)
                    return;
                j = ring[head];
                ring[head] = null;
                head = (head + 1) % ring.length;
                count--;
            }
            j();
        }
    }
}

private __gshared ThreadPool gPool;
private __gshared Mutex gPoolMu;
private __gshared uint gThreads, gQueue = 256; // gThreads 0: the CPUs this process may use

shared static this() @trusted
{
    gPoolMu = new Mutex;
}

/// Sets the size of the default pool. Call it before `serve`; once the pool
/// exists, the call is ignored (returns false). Without it the pool has one thread per CPU the process may use
/// (`usableCpuCount`: the affinity mask on Linux), and `queueMax` is 256.
bool configureOffload(uint threads, uint queueMax) @trusted
{
    synchronized (gPoolMu)
    {
        if (gPool !is null)
            return false;
        gThreads = threads;
        gQueue = queueMax;
        return true;
    }
}

/// The default pool (created on first use).
ThreadPool offloadPool() @trusted
{
    synchronized (gPoolMu)
    {
        if (gPool is null)
            gPool = new ThreadPool(threadsLocked(), gQueue);
        return gPool;
    }
}

/// Threads of the default pool: the number it has, or will have when it is created. Without `configureOffload` that is
/// the number of CPUs the process may use.
uint offloadThreads() @trusted
{
    synchronized (gPoolMu)
        return threadsLocked();
}

/// Queue length of the default pool (`configureOffload`'s `queueMax`, 256 by default).
uint offloadQueueMax() @trusted
{
    synchronized (gPoolMu)
        return gQueue;
}

private uint threadsLocked() @trusted // callers hold gPoolMu
{
    return gThreads ? gThreads : usableCpuCount();
}

/// State shared between the fiber and the pool thread. Owner of the notification descriptor:
/// whoever decrements `refs` to zero closes it.
private final class Call(T)
{
    NotifyFd nfd;
    shared int refs = 2;
    Throwable err;
    static if (!is(T == void))
        T value;
    version (assert)
        FiberLocals sender; // what offloadSenderLocal reads on the pool thread

    void release() nothrow @nogc @trusted
    {
        if (atomicFetchSub(refs, 1) == 1)
            nfd.close();
    }
}

/// Runs `work` on a pool thread and returns the result, suspending only the fiber.
/// Exceptions from `work` are rethrown here.
T offload(T)(T delegate() @safe work) @trusted
{
    if (currentScheduler is null || !currentScheduler.inRequest)
        return work(); // outside a fiber: inline

    auto call = new Call!T;
    if (!call.nfd.open())
        throw new Exception("andaime: NotifyFd failed in offload");
    version (assert)
        call.sender = copyLocalsHere(); // a copy: the fiber may be cancelled and reused while the job runs

    auto job = delegate() @trusted {
        version (assert)
        {
            offloadSender = &call.sender;
            scope (exit)
                offloadSender = null;
        }
        try
        {
            static if (is(T == void))
                work();
            else
                call.value = work();
        }
        catch (Throwable t)
            call.err = t;
        call.nfd.notify();
        call.release();
    };

    if (!offloadPool().submit(job))
    {
        call.nfd.close();
        throw new PoolSaturated;
    }

    // If awaitFd throws RequestCancelled, the job will still notify
    // and close it; here we only drop our reference.
    scope (exit)
        call.release();
    awaitFd(call.nfd.readFd, IoEvent.readable);
    call.nfd.drain();

    if (call.err !is null)
        throw call.err;
    static if (!is(T == void))
        return call.value;
}

@trusted unittest
{
    // outside a fiber: inline
    assert(offload(() => 40 + 2) == 42);
    int x;
    offload(() { x = 7; });
    assert(x == 7);
    bool threw;
    try
        offload(() { throw new Exception("boom"); });
    catch (Exception e)
        threw = e.msg == "boom";
    assert(threw);

    auto p = new ThreadPool(2, 2);
    shared int n;
    foreach (i; 0 .. 2)
        assert(p.submit(() { import core.atomic : atomicOp; atomicOp!"+="(n, 1); }));
    p.shutdown();
    assert(atomicLoad(n) == 2);
}
