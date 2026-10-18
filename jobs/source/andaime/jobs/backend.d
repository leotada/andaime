/// In-memory job queue and the runner that calls `perform`.
///
/// `JobStore` is the contract a Postgres store implements as well: `enqueue`, `claimBatch`,
/// `complete`, `fail`, `discard`, `release`. Records are runtime rows (JSON payload, state, attempt),
/// not the D struct. `enqueue` / `enqueueAt` encode a job; `runClaimed` decodes it and calls `perform`.
///
/// Time is microseconds since the Unix epoch. `InMemoryJobStore` is one thread: its methods never wait,
/// so fibers of that thread can share it. Another thread needs a different store.
module andaime.jobs.backend 2025;

@safe:

import core.time : Duration, usecs;
import andaime.engine.fiberio : currentFiberLocal, setCurrentFiberLocal;
import andaime.engine.offload : offload;
import andaime.log : LogScope, setLogSyncScope;
import andaime.jobs.job;
import andaime.web.numtext : itoa;

// =====================================================================
// Records
// =====================================================================

/// Row state. The names are the stored spellings (`available`, `scheduled`, ...).
enum JobState
{
    available,
    scheduled,
    running,
    completed,
    retryable,
    discarded,
}

/// Stored spelling of `state`, for logs and a later SQL column.
string jobStateText(JobState state) pure nothrow @nogc @safe
{
    final switch (state)
    {
        case JobState.available: return "available";
        case JobState.scheduled: return "scheduled";
        case JobState.running: return "running";
        case JobState.completed: return "completed";
        case JobState.retryable: return "retryable";
        case JobState.discarded: return "discarded";
    }
}

/// One queued job. `runAtUs` and `uniqueSlot` are microseconds since the Unix epoch.
/// `attempt` is 0 until the first `claimBatch`, then the 1-based number of the run in progress
/// (or the last run, once the job has left `running`).
struct JobRecord
{
    long id;
    string queue;
    string name;
    string payload;
    JobState state;
    int attempt;
    int maxAttempts = 1;
    int priority = 100;
    long runAtUs;
    string uniqueKey;
    long uniqueSlot;
    string lastError;
}

/// What `enqueue` stores. `hasRunAt` false means "due now".
/// A non-empty `uniqueKey` deduplicates against a live row with the same name, key and slot.
/// Leave the key empty and set `uniquePeriod` to have the memory store fill `uniqueKey` (FNV-1a of the
/// JSON) and `uniqueSlot` (the start of the window that contains now).
struct JobSpec
{
    string queue;
    string name;
    string payload;
    int maxAttempts = 1;
    int priority = 100;
    bool hasRunAt;
    long runAtUs;
    Duration uniquePeriod;
    string uniqueKey;
    long uniqueSlot;
}

/// `inserted` is false when an existing row already holds this unique window. `id` is that row.
struct EnqueueResult
{
    long id;
    bool inserted;
}

/// Thrown from `perform` to drop the job. `@Retry` does not apply: the runner discards it.
class JobDiscard : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg.length ? msg : "andaime.jobs: job discarded", file, line);
    }
}

/// A store call that cannot be done (missing id, wrong state, empty queue).
class JobStoreError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

// =====================================================================
// JobStore
// =====================================================================

/// Queue backend. `claimBatch` marks rows `running` and returns. `perform` runs after that, outside the store.
/// `fail` keeps the attempt and schedules a retry. `release` gives the attempt back.
interface JobStore
{
    /// Inserts a row. `runAt` in the future is `scheduled`; otherwise `available`.
    /// A non-empty unique key that already exists on a non-discarded row of the same job and slot
    /// inserts nothing and returns that row.
    EnqueueResult enqueue(JobSpec spec);

    /// Up to `limit` due rows in `queue` (`""` is every queue), marked `running`.
    /// Due means `available`, `scheduled` or `retryable` with `runAtUs <= now`.
    /// Order is priority ascending, then `runAtUs` ascending, then id ascending.
    /// Each claimed row's `attempt` increases by one.
    JobRecord[] claimBatch(string queue, int limit);

    /// `running` -> `completed`.
    void complete(long id);

    /// `running` -> `retryable`, `runAt = now + delay`. The attempt counted at claim stays spent.
    void fail(long id, Duration delay, string reason);

