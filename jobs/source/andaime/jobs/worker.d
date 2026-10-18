/// Process roles for a job binary.
///
/// `--role=api`: call `runApi`, then `serve` / `tryServe` as usual. This package does not consume
/// and does not call `serve` (the root `andaime` package is what exports it). Enqueue on the store
/// the application already holds.
///
/// `--role=worker`: call `runJobs`. It runs the epoll loop with no user routes. `healthPort` 0
/// does not bind; any other port serves `GET /health` (text `ok`, no TLS). `InMemoryJobStore` is
/// one thread: leave `singleThread` at its default `true`, which forces `workers = 1`. A store
/// that is safe across threads may pass `singleThread: false` and keep `ServerConfig.workers`
/// (0 means one thread per core). Consumption, cron, and `WorkerHooks` still run only on worker 0,
/// so `--queues` is not multiplied by the core count.
///
/// `--role=all`: call `applyJobGrace` on the `ServerConfig`, then `serve` / `tryServe` with
/// `supervisorHook` as `onWorker0`. HTTP stays the application's. The hook spawns the supervisor
/// on worker 0 only. With `InMemoryJobStore` the application must set `ServerConfig.workers = 1`
/// itself: every request thread would otherwise enqueue on a store that is not safe across threads.
///
/// The development server runs `spawn` inline. Background jobs need the epoll loop.
///
/// `@Offload` is unchanged. `runClaimed` waits for the pool. If shutdown cancels the fiber while
/// it is inside `offload`, the pool thread can still finish that work; the row has been released
/// (`RequestCancelled` is not an `Exception`) and the result is discarded.
module andaime.jobs.worker;

@safe:

import core.time : Duration, msecs, seconds;
import std.datetime.systime : Clock, SysTime;
import andaime.engine.fiberio : currentFiberLocal, sleep, spawn, stopping, workerIndex;
import andaime.log : LogScope, setLogFiberSource;
import andaime.engine.loop : HandlerFactory, RequestCallback, ServerConfig, TlsConfig, WorkerInit;
import andaime.http.response : ResponseSink;
import andaime.http.types : Method, Request;
import andaime.jobs.backend : JobRecord, JobRuntime, JobState, JobStore, jobSpec, logJobFailure, runClaimed;
import andaime.jobs.cli : ProcessRole, Startup, parseStartup, roleText;
import andaime.jobs.cron : CronClock, ScheduleKind, ScheduledFire, ScheduledJob, cronError, slotUnseen;
import andaime.jobs.job : JobContext, jobCronExpr, jobError, jobEveryPeriod, jobName;
import andaime.web.application : App;
import andaime.web.context : Context;
import andaime.web.stream : sendResponse;

/// `ServerConfig.shutdownGraceMs` as defined on the struct. Compared by value.
private enum uint serverDefaultGraceMs = 10_000;

/// Grace used when a process runs jobs and the caller left the default. API role does not use this.
private enum uint workerGraceMs = 30_000;

/// How long an in-memory consumer waits after an empty claim. Also the cron fiber's poll.
/// A `JobRuntime` store waits in `waitIdle` instead (notify, or its own fallback). Not a busy loop.
enum Duration defaultIdleBackoff = 200.msecs;

/// `--role=worker` and `--role=all`. When `shutdownGraceMs` is still the `ServerConfig` default
/// (10 seconds), set it to 30 seconds so a running job can finish or be released. Any other value
/// is kept, including 0. `--role=api` must not call this.
void applyJobGrace(ref ServerConfig cfg) pure @safe
{
    if (cfg.shutdownGraceMs == serverDefaultGraceMs)
        cfg.shutdownGraceMs = workerGraceMs;
}

/// Optional work on worker 0, after the store's own services and the queue fibers have been
/// `spawn`ed and before the loop polls. A `JobRuntime` store already starts its listen fiber and
/// its reaper. `spawn` from `extra` is queued and starts when the loop begins. Do not `sleep` or
/// `awaitFd` in `extra` itself: this call is not yet inside a fiber. Null skips it.
struct WorkerHooks
{
    void delegate() @safe extra;
    /// Schedules set at startup (see `JobSchedule`). Empty: the `@Every` / `@Cron` UDAs alone.
    JobSchedule schedule;
}

