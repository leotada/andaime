/// Process roles for a job binary.
///
/// `--role=api`: call `runApi`, then `serve` / `tryServe` as usual. This package does not consume
/// and does not call `serve` (the root `vela` package is what exports it). Enqueue on the store
/// the application already holds.
///
/// `--role=worker`: call `runJobs`. It runs the epoll loop with no user routes. `healthPort` 0
/// does not bind; any other port serves `GET /health` (text `ok`, no TLS). `InMemoryJobStore` is
/// one thread: leave `singleThread` at its default `true`, which forces `workers = 1`. A store
/// that is safe across threads may pass `singleThread: false` and keep `ServerConfig.workers`
/// (0 means one thread per core). Consumption, cron, and `WorkerHooks` still run only on worker 0,
/// so `--queues` is not multiplied by the core count.
///
/// `--role=all`: call `serve` / `tryServe` with `supervisorHook` as `onWorker0`. HTTP stays the
/// application's. The hook spawns the supervisor on worker 0 only. With `InMemoryJobStore` the
/// application must set `ServerConfig.workers = 1` itself: every request thread would otherwise
/// enqueue on a store that is not safe across threads.
///
/// The development server runs `spawn` inline. Background jobs need the epoll loop.
///
/// `@Offload` is unchanged. `runClaimed` waits for the pool. If shutdown cancels the fiber while
/// it is inside `offload`, the pool thread can still finish that work; the row has been released
/// (`RequestCancelled` is not an `Exception`) and the result is discarded.
module vela.jobs.worker;

@safe:

import core.time : Duration, msecs, seconds;
import std.datetime.systime : Clock, SysTime;
import vela.engine.fiberio : sleep, spawn, stopping, workerIndex;
import vela.engine.loop : HandlerFactory, RequestCallback, ServerConfig, TlsConfig, WorkerInit;
import vela.http.response : ResponseSink;
import vela.http.types : Method, Request;
import vela.jobs.backend : JobState, JobStore, jobSpec, runClaimed;
import vela.jobs.cli : ProcessRole, Startup, parseStartup, roleText;
import vela.jobs.cron : CronClock, ScheduleKind, ScheduledFire, ScheduledJob, slotUnseen;
import vela.jobs.job : JobContext, jobCronExpr, jobEveryPeriod, jobName;
import vela.web.application : App;
import vela.web.context : Context;
import vela.web.stream : sendResponse;

/// `ServerConfig.shutdownGraceMs` as defined on the struct. Compared by value.
private enum uint serverDefaultGraceMs = 10_000;

/// Grace used by `--role=worker` when the caller left the default. API role does not use this.
private enum uint workerGraceMs = 30_000;

/// How long a consumer waits after an empty claim. Also the cron fiber's poll. Not a busy loop.
enum Duration defaultIdleBackoff = 200.msecs;

/// Optional work the Postgres package starts on worker 0 without this file changing again.
/// `extra` runs during worker 0's init, after the consumer and cron fibers have been `spawn`ed
/// and before the loop polls. `spawn` from here is queued and starts when the loop begins, so
/// this is the place to start LISTEN and the reaper. Do not `sleep` or `awaitFd` in `extra`
/// itself: this call is not yet inside a fiber, and those would block the thread. Null skips it.
struct WorkerHooks
{
    void delegate() @safe extra;
}

/// `--role=api`. Does not start a consumer and does not call `serve`.
/// The application's `main` keeps calling `serve` / `tryServe`. Enqueue stays on the store the
/// application holds (`enqueue!T(store, job)` from a handler). `startup.queues` is ignored:
/// this process has no consumers. This function does not change `ServerConfig.shutdownGraceMs`
/// (the API keeps the 10s default unless the application sets it).
void runApi(Startup startup) @safe
{
    if (startup.role != ProcessRole.api)
        throw new Exception("vela.jobs: runApi is for --role=api, not " ~ roleText(startup.role));
}

