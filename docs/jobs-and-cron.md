# Background jobs and cron

`vela:jobs` (`import vela.jobs;`) is the job package. The struct is the payload, `perform` is the body, and `@Job` names the queue. It does not talk to Postgres. The Postgres queue is a separate package, `vela-pg-jobs` (`import vela.jobs.pg;`), at the end of this page. The root `vela` package depends on neither, so `import vela;` does not bring jobs in.

`dub.sdl`:

```sdl
dependency "vela:jobs" path="../dapi"
```

Background jobs need the epoll loop. `runJobs` refuses the non-Linux development server, which runs `spawn` inline.

## Declaring a job

```d
// check
@safe:

import vela.jobs;

@Job("mail")
struct SendMail
{
    string to;
    long userId;

    void perform(ref JobContext ctx) @safe
    {
    }
}

void main()
{
    auto store = new TestJobStore;
    SendMail mail;
    mail.to = "a@b.c";
    mail.userId = 7;
    enqueue(store, mail);                 // priority defaults to 100; a lower number runs first
    store.assertEnqueued!SendMail("a@b.c");
    store.drainJobs!SendMail();           // TestJobStore runs nothing until this call
}
```

- `@Job("mail")` is the queue. It is required. The stored job name is `jobName!SendMail`, the struct's fully qualified name, so two `SendMail` structs in different modules do not collide.
- `void perform(ref JobContext ctx) @safe`. `ctx` carries `id`, `attempt` (1-based), `maxAttempts` and `queue`. There is no dependency injection: a pool or an HTTP client stays thread-local, as `db()` does in [database.md](database.md).
- The payload is the JSON object of the struct fields (bool, numbers, string, enum, arrays, string-keyed maps, structs, `Optional!T`). A pointer, class, delegate or interface is a one-line compile error.
- `TestJobStore` does not run by itself. `assertEnqueued!T(substring)` checks the job name, the queue from `@Job`, and that the JSON contains `substring`. It does not call `perform`. `drainJobs!T()` claims due rows and runs them. A row whose `run_at` is still in the future stays queued: `drainJobs` does not move the clock.

## Retry

```d
// check
@safe:

import vela.jobs;

@Job("mail")
struct NotifyOnce
{
    string to;

    void perform(ref JobContext ctx) @safe
    {
        throw new Exception("upstream down");   // no @Retry: this attempt is discarded
    }
}

@Job("mail")
@Retry(5, BackoffStrategy.exponential)
struct SendMail
{
    long userId;

    void perform(ref JobContext ctx) @safe
    {
        if (userId == 0)
            throw new JobDiscard("no such user");
        throw new Exception("upstream down");
    }
}

void main()
{
    auto store = new TestJobStore;
    NotifyOnce once;
    once.to = "a@b.c";
    enqueue(store, once);
    SendMail mail;
    mail.userId = 0;
    enqueue(store, mail);
    store.drainJobs!(NotifyOnce, SendMail)();
}
```

No `@Retry` means `maxAttempts` is 1. The failure is discarded, and the delay below is unused.

`@Retry(maxAttempts, BackoffStrategy.exponential)` counts the first run. After a failed attempt the next wait is `min(6 hours, 1 second * 2^^(attempt - 1))`. `attempt` is 1-based, so the first failure waits 1 second, the next 2, then 4, up to 6 hours. The delay has no jitter, so a test can step the clock. The last attempt is discarded.

`throw new JobDiscard("...")` discards the row immediately. `@Retry` does not apply.

An `Error` (an `AssertError`, for example) is released back to `retryable` without spending the attempt, and then it propagates. The runner does not catch it. The fiber is retired.

## `@Offload`

```d
// check
@safe:

import vela.jobs;

@Job("images")
@Offload
struct Resize
{
    long id;

    void perform(ref JobContext ctx) @safe
    {
    }
}

void main()
{
    auto store = new TestJobStore;
    Resize image;
    image.id = 4;
    enqueue(store, image);
    store.drainJobs!Resize();
}
```

