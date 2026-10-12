/// Cooperative PostgreSQL driver over asynchronous libpq.
///
/// Inside a request, every wait (connect, send, response) goes through
/// `awaitFd`: the fiber suspends and the worker serves other connections. No
/// call blocks the loop, whatever the database latency (a remote RDS,
/// for example). The host's DNS is resolved on a pool thread (`offload`).
///
/// ```d
/// auto db = pgPool("host=my-rds.example.rds.amazonaws.com dbname=app user=app");
/// auto res = db.query("select id, name from users where id = $1", id);
/// auto users = res.rowsAs!User;          // User has fields id and name
/// ```
///
/// Rules:
///  - each worker has its own connection pool (thread-local): use `pgPool`;
///  - a connection serves one query at a time; the pool gives one per fiber;
///  - if the request is cancelled or the query hits its deadline midway, the
///    driver asks the server to cancel and DISCARDS the connection (it never
///    returns it to the pool with a response pending);
///  - parameters go in text format ($1, $2...), so there is no SQL injection
///    by concatenation: never build SQL with user-supplied values.
module vela.db.pg;

@safe:

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import core.time : Duration, MonoTime, msecs, seconds, minutes;

import core.sys.linux.sys.eventfd : eventfd;
import core.sys.posix.unistd : close, write;

import vela.engine.fiberio : awaitFd, currentScheduler, IoEvent, RequestCancelled;
import vela.engine.offload : offload, offloadPool;
import vela.db.libpq;

// ============================================================ errors

/// Database or driver error. `sqlState` is PostgreSQL's 5-character
/// code (e.g. "23505" = unique violation); empty for driver errors.
class PgError : Exception
{
    string sqlState;

    this(string msg, string sqlState = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.sqlState = sqlState;
    }

    bool isUniqueViolation() const pure nothrow @safe @nogc => sqlState == "23505";
    bool isForeignKeyViolation() const pure nothrow @safe @nogc => sqlState == "23503";
}

/// The query went past its deadline (`PgConfig.queryTimeout`); the server was notified.
final class PgTimeout : PgError
{
    this(string msg = "vela.db: query timed out", string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, "57014", file, line);
    }
}

// ============================================================ values

/// Column/parameter that may be NULL.
struct Maybe(T)
{
    T value;
    bool has;

    this(T v) { value = v; has = true; }
    static Maybe none() { return Maybe.init; }
}

// ============================================================ result
//
// Safety model: everything below talks to libpq through raw pointers, which never leave
// this module. Public entry points are therefore `@trusted` façades: callers in `@safe`
// code cannot reach a libpq pointer, a freed result or an unchecked index (`checkIdx`).
// The only raw view is `PgResult.text`, which is `@system` because the slice dies on `close()`.
@trusted:

/// Result of a query. The `text` slices point to libpq's memory
/// and are valid until `close()` (or until the object is collected): copy with
/// `.idup` whatever you need to keep. `rowsAs` and `get` already copy.
final class PgResult
{
    private PGresult* res;
    private string tag;

    /// Number of rows and columns.
    int rows, cols;

    private this(PGresult* r)
    {
        res = r;
        rows = pq.PQntuples(r);
        cols = pq.PQnfields(r);
    }

    ~this() { close(); }

    void close() nothrow @nogc
    {
        if (res !is null)
        {
            pq.PQclear(res);
            res = null;
        }
    }

    /// Rows affected by INSERT/UPDATE/DELETE ("" for SELECT).
    string affected() const nothrow
    {
        auto p = pq.PQcmdTuples(res);
        return cstr(p).idup;
    }

    bool isNull(int row, int col) const nothrow => pq.PQgetisnull(res, row, col) != 0;

    /// The value as text (zero-copy). Empty for NULL: use `isNull` to tell them apart.
    /// `@system`: the slice points into libpq memory and dangles after `close()`;
    /// from `@safe` code use `get!string` (copies).
    const(char)[] text(int row, int col) const nothrow @system
    {
        checkIdx(row, col);
        return pq.PQgetvalue(res, row, col)[0 .. pq.PQgetlength(res, row, col)];
    }