    /// `running` -> `discarded`. The attempt stays spent. No further run.
    void discard(long id, string reason);

    /// `running` -> `retryable`, and the attempt `claimBatch` added is given back.
    /// `runAtUs` stays as it was, so a job that was due is due again under the same attempt number.
    /// Shutdown and a poisoned fiber use this. The run is not a failed attempt.
    void release(long id);
}

/// What a durable store adds to the in-memory queue: one cron slot across processes, a wake
/// instead of a poll, and the fibers that listen and reap. `InMemoryJobStore` does not implement
/// this. The supervisor checks with `cast(JobRuntime)`.
interface JobRuntime
{
    /// True when this process may enqueue that cron slot. False when another process already inserted it.
    bool claimCron(string jobName, long slotStdTime);

    /// Starts the store's own fibers (listen, reaper). Called once on worker 0, during init.
    /// `spawn` from here is queued until the loop polls. Do not `sleep` or `awaitFd` in this call.
    void startServices();

    /// After an empty claim: return when a job may be waiting, or when `maxWait` has passed.
    void waitIdle(Duration maxWait);
}

/// One line through `andaime.log` at the `error` level: `andaime.jobs: <where>: <message>` in the `text` format,
/// `msg="job failure"` with `where` and `error` in `kv`/`json`. The consumer and the cron fiber log and keep running.
void logJobFailure(string where, Exception e) nothrow
{
    import andaime.log : LogLevel, logEnabled, logAndaime;

    if (!logEnabled(LogLevel.error))
        return;
    logAndaime(LogLevel.error, "andaime.jobs: " ~ where ~ ": " ~ e.msg, "job failure", "where", where, "error", e.msg);
}

// =====================================================================
// FNV-1a and the unique window
// =====================================================================

/// FNV-1a 64-bit of the JSON bytes. No `std.digest`: the mix is twenty lines and stays `@nogc`.
ulong fnv1a(scope const(char)[] bytes) pure nothrow @nogc @safe
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (char c; bytes)
        h = (h ^ c) * 0x100000001b3UL;
    return h;
}

/// 16 lowercase hex digits of `fnv1a`. A zero hash is `"0000000000000000"`, which is still a key.
string fnv1aHex(scope const(char)[] bytes) pure @safe
{
    ulong h = fnv1a(bytes);
    char[16] buf;
    static immutable string hex = "0123456789abcdef";
    foreach_reverse (i; 0 .. 16)
    {
        buf[i] = hex[cast(size_t)(h & 0xf)];
        h >>= 4;
    }
    return buf[].idup;
}

/// Start of the window that contains `nowUs`. Both are microseconds since the Unix epoch.
/// `period` below 1 microsecond is an error: the slot would collapse onto every instant.
long uniqueSlot(long nowUs, Duration period) pure @safe
{
    immutable long periodUs = period.total!"usecs";
    if (periodUs <= 0)
        throw new JobStoreError("andaime.jobs: unique period must be at least 1 microsecond");
    if (nowUs >= 0)
        return (nowUs / periodUs) * periodUs;
    // Integer division truncates toward zero. A negative clock still needs the floor.
    long q = nowUs / periodUs;
    if (q * periodUs != nowUs)
        q--;
    return q * periodUs;
}

/// Fills `uniqueKey` and `uniqueSlot` from the payload and `nowUs` when the caller set a period and no key.
/// A key that is already set is left alone, so a store with its own clock can fill the spec and then enqueue.
void assignUnique(ref JobSpec spec, long nowUs) @safe
{
    if (spec.uniquePeriod <= Duration.zero || spec.uniqueKey.length != 0)
        return;
    spec.uniqueKey = fnv1aHex(spec.payload);
    spec.uniqueSlot = uniqueSlot(nowUs, spec.uniquePeriod);
}

/// `min(6 hours, 1 second * 2^^(attempt - 1))`. `attempt` is 1-based. No jitter, so a test can step the clock.
Duration backoffDelay(BackoffStrategy strategy, int attempt) pure nothrow @safe
{
    final switch (strategy)
    {
        case BackoffStrategy.exponential:
            return usecs(exponentialBackoffUs(attempt));
    }
}