/// `--role=worker`. Blocks in the epoll loop until SIGINT/SIGTERM.
///
/// Copies `cfg`. When `singleThread` is true (the default), the copy's `workers` is forced to 1
/// because `InMemoryJobStore` is one thread. Pass false only for a store that is safe across
/// threads; `cfg.workers` is then left as given (0 means one per core). The supervisor still
/// runs only on worker 0.
///
/// `healthPort` 0 sets `accept = false` and binds nothing. Any other value binds that port, and
/// only `GET /health`, with TLS cleared. User routes are not registered.
///
/// Only this role changes shutdown grace, and only when `shutdownGraceMs` is still the
/// `ServerConfig` default of 10_000: the copy becomes 30_000 so a running job can finish or be
/// released. A caller who already set a different `shutdownGraceMs` keeps that value.
/// `--role=api` does not come through here. `--role=all` does not either: the application owns
/// the `ServerConfig` it passes to `serve`.
void runJobs(Jobs...)(JobStore store, Startup startup, ServerConfig cfg = ServerConfig.init,
        bool singleThread = true, ushort healthPort = 0, WorkerHooks hooks = WorkerHooks.init,
        Duration idleBackoff = defaultIdleBackoff) @safe
{
    if (store is null)
        throw new Exception("vela.jobs: runJobs needs a store");
    if (startup.role != ProcessRole.worker)
        throw new Exception("vela.jobs: runJobs is for --role=worker, not " ~ roleText(startup.role));
    checkQueues(startup);
    idleBackoff = normalizeBackoff(idleBackoff);
    configureWorker(cfg, singleThread, healthPort);
    version (linux)
    {
        WorkerInit init = () {
            if (workerIndex == 0)
                startSupervisor!Jobs(store, startup, hooks, idleBackoff);
            if (healthPort == 0)
                return () => (ref Request, ResponseSink) {};
            auto app = healthApp();
            app.freeze();
            return healthFactory(app);
        };
        import vela.engine.epoll : runEpollServer;

        // sound: runEpollServer is @system epoll code; it only calls this @safe WorkerInit and the @safe fibers it spawns
        bool ok = (() @trusted => runEpollServer(cfg, init))();
        if (!ok)
            throw new Exception("vela.jobs: the worker loop did not start");
    }
    else
        throw new Exception(
            "vela.jobs: background jobs need the epoll loop (the development server runs spawn inline)");
}

/// `--role=all`. Pass the result as `onWorker0` to `serve` / `tryServe`.
/// The delegate spawns the supervisor on worker 0 and returns. It does not bind a port and does
/// not change `shutdownGraceMs`: the application passes its own `ServerConfig` to `serve`.
/// Queue concurrency is the number of fibers on worker 0, not per core. Cron runs only there.
void delegate() @safe supervisorHook(Jobs...)(JobStore store, Startup startup,
        WorkerHooks hooks = WorkerHooks.init, Duration idleBackoff = defaultIdleBackoff) @safe
{
    if (store is null)
        throw new Exception("vela.jobs: supervisorHook needs a store");
    if (startup.role != ProcessRole.all)
        throw new Exception("vela.jobs: supervisorHook is for --role=all, not " ~ roleText(startup.role));
    checkQueues(startup);
    idleBackoff = normalizeBackoff(idleBackoff);
    return () @safe { startSupervisor!Jobs(store, startup, hooks, idleBackoff); };
}

// =====================================================================
// Loop config
// =====================================================================

/// See `runJobs`. API and `all` do not call this, so their grace and listeners stay as the app set them.
private void configureWorker(ref ServerConfig cfg, bool singleThread, ushort healthPort) pure @safe
{
    if (singleThread)
        cfg.workers = 1;
    // The health port is cleartext. A cert left on `cfg` would make `runEpollServer` load TLS.
    cfg.tls = TlsConfig.init;
    // Only `--role=worker`, and only the numeric default. An application that set any other
    // `shutdownGraceMs` keeps it. API role does not call `configureWorker`. Role `all` does not
    // either: that process passes `ServerConfig` to `serve` itself.
    if (cfg.shutdownGraceMs == serverDefaultGraceMs)
        cfg.shutdownGraceMs = workerGraceMs;
    if (healthPort == 0)
        cfg.accept = false;
    else
    {
        cfg.accept = true;
        cfg.port = healthPort;
    }
}

private Duration normalizeBackoff(Duration d) pure nothrow @safe
{
    return d <= Duration.zero ? defaultIdleBackoff : d;
}

private void checkQueues(Startup startup) pure @safe
{
    if (startup.queues.length == 0)
        throw new Exception("vela.jobs: no queues configured");
    foreach (q; startup.queues)
    {
        if (q.queue.length == 0)
            throw new Exception("vela.jobs: a queue name is empty");
        if (q.concurrency < 1)
            throw new Exception("vela.jobs: queue '" ~ q.queue ~ "' needs a concurrency of at least 1");
    }
}

