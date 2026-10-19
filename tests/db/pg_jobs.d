/// Postgres job queue: rollback drops the row and the notify, two claimers never share an id,
/// LISTEN wakes a fiber, a cron slot inserts once, and a lease returns an abandoned `running` row.
/// Without ANDAIME_PG the test prints `skip: ...` and exits 77. Build it, then run the binary:
/// `dmd -run` turns that 77 into 1.
module pg_jobs 2025;

version (linux):

import andaime;
import andaime.db;
import andaime.jobs;
import andaime.jobs.pg;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.stdio : printf, fprintf, fflush, stdout, stderr;
import core.stdc.stdlib : getenv, exit;
import core.stdc.string : strlen;
import core.thread : Thread;
import core.time : Duration, minutes, msecs, seconds;
import andaime.web.numtext : itoa;
import std.datetime.date : DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;

@Job("default")
struct Ping
{
    int n;

    void perform(ref JobContext) @safe
    {
    }
}

__gshared string conninfo;
shared int gWakes, gWins;
shared long gSeen;

@safe:

string pgConninfo() @trusted
{
    // sound: main writes `conninfo` once before any test thread or the server starts
    return conninfo;
}

PgJobStore newStore(PgConn admin, Duration leasePeriod = 15.minutes)
{
    auto store = new PgJobStore(pgConninfo(), leasePeriod);
    store.ensureSchema(admin);
    return store;
}

void reset(PgConn admin)
{
    admin.exec("drop table if exists andaime_jobs");
    admin.exec("drop table if exists andaime_cron_executions");
}

JobSpec spec(string queue, string name, string payload = `{}`, int priority = 100)
{
    JobSpec s;
    s.queue = queue;
    s.name = name;
    s.payload = payload;
    s.priority = priority;
    return s;
}

int qint(PgConn c, string sql)
{
    auto r = c.query(sql);
    scope (exit)
        r.close();
    return r.get!int(0, 0);
}

int qint(A)(PgConn c, string sql, A a)
{
    auto r = c.query(sql, a);
    scope (exit)
        r.close();
    return r.get!int(0, 0);
}

string qstr(A)(PgConn c, string sql, A a)
{
    auto r = c.query(sql, a);
    scope (exit)
        r.close();
    return r.get!string(0, 0);
}

long qlong(A)(PgConn c, string sql, A a)
{
    auto r = c.query(sql, a);
    scope (exit)
        r.close();
    return r.get!long(0, 0);
}

void rollbackQuiet(PgConn c)
{
    try
        c.exec("rollback");
    catch (Exception)
    {
    }
}

bool contains(string s, string part) pure
{
    if (part.length > s.length)
        return false;
    foreach (size_t i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part)
            return true;
    return false;
}

/// A database from before the rename (vela_jobs, no andaime_jobs) gets one warning from ensureSchema.
void testLegacyTables(PgConn admin)
{
    reset(admin);
    admin.exec("drop table if exists vela_jobs");
    admin.exec("create table vela_jobs (id bigint)");
    scope (exit)
        admin.exec("drop table if exists vela_jobs");
    auto logs = captureLog({ newStore(admin); });
    assert(logs.length == 1 && logs[0].level == LogLevel.warn, "ensureSchema should warn about vela_jobs");
    assert(logs[0].message == "vela_jobs exists but andaime_jobs does not", logs[0].message);
    // andaime_jobs exists now: no warning on the next start
    assert(captureLog({ newStore(admin); }).length == 0);
}

/// ROLLBACK drops the inserted row and does not leave a job `claimBatch` can see.
void testRollback(PgConn admin)
{
    reset(admin);
    auto store = newStore(admin);
    bool threw;
    try
    {
        pgPool(pgConninfo()).transaction((PgConn tx) {
            auto r = enqueueJob(tx, store, Ping(7));
            assert(r.inserted && r.id > 0);
            throw new Exception("rollback");
        });
    }
    catch (Exception e)
    {
        threw = e.msg == "rollback";
    }
    assert(threw);
    assert(qint(admin, "select count(*)::int from andaime_jobs") == 0);
    assert(store.claimBatch("default", 10).length == 0);

    // the same through the store-neutral JobTransaction: committed with the caller's data, or not at all
    pgPool(pgConninfo()).transaction((PgConn tx) {
        JobTransaction jt = store.within(tx);
        assert(enqueue(jt, Ping(8)).inserted);
    });
    assert(qint(admin, "select count(*)::int from andaime_jobs") == 1);
    threw = false;
    try
        pgPool(pgConninfo()).transaction((PgConn tx) {
            enqueue(store.within(tx), Ping(9));
            throw new Exception("rollback");
        });
    catch (Exception e)
        threw = true;
    assert(threw && qint(admin, "select count(*)::int from andaime_jobs") == 1);
}

