/// Postgres `JobStore`: `SKIP LOCKED` claims, unique jobs, a cron slot shared by processes, and `LISTEN`.
///
/// One store per worker thread. It uses that thread's `pgPool` (the same pool as `pgPool(conninfo)`), so do not
/// hand a store to another worker. `enqueue(JobSpec)` borrows a pooled connection. `enqueue(PgConn, JobSpec)`
/// only inserts and notifies inside the caller's transaction: no `BEGIN`/`COMMIT`, and `ROLLBACK` drops both
/// the row and the notification.
///
/// The typed insert lives here because `vela.jobs` cannot name `PgConn`. Either call `jobSpec` and then
/// `store.enqueue(tx, spec)`, or `enqueueJob(tx, store, job)`.
///
/// Schema: `ensureSchema(conn)` on a connection that is not already inside a transaction. `enqueue(JobSpec)`,
/// `claimBatch`, `listen`, `reap` and `claimCronSlot` do that on first use. `enqueue(PgConn, JobSpec)` does not:
/// call `ensureSchema` before opening the caller's transaction. Two starters take `pg_advisory_lock` so the
/// creates cannot race.
///
/// Supervisor, on worker 0: `startServices` spawns `listen` and the reaper. `waitIdle` returns when a
/// notification arrives or after 5 seconds. `claimCron` inserts the cron slot; the supervisor enqueues
/// only when that returns true. `hooks.extra` is not required for either.
module vela.jobs.pg;

@safe:

import core.time : Duration, MonoTime, minutes, msecs, seconds;

import vela.db : Optional, PgConfig, PgConn, PgPool, PgResult, pgPool;
import vela.engine.fiberio : awaitFd, IoEvent, RequestCancelled, sleep, spawn, stopping;
import vela.http.buffer : ByteBuffer;
import vela.http.naming : Naming, naming;
import vela.jobs.backend : EnqueueResult, JobRecord, JobRuntime, JobSpec, JobState, JobStore, JobStoreError,
    assignUnique, jobSpec, logJobFailure, unixNowUs;
import vela.web.json : writeJsonString;
import vela.web.numtext : itoa;

/// Channel both the insert and `listen` use. `NOTIFY` is delivered at COMMIT and dropped by ROLLBACK.
private enum string notifyChannel = "vela_jobs_notify";

/// How long `listen` waits before claiming anyway, so a `run_at` in the future still runs.
private enum notifyFallback = 5.seconds;

/// `errors` keeps this many characters of a failure. A longer message is cut on a UTF-8 boundary.
private enum size_t maxErrorChars = 1024;

/// Hectonanoseconds from 0001-01-01 to the Unix epoch. `SysTime.stdTime` minus this, divided by 10, is microseconds.
private enum long unixEpochStdTime = 621_355_968_000_000_000L;

// =====================================================================
// Store
// =====================================================================

/// Queue in `vela_jobs`. Claims commit before the caller runs `perform`, so the row lock is not held across the work.
final class PgJobStore : JobStore, JobRuntime
{
    private PgConfig cfg;
    private PgPool pool;
    private Duration leasePeriod;
    private bool schemaReady;
    private bool servicesStarted;
    private int wakeGen;

    /// `conninfo` is `host=... dbname=...`. `leasePeriod` is how long `running` may sit before `reap` (default 15 minutes).
    this(string conninfo, Duration leasePeriod = 15.minutes)
    {
        PgConfig c;
        c.conninfo = conninfo;
        this.cfg = c;
        this.leasePeriod = leasePeriod;
        if (c.conninfo.length == 0)
            throw new JobStoreError("vela.jobs: PgJobStore needs a conninfo");
        if (leasePeriod <= Duration.zero)
            throw new JobStoreError("vela.jobs: lease must be positive");
        pool = pgPool(c);
    }