    /// Index of the column called `name`, or -1.
    int column(const(char)[] name) const nothrow
    {
        foreach (c; 0 .. cols)
            if (cstr(pq.PQfname(res, c)) == name)
                return c;
        return -1;
    }

    /// Converts a cell to `T` (integers, bool, double, string, Maybe!X).
    T get(T)(int row, int col) const
    {
        checkIdx(row, col);
        static if (is(T == Maybe!U, U))
        {
            if (isNull(row, col))
                return T.init;
            return T(get!U(row, col));
        }
        else
        {
            if (isNull(row, col))
                throw new PgError("vela.db: column '" ~ cstr(pq.PQfname(res, col)).idup
                        ~ "' is NULL; use Maybe!" ~ T.stringof ~ " in the field");
            return parseCell!T(text(row, col), cstr(pq.PQfname(res, col)));
        }
    }

    /// Maps all rows to a struct, matching fields and columns by name.
    T[] rowsAs(T)() const if (is(T == struct))
    {
        int[T.tupleof.length] idx;
        static foreach (i, f; T.tupleof)
        {
            idx[i] = column(__traits(identifier, f));
            if (idx[i] < 0)
                throw new PgError("vela.db: the query did not return the column '"
                        ~ __traits(identifier, f) ~ "' expected by " ~ T.stringof);
        }
        auto out_ = new T[rows];
        foreach (r; 0 .. rows)
        {
            static foreach (i, f; T.tupleof)
                mixin("out_[r].", __traits(identifier, f), " = get!(typeof(f))(r, idx[i]);");
        }
        return out_;
    }

    /// First row as a struct; throws if there is none.
    T one(T)() const if (is(T == struct))
    {
        auto all = rowsAs!T;
        if (all.length == 0)
            throw new PgError("vela.db: the query returned no rows");
        return all[0];
    }

    private void checkIdx(int row, int col) const nothrow
    {
        assert(row >= 0 && row < rows && col >= 0 && col < cols, "vela.db: row/column outside the result");
    }
}

private const(char)[] cstr(const(char)* p) nothrow
{
    if (p is null)
        return null;
    size_t n;
    while (p[n])
        n++;
    return p[0 .. n];
}

private T parseCell(T)(const(char)[] s, const(char)[] col)
{
    import std.traits : isIntegral, isSigned, isFloatingPoint, isSomeString;

    static if (is(T == bool))
    {
        if (s == "t") return true;
        if (s == "f") return false;
        throw badCell(col, "bool", s);
    }
    else static if (isIntegral!T)
    {
        size_t i;
        bool neg;
        if (s.length && (s[0] == '-' || s[0] == '+'))
        {
            neg = s[0] == '-';
            i = 1;
        }
        if (i == s.length)
            throw badCell(col, T.stringof, s);
        ulong acc;
        for (; i < s.length; i++)
        {
            immutable d = s[i] - '0';
            if (d < 0 || d > 9 || acc > (ulong.max - d) / 10)
                throw badCell(col, T.stringof, s);
            acc = acc * 10 + d;
        }
        static if (isSigned!T)
        {
            if (neg ? acc > cast(ulong) T.max + 1 : acc > cast(ulong) T.max)
                throw badCell(col, T.stringof, s);
            return cast(T)(neg ? -cast(long) acc : cast(long) acc);
        }
        else
        {
            if ((neg && acc != 0) || acc > T.max)
                throw badCell(col, T.stringof, s);
            return cast(T) acc;
        }
    }
    else static if (isFloatingPoint!T)
    {
        // libpq values are zero-terminated
        const(char)* end;
        auto v = strtod(s.ptr, &end);
        if (end != s.ptr + s.length || s.length == 0)
            throw badCell(col, T.stringof, s);
        return cast(T) v;
    }
    else static if (isSomeString!T)
        return s.idup;
    else
        static assert(0, "vela.db: unsupported field type in rowsAs/get: " ~ T.stringof
                ~ " (use integers, bool, double, string or Maybe!X)");
}