/// Schedules decided when the process starts, for periods that come from configuration. Each call
/// replaces one half of a job's schedule (its `@Every` period or its `@Cron` expression); a job with
/// neither UDA can be scheduled here alone. Pass it as `WorkerHooks.schedule` to `runJobs` or
/// `supervisorHook`, which check it before anything starts: a period that is not positive, a bad
/// cron expression or a job missing from their `Jobs` list throws one `andaime.jobs:` line.
///
///     JobSchedule s;
///     s.every!Recurrence(seconds(envLong("RECURRENCE_INTERVAL_SECONDS", 300)));
///     s.cron!PurgeTokens(environment.get("PURGE_CRON", "0 3 * * *"));
///     runJobs!(Recurrence, PurgeTokens)(store, startup, cfg, true, 0, WorkerHooks(null, s));
///
/// Every process that runs the scheduler must use the same values. Slots are still deduplicated
/// across processes (`claimCron`), but an `@Every` slot is a multiple of the period: processes
/// with different periods enqueue different slots.
struct JobSchedule
{
    private ScheduleChange[] changes;

    /// Enqueue `J` on every multiple of `period`, in place of its `@Every`.
    ref JobSchedule every(J)(Duration period) return
    {
        static assert(jobError!J.length == 0, jobError!J);
        changes ~= ScheduleChange(jobName!J, ScheduleChange.What.every, period, null);
        return this;
    }

    /// Enqueue `J` on the five-field cron expression `expr`, in place of its `@Cron`.
    ref JobSchedule cron(J)(string expr) return
    {
        static assert(jobError!J.length == 0, jobError!J);
        changes ~= ScheduleChange(jobName!J, ScheduleChange.What.cron, Duration.zero, expr);
        return this;
    }

    /// Never enqueue `J` on a schedule (neither its `@Every` nor its `@Cron`).
    ref JobSchedule disable(J)() return
    {
        static assert(jobError!J.length == 0, jobError!J);
        changes ~= ScheduleChange(jobName!J, ScheduleChange.What.disable, Duration.zero, null);
        return this;
    }
}

private struct ScheduleChange
{
    enum What : ubyte { every, cron, disable }

    string jobName;
    What what;
    Duration period;
    string expr;
}

/// `--role=api`. Does not start a consumer and does not call `serve`.
/// The application's `main` keeps calling `serve` / `tryServe`. Enqueue stays on the store the
/// application holds (`enqueue!T(store, job)` from a handler). `startup.queues` is ignored:
/// this process has no consumers. This function does not change `ServerConfig.shutdownGraceMs`
/// (the API keeps the 10s default unless the application sets it).
void runApi(Startup startup) @safe
{
    if (startup.role != ProcessRole.api)
        throw new Exception("andaime.jobs: runApi is for --role=api, not " ~ roleText(startup.role));
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
        throw new Exception("andaime.jobs: runJobs needs a store");
    if (startup.role != ProcessRole.worker)
        throw new Exception("andaime.jobs: runJobs is for --role=worker, not " ~ roleText(startup.role));
    checkQueues(startup);
    cast(void) scheduledJobs!Jobs(hooks.schedule); // throws now, not on worker 0 once the loop runs
    idleBackoff = normalizeBackoff(idleBackoff);
    configureWorker(cfg, singleThread, healthPort);
    WorkerInit init = () {
        setLogFiberSource(&jobFiberLog); // andaime.log reads the running job from its fiber
        if (workerIndex == 0)
            startSupervisor!Jobs(store, startup, hooks, idleBackoff);
        if (healthPort == 0)
            return () => (ref Request, ResponseSink) {};
        auto app = healthApp();
        app.freeze();
        return healthFactory(app);
    };
    import andaime.engine.epoll : runEpollServer;

    // sound: runEpollServer is @system event loop code; it only calls this @safe WorkerInit and the @safe fibers it spawns
    bool ok = (() @trusted => runEpollServer(cfg, init))();
    if (!ok)
        throw new Exception("andaime.jobs: the worker loop did not start");
}

/// andaime.log's context in a `--role=worker` fiber: the `LogScope` the runner put in the fiber's slot while `perform`
/// runs. (`--role=all` uses the server's source, which knows both requests and jobs.)
private bool jobFiberLog(out const(char)[] id, out LogScope fields) nothrow
{
    if (auto s = cast(LogScope) currentFiberLocal())
    {
        fields = s;
        return true;
    }
    return false;
}

