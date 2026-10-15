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

import vela.http.texttype : isTextType, textFromString, textToString;
import vela.http.naming : applyNaming, namingOf, parseEnumWire, enumToWire;
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

/// A column or parameter that may be NULL is an `Optional!T`: an empty one is SQL NULL (the same type the web layer uses,
/// so a row serializes to JSON `null` with no conversion). Re-exported here for convenience.
public import vela.http.optional : Optional;

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

    /// Converts a cell to `T` (integers, bool, double, string, Optional!X).
    T get(T)(int row, int col) const
    {
        checkIdx(row, col);
        static if (is(T == Optional!U, U))
        {
            if (isNull(row, col))
                return T.init;
            return T(get!U(row, col));
        }
        else
        {
            if (isNull(row, col))
                throw new PgError("vela.db: column '" ~ cstr(pq.PQfname(res, col)).idup
                        ~ "' is NULL; use Optional!" ~ T.stringof ~ " in the field");
            return parseCell!T(text(row, col), cstr(pq.PQfname(res, col)));
        }
    }

    /// Maps all rows to a struct, matching fields and columns by name. A field's column is its `@column("name")`, else
    /// its name spelled with the struct's `@naming` (`@naming(Naming.snakeCase)`: `firstName` reads `first_name`). A
    /// struct field marked `@prefix("author_")` (or an `Optional` of a struct) takes its fields from the columns with that
    /// prefix (`author_id`, `author_first_name`...: the prefix goes before the nested struct's own names); an `Optional`
    /// one is empty when all of its columns are NULL (a LEFT JOIN that found nothing). A missing column throws.
    T[] rowsAs(T)() const if (is(T == struct))
    {
        int[rowColumnCount!T] idx;
        size_t k;
        resolveColumns!T(idx[], k, null);
        auto out_ = new T[rows];
        foreach (r; 0 .. rows)
        {
            k = 0;
            fillRow(out_[r], r, idx[], k);
        }
        return out_;
    }

    /// The column index of every leaf field of `T` (depth first, in field order), with `pre` before each name.
    private void resolveColumns(T)(int[] idx, ref size_t k, string pre) const
    {
        static foreach (i, f; T.tupleof)
        {{
            alias F = typeof(f);
            enum p = prefixOf!(T, i);
            static if (p.length)
                resolveColumns!(NestedRow!F)(idx, k, pre ~ p);
            else
            {
                immutable name = pre ~ columnNameOf!(T, i);
                idx[k] = column(name);
                if (idx[k] < 0)
                    throw new PgError("vela.db: the query did not return the column '" ~ name ~ "' expected by "
                        ~ T.stringof);
                k++;
            }
        }}
    }

    private void fillRow(T)(ref T dest, int r, const(int)[] idx, ref size_t k) const
    {
        static foreach (i, f; T.tupleof)
        {{
            alias F = typeof(f);
            static if (prefixOf!(T, i).length)
            {
                static if (is(F == Optional!S, S))
                {
                    enum n = rowColumnCount!S;
                    bool allNull = true;
                    foreach (j; k .. k + n)
                        allNull &= isNull(r, idx[j]);
                    if (allNull)
                    {
                        dest.tupleof[i] = F.init;
                        k += n;
                    }
                    else
                    {
                        S s;
                        fillRow(s, r, idx, k);
                        dest.tupleof[i] = F(s);
                    }
                }
                else
                    fillRow(dest.tupleof[i], r, idx, k);
            }
            else
                dest.tupleof[i] = get!F(r, idx[k++]);
        }}
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

/// Maps a struct field of a row to the columns that start with `value`: `@prefix("author_") Optional!UserSummary author;`
/// (see `PgResult.rowsAs`).
struct prefix
{
    string value;
}

/// The column of a row field when it differs from the field's name: `@column("created_at") SysTime created;`
/// (see `PgResult.rowsAs`; `@naming` on the struct names all of its fields at once).
struct column
{
    string name;
}

/// The column name of field `i` of `T` (without the `@prefix` of an enclosing field).
private template columnNameOf(T, size_t i)
{
    enum string columnNameOf = () {
        string r = applyNaming(__traits(identifier, T.tupleof[i]), namingOf!T);
        static foreach (a; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(a) == column))
                r = a.name;
        return r;
    }();
}