    /// ditto. The pool is `pgPool(cfg)`: the first `pgPool` on this thread for that conninfo wins.
    this(PgConfig cfg, Duration leasePeriod = 15.minutes)
    {
        if (cfg.conninfo.length == 0)
            throw new JobStoreError("vela.jobs: PgJobStore needs a conninfo");
        if (leasePeriod <= Duration.zero)
            throw new JobStoreError("vela.jobs: lease must be positive");
        this.cfg = cfg;
        this.leasePeriod = leasePeriod;
        pool = pgPool(cfg);
    }

    /// How old a `running` row must be before `reap` returns it.
    Duration lease() const pure nothrow @nogc => leasePeriod;

    /// Creates `vela_jobs` and `vela_cron_executions` if they are missing.
    /// `conn` must not already be inside a transaction: each statement autocommits, and the advisory lock is what
    /// keeps a second starter waiting until those commits are visible. A later call is a no-op aside from the lock.
    void ensureSchema(PgConn conn)
    {
        if (conn is null || !conn.usable)
            throw new JobStoreError("vela.jobs: ensureSchema needs an open connection");
        // Session lock, not transaction lock: CREATE commits on its own, and the other starter must wait for that.
        conn.exec("select pg_advisory_lock(hashtext('vela_jobs_schema')::bigint)");
        scope (exit)
            unlockSchema(conn);
        conn.exec(createJobsSql);
        conn.exec(createUniqueSql);
        conn.exec(createCronSql);
        schemaReady = true;
    }

    /// Inserts on a pooled connection and commits, including the notify.
    override EnqueueResult enqueue(JobSpec spec)
    {
        prepare(spec);
        ready();
        return pool.transaction((PgConn c) => insertRow(c, spec));
    }

    /// Inserts and notifies on `tx` only. The caller's `COMMIT` publishes both; `ROLLBACK` publishes neither.
    EnqueueResult enqueue(PgConn tx, JobSpec spec)
    {
        if (tx is null || !tx.usable)
            throw new JobStoreError("vela.jobs: enqueue needs an open connection");
        prepare(spec);
        return insertRow(tx, spec);
    }

    /// Marks up to `limit` due rows `running`. `queue` `""` is every queue; one name is a one-element array.
    /// The attempt increases here. The transaction commits before this returns.
    override JobRecord[] claimBatch(string queue, int limit)
    {
        if (limit <= 0)
            return null;
        ready();
        Optional!string queues;
        if (queue.length)
            queues = Optional!string(textArray(queue));
        return pool.transaction((PgConn c) {
            auto r = c.query(claimSql, queues, limit);
            scope (exit)
                r.close();
            JobRecord[] got;
            foreach (row; r.rowsAs!JobRow)
                got ~= toRecord(row);
            sortClaimed(got);
            return got;
        });
    }

    override void complete(long id)
    {
        touchRunning(id, (PgConn c) => c.query(completeSql, id));
    }

    /// `retryable` at `now + delay`. The attempt `claimBatch` already counted stays spent.
    override void fail(long id, Duration delay, string reason)
    {
        touchRunning(id, (PgConn c) => c.query(failSql, id, delayUs(delay), jsonString(reason)));
    }

    override void discard(long id, string reason)
    {
        touchRunning(id, (PgConn c) => c.query(discardSql, id, jsonString(reason)));
    }

    /// `retryable` again, and the attempt added by `claimBatch` is given back. `run_at` is unchanged.
    override void release(long id)
    {
        touchRunning(id, (PgConn c) => c.query(releaseSql, id));
    }

    /// `running` rows last touched more than `lease` ago become `retryable`. The attempt is left as it is.
    /// Call this on a timer. It does not start a thread.
    void reap()
    {
        ready();
        auto l = pool.lease();
        l.conn.exec(reapSql, delayUs(leasePeriod));
    }