private PgError badCell(const(char)[] col, string type, const(char)[] val)
{
    return new PgError("vela.db: column '" ~ col.idup ~ "' has the value '" ~ val.idup ~ "', which is not " ~ type);
}

// ============================================================ parameters

/// Encodes the parameters as text for PQsendQueryParams.
private struct Encoded(size_t N)
{
    char[] buf;
    const(char)*[N] vals;

    this(Args...)(ref Args args)
    {
        ptrdiff_t[N] offs;
        static foreach (i; 0 .. N)
            offs[i] = put(args[i]);
        foreach (i; 0 .. N)
            vals[i] = offs[i] < 0 ? null : buf.ptr + offs[i];
    }

    private ptrdiff_t put(A)(ref A a)
    {
        import std.traits : isIntegral, isFloatingPoint, isSomeString, Unqual;

        alias U = Unqual!A;
        static if (is(U == typeof(null)))
            return -1;
        else static if (is(U == Maybe!X, X))
            return a.has ? put(a.value) : -1;
        else static if (is(U == bool))
            return append(a ? "t" : "f");
        else static if (isIntegral!U)
        {
            char[24] tmp;
            size_t n = tmp.length;
            bool neg = a < 0;
            ulong v = neg ? -cast(long) a : a;
            do
            {
                tmp[--n] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v);
            if (neg)
                tmp[--n] = '-';
            return append(tmp[n .. $]);
        }
        else static if (isFloatingPoint!U)
        {
            char[40] tmp;
            auto n = snprintf(tmp.ptr, tmp.length, "%.17g", cast(double) a);
            return append(tmp[0 .. n]);
        }
        else static if (isSomeString!U || is(U : const(char)[]))
            return append(a);
        else
            static assert(0, "vela.db: unsupported parameter type: " ~ A.stringof
                    ~ " (use integers, bool, double, string, null or Maybe!X)");
    }

    private ptrdiff_t append(const(char)[] s)
    {
        immutable at = buf.length;
        buf ~= s;
        buf ~= '\0';
        return at;
    }
}

// ============================================================ configuration

struct PgConfig
{
    string conninfo;                      /// "host=... dbname=... user=..." or postgresql:// URI
    uint maxConns = 8;                    /// connections per worker
    Duration connectTimeout = 10.seconds;
    Duration acquireTimeout = 5.seconds;  /// wait for a free connection
    Duration queryTimeout = 30.seconds;   /// deadline of each query
    Duration idleTimeout = 5.minutes;     /// connection idle longer than this is discarded
    /// Prepares each SQL the first time and reuses the plan afterwards (up to 128 per
    /// connection). Off by default: PgBouncer in transaction mode and some proxies
    /// do not accept named statements. Turn it on when talking straight to Postgres/RDS.
    bool cacheStatements = false;
}

// ============================================================ connection

/// A connection. Use it through the pool (`PgPool.acquire`/`query`); one query at a time.
final class PgConn
{
    private PGconn* c;
    private Duration queryTimeout;
    private bool cacheStatements;
    private uint[string] stmts;      // SQL -> prepared statement number on this connection
    private enum maxStatements = 128;
    private MonoTime lastUsed;
    package bool broken;

    private this(PGconn* conn, Duration qt, bool cache)
    {
        c = conn;
        queryTimeout = qt;
        cacheStatements = cache;
        lastUsed = MonoTime.currTime;
    }

    ~this() { shutdown(); }

    /// Closes the connection (idempotent).
    void shutdown() nothrow @nogc
    {
        if (c !is null)
        {
            pq.PQfinish(c);
            c = null;
        }
        broken = true;
    }

