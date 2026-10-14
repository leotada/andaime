/// Background fibers on a loop that does not accept connections.
/// One fiber sleeps until stop, a second is spawned from the first (so the wake-up is deferred to the
/// loop), then SIGTERM: the process must return once they notice the stop, without waiting out the grace
/// period. A second run sleeps past the grace period and must be cancelled.
module spawn_net;

version (linux):

import vela;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import core.stdc.stdio : printf, fprintf, fflush, stderr, stdout;
import core.stdc.stdlib : exit;
import core.sys.posix.signal : kill, SIGTERM;
import core.sys.posix.unistd : getpid;

shared int phase, child, cancelled, hooks, mask;

@safe:

/// Started from `parentFiber`, so the loop must defer the resume until that fiber yields.
void childFiber()
{
    atomicStore(child, 1);
    while (!stopping())
        sleep(20.msecs);
    atomicStore(child, 2);
}

/// Queued from worker 0's init. Stays asleep until the loop is stopping.
void parentFiber()
{
    atomicStore(phase, 1);
    spawn(&childFiber); // function pointer: queued until this fiber yields
    while (!stopping())
        sleep(20.msecs);
    atomicStore(phase, 2);
}

void hookFinish()
{
    assert(workerIndex == 0);
    atomicOp!"+="(hooks, 1);
    spawn(&parentFiber);
}

/// Sleeps much longer than `shutdownGraceMs`. `scope(failure)` records the cancel: `@safe` code cannot
/// catch `RequestCancelled` (it is a `Throwable`, not an `Exception`).
void cancelFiber()
{
    atomicStore(phase, 1);
    scope (failure)
        atomicStore(cancelled, 1);
    sleep(30.seconds);
    atomicStore(phase, 2);
}

void hookCancel()
{
    assert(workerIndex == 0);
    spawn(&cancelFiber);
}

@system:

App build()
{
    atomicOp!"|="(mask, 1 << workerIndex);
    return new App;
}

void resetFlags()
{
    atomicStore(phase, 0);
    atomicStore(child, 0);
    atomicStore(cancelled, 0);
    atomicStore(hooks, 0);
    atomicStore(mask, 0);
}

bool waitUntil(int wantPhase, int wantChild, int timeoutMs)
{
    foreach (_; 0 .. timeoutMs / 5)
    {
        if (atomicLoad(phase) == wantPhase && (wantChild < 0 || atomicLoad(child) == wantChild))
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

/// `accept = false`: the loop polls with no listener. Stop leaves as soon as the background fibers return.
void testStopsWhenFibersFinish()
{
    resetFlags();
    ServerConfig cfg;
    cfg.accept = false;
    cfg.workers = 2;
    cfg.shutdownGraceMs = 8_000;

    bool result;
    auto t = new Thread({
        result = tryServe(&build, cfg, &hookFinish);
    });
    t.start();

    if (!waitUntil(1, 1, 2000))
    {
        printf("phase=%d child=%d hooks=%d mask=%d\n", atomicLoad(phase), atomicLoad(child),
            atomicLoad(hooks), atomicLoad(mask));
        assert(0, "background fiber did not start");
    }
    kill(getpid(), SIGTERM);
    immutable t0 = MonoTime.currTime;
    t.join();
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("stop returned in %ld ms\n", ms);
    fflush(stdout);

    assert(result, "tryServe should return true after a graceful stop with accept=false");
    assert(atomicLoad(hooks) == 1, "onWorker0 runs only on worker 0");
    assert(atomicLoad(mask) == 3, "workerIndex 0 and 1 were both visible to WorkerInit");
    assert(atomicLoad(phase) == 2 && atomicLoad(child) == 2, "both fibers should see the stop and return");
    assert(atomicLoad(cancelled) == 0);
    assert(ms < 2500, "the loop should return once the fibers finish, not at shutdownGraceMs");
    ok("accept=false: background fiber sleeps, sees stop, and the process returns");
}

/// A fiber that ignores the stop is cancelled with RequestCancelled when the grace period ends.
void testCancelsAtDeadline()
{
    resetFlags();
    ServerConfig cfg;
    cfg.accept = false;
    cfg.workers = 1;
    cfg.shutdownGraceMs = 300;

    bool result;
    auto t = new Thread({
        result = tryServe(&build, cfg, &hookCancel);
    });
    t.start();

    if (!waitUntil(1, -1, 2000))
        assert(0, "background fiber did not start");
    kill(getpid(), SIGTERM);
    immutable t0 = MonoTime.currTime;
    t.join();
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("cancel returned in %ld ms\n", ms);
    fflush(stdout);

    assert(result);
    assert(atomicLoad(cancelled) == 1, "the sleeping fiber should get RequestCancelled at the deadline");
    assert(atomicLoad(phase) == 1, "the long sleep should not finish on its own");
    assert(ms < 2000, "cancellation should happen at shutdownGraceMs, not after the 30 s sleep");
    ok("shutdownGraceMs cancels a background fiber that is still sleeping");
}

void main()
{
    auto guard = new Thread({
        Thread.sleep(20.seconds);
        fprintf(stderr, "spawn_net: timed out\n");
        exit(1);
    });
    guard.isDaemon = true;
    guard.start();

    testStopsWhenFibersFinish();
    testCancelsAtDeadline();
    printf("all background-fiber tests passed\n");
}