    /// Inserts `(jobName, slotStdTime)` into `vela_cron_executions`. False when that slot is already taken.
    /// `slotStdTime` is `SysTime.stdTime` from `cronSlot` (`@Cron`) or `slotStart` (`@Every`), not Unix microseconds.
    /// The supervisor calls this through `claimCron` and enqueues only when it returns true.
    bool claimCronSlot(string jobName, long slotStdTime)
    {
        if (jobName.length == 0)
            throw new JobStoreError("vela.jobs: claimCronSlot needs a job name");
        ready();
        auto l = pool.lease();
        auto r = l.conn.query(cronSql, jobName, unixUsFromStdTime(slotStdTime));
        scope (exit)
            r.close();
        return r.rows > 0;
    }

    bool claimCron(string jobName, long slotStdTime)
    {
        return claimCronSlot(jobName, slotStdTime);
    }

    /// `LISTEN` and the reaper, each on its own fiber. A notification bumps `wakeGen`, which
    /// `waitIdle` observes. Called once from the supervisor, during worker 0's init.
    void startServices()
    {
        if (servicesStarted)
            return;
        servicesStarted = true;
        spawn(() {
            try
                listen(() { wakeGen++; });
            catch (Exception e)
                logJobFailure("listen", e);
        });
        Duration period = leasePeriod;
        spawn(() {
            while (!stopping())
            {
                sleep(period);
                if (stopping())
                    return;
                try
                    reap();
                catch (Exception e)
                    logJobFailure("reap", e);
            }
        });
    }

    /// Returns when `listen` saw a notification, or when `maxWait` (at least 5 seconds) has passed.
    /// The slice is 100 ms so a wake is noticed without another query.
    void waitIdle(Duration maxWait)
    {
        if (maxWait < notifyFallback)
            maxWait = notifyFallback;
        immutable seen = wakeGen;
        immutable end = MonoTime.currTime + maxWait;
        while (!stopping() && wakeGen == seen)
        {
            Duration left = end - MonoTime.currTime;
            if (left <= Duration.zero)
                return;
            sleep(left > 100.msecs ? 100.msecs : left);
        }
    }

    /// Blocks on a connection that is not from the pool: `LISTEN`, then `awaitFd` on libpq's socket.
    /// `onWake` runs when a notification arrives and every 5 seconds (a scheduled job does not notify).
    /// Returns when the fiber is cancelled or the worker is stopping. The listen connection closes on the way out.
    void listen(void delegate() @safe onWake)
    {
        if (onWake is null)
            throw new JobStoreError("vela.jobs: listen needs a wake handler");
        ready();
        auto c = PgConn.connect(cfg.conninfo, cfg.connectTimeout, cfg.queryTimeout);
        scope (exit)
            c.shutdown();
        c.exec("listen " ~ notifyChannel);
        runListen(c, onWake);
    }

    // -----------------------------------------------------------------

    private void unlockSchema(PgConn conn)
    {
        if (!conn.usable)
            return;
        try
            conn.exec("select pg_advisory_unlock(hashtext('vela_jobs_schema')::bigint)");
        catch (Exception)
            conn.shutdown(); // a stuck session lock would block every later ensureSchema
    }

    private void ready()
    {
        if (schemaReady)
            return;
        auto l = pool.lease();
        ensureSchema(l.conn);
    }

    private void touchRunning(long id, scope PgResult delegate(PgConn c) @safe run)
    {
        ready();
        auto l = pool.lease();
        auto r = run(l.conn);
        string n = r.affected;
        r.close();
        mustRunning(l.conn, id, n);
    }

    private void mustRunning(PgConn c, long id, string affected)
    {
        if (affected == "1")
            return;
        auto cur = c.query("select state from vela_jobs where id = $1", id);
        scope (exit)
            cur.close();
        if (cur.rows == 0)
            throw new JobStoreError("vela.jobs: no job " ~ itoa(id));
        throw new JobStoreError("vela.jobs: job " ~ itoa(id) ~ " is " ~ cur.get!string(0, 0) ~ "; expected running");
    }
}

/// Encodes `job` (`jobSpec`) and inserts it on `tx`. Same transaction rules as `PgJobStore.enqueue(PgConn, JobSpec)`.
EnqueueResult enqueueJob(T)(PgConn tx, PgJobStore store, auto ref const T job, int priority = 100)
{
    if (store is null)
        throw new JobStoreError("vela.jobs: enqueueJob needs a store");
    return store.enqueue(tx, jobSpec(job, priority));
}