private long exponentialBackoffUs(int attempt) pure nothrow @nogc @safe
{
    if (attempt < 1)
        attempt = 1;
    immutable int exp = attempt - 1;
    enum long capUs = 6L * 60 * 60 * 1_000_000;
    if (exp >= 15)
        return capUs;
    return (1L << exp) * 1_000_000L;
}

// =====================================================================
// Typed enqueue
// =====================================================================

/// The spec `enqueue` stores for `job`, before the store fills a missing unique key.
/// A transactional insert (Postgres, on the caller's connection) builds this and writes the row itself.
JobSpec jobSpec(T)(auto ref const T job, int priority = 100, bool hasRunAt = false, long runAtUs = 0)
{
    JobSpec spec;
    spec.queue = jobQueue!T;
    spec.name = jobName!T;
    spec.payload = JobSet!T.encode(job);
    spec.maxAttempts = jobMaxAttempts!T;
    spec.priority = priority;
    spec.hasRunAt = hasRunAt;
    spec.runAtUs = runAtUs;
    spec.uniquePeriod = jobUniquePeriod!T;
    return spec;
}

/// Encodes `job` and enqueues it, due now, at `priority` (default 100; lower runs first).
EnqueueResult enqueue(T)(JobStore store, auto ref const T job, int priority = 100)
{
    return store.enqueue(jobSpec(job, priority));
}

/// Same as `enqueue`, due at `runAtUs` (microseconds since the Unix epoch). Later than now is `scheduled`.
EnqueueResult enqueueAt(T)(JobStore store, auto ref const T job, long runAtUs, int priority = 100)
{
    return store.enqueue(jobSpec(job, priority, true, runAtUs));
}

/// Enqueues as part of a unit of work: the jobs exist if and only if it commits. On Postgres they are rows of the caller's
/// transaction (`PgJobStore.within(tx)`); in tests `TestJobStore.transaction()` keeps them until `commit`. Code that
/// schedules jobs "after commit" takes this interface and is tested without a database.
interface JobTransaction
{
    EnqueueResult enqueue(JobSpec spec);
}

/// Encodes `job` and enqueues it in `tx`, due now.
EnqueueResult enqueue(T)(JobTransaction tx, auto ref const T job, int priority = 100)
{
    return tx.enqueue(jobSpec(job, priority));
}

/// Same, due at `runAtUs` (microseconds since the Unix epoch).
EnqueueResult enqueueAt(T)(JobTransaction tx, auto ref const T job, long runAtUs, int priority = 100)
{
    return tx.enqueue(jobSpec(job, priority, true, runAtUs));
}

// =====================================================================
// InMemoryJobStore
// =====================================================================

/// Single-threaded queue. Methods do not wait, so fibers on this thread run them one at a time.
/// `now` null uses the wall clock. Tests pass a clock they can step; nothing here sleeps.
class InMemoryJobStore : JobStore
{
    private JobRecord[] rows;
    private long nextId;
    private long delegate() @safe nothrow clock;

    this(long delegate() @safe nothrow now = null) @safe
    {
        clock = now;
    }

    /// A copy of the rows. The copy is the caller's: later enqueues do not move it.
    JobRecord[] jobs() @safe
    {
        return rows.dup;
    }

    override EnqueueResult enqueue(JobSpec spec) @safe
    {
        if (spec.queue.length == 0)
            throw new JobStoreError("andaime.jobs: enqueue needs a queue");
        if (spec.name.length == 0)
            throw new JobStoreError("andaime.jobs: enqueue needs a job name");
        if (spec.maxAttempts < 1)
            throw new JobStoreError("andaime.jobs: maxAttempts must be >= 1");

        immutable long now = tick();
        assignUnique(spec, now);
        if (spec.uniqueKey.length != 0)
        {
            foreach (ref r; rows)
            {
                if (r.name == spec.name && r.uniqueKey == spec.uniqueKey && r.uniqueSlot == spec.uniqueSlot
                    && r.state != JobState.discarded)
                    return EnqueueResult(r.id, false);
            }
        }

        JobRecord rec;
        rec.id = ++nextId;
        rec.queue = spec.queue;
        rec.name = spec.name;
        rec.payload = spec.payload;
        rec.maxAttempts = spec.maxAttempts;
        rec.priority = spec.priority;
        rec.runAtUs = spec.hasRunAt ? spec.runAtUs : now;
        rec.state = rec.runAtUs > now ? JobState.scheduled : JobState.available;
        rec.uniqueKey = spec.uniqueKey;
        rec.uniqueSlot = spec.uniqueSlot;
        rows ~= rec;
        return EnqueueResult(rec.id, true);
    }