// =====================================================================
// Supervisor
// =====================================================================

/// One fiber per concurrency slot of each queue, one cron fiber, then `hooks.extra`.
/// Worker 0 only. Other threads return without claiming, so `--queues` is not multiplied by cores.
private void startSupervisor(Jobs...)(JobStore store, Startup startup, WorkerHooks hooks, Duration idleBackoff)
{
    if (workerIndex != 0)
        return;
    // `idle` is captured so the lambda is a delegate the fibers can store. It stays false.
    bool idle = false;
    bool delegate() @safe nothrow stop = () @safe nothrow => idle || stopping();
    foreach (q; startup.queues)
    {
        string queue = q.queue;
        int left = q.concurrency;
        while (left > 0)
        {
            left--;
            launchConsumer!Jobs(store, queue, idleBackoff, stop);
        }
    }
    spawn(() { cronLoop!Jobs(store, idleBackoff, stop); });
    if (hooks.extra !is null)
        hooks.extra();
}

private void launchConsumer(Jobs...)(JobStore store, string queue, Duration backoff,
        bool delegate() @safe nothrow stop)
{
    spawn(() { consumeLoop!Jobs(store, queue, backoff, stop); });
}

/// Claims until `stop` is true. An empty claim sleeps `backoff` (the loop does not spin).
/// A row claimed after stop is released here and is not passed to `runClaimed`.
/// `runClaimed` releases on `RequestCancelled` when a job was already in `perform`.
private void consumeLoop(Jobs...)(JobStore store, string queue, Duration backoff,
        bool delegate() @safe nothrow stop)
{
    while (!stop())
    {
        bool ran = false;
        try
            ran = consumeOnce!Jobs(store, queue, stop);
        catch (Exception)
            ran = false;
        if (stop())
            return;
        if (!ran)
            sleep(backoff);
    }
}

/// One claim. Returns true when `runClaimed` ran.
/// `stop` true before the claim claims nothing. `stop` true after the claim releases the row:
/// a store whose `claimBatch` waits (Postgres) can be stopped between the two checks.
private bool consumeOnce(Jobs...)(JobStore store, string queue, bool delegate() @safe nothrow stop)
{
    if (stop())
        return false;
    auto batch = store.claimBatch(queue, 1);
    if (batch.length == 0)
        return false;
    if (stop())
    {
        foreach (rec; batch)
            releaseClaim(store, rec.id);
        return false;
    }
    // `@Offload` runs `perform` on the pool and `runClaimed` waits for it. This loop does not
    // change `offload`. If shutdown cancels the fiber inside `offload`, the pool thread can
    // still finish that work; `RequestCancelled` has already released the row and the result
    // is discarded.
    runClaimed!Jobs(store, batch[0]);
    return true;
}

private void releaseClaim(JobStore store, long id) @safe
{
    try
        store.release(id);
    catch (Exception)
    {
    }
}

private void cronLoop(Jobs...)(JobStore store, Duration backoff, bool delegate() @safe nothrow stop)
{
    auto jobs = scheduledJobs!Jobs();
    if (jobs.length == 0)
        return;
    auto buf = new ScheduledFire[](jobs.length * 2);
    SeenFire[] seen;
    while (!stop())
    {
        try
            enqueueDue!Jobs(store, Clock.currTime(), seen, jobs, buf);
        catch (Exception)
        {
        }
        if (stop())
            return;
        sleep(backoff);
    }
}

// =====================================================================
// Cron enqueue
// =====================================================================

private struct SeenFire
{
    string jobName;
    ScheduleKind kind;
    bool haveSeen;
    SysTime seen;
}

/// Jobs in `Jobs` that carry `@Cron`, `@Every`, or both. A job may have both; each kind is its own slot.
private ScheduledJob[] scheduledJobs(Jobs...)() @safe
{
    ScheduledJob[] list;
    static foreach (J; Jobs)
    {{
        static if (jobCronExpr!J.length > 0 || jobEveryPeriod!J > Duration.zero)
        {
            ScheduledJob s;
            s.jobName = jobName!J;
            s.cronExpr = jobCronExpr!J;
            s.every = jobEveryPeriod!J;
            list ~= s;
        }
    }}
    return list;
}