// =====================================================================
// Rows
// =====================================================================

/// The `RETURNING` list of `claimSql`, read with `rowsAs` (snake_case columns).
@naming(Naming.snakeCase)
private struct JobRow
{
    long id;
    string queue;
    string name;
    string payload;
    string state;
    int attempt;
    int maxAttempts;
    int priority;
    long runAtUs;
    string uniqueKey;
    long uniqueSlot;
    string lastError;
}

private void prepare(ref JobSpec spec)
{
    if (spec.queue.length == 0)
        throw new JobStoreError("vela.jobs: enqueue needs a queue");
    if (spec.name.length == 0)
        throw new JobStoreError("vela.jobs: enqueue needs a job name");
    if (spec.maxAttempts < 1)
        throw new JobStoreError("vela.jobs: maxAttempts must be >= 1");
    if (spec.payload.length == 0)
        throw new JobStoreError("vela.jobs: enqueue needs a JSON payload");
    assignUnique(spec, unixNowUs());
}

private EnqueueResult insertRow(PgConn c, JobSpec spec)
{
    Optional!string key;
    long slotUs;
    if (spec.uniqueKey.length)
    {
        key = Optional!string(spec.uniqueKey);
        slotUs = spec.uniqueSlot;
    }
    auto r = c.query(insertSql, spec.queue, spec.name, spec.payload, spec.hasRunAt,
        spec.hasRunAt ? spec.runAtUs : 0L, spec.maxAttempts, spec.priority, key, slotUs);
    long id;
    bool inserted;
    if (r.rows == 1)
    {
        id = r.get!long(0, 0);
        inserted = true;
    }
    r.close();
    if (!inserted)
    {
        if (spec.uniqueKey.length == 0)
            throw new JobStoreError("vela.jobs: enqueue inserted nothing");
        auto cur = c.query(findUniqueSql, spec.name, spec.uniqueKey, slotUs);
        scope (exit)
            cur.close();
        if (cur.rows == 0)
            throw new JobStoreError("vela.jobs: unique job '" ~ spec.name ~ "' was not inserted and no live row exists");
        id = cur.get!long(0, 0);
    }
    c.exec("select pg_notify('" ~ notifyChannel ~ "', '')");
    return EnqueueResult(id, inserted);
}

private JobRecord toRecord(JobRow row)
{
    JobRecord rec;
    rec.id = row.id;
    rec.queue = row.queue;
    rec.name = row.name;
    rec.payload = row.payload;
    rec.state = parseState(row.state);
    rec.attempt = row.attempt;
    rec.maxAttempts = row.maxAttempts;
    rec.priority = row.priority;
    rec.runAtUs = row.runAtUs;
    rec.uniqueKey = row.uniqueKey;
    rec.uniqueSlot = row.uniqueSlot;
    rec.lastError = row.lastError.length ? row.lastError : null;
    return rec;
}

private JobState parseState(string state)
{
    switch (state)
    {
    case "available":
        return JobState.available;
    case "scheduled":
        return JobState.scheduled;
    case "running":
        return JobState.running;
    case "completed":
        return JobState.completed;
    case "retryable":
        return JobState.retryable;
    case "discarded":
        return JobState.discarded;
    default:
        throw new JobStoreError("vela.jobs: unknown job state '" ~ state ~ "'");
    }
}

private void sortClaimed(JobRecord[] rows) pure
{
    foreach (size_t i; 1 .. rows.length)
    {
        JobRecord v = rows[i];
        size_t j = i;
        while (j > 0 && claimBefore(v, rows[j - 1]))
        {
            rows[j] = rows[j - 1];
            j--;
        }
        rows[j] = v;
    }
}

private bool claimBefore(ref const JobRecord a, ref const JobRecord b) pure nothrow @nogc
{
    if (a.priority != b.priority)
        return a.priority < b.priority;
    if (a.runAtUs != b.runAtUs)
        return a.runAtUs < b.runAtUs;
    return a.id < b.id;
}