    bool usable() const nothrow => c !is null && !broken && pq.PQstatus(c) == CONNECTION_OK;

    /// Opens a connection without blocking the worker.
    static PgConn connect(string conninfo, Duration connectTimeout, Duration queryTimeout, bool cacheStatements = false)
    {
        if (auto err = loadLibpq())
            throw new PgError(err);

        // PQconnectStart resolves DNS synchronously: on a pool thread.
        auto zinfo = (conninfo ~ '\0');
        PGconn* c = offload(() @trusted => pq.PQconnectStart(zinfo.ptr));
        if (c is null)
            throw new PgError("vela.db: PQconnectStart failed (out of memory)");
        auto conn = new PgConn(c, queryTimeout, cacheStatements);
        pq.PQsetNoticeProcessor(c, &silentNotice, null);

        scope (failure)
            conn.shutdown();

        if (pq.PQstatus(c) == CONNECTION_BAD)
            throw new PgError("vela.db: " ~ conn.lastError());
        pq.PQsetnonblocking(c, 1);

        immutable deadline = MonoTime.currTime + connectTimeout;
        int state = PGRES_POLLING_WRITING;
        for (;;)
        {
            immutable left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                throw new PgError("vela.db: timed out while connecting");
            immutable fd = pq.PQsocket(c);
            if (fd < 0)
                throw new PgError("vela.db: " ~ conn.lastError());
            if (state == PGRES_POLLING_READING)
            {
                if (awaitFd(fd, IoEvent.readable, left) == 0)
                    throw new PgError("vela.db: timed out while connecting");
            }
            else if (state == PGRES_POLLING_WRITING)
            {
                if (awaitFd(fd, IoEvent.writable, left) == 0)
                    throw new PgError("vela.db: timed out while connecting");
            }
            state = pq.PQconnectPoll(c);
            if (state == PGRES_POLLING_OK)
                break;
            if (state == PGRES_POLLING_FAILED)
                throw new PgError("vela.db: " ~ conn.lastError());
        }
        return conn;
    }

    /// Runs `sql` with parameters $1..$n and returns the result.
    PgResult query(Args...)(const(char)[] sql, Args args)
    {
        auto enc = Encoded!(Args.length)(args);
        return run(sql, enc.vals[]);
    }

    private void exec_(const(char)[] sql)
    {
        immutable old = cacheStatements;
        cacheStatements = false; // utilities such as DEALLOCATE do not go through the cache
        scope (exit)
            cacheStatements = old;
        run(sql, null, true).close();
    }

    /// Runs a command without caring about the result (BEGIN, UPDATE...).
    void exec(Args...)(const(char)[] sql, Args args)
    {
        query(sql, args).close();
    }

