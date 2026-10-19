# Background jobs and cron

A job is a struct: the fields are the JSON payload, `perform` is the body, and `@Job` names the queue. The same signatures
drive retries, uniqueness, cron and the OpenAPI-free compile-time checks. Enqueue from a handler; a separate process (or
the same one in development) claims and runs the work on the epoll loop.

The package is `andaime:jobs` (`import andaime.jobs;`). It does not talk to Postgres. The durable queue is
`andaime:pgjobs` (`import andaime.jobs.pg;`), covered at the end. The root `andaime` package depends on neither, so
`import andaime;` does not pull jobs in. Background jobs need the Linux epoll loop; `runJobs` refuses the blocking
development server.

```sdl
dependency "andaime:jobs" path="../andaime"
```

## Declaring a job

```d
// check
@safe:

import andaime.jobs;

@Job("mail")
struct SendMail
{
    string to;
    long userId;

    void perform(ref JobContext ctx) @safe
    {
        // ctx.id, ctx.attempt (1-based), ctx.maxAttempts, ctx.queue
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

- `@Job("mail")` is the **queue**. It is required. The stored job name is `jobName!SendMail` (the struct's fully
  qualified name), so two `SendMail` structs in different modules do not collide.
- `void perform(ref JobContext ctx) @safe`. A pool or an HTTP client stays thread-local, as `db()` does in
  [database.md](database.md). A job that needs a use case gets it from a handler instead (below).
- The payload is the JSON of the struct fields: bool, numbers, string, enum, arrays, string-keyed maps, structs,
  `Optional!T`. A pointer, class, delegate or interface is a one-line compile error (`andaime.jobs:`).
- `TestJobStore` never runs by itself. `assertEnqueued!T(substring)` checks the job name, the queue and a payload
  substring; it does not call `perform`. `drainJobs!T()` claims due rows and runs them. A row whose `run_at` is still
  in the future stays queued: `drainJobs` does not move the clock.

## Jobs that receive their dependencies: handlers

A job struct is built from its stored JSON, so it has no constructor through which to receive a use case. Split it in
two: the **payload** (the `@Job` struct, without `perform`: what is stored) and its **handler** (a class built with what it
needs), and build the handlers once per worker thread in a composition root, as `buildApp` builds the routes:

```d
// check
@safe:

import andaime.jobs;

final class WelcomeUser { void execute(long userId) { } }   // a use case

@Job("mail")
struct SendWelcome { long userId; }                          // the payload

final class SendWelcomeHandler
{
    private WelcomeUser welcome;
    this(WelcomeUser welcome) { this.welcome = welcome; }
    void perform(const SendWelcome job, ref JobContext ctx) @safe { welcome.execute(job.userId); }
}

JobHandlers buildJobs()                                      // once per worker thread
{
    auto handlers = new JobHandlers;
    handlers.handle!SendWelcome(new SendWelcomeHandler(new WelcomeUser));
    return handlers;
}

void main()
{
    auto store = new TestJobStore;
    enqueue(store, SendWelcome(7));
    store.drainJobs!SendWelcome(buildJobs());                // tests pass the handlers to drainJobs

    WorkerHooks hooks;
    hooks.handlers = () => buildJobs();                      // runJobs and supervisorHook build them on worker 0
}
```

- `hooks.handlers` runs on the thread that runs the jobs, so the use cases and the pool they hold belong to it.
- At startup the runner checks the handlers against its job list (`checkHandlers`): a job without its own `perform` and
  without a handler, a handler for a job that is not in the list, or the same payload registered twice stops the start
  with one `andaime.jobs:` line. Without `hooks.handlers`, a payload-only job in the list fails the call to `runJobs` or
  `supervisorHook` at once.
- A struct with its own `perform` keeps working without a handler (and cannot have one too); both styles mix in one list.
- Scheduled jobs (`@Every`, `@Cron`) work the same way: the scheduler enqueues the payload, the handler runs it.
- `@Offload` is for a struct's own `perform`: a handler's dependencies belong to its worker thread, so a handled payload
  with `@Offload` is a compile error. Call `offload` inside the handler for the heavy part.
- Mistakes in a handler's signature are one-line compile errors.

## Retry and discard

```d
// check
@safe:

import andaime.jobs;

@Job("mail")
struct NotifyOnce
{
    string to;