/// Enqueues each due slot this process has not yet enqueued (`slotUnseen`).
/// The insert is unconditional after that: a store that dedupes in SQL (the Postgres package)
/// still receives the row. This function does not open a database connection.
private size_t enqueueDue(Jobs...)(JobStore store, SysTime now, ref SeenFire[] seen, ScheduledJob[] jobs,
        ScheduledFire[] buf) @safe
{
    if (store is null || jobs.length == 0 || buf.length == 0)
        return 0;
    size_t n = CronClock.tick(jobs, now, buf);
    if (n > buf.length)
        n = buf.length;
    size_t wrote = 0;
    foreach (i; 0 .. n)
    {
        if (seenAlready(seen, buf[i]))
            continue;
        if (!enqueueScheduled!Jobs(store, buf[i]))
            continue;
        rememberFire(seen, buf[i]);
        wrote++;
    }
    return wrote;
}

private bool seenAlready(ref SeenFire[] seen, ScheduledFire fire) @safe
{
    foreach (s; seen)
    {
        if (s.jobName == fire.jobName && s.kind == fire.kind)
            return !slotUnseen(s.haveSeen, s.seen, fire.slot);
    }
    return false;
}

private void rememberFire(ref SeenFire[] seen, ScheduledFire fire) @safe
{
    foreach (ref s; seen)
    {
        if (s.jobName == fire.jobName && s.kind == fire.kind)
        {
            s.haveSeen = true;
            s.seen = fire.slot;
            return;
        }
    }
    SeenFire s;
    s.jobName = fire.jobName;
    s.kind = fire.kind;
    s.haveSeen = true;
    s.seen = fire.slot;
    seen ~= s;
}

private bool enqueueScheduled(Jobs...)(JobStore store, ScheduledFire fire) @safe
{
    static foreach (J; Jobs)
    {{
        if (fire.jobName == jobName!J)
        {
            J job;
            store.enqueue(jobSpec(job));
            return true;
        }
    }}
    return false;
}

// =====================================================================
// Health
// =====================================================================

/// `GET /health` -> text `ok`. No other route. The worker builds this itself: jobs does not import
/// the root package, so it cannot call `vela.server.serve`.
private App healthApp() @safe
{
    auto app = new App;
    app.register(Method.GET, "/health", (Context ctx) { ctx.text("ok"); });
    return app;
}

/// Same shape as `vela.server.handlerFactory`, without WebSocket compression: health has no upgrade.
private HandlerFactory healthFactory(App app) @safe
{
    return () {
        auto ctx = new Context;
        RequestCallback cb = (ref Request req, ResponseSink sink) {
            ctx.reset(req, sink);
            scope (exit)
            {
                ctx.response.body.shrinkTo(64 << 10);
                ctx.request = Request.init;
                ctx.sink = null;
            }
            app.handle(ctx);
            sendResponse(ctx);
        };
        return cb;
    };
}

// =====================================================================
// Tests
// =====================================================================

version (unittest)
{
    import core.time : minutes;
    import std.datetime.date : DateTime;
    import std.datetime.timezone : UTC;
    import vela.jobs.backend : TestJobStore;
    import vela.jobs.cron : dueFires;
    import vela.jobs.job : Cron, Every, Job;
    import vela.web.testing : TestClient;

    int performCount;

    @Job("default")
    struct UnitWork
    {
        int n;

        void perform(ref JobContext ctx)
        {
            performCount++;
        }
    }

    @Job("alpha")
    struct UnitAlpha
    {
        int n;

        void perform(ref JobContext ctx)
        {
            performCount++;
        }
    }

    @Job("beta")
    struct UnitBeta
    {
        int n;

        void perform(ref JobContext ctx)
        {
        }
    }

    @Job("default")
    @Every(1.minutes)
    struct UnitEvery
    {
        int n;

        void perform(ref JobContext ctx)
        {
        }
    }

    @Job("reports")
    @Cron("0 0 * * *")
    struct UnitCron
    {
        int n;

        void perform(ref JobContext ctx)
        {
        }
    }

    @Job("both")
    @Cron("* * * * *")
    @Every(2.minutes)
    struct UnitBoth
    {
        int n;

        void perform(ref JobContext ctx)
        {
        }
    }

    /// False means "do not stop": `consumeOnce` claims.
    bool delegate() @safe nothrow keepGoing()
    {
        bool stop = false;
        return () @safe nothrow => stop;
    }

    bool delegate() @safe nothrow halt()
    {
        bool stop = true;
        return () @safe nothrow => stop;
    }

    SysTime utc(int y, int mo, int d, int h, int mi, int s)
    {
        return SysTime(DateTime(y, mo, d, h, mi, s), UTC());
    }

    size_t dueNow(Jobs...)(TestJobStore store, SysTime now, ref SeenFire[] seen)
    {
        auto jobs = scheduledJobs!Jobs();
        auto buf = new ScheduledFire[](jobs.length * 2);
        return enqueueDue!Jobs(store, now, seen, jobs, buf);
    }
}