    private PgResult run(const(char)[] sql, const(char)*[] vals, bool retried = false)
    {
        if (!usable)
            throw new PgError("vela.db: connection closed");
        auto zsql = sql ~ '\0';

        bool clean;
        scope (exit)
        {
            lastUsed = MonoTime.currTime;
            if (!clean) // cancellation, deadline or network error midway: the connection does not go back to the pool
                abort();
        }

        immutable deadline = queryTimeout == Duration.max ? MonoTime.max : MonoTime.currTime + queryTimeout;

        bool cached;
        uint stmtNo;
        if (cacheStatements)
        {
            if (auto p = sql in stmts)
            {
                stmtNo = *p;
                cached = true;
            }
            else if (stmts.length < maxStatements)
            {
                stmtNo = cast(uint) stmts.length + 1;
                prepare(sql, zsql, stmtNo, vals.length, deadline);
                stmts[sql.idup] = stmtNo;
                cached = true;
            }
        }

        if (cached)
        {
            char[16] name = stmtName(stmtNo);
            if (!pq.PQsendQueryPrepared(c, name.ptr, cast(int) vals.length,
                    vals.length ? vals.ptr : null, null, null, 0))
                throw new PgError("vela.db: " ~ lastError());
        }
        else if (!pq.PQsendQueryParams(c, zsql.ptr, cast(int) vals.length, null,
                vals.length ? vals.ptr : null, null, null, 0))
            throw new PgError("vela.db: " ~ lastError());

        flush(deadline);

        PGresult* kept;
        bool keptIsError;
        scope (failure)
            if (kept !is null)
                pq.PQclear(kept);

        for (;;)
        {
            waitResult(deadline);
            auto r = pq.PQgetResult(c);
            if (r is null)
                break;
            immutable st = pq.PQresultStatus(r);
            immutable isErr = st == PGRES_FATAL_ERROR || st == PGRES_BAD_RESPONSE;
            if (isErr && !keptIsError)
            {
                if (kept !is null)
                    pq.PQclear(kept);
                kept = r;
                keptIsError = true;
            }
            else if (!isErr && !keptIsError)
            {
                if (kept !is null)
                    pq.PQclear(kept);
                kept = r; // the last result of the command counts
            }
            else
                pq.PQclear(r);
        }
        clean = true;

        if (kept is null)
            throw new PgError("vela.db: the server returned no result");
        if (keptIsError)
        {
            auto state = cstr(pq.PQresultErrorField(kept, PG_DIAG_SQLSTATE)).idup;
            auto msg = cstr(pq.PQresultErrorMessage(kept)).idup;
            pq.PQclear(kept);
            kept = null;
            if (cached && state == "0A000" && !retried)
            {
                // "cached plan must not change result type" (ALTER TABLE after preparing):
                // forget the statement and repeat once
                stmts.remove(cast(string) sql);
                exec_("DEALLOCATE ALL");
                stmts = null;
                return run(sql, vals, true);
            }
            throw new PgError(trimEol(msg), state);
        }
        return new PgResult(kept);
    }

    /// Prepares `sql` as statement `no` and waits for the server's confirmation.
    private void prepare(const(char)[] sql, const(char)[] zsql, uint no, size_t nparams, MonoTime deadline)
    {
        char[16] name = stmtName(no);
        if (!pq.PQsendPrepare(c, name.ptr, zsql.ptr, cast(int) nparams, null))
            throw new PgError("vela.db: " ~ lastError());
        flush(deadline);
        PGresult* err;
        for (;;)
        {
            waitResult(deadline);
            auto r = pq.PQgetResult(c);
            if (r is null)
                break;
            immutable st = pq.PQresultStatus(r);
            if ((st == PGRES_FATAL_ERROR || st == PGRES_BAD_RESPONSE) && err is null)
                err = r;
            else
                pq.PQclear(r);
        }
        if (err !is null)
        {
            auto state = cstr(pq.PQresultErrorField(err, PG_DIAG_SQLSTATE)).idup;
            auto msg = trimEol(cstr(pq.PQresultErrorMessage(err)).idup);
            pq.PQclear(err);
            throw new PgError(msg, state);
        }
    }

    private static char[16] stmtName(uint no) pure nothrow @nogc @safe
    {
        char[16] n = 0;
        n[0] = 'v';
        n[1] = 'e';
        size_t i = 2;
        char[10] t;
        size_t k = t.length;
        do
        {
            t[--k] = cast(char)('0' + no % 10);
            no /= 10;
        }
        while (no);
        n[i .. i + (t.length - k)] = t[k .. $];
        return n;
    }

    /// Finishes sending the query (the output buffer may not fit all at once).
    private void flush(MonoTime deadline)
    {
        for (;;)
        {
            immutable f = pq.PQflush(c);
            if (f == 0)
                return;
            if (f < 0)
                throw new PgError("vela.db: " ~ lastError());
            immutable ev = awaitFd(pq.PQsocket(c), IoEvent.writable | IoEvent.readable, left(deadline));
            if (ev == 0)
                throw new PgTimeout;
            if (ev & IoEvent.readable)
                if (!pq.PQconsumeInput(c))
                    throw new PgError("vela.db: " ~ lastError());
        }
    }