    void perform(ref JobContext ctx) @safe
    {
        throw new Exception("upstream down");   // no @Retry: discarded after this attempt
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

- No `@Retry` means `maxAttempts` is 1: the failure is discarded.
- `@Retry(maxAttempts, BackoffStrategy.exponential)`: after a failed attempt the next wait is
  `min(6 hours, 1 second * 2^^(attempt - 1))`. `attempt` is 1-based (1 s, then 2 s, then 4 s, …). No jitter, so a test
  can step the clock. The last attempt is discarded.
- `throw new JobDiscard("...")` discards immediately; `@Retry` does not apply.
- An `Error` (for example `AssertError`) is returned to `retryable` without spending the attempt, then propagates. The
  fiber is retired.

## Offload and uniqueness

```d
// check
@safe:

import andaime.jobs;

import core.time : minutes;

@Job("images")
@Offload
struct Resize
{
    long id;

    void perform(ref JobContext ctx) @safe
    {
    }
}

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
    Resize image;
    image.id = 4;
    enqueue(store, image);
    Welcome job;
    job.to = "a@b.c";
    auto first = enqueue(store, job);
    auto again = enqueue(store, job);
    assert(first.inserted);
    assert(!again.inserted && again.id == first.id);
    store.drainJobs!(Resize, Welcome)();
}
```

`@Offload` runs `perform` on the offload pool ([concurrency.md](concurrency.md#offload-the-thread-pool)). Waiting I/O
(`sleep`, `awaitFd`, a Postgres query, `httpClient()`) stays on the fiber. CPU-heavy work and blocking C go through
`@Offload` or `offload`. Outside a fiber the pool runs inline, which is what `drainJobs` does in a unit test.

If shutdown cancels the fiber while it is inside `offload`, the pool thread may still finish that work.
`RequestCancelled` has already released the row; the result is discarded.

`@UniqueJob(period)` allows one live row of the same payload per window. The key is an FNV-1a of the canonical JSON; the
slot is the start of the window that contains now. A second insert in that window returns the existing id.
`period` must be positive. A discarded row does not hold the window.

## Cron and every

```d
// check
@safe:

import andaime.jobs;

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

`@Cron` is five fields: minute, hour, day-of-month, month, day-of-week (0 and 7 are Sunday). A bad expression is a
one-line compile error. `@Every(duration)` fires on a multiple of `period` (`period` must be positive). A struct may carry
both; each kind is its own slot.

In memory, the supervisor enqueues a due slot once per process. `TestJobStore` does not tick: the example above enqueues
by hand, and `drainJobs` runs the row.

On Postgres the supervisor calls `claimCron` first. Only the process that inserts `(job_name, scheduled_slot)` into
`andaime_cron_executions` enqueues the job. See [Postgres](#postgres-andaimepgjobs) below.

### Schedules from configuration: `JobSchedule`

When a period comes from the environment, set it at startup instead of in the UDA:

```d
// check
@safe:

import andaime.jobs;
import andaime.engine.loop : ServerConfig;

import core.time : seconds;
import std.conv : to;
import std.process : environment;

@Job("maintenance")
@Every(seconds(300)) // the default; the environment may change it
struct Recurrence
{
    void perform(ref JobContext ctx) @safe {}
}

@Job("maintenance") // no UDA: scheduled only by JobSchedule
struct PurgeTokens
{
    void perform(ref JobContext ctx) @safe {}
}

void main(string[] args)
{
    JobSchedule s;
    s.every!Recurrence(seconds(environment.get("RECURRENCE_INTERVAL_SECONDS", "300").to!long));
    s.cron!PurgeTokens(environment.get("PURGE_CRON", "0 3 * * *"));
    auto startup = parseStartup(args);
    if (startup.role == ProcessRole.worker)
        runJobs!(Recurrence, PurgeTokens)(new InMemoryJobStore, startup, ServerConfig.init, true, 0, WorkerHooks(null, s));
}
```

- `every!J(period)` replaces the `@Every` period, `cron!J(expr)` replaces the `@Cron` expression (the other half stays),
  `disable!J()` removes both. A job with neither UDA can be scheduled here alone.
- `runJobs` and `supervisorHook` check the schedule before anything starts: a period that is not positive, a bad cron
  expression or a job that is not in their list throws one `andaime.jobs:` line. A type that is not a job is a compile error.
- **Every process must use the same values.** Slots are still deduplicated across processes (`claimCron`), but an `@Every`
  slot is a multiple of its period: processes with different periods enqueue different slots.

## Stores and workers

`InMemoryJobStore` is one thread. Its methods do not wait, so the fibers of that thread can share it. `runJobs` defaults
`singleThread` to true and forces `workers = 1`.

Several cores, or several processes, need `PgJobStore`: one store per worker thread. Only worker 0 of each process
consumes and runs cron. A queue's concurrency is how many jobs that thread runs at once; one fiber claims for the queue.
The limit is not multiplied by the number of cores.

With `InMemoryJobStore` and `--role=all`, set `ServerConfig.workers = 1` yourself. `serve` does not look at the store.

## Process roles

`parseStartup(args)` reads `--role=api|worker|all` (default `api`) and `--queues=name:concurrency,...` (default
`default:5`). `args[0]` is the program name. Anything else throws with a message starting `andaime.jobs:`. Strip your own
flags first if you have them.

```d
// check
@safe:

import andaime;
import andaime.jobs;

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
        applyJobGrace(cfg);   // 10 s default becomes 30 s; a value you already set is kept
        serve(&buildApp, cfg, supervisorHook!(Ping, Daily, Sweep)(store, startup));
    }
}
```

| Role | What runs |
|------|-----------|
| `--role=api` | `runApi`, then your `serve`. Handlers enqueue; nothing consumes. |
| `--role=worker` | `runJobs!(Jobs)(store, startup, cfg)`. No user routes. `healthPort` 0 binds nothing; any other port is cleartext `GET /health` only. One claim fiber per queue; up to the queue's concurrency jobs run at once. |
| `--role=all` | `applyJobGrace(cfg)`, then `serve(..., supervisorHook!(Jobs)(...))`. HTTP is yours. Worker 0 runs claim, cron, and (for Postgres) listen and the reaper. |

On an empty queue, `PgJobStore` waits for `NOTIFY` or 5 seconds. An in-memory store waits `defaultIdleBackoff` (200 ms). A
failed claim, listen, reap or cron tick is one `andaime.jobs:` line on stderr; the fiber waits and tries again.

`WorkerHooks.extra` runs at the end of worker 0's init, after those fibers have been `spawn`ed and before the loop polls.
`spawn` from `extra` is queued; do not call `sleep` or `awaitFd` inside `extra` itself. `PgJobStore` already starts
`listen` and the reaper; use `extra` for anything else.

Pass `singleThread: false` to `runJobs` only for a store that is safe across threads. `cfg.workers` is then left as given
(0 means one thread per core). Consumption still runs only on worker 0.

## Shutdown

SIGINT or SIGTERM stops new claims. A row claimed and not yet in `perform` is `release`d (`retryable`, attempt given
back). `RequestCancelled` inside `perform` (the grace period cancelled the fiber) does the same. An `Exception` is still
a failed attempt; an `Error` is a release.

When `shutdownGraceMs` is still the 10 second default, `--role=worker` (`runJobs`) and `--role=all` (`applyJobGrace`
before `serve`) raise it to 30 seconds so a running job can finish or be released. A value you already set, including 0,
is kept. `--role=api` leaves the API's grace alone.

## Postgres (`andaime:pgjobs`)

```sdl
dependency "andaime:jobs" path="../andaime"
dependency "andaime:pg" path="../andaime"
dependency "andaime:pgjobs" path="../andaime"
```

`PgJobStore` (`import andaime.jobs.pg;`) is the durable `JobStore`. One store per worker thread: it uses that thread's
`pgPool`, and must not be handed to another thread. Worker 0 is the thread that called `serve` or `runJobs`. A
thread-local helper gives every worker its own store; the one created on the main thread is worker 0's:

```d
import andaime.jobs.pg;

PgJobStore jobs()
{
    static PgJobStore store;   // thread-local, like any module state
    if (store is null)
        store = new PgJobStore("host=db.example.com dbname=app user=app");
    return store;
}
```

### Schema and transactional enqueue

`ensureSchema` creates `andaime_jobs` and `andaime_cron_executions` if they are missing. Call it on a connection that is not
already inside a transaction, before a caller opens one. `enqueue(JobSpec)`, `claimBatch`, `listen`, `reap` and
`claimCronSlot` do that on first use. `enqueue(PgConn, JobSpec)` does not. On a database from before the rename, where
`vela_jobs` exists and `andaime_jobs` does not, it logs one warning: rename the two tables before starting, or the old jobs
are not read.

```d
import andaime.db;
import core.time : seconds;

auto c = PgConn.connect("host=db.example.com dbname=app user=app", 10.seconds, 30.seconds);
scope (exit) c.shutdown();
jobs().ensureSchema(c);

pgPool("host=db.example.com dbname=app user=app").transaction((PgConn tx) {
    enqueueJob(tx, jobs(), SendMail("a@b.c", 7));
});
```

`enqueue(PgConn, JobSpec)` inserts the row and runs `pg_notify('andaime_jobs_notify', '')` inside the caller's transaction.
It does not `BEGIN` or `COMMIT`. `COMMIT` publishes both; `ROLLBACK` drops both. `enqueueJob(tx, store, job)` is that
insert with the typed payload. `store.enqueue(spec)` borrows a pooled connection and commits.

**The outbox without a connection.** `PgPool.transaction` is ambient (see [Database](database.md#one-transaction-across-repositories)):
inside it, a plain `enqueue(store, job)` on this fiber joins the transaction when the store's pool is the same one, that
is when the store and the repositories use the same conninfo on the same worker (`pgPool` is per thread and keyed by
conninfo). So a use case that writes a user and schedules its welcome e-mail needs no `PgConn`:

```d
db.transaction((PgConn _) {
    users.add(user);                        // a repository over `db`
    enqueue(store, SendWelcome(user.id));   // stored only if the transaction commits
});
```

The schema is created on a separate connection the first time (`ensureSchema` must not run inside a transaction).

To test that code without a database, write it against `JobTransaction` (in `andaime.jobs`), which both stores provide:

```d
void signUp(JobTransaction jobs, string email)
{
    enqueue(jobs, Welcome(email));              // or enqueueAt(jobs, job, runAtUs)
}

// production: the caller's Postgres transaction
pool.transaction((PgConn tx) { insertUser(tx, email); signUp(store.within(tx), email); });

// test: published on commit, dropped on rollback
auto tx = testStore.transaction();
signUp(tx, "ana@x.com");
assert(tx.pending.length == 1);
tx.commit();                                    // or tx.rollback()
testStore.assertEnqueued!Welcome("ana@x.com");
```

`TestJobTransaction.enqueue` returns id 0 (the row does not exist yet); `commit` returns the real `EnqueueResult`s, with
unique windows applied then.

### Claim, listen and the lease

A claim is one statement; the transaction commits **before** `perform`, so the row lock is not held across the work:

```sql
update andaime_jobs set state = 'running', attempt = attempt + 1, attempted_at = now()
where id in (
    select id from andaime_jobs
    where state in ('available', 'scheduled', 'retryable') and run_at <= now()
    order by priority, run_at, id
    for update skip locked
    limit $n
)
```

The supervisor starts `listen` and the reaper on worker 0 (`JobRuntime.startServices`). `listen` uses a connection that
is not from the pool, runs `LISTEN andaime_jobs_notify`, and waits on libpq's socket. A notification wakes the claim fiber;
so does a 5 second fallback (a scheduled job does not notify). Do not claim from the listen callback: leave that to the
claim fiber.

`reap` returns `running` rows whose `attempted_at` is older than the lease (default 15 minutes, `store.lease`) to
`retryable` without changing `attempt`. A job that runs longer than the lease can be claimed again and run twice.

### Retention

A finished row is not kept forever. After each `reap`, the reaper runs `purge`, which deletes in batches of 1,000:

- `completed` rows older than `store.completedRetention` (default 1 day, by `completed_at`);
- `discarded` rows older than `store.discardedRetention` (default 14 days, by their last attempt): they keep their payload
  and errors until then, for diagnosis;
- `andaime_cron_executions` slots older than `discardedRetention`.

Rows still waiting (`available`, `scheduled`, `retryable`) or `running` are never purged. Set the two durations before the
services start. Without a supervisor (your own claim loop), call `store.purge()` on a timer.

A payload that carries a secret (a one-time code, a magic link, an invitation token) should not wait for the purge:

```d
@Job("mail", dropOnSuccess: true)
struct SendLoginCode { string email; string code; void perform(ref JobContext ctx) { ... } }
```

With `dropOnSuccess`, a successful run deletes the row. A `@UniqueJob` keeps its row, with the payload replaced by `{}`, so
its window still deduplicates. A failed or discarded run keeps the payload as any job does. The memory stores do the same.
A custom `JobStore` opts in by implementing `JobPayloadDrop`; without it the row is completed normally.

### Cron across processes

The supervisor calls `claimCronSlot` before it enqueues a due `@Cron` / `@Every` slot. Only the insert that wins
enqueues. The same function is available if you enqueue a slot yourself:

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

`slotStdTime` is `SysTime.stdTime` from `cronSlot` (`@Cron`) or `slotStart` (`@Every`), not Unix microseconds.