    override JobRecord[] claimBatch(string queue, int limit) @safe
    {
        if (limit <= 0)
            return null;
        immutable long now = tick();
        JobRecord[] claimed;
        int n = 0;
        while (n < limit)
        {
            bool any = false;
            size_t best;
            foreach (i, ref r; rows)
            {
                if (!canClaim(r, queue, now))
                    continue;
                if (!any || before(r, rows[best]))
                {
                    best = i;
                    any = true;
                }
            }
            if (!any)
                break;
            rows[best].state = JobState.running;
            rows[best].attempt++;
            claimed ~= rows[best];
            n++;
        }
        return claimed;
    }

    override void complete(long id) @safe
    {
        immutable i = mustRunning(id);
        rows[i].state = JobState.completed;
        rows[i].lastError = null;
    }

    override void fail(long id, Duration delay, string reason) @safe
    {
        immutable i = mustRunning(id);
        long waitUs = delay.total!"usecs";
        if (waitUs < 0)
            waitUs = 0;
        rows[i].state = JobState.retryable;
        rows[i].runAtUs = tick() + waitUs;
        rows[i].lastError = reason;
    }

    override void discard(long id, string reason) @safe
    {
        immutable i = mustRunning(id);
        rows[i].state = JobState.discarded;
        rows[i].lastError = reason;
    }

    override void release(long id) @safe
    {
        immutable i = mustRunning(id);
        if (rows[i].attempt > 0)
            rows[i].attempt--;
        rows[i].state = JobState.retryable;
    }

    private long tick() @safe nothrow
    {
        return clock is null ? unixNowUs() : clock();
    }

    private size_t mustRunning(long id) @safe
    {
        foreach (i, ref r; rows)
        {
            if (r.id != id)
                continue;
            if (r.state != JobState.running)
                throw new JobStoreError("andaime.jobs: job " ~ itoa(id) ~ " is " ~ jobStateText(r.state)
                    ~ "; expected running");
            return i;
        }
        throw new JobStoreError("andaime.jobs: no job " ~ itoa(id));
    }
}

private bool canClaim(ref const JobRecord r, string queue, long now) pure nothrow @nogc @safe
{
    if (queue.length != 0 && r.queue != queue)
        return false;
    if (r.runAtUs > now)
        return false;
    return r.state == JobState.available || r.state == JobState.scheduled || r.state == JobState.retryable;
}

/// True when `a` should run before `b`: lower priority, then earlier `runAt`, then lower id.
private bool before(ref const JobRecord a, ref const JobRecord b) pure nothrow @nogc @safe
{
    if (a.priority != b.priority)
        return a.priority < b.priority;
    if (a.runAtUs != b.runAtUs)
        return a.runAtUs < b.runAtUs;
    return a.id < b.id;
}

// =====================================================================
// TestJobStore
// =====================================================================

/// In-memory store that does not run anything until the test calls `drainJobs`.
class TestJobStore : InMemoryJobStore
{
    this(long delegate() @safe nothrow now = null) @safe
    {
        super(now);
    }

    /// Claims due jobs one at a time and runs each through `runClaimed`. A retry scheduled in the future
    /// stays queued: the clock does not move here. An `Error` from `perform` leaves this function.
    void drainJobs(Jobs...)() @safe
    {
        int ran = 0;
        while (true)
        {
            auto batch = claimBatch("", 1);
            if (batch.length == 0)
                return;
            if (ran == 10_000)
            {
                // Claimed but not performed. Give the attempt back so the row is not stuck `running`.
                release(batch[0].id);
                throw new JobStoreError("andaime.jobs: drainJobs stopped after 10000 jobs; one is being requeued as due");
            }
            runClaimed!Jobs(this, batch[0]);
            ran++;
        }
    }