/// `--role=all`. Pass the result as `onWorker0` to `serve` / `tryServe`.
/// Call `applyJobGrace` on that `ServerConfig` first: this delegate cannot see it, and the
/// default 10 seconds is too short for a job. The delegate spawns the supervisor on worker 0
/// and returns. It does not bind a port. Queue concurrency is the number of jobs in flight on
/// worker 0, not per core. Cron runs only there.
void delegate() @safe supervisorHook(Jobs...)(JobStore store, Startup startup,
        WorkerHooks hooks = WorkerHooks.init, Duration idleBackoff = defaultIdleBackoff) @safe
{
    if (store is null)
        throw new Exception("andaime.jobs: supervisorHook needs a store");
    if (startup.role != ProcessRole.all)
        throw new Exception("andaime.jobs: supervisorHook is for --role=all, not " ~ roleText(startup.role));
    checkQueues(startup);
    cast(void) scheduledJobs!Jobs(hooks.schedule);
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
    // `--role=worker` only. `--role=all` calls `applyJobGrace` itself, before `serve`.
    applyJobGrace(cfg);
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
        throw new Exception("andaime.jobs: no queues configured");
    foreach (q; startup.queues)
    {
        if (q.queue.length == 0)
            throw new Exception("andaime.jobs: a queue name is empty");
        if (q.concurrency < 1)
            throw new Exception("andaime.jobs: queue '" ~ q.queue ~ "' needs a concurrency of at least 1");
    }
}

// =====================================================================
// Supervisor
// =====================================================================

/// One claim fiber per queue, then up to `limit` jobs in flight, then cron, then `hooks.extra`.
/// Worker 0 only. Other threads return without claiming, so `--queues` is not multiplied by cores.
/// A `JobRuntime` store starts its listen fiber and its reaper here, and wins or loses each cron slot.
private void startSupervisor(Jobs...)(JobStore store, Startup startup, WorkerHooks hooks, Duration idleBackoff)
{
    if (workerIndex != 0)
        return;
    bool delegate() @safe nothrow stop = () @safe nothrow => stopping();
    if (auto rt = cast(JobRuntime) store)
        rt.startServices();
    foreach (q; startup.queues)
        launchQueue!Jobs(store, q.queue, q.concurrency, idleBackoff, stop);
    auto schedule = scheduledJobs!Jobs(hooks.schedule);
    spawn(() { cronLoop!Jobs(store, idleBackoff, stop, schedule); });
    if (hooks.extra !is null)
        hooks.extra();
}

/// Jobs running for one queue. The claim fiber and the runners share it on this thread.
private final class Lane
{
    int limit;
    int running;
}

private void launchQueue(Jobs...)(JobStore store, string queue, int limit, Duration backoff,
        bool delegate() @safe nothrow stop)
{
    auto lane = new Lane;
    lane.limit = limit;
    spawn(() { dispatchLoop!Jobs(store, queue, lane, backoff, stop); });
}

/// One fiber claims for the queue. An empty claim waits (`waitIdle` on a `JobRuntime` store,
/// otherwise `backoff`) instead of querying again. While `lane.limit` jobs are in `perform`,
/// it sleeps a short slice and does not claim.
private void dispatchLoop(Jobs...)(JobStore store, string queue, Lane lane, Duration backoff,
        bool delegate() @safe nothrow stop)
{
    while (!stop())
    {
        if (lane.running >= lane.limit)
        {
            sleep(50.msecs);
            continue;
        }
        JobRecord[] batch;
        try
            batch = store.claimBatch(queue, lane.limit - lane.running);
        catch (Exception e)
        {
            logJobFailure("claim", e);
            idleWait(store, backoff);
            continue;
        }
        if (stop())
        {
            foreach (rec; batch)
                releaseClaim(store, rec.id);
            return;
        }
        if (batch.length == 0)
        {
            idleWait(store, backoff);
            continue;
        }
        foreach (rec; batch)
        {
            if (stop() || lane.running >= lane.limit)
            {
                releaseClaim(store, rec.id);
                continue;
            }
            lane.running++;
            JobRecord copy = rec;
            spawn(() {
                scope (exit)
                    lane.running--;
                try
                    runClaimed!Jobs(store, copy);
                catch (Exception e)
                    logJobFailure("job", e);
            });
        }
    }
}

private void idleWait(JobStore store, Duration backoff)
{
    if (auto rt = cast(JobRuntime) store)
        rt.waitIdle(backoff);
    else
        sleep(backoff);
}

/// One claim. Returns true when `runClaimed` ran.
/// `stop` true before the claim claims nothing. `stop` true after the claim releases the row.
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
    // `@Offload` runs `perform` on the pool and `runClaimed` waits for it. If shutdown cancels
    // the fiber inside `offload`, the pool thread can still finish that work; `RequestCancelled`
    // has already released the row and the result is discarded.
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