unittest
{
    ServerConfig cfg;
    cfg.workers = 4;
    cfg.shutdownGraceMs = serverDefaultGraceMs;
    cfg.accept = true;
    cfg.port = 8080;
    cfg.tls.certFile = "cert.pem";
    cfg.tls.keyFile = "key.pem";
    configureWorker(cfg, true, 0);
    assert(cfg.workers == 1);
    assert(cfg.accept == false);
    assert(cfg.shutdownGraceMs == workerGraceMs);
    assert(cfg.tls.certFile.length == 0);
    assert(cfg.port == 8080);

    ServerConfig kept;
    kept.shutdownGraceMs = 2_500;
    kept.workers = 8;
    configureWorker(kept, false, 9090);
    assert(kept.workers == 8);
    assert(kept.shutdownGraceMs == 2_500);
    assert(kept.accept == true);
    assert(kept.port == 9090);
    assert(kept.tls.enabled == false);

    ServerConfig zero;
    zero.shutdownGraceMs = 0;
    configureWorker(zero, true, 0);
    assert(zero.shutdownGraceMs == 0);

    ServerConfig already;
    already.shutdownGraceMs = workerGraceMs;
    configureWorker(already, true, 0);
    assert(already.shutdownGraceMs == workerGraceMs);

    assert(normalizeBackoff(Duration.zero) == defaultIdleBackoff);
    assert(normalizeBackoff((-1).seconds) == defaultIdleBackoff);
    assert(normalizeBackoff(50.msecs) == 50.msecs);
}

unittest
{
    auto store = new TestJobStore;
    performCount = 0;
    UnitWork job;
    job.n = 4;
    store.enqueue(jobSpec(job));
    UnitBeta other;
    store.enqueue(jobSpec(other));

    assert(consumeOnce!UnitWork(store, "default", halt()) == false);
    assert(store.jobs()[0].state == JobState.available);
    assert(store.jobs()[0].attempt == 0);
    assert(performCount == 0);

    assert(consumeOnce!(UnitWork, UnitBeta)(store, "default", keepGoing()) == true);
    assert(performCount == 1);
    assert(store.jobs()[0].state == JobState.completed);
    assert(store.jobs()[0].attempt == 1);
    assert(store.jobs()[1].state == JobState.available);
    assert(consumeOnce!UnitWork(store, "default", keepGoing()) == false);

    assert(consumeOnce!UnitBeta(store, "beta", keepGoing()) == true);
    assert(store.jobs()[1].state == JobState.completed);

    UnitAlpha side;
    store.enqueue(jobSpec(side));
    assert(consumeOnce!UnitAlpha(store, "beta", keepGoing()) == false);
    JobState alphaState = JobState.discarded;
    foreach (row; store.jobs())
        if (row.queue == "alpha")
            alphaState = row.state;
    assert(alphaState == JobState.available);
}

unittest
{
    auto store = new TestJobStore;
    performCount = 0;
    UnitWork job;
    job.n = 1;
    store.enqueue(jobSpec(job));

    int checks;
    bool stopAfterClaim() @safe nothrow
    {
        checks++;
        return checks >= 2;
    }

    assert(consumeOnce!UnitWork(store, "default", &stopAfterClaim) == false);
    assert(performCount == 0);
    assert(store.jobs()[0].state == JobState.retryable);
    assert(store.jobs()[0].attempt == 0);

    assert(consumeOnce!UnitWork(store, "default", keepGoing()) == true);
    assert(performCount == 1);
    assert(store.jobs()[0].state == JobState.completed);
    assert(store.jobs()[0].attempt == 1);
}