    /// Asserts some row of `T` is on `jobQueue!T` and its payload contains `payloadSubstring`.
    /// Any state counts: this checks that the enqueue was accepted.
    void assertEnqueued(T)(string payloadSubstring) @safe
    {
        static if (jobError!T.length)
            static assert(0, jobError!T);
        else
        {
            enum string name = jobName!T;
            enum string queue = jobQueue!T;
            foreach (r; jobs())
            {
                if (r.name == name && r.queue == queue && containsSlice(r.payload, payloadSubstring))
                    return;
            }
            assert(0, "andaime.jobs: expected job '" ~ name ~ "' on queue '" ~ queue
                ~ "' with payload containing '" ~ payloadSubstring ~ "'");
        }
    }

    /// A unit of work for code that enqueues inside a database transaction (`PgJobStore.within(tx)` in production): its
    /// jobs reach this store only on `commit`, and `rollback` drops them.
    TestJobTransaction transaction() @safe
    {
        return new TestJobTransaction(this);
    }
}

/// See `TestJobStore.transaction`. `enqueue` returns id 0 (the row does not exist yet); `commit` returns the real results.
final class TestJobTransaction : JobTransaction
{
    private TestJobStore store;
    private JobSpec[] specs;
    private bool finished;

    private this(TestJobStore store) @safe
    {
        this.store = store;
    }

    EnqueueResult enqueue(JobSpec spec) @safe
    {
        if (finished)
            throw new JobStoreError("andaime.jobs: enqueue on a transaction that was already committed or rolled back");
        specs ~= spec;
        return EnqueueResult(0, true);
    }

    /// The jobs enqueued so far and not yet committed.
    const(JobSpec)[] pending() const @safe => specs;

    /// Hands the jobs to the store, in order (unique windows apply then), and ends the transaction.
    EnqueueResult[] commit() @safe
    {
        if (finished)
            throw new JobStoreError("andaime.jobs: commit on a transaction that was already committed or rolled back");
        finished = true;
        EnqueueResult[] r;
        foreach (s; specs)
            r ~= store.enqueue(s);
        specs = null;
        return r;
    }

    /// Drops the jobs and ends the transaction.
    void rollback() @safe
    {
        finished = true;
        specs = null;
    }
}

private bool containsSlice(scope const(char)[] s, scope const(char)[] part) pure nothrow @nogc @safe
{
    if (part.length == 0)
        return true;
    if (part.length > s.length)
        return false;
    foreach (size_t i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part)
            return true;
    return false;
}

// =====================================================================
// Runner
// =====================================================================

/// Runs one row that `claimBatch` already marked `running`.
///
/// `Exception` records the failure: `discard` on the last attempt (and when there is no `@Retry`),
/// otherwise `fail` with `backoffDelay`. `JobDiscard` discards immediately.
/// Anything else (`Error`, `RequestCancelled`) is given back with `release` and then propagated.
/// The `Error` is not caught: the fiber must not be reused after it.
void runClaimed(Jobs...)(JobStore store, JobRecord rec) @safe
{
    static foreach (J; Jobs)
    {{
        if (rec.name == jobName!J)
        {
            runTyped!J(store, rec);
            return;
        }
    }}
    store.discard(rec.id, "andaime.jobs: unknown job '" ~ rec.name ~ "'");
}

private void runTyped(J)(JobStore store, JobRecord rec) @safe
{
    J value;
    FieldErrors errs;
    if (!JobSet!J.decode(rec.payload, value, errs))
    {
        string why = "andaime.jobs: payload for '" ~ rec.name ~ "' does not match the job";
        if (errs.count)
            why ~= " (" ~ errs.items[0].message ~ ")";
        store.discard(rec.id, why);
        return;
    }

    JobContext ctx;
    ctx.id = rec.id;
    ctx.attempt = rec.attempt;
    ctx.maxAttempts = rec.maxAttempts;
    ctx.queue = rec.queue;

    // andaime.log lines of `perform` carry the job: through the fiber's slot, or the thread's scope without a fiber
    // (`drainJobs`). Not across `@Offload`: the pool thread has neither.
    auto fields = new LogScope().add("job", rec.name).add("job_id", rec.id).add("attempt", rec.attempt);
    auto prevLocal = currentFiberLocal();
    immutable inFiber = setCurrentFiberLocal(fields);
    LogScope prevScope;
    if (!inFiber)
        prevScope = setLogSyncScope(fields);
    scope (exit)
    {
        if (inFiber)
            setCurrentFiberLocal(prevLocal);
        else
            setLogSyncScope(prevScope);
    }

    // Still running when an Error (or any other non-Exception) leaves. scope(failure) gives the
    // attempt back and the Throwable keeps going; a caught Exception sets this false first.
    bool running = true;
    scope (failure)
    {
        if (running)
            releaseQuiet(store, rec.id);
    }

    try
    {
        static if (jobOffload!J)
            offload(() => value.perform(ctx));
        else
            value.perform(ctx);
    }
    catch (JobDiscard d)
    {
        running = false;
        store.discard(rec.id, d.msg);
        return;
    }
    catch (Exception e)
    {
        running = false;
        if (rec.attempt >= rec.maxAttempts)
            store.discard(rec.id, e.msg);
        else
            store.fail(rec.id, backoffDelay(jobBackoff!J, rec.attempt), e.msg);
        return;
    }

    running = false;
    store.complete(rec.id);
}