private void cronLoop(Jobs...)(JobStore store, Duration backoff, bool delegate() @safe nothrow stop,
        ScheduledJob[] jobs)
{
    if (jobs.length == 0)
        return;
    auto buf = new ScheduledFire[](jobs.length * 2);
    SeenFire[] seen;
    while (!stop())
    {
        try
            enqueueDue!Jobs(store, Clock.currTime(), seen, jobs, buf);
        catch (Exception e)
            logJobFailure("cron", e);
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

/// Jobs in `Jobs` that carry `@Cron`, `@Every`, or both, after the changes of `schedule`. A job may
/// have both; each kind is its own slot. Throws on a change that is invalid or names a job outside `Jobs`.
private ScheduledJob[] scheduledJobs(Jobs...)(const JobSchedule schedule = JobSchedule.init) @safe
{
    ScheduledJob[Jobs.length] all;
    static foreach (k, J; Jobs)
        all[k] = ScheduledJob(jobName!J, jobCronExpr!J, jobEveryPeriod!J);
    foreach (ch; schedule.changes)
    {
        size_t t = all.length;
        foreach (k, ref s; all)
            if (s.jobName == ch.jobName)
                t = k;
        if (t == all.length)
            throw new Exception("andaime.jobs: job '" ~ ch.jobName ~ "' has a JobSchedule entry but is not one of the jobs given to "
                ~ "runJobs or supervisorHook");
        final switch (ch.what)
        {
        case ScheduleChange.What.every:
            if (ch.period <= Duration.zero)
                throw new Exception("andaime.jobs: job '" ~ ch.jobName ~ "' has a JobSchedule period that is not positive");
            all[t].every = ch.period;
            break;
        case ScheduleChange.What.cron:
            immutable err = cronError(ch.expr);
            if (err.length)
                throw new Exception("andaime.jobs: job '" ~ ch.jobName ~ "' has an invalid JobSchedule cron '" ~ ch.expr ~ "': " ~ err);
            all[t].cronExpr = ch.expr;
            break;
        case ScheduleChange.What.disable:
            all[t].cronExpr = null;
            all[t].every = Duration.zero;
            break;
        }
    }
    ScheduledJob[] list;
    foreach (s; all)
        if (s.cronExpr.length > 0 || s.every > Duration.zero)
            list ~= s;
    return list;
}

/// Enqueues each due slot this process has not yet enqueued (`slotUnseen`).
/// A `JobRuntime` store must also win `claimCron` for that slot: the loser does not enqueue,
/// and the slot is remembered so the next tick does not insert it again.
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
        bool again;
        if (!cronWon(store, buf[i], again))
        {
            if (!again)
                rememberFire(seen, buf[i]);
            continue;
        }
        if (!enqueueScheduled!Jobs(store, buf[i]))
            continue;
        rememberFire(seen, buf[i]);
        wrote++;
    }
    return wrote;
}