    /// Waits until `PQgetResult` can return without blocking.
    private void waitResult(MonoTime deadline)
    {
        while (pq.PQisBusy(c))
        {
            if (awaitFd(pq.PQsocket(c), IoEvent.readable, left(deadline)) == 0)
                throw new PgTimeout;
            if (!pq.PQconsumeInput(c))
                throw new PgError("vela.db: " ~ lastError());
        }
    }

    private static Duration left(MonoTime deadline)
    {
        if (deadline == MonoTime.max)
            return Duration.max;
        immutable d = deadline - MonoTime.currTime;
        return d <= Duration.zero ? Duration.zero : d;
    }

    /// Asks the server to cancel what is running and closes the connection.
    /// The cancellation opens another TCP connection; it goes to the thread pool so
    /// it does not hold the worker (if the pool is full, it does it right away).
    private void abort() nothrow
    {
        if (c is null)
            return;
        auto cancel = pq.PQgetCancel(c);
        if (cancel !is null)
        {
            bool queued;
            try
                queued = offloadPool().submit(() { sendCancel(cancel); });
            catch (Throwable)
                queued = false;
            if (!queued)
                sendCancel(cancel);
        }
        shutdown();
    }

    private static void sendCancel(PGcancel* cancel) nothrow
    {
        char[256] err;
        pq.PQcancel(cancel, err.ptr, cast(int) err.length);
        pq.PQfreeCancel(cancel);
    }

    private string lastError() nothrow
    {
        return trimEol(cstr(pq.PQerrorMessage(c)).idup);
    }
}

private extern (C) void silentNotice(void*, const(char)*) nothrow
{
}

private string trimEol(string s) pure nothrow @safe
{
    while (s.length && (s[$ - 1] == '\n' || s[$ - 1] == '\r'))
        s = s[0 .. $ - 1];
    return s;
}

// ============================================================ pool

private final class Waiter
{
    int efd = -1;
    PgConn conn;     /// handed over directly by release()
    bool signaled;
}

/// Connection pool of ONE worker (not thread-safe on purpose: each worker
/// has its own, see `pgPool`).
final class PgPool
{
    private PgConfig cfg;
    private PgConn[] idle;
    private uint open;
    private Waiter[] waiters;

    this(PgConfig cfg)
    {
        assert(cfg.maxConns > 0, "vela.db: maxConns must be > 0");
        this.cfg = cfg;
    }

    /// Open connections (idle + lent out) and idle ones.
    uint openCount() const nothrow => open;
    size_t idleCount() const nothrow => idle.length;

    /// Takes a connection, opening another if there is room or waiting for a free one.
    /// Give it back with `release` (or use `lease`/`query`).
    PgConn acquire()
    {
        immutable deadline = MonoTime.currTime + cfg.acquireTimeout;
        for (;;)
        {
            while (idle.length)
            {
                auto c = idle[$ - 1];
                idle = idle[0 .. $ - 1];
                if (c.usable && MonoTime.currTime - c.lastUsed < cfg.idleTimeout)
                    return c;
                c.shutdown();
                open--;
            }
            if (open < cfg.maxConns)
            {
                open++;
                try
                    return PgConn.connect(cfg.conninfo, cfg.connectTimeout, cfg.queryTimeout, cfg.cacheStatements);
                catch (Throwable t)
                {
                    open--;
                    wakeOne(null); // someone waiting may try to open theirs
                    throw t;
                }
            }

            // pool full: join the queue and wait for a return
            auto w = new Waiter;
            w.efd = eventfd(0, 0x800 | 0x80000);
            if (w.efd < 0)
                throw new PgError("vela.db: eventfd failed");
            waiters ~= w;
            bool served;
            scope (exit)
            {
                removeWaiter(w);
                close(w.efd);
                if (!served && w.signaled)
                {
                    // we were woken but left before using it (deadline/cancellation):
                    // pass the connection (or the slot) on to the next in the queue
                    if (w.conn !is null)
                        release(w.conn);
                    else
                        wakeOne(null);
                }
            }
            immutable left = deadline - MonoTime.currTime;
            if (left <= Duration.zero || awaitFd(w.efd, IoEvent.readable, left) == 0)
                throw new PgError("vela.db: connection pool exhausted (all in use for more than "
                        ~ "acquireTimeout)");
            served = true;
            if (w.conn !is null)
                return w.conn;
            // woken without a connection: one was discarded; try again
        }
    }