unittest
{
    auto store = new TestJobStore;
    SeenFire[] seen;
    auto midnight = utc(2026, 1, 1, 0, 0, 10);
    assert(scheduledJobs!UnitWork().length == 0);
    assert(dueNow!UnitWork(store, midnight, seen) == 0);
    assert(store.jobs().length == 0);

    assert(dueNow!(UnitCron, UnitEvery)(store, midnight, seen) == 2);
    assert(store.jobs().length == 2);
    assert(store.jobs()[0].state == JobState.available);
    assert(store.jobs()[0].attempt == 0);
    assert(store.jobs()[0].queue == "reports" || store.jobs()[1].queue == "reports");
    assert(dueNow!(UnitCron, UnitEvery)(store, midnight, seen) == 0);
    assert(store.jobs().length == 2);

    auto nextMinute = utc(2026, 1, 1, 0, 1, 10);
    assert(dueNow!(UnitCron, UnitEvery)(store, nextMinute, seen) == 1);
    assert(store.jobs().length == 3);
    assert(store.jobs()[2].queue == "default");

    // Both kinds, and the two slots are different instants, so both are inserted.
    // TestJobStore does not run them: the row stays available until something claims it.
    auto bothAt = utc(2026, 1, 1, 0, 1, 30);
    ScheduledFire[2] fires;
    ScheduledJob probe;
    probe.jobName = jobName!UnitBoth;
    probe.cronExpr = jobCronExpr!UnitBoth;
    probe.every = jobEveryPeriod!UnitBoth;
    assert(dueFires(probe, bothAt, fires[]) == 2);
    assert(fires[0].slot.stdTime != fires[1].slot.stdTime);

    SeenFire[] bothSeen;
    assert(dueNow!UnitBoth(store, bothAt, bothSeen) == 2);
    assert(dueNow!UnitBoth(store, bothAt, bothSeen) == 0);
    int bothRows;
    foreach (row; store.jobs())
        if (row.queue == "both")
        {
            bothRows++;
            assert(row.state == JobState.available);
        }
    assert(bothRows == 2);

    assert(consumeOnce!UnitBoth(store, "both", keepGoing()) == true);
    int ranBoth;
    foreach (row; store.jobs())
        if (row.queue == "both" && row.state == JobState.completed)
            ranBoth++;
    assert(ranBoth == 1);
}

unittest
{
    auto app = healthApp();
    auto client = new TestClient(app);
    auto ok = client.get("/health");
    assert(ok.status == 200);
    assert(ok.body == "ok");
    assert(ok.contentType == "text/plain; charset=utf-8");
    auto missing = client.get("/");
    assert(missing.status == 404);
    auto post = client.post("/health", "");
    assert(post.status == 405);
}

unittest
{
    auto api = parseStartup(["prog", "--role=api"]);
    runApi(api);
    bool badApi = false;
    try
        runApi(parseStartup(["prog", "--role=worker"]));
    catch (Exception e)
    {
        badApi = true;
        assert(e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:");
    }
    assert(badApi);

    auto store = new TestJobStore;
    bool badRun = false;
    try
        runJobs!UnitWork(null, parseStartup(["prog", "--role=worker"]));
    catch (Exception e)
    {
        badRun = true;
        assert(e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:");
    }
    assert(badRun);

    badRun = false;
    try
        runJobs!UnitWork(store, parseStartup(["prog", "--role=api"]));
    catch (Exception e)
    {
        badRun = true;
        assert(e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:");
    }
    assert(badRun);

    bool badHook = false;
    try
        supervisorHook!UnitWork(store, parseStartup(["prog", "--role=worker"]));
    catch (Exception e)
    {
        badHook = true;
        assert(e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:");
    }
    assert(badHook);

    badHook = false;
    try
        supervisorHook!UnitWork(null, parseStartup(["prog", "--role=all"]));
    catch (Exception e)
    {
        badHook = e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:";
    }
    assert(badHook);

    Startup empty;
    empty.role = ProcessRole.worker;
    bool badQueues = false;
    try
        runJobs!UnitWork(store, empty);
    catch (Exception e)
    {
        badQueues = true;
        assert(e.msg.length >= 10 && e.msg[0 .. 10] == "vela.jobs:");
    }
    assert(badQueues);
}

version (linux)
unittest
{
    auto store = new TestJobStore;
    int extras;
    WorkerHooks hooks;
    hooks.extra = () { extras++; };
    auto hook = supervisorHook!UnitWork(store, parseStartup(["prog", "--role=all", "--queues=default:1"]), hooks);
    scope (exit)
        workerIndex = 0;
    workerIndex = 0;
    hook();
    assert(extras == 1);
    // Outside the loop, spawn queues nothing on Linux. The hook still invoked extra on worker 0.
    assert(store.jobs().length == 0);

    workerIndex = 2;
    hook();
    assert(extras == 1);
}