private long delayUs(Duration delay) pure nothrow @nogc
{
    long us = delay.total!"usecs";
    return us < 0 ? 0 : us;
}

/// `stdTime` (hnsecs since 0001-01-01) to microseconds since the Unix epoch. Negative values floor.
private long unixUsFromStdTime(long stdTime) pure nothrow @nogc
{
    long hnsecs = stdTime - unixEpochStdTime;
    if (hnsecs >= 0)
        return hnsecs / 10;
    long q = hnsecs / 10;
    if (q * 10 != hnsecs)
        q--;
    return q;
}

/// One Postgres text-array literal. `\` and `"` are escaped so the element cannot break out of the quotes.
private string textArray(scope const(char)[] element) pure
{
    string o = `{"`;
    foreach (char c; element)
    {
        if (c == '\\' || c == '"')
            o ~= '\\';
        o ~= c;
    }
    return o ~ `"}`;
}

private const(char)[] clipUtf8(scope const(char)[] s, size_t max) pure nothrow @nogc
{
    if (s.length <= max)
        return s;
    size_t n = max;
    while (n > 0 && (s[n] & 0xC0) == 0x80)
        n--;
    return s[0 .. n];
}

/// A JSON string literal, truncated, so `$1::jsonb` appends one element to `errors`.
private string jsonString(scope const(char)[] s)
{
    ByteBuffer buf;
    writeJsonString(buf, clipUtf8(s, maxErrorChars));
    return buf.data.idup;
}

private bool takeNotifies(PgConn c)
{
    if (c.socket() < 0)
        throw new JobStoreError("vela.jobs: the LISTEN connection has no socket");
    if (!c.consumeInput())
        throw new JobStoreError("vela.jobs: reading notifications failed");
    string channel, payload;
    bool any;
    while (c.popNotify(channel, payload))
        any = true;
    return any;
}

private struct ListenWait
{
    bool died;
}

private ListenWait waitListen(PgConn c)
{
    immutable fd = c.socket();
    if (fd < 0)
        throw new JobStoreError("vela.jobs: the LISTEN connection has no socket");
    immutable ev = awaitFd(fd, IoEvent.readable, notifyFallback);
    ListenWait w;
    if (ev & IoEvent.readable)
        takeNotifies(c);
    w.died = (ev & (IoEvent.hangup | IoEvent.error)) != 0;
    return w;
}

/// sound: `RequestCancelled` is this fiber's cancel signal; catching it makes `listen` return.
private void runListen(PgConn c, void delegate() @safe onWake) @trusted
{
    try
    {
        if (takeNotifies(c) && !stopping())
            onWake();
        while (!stopping())
        {
            auto w = waitListen(c);
            if (stopping())
                return;
            onWake();
            if (w.died)
                throw new JobStoreError("vela.jobs: the LISTEN connection closed");
        }
    }
    catch (RequestCancelled)
    {
    }
}

// =====================================================================
// SQL
// =====================================================================

private enum createJobsSql = q"SQL
create table if not exists vela_jobs (
    id bigserial primary key,
    queue text not null,
    job_name text not null,
    payload jsonb not null,
    state text not null,
    attempt int not null default 0,
    max_attempts int not null,
    priority int not null default 100,
    run_at timestamptz not null,
    attempted_at timestamptz,
    completed_at timestamptz,
    unique_key text,
    unique_slot timestamptz,
    errors jsonb not null default '[]'
)
SQL";

private enum createUniqueSql = q"SQL
create unique index if not exists vela_jobs_unique_live
    on vela_jobs (job_name, unique_key, unique_slot)
    where unique_key is not null and state <> 'discarded'
SQL";

private enum createCronSql = q"SQL
create table if not exists vela_cron_executions (
    job_name text not null,
    scheduled_slot timestamptz not null,
    primary key (job_name, scheduled_slot)
)
SQL";