    /// Gives the connection back. Broken/closed: it is discarded and frees the slot.
    void release(PgConn c) nothrow
    {
        if (c is null)
            return;
        if (!c.usable)
        {
            c.shutdown();
            open--;
            wakeOne(null);
            return;
        }
        if (wakeOne(c))
            return;
        idle ~= c;
    }

    /// Wakes the first in the queue, handing over `c` (may be null = "free slot").
    private bool wakeOne(PgConn c) nothrow
    {
        foreach (i, w; waiters)
        {
            if (w.signaled)
                continue;
            w.signaled = true;
            w.conn = c;
            ulong one = 1;
            write(w.efd, &one, one.sizeof);
            return true;
        }
        return false;
    }

    private void removeWaiter(Waiter w) nothrow
    {
        foreach (i, x; waiters)
            if (x is w)
            {
                waiters = waiters[0 .. i] ~ waiters[i + 1 .. $];
                return;
            }
    }

    /// Lends a connection for a scope: returned by itself on exit.
    Lease lease() => Lease(this, acquire());

    /// Shortcut: takes a connection, runs and gives it back.
    PgResult query(Args...)(const(char)[] sql, Args args)
    {
        auto l = lease();
        return l.conn.query(sql, args);
    }

    void exec(Args...)(const(char)[] sql, Args args)
    {
        query(sql, args).close();
    }

    /// Runs `body` inside BEGIN/COMMIT on the same connection; ROLLBACK if it throws.
    T transaction(T)(T delegate(PgConn) @safe body_)
    {
        auto l = lease();
        l.conn.exec("BEGIN");
        try
        {
            static if (is(T == void))
            {
                body_(l.conn);
                l.conn.exec("COMMIT");
            }
            else
            {
                auto r = body_(l.conn);
                l.conn.exec("COMMIT");
                return r;
            }
        }
        catch (Throwable t)
        {
            if (l.conn.usable)
            {
                try
                    l.conn.exec("ROLLBACK");
                catch (Throwable)
                    l.conn.shutdown();
            }
            throw t;
        }
    }

    /// Closes all idle connections.
    void closeAll() nothrow
    {
        foreach (c; idle)
        {
            c.shutdown();
            open--;
        }
        idle = null;
    }
}

/// Connection lent out; returns to the pool in the destructor.
struct Lease
{
    private PgPool pool;
    PgConn conn;

    @disable this(this);

    private this(PgPool p, PgConn c) { pool = p; conn = c; }

    ~this()
    {
        if (pool !is null)
            pool.release(conn);
    }
}

private PgPool[string] tlsPools; // thread-local: one pool per worker

/// This worker's pool for `conninfo` (created on first use). Call it from
/// inside the handlers: each thread/worker gets its own, with no locks.
PgPool pgPool(string conninfo, uint maxConns = 8)
{
    if (auto p = conninfo in tlsPools)
        return *p;
    PgConfig cfg;
    cfg.conninfo = conninfo;
    cfg.maxConns = maxConns;
    return tlsPools[conninfo] = new PgPool(cfg);
}

/// Same, with the full configuration.
PgPool pgPool(PgConfig cfg)
{
    if (auto p = cfg.conninfo in tlsPools)
        return *p;
    return tlsPools[cfg.conninfo] = new PgPool(cfg);
}