/// Unique window, priority order, a future `run_at`, and attempt accounting for fail / release / discard.
void testUniqueAndAttempts(PgConn admin)
{
    reset(admin);
    auto store = newStore(admin);

    JobSpec u = spec("default", "uniq", `{"k":1}`);
    u.uniqueKey = "same";
    u.uniqueSlot = 1_700_000_000_000_000L;
    auto first = store.enqueue(u);
    auto again = store.enqueue(u);
    assert(first.inserted && !again.inserted && again.id == first.id);
    assert(qint(admin, "select count(*)::int from andaime_jobs") == 1);
    assert(qlong(admin, "select (extract(epoch from unique_slot) * 1000000)::bigint from andaime_jobs where id = $1", first.id)
        == u.uniqueSlot);

    auto claimed = store.claimBatch("default", 1);
    assert(claimed.length == 1 && claimed[0].id == first.id && claimed[0].attempt == 1);
    assert(claimed[0].state == JobState.running);
    store.discard(claimed[0].id, "drop");
    auto third = store.enqueue(u);
    assert(third.inserted && third.id != first.id);
    auto thirdRun = store.claimBatch("default", 1);
    assert(thirdRun.length == 1 && thirdRun[0].id == third.id);
    store.complete(thirdRun[0].id);

    store.enqueue(spec("default", "late", `{}`, 100));
    JobSpec soon = spec("default", "soon", `{}`, 1);
    store.enqueue(soon);
    JobSpec future = spec("default", "future");
    future.hasRunAt = true;
    future.runAtUs = unixNowUs() + 3_600_000_000L;
    store.enqueue(future);
    auto batch = store.claimBatch("default", 10);
    assert(batch.length == 2);
    assert(batch[0].name == "soon" && batch[0].priority == 1);
    assert(batch[1].name == "late" && batch[1].priority == 100);
    assert(store.claimBatch("", 10).length == 0); // future, or already running

    store.release(batch[0].id);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", batch[0].id) == "retryable");
    assert(qint(admin, "select attempt from andaime_jobs where id = $1", batch[0].id) == 0);
    auto rerun = store.claimBatch("default", 1);
    assert(rerun.length == 1 && rerun[0].id == batch[0].id && rerun[0].attempt == 1);

    store.fail(rerun[0].id, 60.minutes, "say \"hi\"");
    assert(qstr(admin, "select state from andaime_jobs where id = $1", rerun[0].id) == "retryable");
    assert(qint(admin, "select attempt from andaime_jobs where id = $1", rerun[0].id) == 1);
    assert(qstr(admin, "select errors->>0 from andaime_jobs where id = $1", rerun[0].id) == "say \"hi\"");
    assert(store.claimBatch("default", 10).length == 0);
    admin.exec("update andaime_jobs set run_at = now() - interval '1 second' where id = $1", rerun[0].id);
    auto after = store.claimBatch("default", 1);
    assert(after.length == 1 && after[0].id == rerun[0].id && after[0].attempt == 2);
    assert(after[0].lastError == "say \"hi\"");
    store.complete(after[0].id);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", after[0].id) == "completed");

    store.discard(batch[1].id, "a'; drop table andaime_jobs;--");
    assert(qint(admin, "select count(*)::int from andaime_jobs") >= 1);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", batch[1].id) == "discarded");
    assert(qstr(admin, "select state from andaime_jobs where job_name = $1", "future") == "scheduled");

    store.enqueue(spec("alpha", "a"));
    store.enqueue(spec("beta", "b"));
    auto both = store.claimBatch("", 10);
    assert(both.length == 2);
    assert((both[0].queue == "alpha" && both[1].queue == "beta") || (both[0].queue == "beta" && both[1].queue == "alpha"));
}