/// The `@prefix` of field `i` of `T`, or "".
private template prefixOf(T, size_t i)
{
    enum prefixOf = () {
        string r;
        static foreach (a; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(a) == prefix))
                r = a.value;
        return r;
    }();
    static if (prefixOf.length)
        static assert(is(NestedRow!(typeof(T.tupleof[i])) == struct) && !isTextType!(NestedRow!(typeof(T.tupleof[i]))),
            "vela.db: @prefix applies to a struct or Optional!struct field, but '" ~ __traits(identifier, T.tupleof[i])
            ~ "' of " ~ T.stringof ~ " is " ~ typeof(T.tupleof[i]).stringof);
}

/// The struct a `@prefix` field holds (unwrapping `Optional`).
private template NestedRow(F)
{
    static if (is(F == Optional!S, S))
        alias NestedRow = S;
    else
        alias NestedRow = F;
}

/// How many columns a row struct reads (nested `@prefix` fields count their own columns).
private template rowColumnCount(T)
{
    enum size_t rowColumnCount = () {
        size_t n;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (prefixOf!(T, i).length)
                n += rowColumnCount!(NestedRow!(typeof(T.tupleof[i])));
            else
                n++;
        }
        return n;
    }();
}

private string itoaU(uint v) pure nothrow
{
    char[10] t;
    size_t n = t.length;
    do
    {
        t[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    return t[n .. $].idup;
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
    else static if (is(T == enum))
    {
        // by wire name (`@naming`, `@wireName`): the label of a Postgres enum, or text
        T v;
        if (!parseEnumWire(s, v))
            throw badCell(col, T.stringof, s);
        return v;
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
    else static if (isTextType!T)
    {
        // your own type (a Uuid, a timestamp...): `fromString` reads the column's text
        T v;
        if (!textFromString(s, v))
            throw badCell(col, T.stringof, s);
        return v;
    }
    else static if (is(T == E[], E))
    {
        static assert(!is(immutable E == immutable ubyte) && !is(immutable E == immutable byte),
            "vela.db: " ~ T.stringof ~ " in rowsAs/get is ambiguous (bytea or an array?); read bytea as string or use int[]");
        static assert(!is(E == F[], F) || isSomeString!E,
            "vela.db: nested arrays are not supported in rowsAs/get (" ~ T.stringof ~ "); read the column as string");
        return parseArray!E(s, col);
    }
    else
        static assert(0, "vela.db: unsupported field type in rowsAs/get: " ~ T.stringof
                ~ " (use integers, bool, double, string, an enum, a text type with fromString/toString, or Optional!X)");
}

/// A one-dimensional Postgres array literal (`{1,2}`, `{"a b","x\"y",NULL}`, `{}`) -> `E[]`. Each element is read like a
/// cell of type `E`; a `NULL` element needs `E` to be an `Optional`. A multidimensional array, or one with explicit bounds
/// (`[0:1]={...}`), throws.
private E[] parseArray(E)(const(char)[] s, const(char)[] col)
{
    if (s.length < 2 || s[0] != '{' || s[$ - 1] != '}')
        throw badCell(col, E.stringof ~ "[] (a one-dimensional array)", s);
    auto inner = s[1 .. $ - 1];
    E[] result;
    if (inner.length == 0)
        return result;
    char[] text; // one element, NUL-terminated (`parseCell` of a float calls strtod)
    size_t i = 0;
    while (true)
    {
        text.length = 0;
        bool quoted, isNull;
        if (i < inner.length && inner[i] == '{')
            throw new PgError("vela.db: column '" ~ col.idup ~ "' is a multidimensional array; read it as string");
        if (i < inner.length && inner[i] == '"')
        {
            quoted = true;
            i++;
            while (true)
            {
                if (i >= inner.length)
                    throw badCell(col, E.stringof ~ "[]", s);
                immutable c = inner[i++];
                if (c == '"')
                    break;
                if (c == '\\')
                {
                    if (i >= inner.length)
                        throw badCell(col, E.stringof ~ "[]", s);
                    text ~= inner[i++];
                }
                else
                    text ~= c;
            }
        }
        else
        {
            while (i < inner.length && inner[i] != ',')
                text ~= inner[i++];
            isNull = text == "NULL";
        }
        static if (is(E == Optional!X, X))
        {
            if (isNull)
                result ~= E.init;
            else
            {
                text ~= '\0';
                result ~= E(parseCell!X(text[0 .. $ - 1], col));
            }
        }
        else
        {
            if (isNull)
                throw new PgError("vela.db: column '" ~ col.idup ~ "' has a NULL element; use Optional!(" ~ E.stringof
                    ~ ")[] in the field");
            text ~= '\0';
            result ~= parseCell!E(text[0 .. $ - 1], col);
        }
        if (i == inner.length)
            return result;
        if (inner[i] != ',')
            throw badCell(col, E.stringof ~ "[]", s);
        i++;
    }
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
        else static if (is(U == Optional!X, X))
            return a.has ? put(a.get) : -1;
        else static if (is(U == bool))
            return append(a ? "t" : "f");
        else static if (is(U == enum))
        {
            // by wire name, for a Postgres enum (`$1::task_type`) or a text column
            auto w = enumToWire(a);
            if (w is null)
                throw new PgError("vela.db: " ~ U.stringof ~ " parameter holds a value that is no member of the enum");
            return append(w);
        }
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
        else static if (isTextType!U)
        {
            // your own type: `toString` writes the text the server will parse ($1::uuid)
            string text;
            textToString(a, (scope const(char)[] piece) { text ~= piece; });
            return append(text);
        }
        else static if (is(U == E[], E))
        {
            // an array literal for `= any($1::uuid[])`: every element quoted (so commas, braces, spaces and the word NULL
            // stay data), `"` and `\` escaped; an empty Optional element is NULL
            static assert(!is(immutable E == immutable ubyte) && !is(immutable E == immutable byte),
                "vela.db: " ~ A.stringof ~ " as a parameter is ambiguous (bytea or an array?); encode bytea as hex text "
                ~ "('\\x...') or pass int[]");
            static assert(!is(E == F[], F) || isSomeString!E || is(E : const(char)[]),
                "vela.db: nested arrays are not supported as parameters (" ~ A.stringof ~ ")");
            char[] lit;
            lit ~= '{';
            foreach (i, ref e; a)
            {
                if (i)
                    lit ~= ',';
                arrayElement(lit, e);
            }
            lit ~= '}';
            return append(lit);
        }
        else
            static assert(0, "vela.db: unsupported parameter type: " ~ A.stringof
                    ~ " (use integers, bool, double, string, an enum, a text type with fromString/toString, an array of those, "
                    ~ "null or Optional!X)");
    }

    /// One element of an array literal, quoted.
    private static void arrayElement(E)(ref char[] lit, ref E e)
    {
        import std.traits : Unqual;

        alias V = Unqual!E;
        static if (is(V == Optional!X, X))
        {
            if (!e.has)
            {
                lit ~= "NULL";
                return;
            }
            arrayElement(lit, e.get);
        }
        else
        {
            // the element's text, as a parameter would encode it
            Encoded!1 one;
            immutable at = one.put(e);
            assert(at >= 0);
            auto text = one.buf[at .. $ - 1]; // without the NUL
            lit ~= '"';
            foreach (c; text)
            {
                if (c == '"' || c == '\\')
                    lit ~= '\\';
                lit ~= c;
            }
            lit ~= '"';
        }
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
    /// Called after every statement a pooled connection runs, successful or not (see `QueryEvent`): count queries in a
    /// test, log the slow ones. It runs on the request's fiber, so `vela.log` lines carry the request id. Null: nothing.
    QueryHook onQuery;
}

/// The access mode of a `transaction`.
enum TxMode
{
    readWrite, /// `BEGIN`
    readOnly,  /// `BEGIN READ ONLY`: writes fail (SQLSTATE 25006), and the server can skip some bookkeeping
}

/// What `PgConfig.onQuery` (or `PgConn.onQuery`) receives.
struct QueryEvent
{
    const(char)[] sql;  /// the statement, as given (valid during the call: `.idup` to keep it)
    Duration duration;  /// from sending it to the last result
    int rows = -1;      /// rows returned (0 for a command without rows), or -1 when it failed
    string error;       /// the failure's message, or null
    string sqlState;    /// Postgres' code of the failure (`23505`...), or null
    bool internal;      /// a statement vela issued itself: `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`...
}

/// The type of `PgConfig.onQuery`. It may throw; the exception reaches the caller of the query.
alias QueryHook = void delegate(ref const QueryEvent) @safe;

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

    /// Called after every statement this connection runs (see `QueryEvent`). The pool sets it from `PgConfig.onQuery`.
    QueryHook onQuery;

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

    /// libpq's socket, or -1. The descriptor stays owned by the connection: wait on it, do not close it.
    int socket() const nothrow => c is null ? -1 : pq.PQsocket(c);

    /// Pulls bytes already queued on the socket into libpq. False when the connection has failed.
    /// Does not block: the socket is non-blocking, and libpq stops at EAGAIN.
    bool consumeInput() nothrow => c !is null && pq.PQconsumeInput(c) != 0;

    /// Copies the next notification already sitting in libpq, then frees libpq's node.
    /// False when nothing is buffered. Call `consumeInput` first so a payload that just
    /// arrived on the socket is visible. The strings are copies; the node does not outlive this call.
    bool popNotify(out string channel, out string payload)
    {
        channel = null;
        payload = null;
        if (c is null)
            return false;
        auto n = pq.PQnotifies(c);
        if (n is null)
            return false;
        scope (exit)
            pq.PQfreeNotify(n); // the C strings inside the node die with it; copy them first
        channel = cstr(n.relname).idup;
        payload = cstr(n.extra).idup;
        return true;
    }

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
        return observed(sql, enc.vals[], false);
    }

    private void exec_(const(char)[] sql)
    {
        immutable old = cacheStatements;
        cacheStatements = false; // utilities such as DEALLOCATE do not go through the cache
        scope (exit)
            cacheStatements = old;
        observed(sql, null, true).close();
    }

    /// `run`, reported to `onQuery`. `internal` statements (vela's own) are also the ones `run` must not repeat.
    private PgResult observed(const(char)[] sql, const(char)*[] vals, bool internal)
    {
        if (onQuery is null)
            return run(sql, vals, internal);
        immutable start = MonoTime.currTime;
        PgResult r;
        try
            r = run(sql, vals, internal);
        catch (Exception e)
        {
            auto pe = cast(PgError) e;
            auto ev = QueryEvent(sql, MonoTime.currTime - start, -1, e.msg, pe is null ? null : pe.sqlState, internal);
            onQuery(ev);
            throw e;
        }
        auto ev = QueryEvent(sql, MonoTime.currTime - start, r.rows, null, null, internal);
        onQuery(ev);
        return r;
    }

    /// Runs a command without caring about the result (BEGIN, UPDATE...).
    void exec(Args...)(const(char)[] sql, Args args)
    {
        query(sql, args).close();
    }

    /// Whether a transaction is open on this connection (also when it failed and waits for ROLLBACK).
    bool inTransaction() const nothrow
    {
        if (c is null)
            return false;
        immutable s = pq.PQtransactionStatus(c);
        return s == PQTRANS_INTRANS || s == PQTRANS_INERROR;
    }

    /// Runs `body` inside a transaction on this connection: BEGIN/COMMIT, ROLLBACK if it throws. When a transaction is
    /// already open (an outer `transaction`, or a test harness's), it is a `savepoint` instead, so transactions nest; a
    /// savepoint keeps the outer transaction's mode. `TxMode.readOnly` begins with `BEGIN READ ONLY`: a write in `body`
    /// fails with SQLSTATE 25006.
    T transaction(T)(T delegate(PgConn) @safe body_, TxMode mode = TxMode.readWrite)
    {
        if (inTransaction)
            return savepoint(body_);
        exec_(mode == TxMode.readOnly ? "BEGIN READ ONLY" : "BEGIN");
        return finishBlock(body_, "COMMIT", "ROLLBACK");
    }

    /// Runs `body` inside a savepoint of the open transaction: `SAVEPOINT`, then `RELEASE` on success or
    /// `ROLLBACK TO SAVEPOINT` if it throws (the outer transaction goes on, without what the body did). Throws `PgError`
    /// when no transaction is open.
    T savepoint(T)(T delegate(PgConn) @safe body_)
    {
        if (!inTransaction)
            throw new PgError("vela.db: savepoint needs an open transaction (use transaction)");
        immutable name = "vela_sp_" ~ itoaU(++savepoints);
        scope (exit)
            savepoints--;
        exec_("SAVEPOINT " ~ name);
        return finishBlock(body_, "RELEASE SAVEPOINT " ~ name, "ROLLBACK TO SAVEPOINT " ~ name);
    }

    private uint savepoints; // depth of the open `savepoint`s, for their names

    /// Runs the body of a transaction or savepoint: `commit` after it, `rollback` if it throws (a connection that cannot
    /// roll back is closed, so it never goes back to the pool mid-transaction).
    private T finishBlock(T)(T delegate(PgConn) @safe body_, string commit, string rollback)
    {
        try
        {
            static if (is(T == void))
            {
                body_(this);
                exec_(commit);
            }
            else
            {
                auto r = body_(this);
                exec_(commit);
                return r;
            }
        }
        catch (Throwable t)
        {
            if (usable)
            {
                try
                    exec_(rollback);
                catch (Throwable)
                    shutdown();
            }
            throw t;
        }
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
    private PgConn pinned; // see `pin`

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
        if (pinned !is null)
            return pinned;
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
                {
                    auto c = PgConn.connect(cfg.conninfo, cfg.connectTimeout, cfg.queryTimeout, cfg.cacheStatements);
                    c.onQuery = cfg.onQuery;
                    return c;
                }
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
        if (c is null || c is pinned)
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

    /// Runs `body` inside BEGIN/COMMIT on the same connection; ROLLBACK if it throws (see `PgConn.transaction`; on a
    /// pinned connection that is already in a transaction, it becomes a savepoint).
    T transaction(T)(T delegate(PgConn) @safe body_, TxMode mode = TxMode.readWrite)
    {
        auto l = lease();
        return l.conn.transaction(body_, mode);
    }

    /// For tests: every `acquire` (and so `query`, `exec`, `transaction`, `lease`) hands out `c` until `unpin`, and giving
    /// it back keeps it pinned. With a transaction open on `c`, everything the code under test does runs inside it, and
    /// its own transactions become savepoints. One request at a time: a connection runs one query at a time.
    void pin(PgConn c)
    {
        assert(c !is null, "vela.db: pin(null); use unpin");
        pinned = c;
    }

    /// Stops handing out the pinned connection (it is not closed, nor returned to the pool).
    void unpin() nothrow
    {
        pinned = null;
    }

    /// For tests: runs `body` on a pinned connection inside a transaction that is always rolled back, so whatever it
    /// writes through this pool disappears afterwards: `db.rollbackAfter({ client.post("/users", ...); });`.
    void rollbackAfter(void delegate() @safe body_)
    {
        auto c = PgConn.connect(cfg.conninfo, cfg.connectTimeout, cfg.queryTimeout, cfg.cacheStatements);
        scope (exit)
            c.shutdown();
        c.exec_("BEGIN");
        pin(c);
        scope (exit)
            unpin();
        scope (exit)
            if (c.usable)
                c.exec_("ROLLBACK");
        // the hook sees the app's statements, not the harness's BEGIN and ROLLBACK
        c.onQuery = cfg.onQuery;
        scope (exit)
            c.onQuery = null;
        body_();
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