private enum insertSql = q"SQL
insert into vela_jobs (
    queue, job_name, payload, state, max_attempts, priority, run_at, unique_key, unique_slot
) values (
    $1,
    $2,
    $3::jsonb,
    case
        when $4::bool and timestamptz 'epoch' + ($5::bigint * interval '1 microsecond') > now()
            then 'scheduled'
        else 'available'
    end,
    $6,
    $7,
    case
        when $4::bool then timestamptz 'epoch' + ($5::bigint * interval '1 microsecond')
        else now()
    end,
    $8,
    case
        when $8::text is null then null
        else timestamptz 'epoch' + ($9::bigint * interval '1 microsecond')
    end
)
on conflict (job_name, unique_key, unique_slot)
    where unique_key is not null and state <> 'discarded'
do nothing
returning id
SQL";

private enum findUniqueSql = q"SQL
select id from vela_jobs
where job_name = $1
  and unique_key = $2
  and unique_slot = timestamptz 'epoch' + ($3::bigint * interval '1 microsecond')
  and state <> 'discarded'
limit 1
SQL";

private enum claimSql = q"SQL
update vela_jobs set
    state = 'running',
    attempt = attempt + 1,
    attempted_at = now()
where id in (
    select id from vela_jobs
    where state in ('available', 'scheduled', 'retryable')
      and ($1::text[] is null or queue = any($1::text[]))
      and run_at <= now()
    order by priority, run_at, id
    for update skip locked
    limit ($2::int)
)
returning
    id,
    queue,
    job_name as name,
    payload::text as payload,
    state,
    attempt,
    max_attempts,
    priority,
    (extract(epoch from run_at) * 1000000)::bigint as run_at_us,
    coalesce(unique_key, '') as unique_key,
    coalesce((extract(epoch from unique_slot) * 1000000)::bigint, 0) as unique_slot,
    case
        when jsonb_array_length(errors) = 0 then ''
        else errors ->> (jsonb_array_length(errors) - 1)
    end as last_error
SQL";

private enum completeSql = q"SQL
update vela_jobs
set state = 'completed', completed_at = now()
where id = $1 and state = 'running'
SQL";

private enum failSql = q"SQL
update vela_jobs
set state = 'retryable',
    run_at = now() + ($2::bigint * interval '1 microsecond'),
    errors = errors || $3::jsonb
where id = $1 and state = 'running'
SQL";

private enum discardSql = q"SQL
update vela_jobs
set state = 'discarded',
    errors = errors || $2::jsonb
where id = $1 and state = 'running'
SQL";

private enum releaseSql = q"SQL
update vela_jobs
set state = 'retryable',
    attempt = case when attempt > 0 then attempt - 1 else 0 end
where id = $1 and state = 'running'
SQL";

private enum reapSql = q"SQL
update vela_jobs
set state = 'retryable'
where state = 'running'
  and attempted_at < now() - ($1::bigint * interval '1 microsecond')
SQL";

private enum cronSql = q"SQL
insert into vela_cron_executions (job_name, scheduled_slot)
values ($1, timestamptz 'epoch' + ($2::bigint * interval '1 microsecond'))
on conflict do nothing
returning job_name
SQL";

// =====================================================================
// Pure helpers
// =====================================================================

unittest
{
    assert(textArray("default") == `{"default"}`);
    assert(textArray(`a"b\c`) == `{"a\"b\\c"}`);
    assert(unixUsFromStdTime(unixEpochStdTime) == 0);
    assert(unixUsFromStdTime(unixEpochStdTime + 10) == 1);
    assert(unixUsFromStdTime(unixEpochStdTime - 1) == -1);
    assert(clipUtf8("abcdef", 3) == "abc");
    assert(clipUtf8([cast(char) 0xC3, cast(char) 0xA9], 1).length == 0);
    assert(jsonString("a\"b") == `"a\"b"`);
    char[maxErrorChars + 8] longMsg = 'x';
    assert(jsonString(longMsg[]).length == maxErrorChars + 2); // quotes around the clipped text
}