/// A row locked by another transaction is skipped. Two threads claiming one job cannot both win.
void testClaimers(PgConn admin) @system
{
    reset(admin);
    auto store = newStore(admin);
    auto low = store.enqueue(spec("locked", "first", `{}`, 1));
    auto high = store.enqueue(spec("locked", "second", `{}`, 100));
    auto holder = PgConn.connect(pgConninfo(), 5.seconds, 10.seconds);
    scope (exit)
    {
        rollbackQuiet(holder);
        holder.shutdown();
    }
    holder.exec("begin");
    holder.exec("select id from andaime_jobs where id = $1 for update", low.id);
    auto got = store.claimBatch("locked", 10);
    assert(got.length == 1 && got[0].id == high.id, "the locked id was claimed");
    holder.exec("rollback");
    auto rest = store.claimBatch("locked", 10);
    assert(rest.length == 1 && rest[0].id == low.id);

    reset(admin);
    store = newStore(admin);
    enum n = 8;
    foreach (i; 0 .. n)
        store.enqueue(spec("batch", "n" ~ itoa(i)));
    __gshared long[] sideA, sideB;
    sideA = null;
    sideB = null;
    auto t1 = new Thread({
        auto s = new PgJobStore(pgConninfo());
        long[] ids;
        foreach (row; s.claimBatch("batch", 20))
            ids ~= row.id;
        sideA = ids;
    });
    auto t2 = new Thread({
        auto s = new PgJobStore(pgConninfo());
        long[] ids;
        foreach (row; s.claimBatch("batch", 20))
            ids ~= row.id;
        sideB = ids;
    });
    t1.start();
    t2.start();
    t1.join();
    t2.join();
    bool[long] seen;
    assert(sideA.length + sideB.length == n);
    foreach (id; sideA ~ sideB)
    {
        assert(id !in seen, "two claimers returned the same id");
        seen[id] = true;
    }

    reset(admin);
    store = newStore(admin);
    auto only = store.enqueue(spec("once", "only"));
    atomicStore(gWins, 0);
    void once()
    {
        auto s = new PgJobStore(pgConninfo());
        if (s.claimBatch("once", 1).length)
            atomicOp!"+="(gWins, 1);
    }
    auto a = new Thread(&once);
    auto b = new Thread(&once);
    a.start();
    b.start();
    a.join();
    b.join();
    assert(atomicLoad(gWins) == 1);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", only.id) == "running");
}

/// `cronSlot` / `slotStart` stdTime inserts once per (job, slot).
void testCron(PgConn admin)
{
    reset(admin);
    auto store = newStore(admin);
    CronExpr expr;
    assert(parseCron("15 10 * * *", expr) == "");
    SysTime now = SysTime(DateTime(2024, 6, 15, 10, 15, 30), UTC());
    SysTime slot;
    assert(cronSlot(expr, now, slot));
    assert(store.claimCronSlot("daily", slot.stdTime));
    assert(!store.claimCronSlot("daily", slot.stdTime));
    assert(qlong(admin, "select extract(epoch from scheduled_slot)::bigint from andaime_cron_executions where job_name = $1", "daily")
        == slot.toUnixTime());

    auto every = slotStart(now, 15.minutes);
    assert(store.claimCronSlot("quarter", every.stdTime));
    assert(!store.claimCronSlot("quarter", every.stdTime));
    assert(store.claimCronSlot("daily", every.stdTime + 60L * 10_000_000L));
    assert(qint(admin, "select count(*)::int from andaime_cron_executions") == 3);
}

/// A `running` row older than the lease becomes `retryable` with the same attempt. A fresh one stays `running`.
void testLease(PgConn admin)
{
    reset(admin);
    auto store = newStore(admin, 1.minutes);
    assert(store.lease == 1.minutes);
    auto old = store.enqueue(spec("lease", "old"));
    auto fresh = store.enqueue(spec("lease", "fresh"));
    auto a = store.claimBatch("lease", 10);
    assert(a.length == 2 && a[0].attempt == 1 && a[1].attempt == 1);
    admin.exec("update andaime_jobs set attempted_at = now() - interval '2 minutes' where id = $1", old.id);
    admin.exec("update andaime_jobs set attempted_at = now() - interval '10 seconds' where id = $1", fresh.id);
    store.reap();
    assert(qstr(admin, "select state from andaime_jobs where id = $1", old.id) == "retryable");
    assert(qint(admin, "select attempt from andaime_jobs where id = $1", old.id) == 1);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", fresh.id) == "running");
    auto again = store.claimBatch("lease", 10);
    assert(again.length == 1 && again[0].id == old.id && again[0].attempt == 2);
}

PgJobStore listenStore;

void onWake()
{
    atomicOp!"+="(gWakes, 1);
    if (listenStore is null)
        return;
    foreach (row; listenStore.claimBatch("notify", 8))
        atomicStore(gSeen, row.id);
}

void listenFiber()
{
    listenStore = new PgJobStore(pgConninfo());
    listenStore.listen(() { onWake(); });
}

void hook()
{
    spawn(&listenFiber);
}

@system:

PgConn connect()
{
    return PgConn.connect(pgConninfo(), 5.seconds, 10.seconds);
}

int listening(PgConn c)
{
    return qint(c, "select count(*)::int from pg_stat_activity where pid <> pg_backend_pid() and query like '%andaime_jobs_notify%' and state = 'idle'");
}

void dumpActivity(PgConn c)
{
    auto r = c.query("select coalesce(state, '') || ' ' || left(query, 120) from pg_stat_activity where datname = current_database()");
    scope (exit)
        r.close();
    foreach (i; 0 .. r.rows)
        fprintf(stderr, "  pg: %.*s\n", cast(int) r.get!string(i, 0).length, r.get!string(i, 0).ptr);
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 10)
    {
        if (cond())
            return true;
        Thread.sleep(10.msecs);
    }
    return cond();
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

App build()
{
    return new App;
}

/// A committed enqueue wakes `listen`. A rolled-back enqueue does not, and leaves no row.
void testNotify(PgConn admin)
{
    reset(admin);
    auto store = newStore(admin);
    atomicStore(gWakes, 0);
    atomicStore(gSeen, 0);
    listenStore = null;

    ServerConfig sc;
    sc.accept = false;
    sc.workers = 1;
    sc.shutdownGraceMs = 800;

    bool serveOk;
    Thread server;
    scope (exit)
    {
        if (server !is null && server.isRunning)
        {
            import core.sys.posix.signal : kill, SIGTERM;
            import core.sys.posix.unistd : getpid;

            kill(getpid(), SIGTERM);
            server.join();
        }
    }
    server = new Thread({
        serveOk = tryServe(&build, sc, &hook);
    });
    server.start();

    if (!waitFor(() => listening(admin) >= 1, 5000))
    {
        dumpActivity(admin);
        assert(0, "LISTEN did not become idle");
    }
    immutable before = atomicLoad(gWakes);
    bool threw;
    try
    {
        pgPool(pgConninfo()).transaction((PgConn tx) {
            auto r = store.enqueue(tx, spec("notify", "gone", `{"n":1}`));
            assert(r.inserted);
            throw new Exception("rollback");
        });
    }
    catch (Exception e)
    {
        threw = e.msg == "rollback";
    }
    assert(threw);
    Thread.sleep(400.msecs);
    assert(atomicLoad(gWakes) == before, "ROLLBACK delivered a notification");
    assert(qint(admin, "select count(*)::int from andaime_jobs") == 0);

    auto live = store.enqueue(spec("notify", "live", `{"n":2}`));
    if (!waitFor(() => atomicLoad(gSeen) == live.id, 2500))
    {
        fprintf(stderr, "wakes=%d seen=%lld id=%lld\n", atomicLoad(gWakes), atomicLoad(gSeen), live.id);
        dumpActivity(admin);
        assert(0, "notify did not wake the listener");
    }
    assert(atomicLoad(gWakes) > before);
    assert(qstr(admin, "select state from andaime_jobs where id = $1", live.id) == "running");
    assert(contains(qstr(admin, "select payload::text from andaime_jobs where id = $1", live.id), "2"));

    import core.sys.posix.signal : kill, SIGTERM;
    import core.sys.posix.unistd : getpid;

    kill(getpid(), SIGTERM);
    server.join();
    assert(serveOk);
    assert(waitFor(() => listening(admin) == 0, 2000), "the LISTEN connection stayed open");
}

void main()
{
    auto env = getenv("ANDAIME_PG");
    if (env is null)
    {
        fprintf(stderr, "skip: set ANDAIME_PG to the conninfo of a test Postgres\n");
        exit(77);
    }
    conninfo = cast(string) env[0 .. strlen(env)].idup;

    auto guard = new Thread({
        Thread.sleep(60.seconds);
        fprintf(stderr, "pg_jobs: timed out\n");
        exit(1);
    });
    guard.isDaemon = true;
    guard.start();

    auto admin = connect();
    scope (exit)
        admin.shutdown();

    testRollback(admin);
    ok("rollback drops the row and leaves nothing to claim");
    testUniqueAndAttempts(admin);
    ok("unique slot, priority, fail, release, discard");
    testClaimers(admin);
    ok("two claimers do not get the same id");
    testCron(admin);
    ok("cron slot insert is unique");
    testLease(admin);
    ok("lease returns an abandoned running row to retryable");
    testNotify(admin);
    ok("notify wakes the listener");
    testLegacyTables(admin);
    ok("ensureSchema warns once about a vela_jobs table");
    printf("all Postgres job tests passed\n");
}