/// Memory stores always win. A runtime store inserts the slot; false means another process has it
/// (`again` is false, so the caller remembers the slot). `again` is true when the insert failed
/// and the next tick should try once more.
private bool cronWon(JobStore store, ScheduledFire fire, out bool again) @safe
{
    again = false;
    auto rt = cast(JobRuntime) store;
    if (rt is null)
        return true;
    try
    {
        if (rt.claimCron(fire.jobName, fire.slot.stdTime))
            return true;
    }
    catch (Exception e)
    {
        logJobFailure("cron", e);
        again = true;
        return false;
    }
    return false;
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
/// the root package, so it cannot call `andaime.server.serve`.
private App healthApp() @safe
{
    auto app = new App;
    app.register(Method.GET, "/health", (Context ctx) { ctx.text("ok"); });
    return app;
}

/// Same shape as `andaime.server.handlerFactory`, without WebSocket compression: health has no upgrade.
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
    import andaime.jobs.backend : TestJobStore;
    import andaime.jobs.cron : dueFires;
    import andaime.jobs.job : Cron, Every, Job;
    import andaime.web.testing : TestClient;

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

    /// Cron gate: `claimCron` false must not enqueue. True enqueues.
    class GateStore : TestJobStore, JobRuntime
    {
        bool allow = true;
        int claims;

        bool claimCron(string, long)
        {
            claims++;
            return allow;
        }

        void startServices()
        {
        }

        void waitIdle(Duration)
        {
        }
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

    ServerConfig sharedGrace;
    applyJobGrace(sharedGrace);
    assert(sharedGrace.shutdownGraceMs == workerGraceMs);
    sharedGrace.shutdownGraceMs = 2_500;
    applyJobGrace(sharedGrace);
    assert(sharedGrace.shutdownGraceMs == 2_500);
}

unittest
{
    auto gate = new GateStore;
    gate.allow = false;
    SeenFire[] seen;
    assert(dueNow!UnitBoth(gate, Clock.currTime(), seen) == 0);
    assert(gate.jobs().length == 0);
    assert(gate.claims >= 1);
    immutable lost = gate.claims;

    gate.allow = true;
    seen = null;
    assert(dueNow!UnitBoth(gate, Clock.currTime(), seen) >= 1);
    assert(gate.jobs().length >= 1);
    assert(gate.claims > lost);
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
    // JobSchedule: replaces one half of a job's schedule, adds one to a job with no UDA, or removes both
    JobSchedule s;
    s.every!UnitWork(5.minutes).cron!UnitEvery("*/10 * * * *").disable!UnitCron().every!UnitBoth(3.minutes);
    auto list = scheduledJobs!(UnitWork, UnitEvery, UnitCron, UnitBoth)(s);
    assert(list.length == 3);
    assert(list[0] == ScheduledJob(jobName!UnitWork, null, 5.minutes));
    assert(list[1] == ScheduledJob(jobName!UnitEvery, "*/10 * * * *", 1.minutes), "the @Every half is kept");
    assert(list[2] == ScheduledJob(jobName!UnitBoth, "* * * * *", 3.minutes));
    assert(scheduledJobs!(UnitEvery)(JobSchedule.init) == [ScheduledJob(jobName!UnitEvery, null, 1.minutes)]);

    // the period now drives the slots: UnitWork every 5 minutes
    auto store = new TestJobStore;
    SeenFire[] seen;
    auto buf = new ScheduledFire[](2);
    JobSchedule only;
    only.every!UnitWork(5.minutes);
    auto jobs = scheduledJobs!UnitWork(only);
    assert(enqueueDue!UnitWork(store, utc(2026, 1, 1, 0, 4, 0), seen, jobs, buf) == 1);
    assert(enqueueDue!UnitWork(store, utc(2026, 1, 1, 0, 4, 59), seen, jobs, buf) == 0);
    assert(enqueueDue!UnitWork(store, utc(2026, 1, 1, 0, 5, 0), seen, jobs, buf) == 1);

    string failure(JobSchedule bad)
    {
        try
            cast(void) scheduledJobs!(UnitWork, UnitEvery)(bad);
        catch (Exception e)
            return e.msg;
        return null;
    }

    JobSchedule zero;
    zero.every!UnitWork(Duration.zero);
    assert(failure(zero) == "andaime.jobs: job '" ~ jobName!UnitWork ~ "' has a JobSchedule period that is not positive");
    JobSchedule badCron;
    badCron.cron!UnitEvery("61 * * * *");
    assert(failure(badCron) == "andaime.jobs: job '" ~ jobName!UnitEvery ~ "' has an invalid JobSchedule cron '61 * * * *': "
        ~ cronError("61 * * * *"));
    JobSchedule stranger;
    stranger.every!UnitCron(1.minutes);
    assert(failure(stranger) == "andaime.jobs: job '" ~ jobName!UnitCron ~ "' has a JobSchedule entry but is not one of the "
        ~ "jobs given to runJobs or supervisorHook");

    // runJobs checks it before it starts anything
    bool threw;
    try
        runJobs!UnitWork(new TestJobStore, parseStartup(["prog", "--role=worker"]), ServerConfig.init, true, 0,
            WorkerHooks(null, zero));
    catch (Exception e)
        threw = e.msg == failure(zero);
    assert(threw);
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
        assert(e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:");
    }
    assert(badApi);

    auto store = new TestJobStore;
    bool badRun = false;
    try
        runJobs!UnitWork(null, parseStartup(["prog", "--role=worker"]));
    catch (Exception e)
    {
        badRun = true;
        assert(e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:");
    }
    assert(badRun);

    badRun = false;
    try
        runJobs!UnitWork(store, parseStartup(["prog", "--role=api"]));
    catch (Exception e)
    {
        badRun = true;
        assert(e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:");
    }
    assert(badRun);

    bool badHook = false;
    try
        supervisorHook!UnitWork(store, parseStartup(["prog", "--role=worker"]));
    catch (Exception e)
    {
        badHook = true;
        assert(e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:");
    }
    assert(badHook);

    badHook = false;
    try
        supervisorHook!UnitWork(null, parseStartup(["prog", "--role=all"]));
    catch (Exception e)
    {
        badHook = e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:";
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
        assert(e.msg.length >= 13 && e.msg[0 .. 13] == "andaime.jobs:");
    }
    assert(badQueues);
}

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