private void releaseQuiet(JobStore store, long id) @safe
{
    try
        store.release(id);
    catch (Exception)
    {
    }
}

/// Wall clock in microseconds since the Unix epoch.
long unixNowUs() @safe nothrow
{
    static long read() @trusted nothrow @nogc
    {
        version (linux)
        {
            import core.sys.posix.time : CLOCK_REALTIME, clock_gettime, timespec;

            timespec ts;
            if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                return 0;
            return cast(long) ts.tv_sec * 1_000_000L + cast(long) ts.tv_nsec / 1_000L;
        }
        else version (Posix)
        {
            import core.sys.posix.sys.time : gettimeofday, timeval;

            timeval tv;
            if (gettimeofday(&tv, null) != 0)
                return 0;
            return cast(long) tv.tv_sec * 1_000_000L + cast(long) tv.tv_usec;
        }
        else version (Windows)
        {
            import core.sys.windows.winbase : GetSystemTimeAsFileTime, FILETIME;

            FILETIME ft;
            GetSystemTimeAsFileTime(&ft);
            ulong t = (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime;
            enum ulong epochDiff = 116_444_736_000_000_000UL;
            if (t < epochDiff)
                return 0;
            return cast(long)((t - epochDiff) / 10);
        }
    }

    return read();
}

// =====================================================================
// Unittest
// =====================================================================

unittest
{
    assert(fnv1a("") == 0xcbf29ce484222325UL);
    assert(fnv1a("a") == 0xaf63dc4c8601ec8cUL);
    assert(fnv1a("foobar") == 0x85944171f73967e8UL);
    assert(fnv1aHex("") == "cbf29ce484222325");
    assert(fnv1aHex("a") == "af63dc4c8601ec8c");

    assert(backoffDelay(BackoffStrategy.exponential, 1) == usecs(1_000_000));
    assert(backoffDelay(BackoffStrategy.exponential, 2) == usecs(2_000_000));
    assert(backoffDelay(BackoffStrategy.exponential, 3) == usecs(4_000_000));
    assert(backoffDelay(BackoffStrategy.exponential, 15) == usecs(16_384_000_000L));
    assert(backoffDelay(BackoffStrategy.exponential, 16) == usecs(21_600_000_000L));
    assert(backoffDelay(BackoffStrategy.exponential, 100) == usecs(21_600_000_000L));

    import core.time : seconds;

    assert(uniqueSlot(0, 1.seconds) == 0);
    assert(uniqueSlot(1_500_000, 1.seconds) == 1_000_000);
    assert(uniqueSlot(2_000_000, 1.seconds) == 2_000_000);
    assert(jobStateText(JobState.retryable) == "retryable");
    assert(unixNowUs() > 1_000_000_000_000_000L);

    auto wall = new InMemoryJobStore;
    JobSpec spec;
    spec.queue = "q";
    spec.name = "n";
    spec.payload = "{}";
    auto enq = wall.enqueue(spec);
    assert(enq.inserted && enq.id == 1);
    assert(wall.jobs[0].state == JobState.available);
    assert(wall.jobs[0].priority == 100 && wall.jobs[0].attempt == 0);
    assert(wall.jobs[0].runAtUs > 1_000_000_000_000_000L);
}