`@Offload` runs `perform` on the offload pool ([concurrency.md](concurrency.md#offload-the-thread-pool)). Waiting I/O stays on the fiber: `sleep`, `awaitFd`, a `vela-pg` query, `httpClient()`. CPU-heavy work and a blocking C library go through `@Offload` or `offload`. Outside a fiber the pool runs the work inline, which is what `drainJobs` does in a unit test.

If shutdown cancels the fiber while it is inside `offload`, the pool thread may still finish that work. `RequestCancelled` has already released the row, and the result is discarded.

## One payload per window

```d
// check
@safe:

import vela.jobs;

import core.time : minutes;

@Job("mail")
@UniqueJob(15.minutes)
struct Welcome
{
    string to;

    void perform(ref JobContext ctx) @safe
    {
    }
}

void main()
{
    auto store = new TestJobStore;
    Welcome job;
    job.to = "a@b.c";
    auto first = enqueue(store, job);
    auto again = enqueue(store, job);
    assert(first.inserted);
    assert(!again.inserted && again.id == first.id);
    store.assertEnqueued!Welcome("a@b.c");
}
```

`@UniqueJob(period)` allows one live row of the same payload per window. The key is an FNV-1a of the canonical JSON. The slot is the start of the window that contains now. A second insert in that window returns the existing row. A discarded row does not hold the window. `period` must be positive.

## Cron

```d
// check
@safe:

import vela.jobs;

import core.time : minutes;

@Job("reports")
@Cron("15 6 * * *")
struct Daily
{
    string report;

    void perform(ref JobContext ctx) @safe
    {
    }
}

@Job("cleanup")
@Every(15.minutes)
struct Sweep
{
    void perform(ref JobContext ctx) @safe
    {
    }
}

void main()
{
    auto store = new TestJobStore;
    Daily daily;
    daily.report = "signups";
    enqueue(store, daily);
    store.assertEnqueued!Daily("signups");
    store.drainJobs!(Daily, Sweep)();
}
```

`@Cron` takes five fields: minute, hour, day-of-month, month, day-of-week. A bad expression is a one-line compile error. `@Every(duration)` fires on a multiple of `period` (`period` must be positive). A struct may carry both; each kind is its own slot.

In memory, the supervisor enqueues a due slot once per process. It remembers the slot it already wrote. `TestJobStore` does not tick: the block above enqueues by hand, and `drainJobs` is what runs the row.

On Postgres, `claimCronSlot(jobName, slotStdTime)` inserts `(job_name, scheduled_slot)` into `vela_cron_executions`. The primary key is that pair, and the insert is `INSERT ... ON CONFLICT DO NOTHING`. It returns true only for the insert that won. Enqueue only then. `slotStdTime` is `SysTime.stdTime` from `cronSlot` (`@Cron`) or `slotStart` (`@Every`). The in-memory supervisor does not write that table. Two processes that both run it will each enqueue; the insert above is the gate across processes. See the Postgres section.

## One thread, or several

`InMemoryJobStore` is one thread. Its methods do not wait, so the fibers of that thread can share it. `runJobs` defaults `singleThread` to true and forces `workers = 1`.

Several cores, or several processes, need `PgJobStore` (below): one store per worker thread. Only worker 0 of each process consumes and runs cron. A queue limit is the number of fibers on that thread. It is not multiplied by the number of cores.

With `InMemoryJobStore` and `--role=all`, the application sets `ServerConfig.workers = 1` itself. `serve` does not look at the store.

## Process roles

`parseStartup(args)` reads `--role=api|worker|all` (default `api`) and `--queues=name:concurrency,...` (default `default:5`). `args[0]` is the program name. Anything else throws, and the message starts with `vela.jobs:`. An application with its own flags strips them first.

```d
// check
@safe:

import vela;
import vela.jobs;

import core.time : minutes;

@Job("default")
struct Ping
{
    int n;

    void perform(ref JobContext ctx) @safe
    {
    }
}

@Job("reports")
@Cron("15 6 * * *")
struct Daily
{
    void perform(ref JobContext ctx) @safe
    {
    }
}

@Job("cleanup")
@Every(15.minutes)
struct Sweep
{
    void perform(ref JobContext ctx) @safe
    {
    }
}

string home() => "ok";

App buildApp()
{
    auto app = new App;
    app.get!("/", home);
    return app;
}

void main(string[] args)
{
    auto startup = parseStartup(args);
    auto store = new InMemoryJobStore;
    ServerConfig cfg;
    cfg.workers = 1;   // InMemoryJobStore is one thread; --role=all does not force this
    if (startup.role == ProcessRole.api)
    {
        runApi(startup);                   // enqueue only; this process has no consumers
        serve(&buildApp, cfg);
    }
    else if (startup.role == ProcessRole.worker)
    {
        // healthPort 0 binds nothing. A non-zero port is cleartext GET /health ("ok") and no other route.
        runJobs!(Ping, Daily, Sweep)(store, startup, cfg, true, 0);
    }
    else if (startup.role == ProcessRole.all)
    {
        serve(&buildApp, cfg, supervisorHook!(Ping, Daily, Sweep)(store, startup));
    }
}
```

- **`--role=api`.** `runApi`, then the application's own `serve`. Handlers enqueue on the store the application holds. Nothing consumes.
- **`--role=worker`.** `runJobs!(Jobs)(store, startup, cfg)`. No user routes. `healthPort` 0 binds nothing (`accept = false`). Any other port serves cleartext `GET /health` and nothing else: the body is `ok`, and TLS is cleared. `shutdownGraceMs` becomes 30 seconds only when it is still the `ServerConfig` default of 10 seconds. A value the application already set is kept.
- **`--role=all`.** `serve(build, cfg, supervisorHook!(Jobs)(store, startup))`. HTTP stays the application's. The hook runs on worker 0 only: the consumers, the cron fiber, then `WorkerHooks.extra`. With `InMemoryJobStore` the application sets `workers = 1`. Queue limits are the fibers on worker 0, not per core. This role does not change `shutdownGraceMs`; the `ServerConfig` passed to `serve` is the one that applies (the default stays 10 seconds).

`WorkerHooks.extra` runs at the end of worker 0's init, after those fibers have been `spawn`ed and before the loop polls. It is not yet inside a fiber. `spawn` from `extra` is queued and starts when the loop begins. Do not call `sleep` or `awaitFd` directly inside `extra`: that would block the thread. The Postgres section is where `extra` starts `listen` and the reaper.

Pass `singleThread: false` to `runJobs` only for a store that is safe across threads. `cfg.workers` is then left as given (0 means one thread per core). Consumption still runs only on worker 0.

## Shutdown

SIGINT or SIGTERM makes the consumers stop calling `claimBatch`. A row already claimed and not yet passed to `perform` is `release`d: `retryable` again, and the attempt just added is given back. `RequestCancelled` inside `perform` (the grace period cancelled the fiber) releases the same way. An `Exception` is still a failed attempt; an `Error` is still a release.

The `--role=worker` grace is 30 seconds when `shutdownGraceMs` was left at 10 seconds, so a running job can finish or be released. `--role=api` and `--role=all` keep the value on the `ServerConfig` the application passes to `serve`.

`@Offload` is the case from above: a pool thread can finish work whose row was already released.

## Postgres (`vela-pg-jobs`)

```sdl
dependency "vela:jobs" path="../dapi"
dependency "vela-pg" path="../dapi/drivers/pg"
dependency "vela-pg-jobs" path="../dapi/drivers/pgjobs"
```

The module is `vela.jobs.pg`. `PgJobStore` is the `JobStore`. One store per worker thread: it uses that thread's `pgPool`, and a store must not be handed to another thread. Worker 0 is the thread that called `serve` or `runJobs`. A thread-local function gives every worker its own store, and the store created on the main thread is worker 0's:

```d
import vela.jobs.pg;

PgJobStore jobs()
{
    static PgJobStore store;   // thread-local, like any module state
    if (store is null)
        store = new PgJobStore("host=db.example.com dbname=app user=app");
    return store;
}
```

`ensureSchema` creates `vela_jobs` and `vela_cron_executions` if they are missing. Call it on a connection that is not already inside a transaction, before a caller opens one. `enqueue(JobSpec)`, `claimBatch`, `listen`, `reap` and `claimCronSlot` do that on first use. `enqueue(PgConn, JobSpec)` does not.

```d
import vela.db;
import core.time : seconds;

auto c = PgConn.connect("host=db.example.com dbname=app user=app", 10.seconds, 30.seconds);
scope (exit) c.shutdown();
jobs().ensureSchema(c);

pgPool("host=db.example.com dbname=app user=app").transaction((PgConn tx) {
    enqueueJob(tx, jobs(), SendMail("a@b.c", 7));   // string to; long userId
});
```

`enqueue(PgConn, JobSpec)` inserts the row and calls `pg_notify('vela_jobs_notify', '')` inside the caller's transaction. It does not `BEGIN` or `COMMIT`. `COMMIT` publishes both; `ROLLBACK` drops both. `enqueueJob(tx, store, job)` is that insert with the typed payload (`jobSpec`). `store.enqueue(spec)` borrows a pooled connection and commits.

A claim is one statement, and the transaction commits before `perform`. In outline (the real statement also restricts the queue; `""` means every queue):

```sql
update vela_jobs set state = 'running', attempt = attempt + 1, attempted_at = now()
where id in (
    select id from vela_jobs
    where state in ('available', 'scheduled', 'retryable') and run_at <= now()
    order by priority, run_at, id
    for update skip locked
    limit $n
)
```

The row lock is not held while `perform` runs.

`listen` uses a connection that is not from the pool. It `LISTEN`s on `vela_jobs_notify` and waits on libpq's socket. The callback runs when a notification arrives and every 5 seconds, because a scheduled job does not notify. `listen` returns when that fiber is cancelled or the worker is stopping, and closes the connection on the way out. The queue fibers already call `claimBatch` on their idle sleep, so the callback does not have to claim. A callback that claims and does not run the row leaves it `running` until `reap`.

`reap` returns `running` rows whose `attempted_at` is older than the lease (default 15 minutes, `store.lease`) to `retryable`. It does not change `attempt`. Call it on a timer. A job that runs longer than the lease can be claimed again and run twice.

On worker 0, `hooks.extra` spawns both. The `sleep` and the wait inside `listen` run on those fibers. `extra` itself must not call `sleep` or `awaitFd`:

```d
import vela;
import vela.jobs;

WorkerHooks hooks;
hooks.extra = () {
    auto store = jobs();
    spawn(() { store.listen(() {}); });
    spawn(() {
        while (!stopping())
        {
            sleep(store.lease);
            if (!stopping())
                store.reap();
        }
    });
};
```

Pass `hooks` to `runJobs` or `supervisorHook`. For `runJobs` with several cores, pass `singleThread: false` so `cfg.workers` is kept. Only worker 0 runs the consumers, cron, `listen` and `reap`.

A cron tick that should fire once across processes asks `claimCronSlot` before it enqueues. `cronSlot` and `slotStart` produce the `SysTime`; the argument is `stdTime`:

```d
import core.time : minutes;
import std.datetime.systime : Clock, SysTime;

CronExpr expr;
SysTime slot;
if (parseCron("15 6 * * *", expr).length == 0
    && cronSlot(expr, Clock.currTime(), slot)
    && jobs().claimCronSlot(jobName!Daily, slot.stdTime))
    enqueue(jobs(), Daily());

SysTime every = slotStart(Clock.currTime(), 15.minutes);
if (jobs().claimCronSlot(jobName!Sweep, every.stdTime))
    enqueue(jobs(), Sweep());
```
