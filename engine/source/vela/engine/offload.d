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
/// Outside a vela fiber (tests, dev server) the delegate runs inline.
module vela.engine.offload;

import core.atomic : atomicFetchSub, atomicStore, atomicLoad;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.eventfd : eventfd;
import core.sys.posix.unistd : close, write;
import core.thread : Thread;

import vela.engine.fiberio : awaitFd, currentScheduler, IoEvent;

/// The pool queue is full: too much pending work.
final class PoolSaturated : Exception
{
    this() @safe pure nothrow { super("vela: thread pool saturated (queue full)"); }
}

private alias Job = void delegate();

/// Pool with fixed threads and a fixed-size circular queue.
final class ThreadPool
{
    private Mutex mu;
    private Condition cv;
    private Job[] ring;
    private size_t head, count;
    private bool closing;
    private Thread[] threads;

    this(uint nThreads, uint queueMax)
    {
        assert(nThreads > 0 && queueMax > 0, "vela: ThreadPool needs threads and a queue > 0");
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
    bool submit(Job j)
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
    size_t pending()
    {
        synchronized (mu)
            return count;
    }

    /// Finishes the already-enqueued tasks and stops the threads.
    void shutdown()
    {
        synchronized (mu)
            closing = true;
        cv.notifyAll();
        foreach (t; threads)
            t.join();
        threads = null;
    }

    private void loop()
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
private __gshared uint gThreads = 4, gQueue = 256;

shared static this()
{
    gPoolMu = new Mutex;
}

/// Sets the size of the default pool. Call it before `serve`; once the pool
/// exists, the call is ignored (returns false).
bool configureOffload(uint threads, uint queueMax)
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
ThreadPool offloadPool()
{
    synchronized (gPoolMu)
    {
        if (gPool is null)
            gPool = new ThreadPool(gThreads, gQueue);
        return gPool;
    }
}

/// State shared between the fiber and the pool thread. Owner of the eventfd:
/// whoever decrements `refs` to zero closes the fd.
private final class Call(T)
{
    int efd = -1;
    shared int refs = 2;
    Throwable err;
    static if (!is(T == void))
        T value;

    void release() nothrow @nogc
    {
        if (atomicFetchSub(refs, 1) == 1)
            close(efd);
    }
}

/// Runs `work` on a pool thread and returns the result, suspending only the fiber.
/// Exceptions from `work` are rethrown here.
T offload(T)(T delegate() work)
{
    if (currentScheduler is null || !currentScheduler.inRequest)
        return work(); // outside a fiber: inline

    auto call = new Call!T;
    call.efd = eventfd(0, 0x800 /*EFD_NONBLOCK*/ | 0x80000 /*EFD_CLOEXEC*/);
    if (call.efd < 0)
        throw new Exception("vela: eventfd failed in offload");

    auto job = delegate() {
        try
        {
            static if (is(T == void))
                work();
            else
                call.value = work();
        }
        catch (Throwable t)
            call.err = t;
        ulong one = 1;
        write(call.efd, &one, one.sizeof);
        call.release();
    };

    if (!offloadPool().submit(job))
    {
        close(call.efd);
        throw new PoolSaturated;
    }

    // If awaitFd throws RequestCancelled, the job will still write to the eventfd
    // and close it; here we only drop our reference.
    scope (exit)
        call.release();
    awaitFd(call.efd, IoEvent.readable);

    if (call.err !is null)
        throw call.err;
    static if (!is(T == void))
        return call.value;
}

unittest
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
