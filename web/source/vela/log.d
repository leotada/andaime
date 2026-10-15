/// `vela.log`: a structured logger on stderr.
///
///     logInfo("user created", "user_id", id, "plan", plan);
///     logWarn("payment retried", "attempt", n);
///
/// Levels: `debug_`, `info`, `warn`, `error` (and `off`). Formats:
/// - `text` (the default): the message and `key=value` fields, and vela's own lines exactly as before;
/// - `kv`: `time=2026-10-14T12:00:00.123Z level=info msg="user created" request_id=4f2a user_id=7 plan=pro`;
/// - `json`: one object per line with the same fields.
/// Inside a request, `request_id` (from the `requestId` middleware) is added by itself. Set the level and the format with
/// `configureLog` or with the `VELA_LOG_LEVEL` / `VELA_LOG_FORMAT` environment variables (the environment wins, so a
/// deployment can turn on `debug` without a rebuild).
///
/// A line below the level costs two loads and allocates nothing; an emitted line is built in a reused per-thread buffer
/// and written with one write(2), so lines from different workers do not interleave.
module vela.log;

@safe:

import core.atomic : atomicLoad, atomicStore;
import vela.http.buffer : ByteBuffer;
import vela.web.json : writeJson, writeJsonString;
import vela.web.numtext : ctNum;

/// How important a line is. `off` turns logging off.
enum LogLevel : ubyte
{
    debug_,
    info,
    warn,
    error,
    off,
}

/// How lines are written (see the module comment).
enum LogFormat : ubyte
{
    text,
    kv,
    json,
}

private shared ubyte gLevel = LogLevel.info;
private shared ubyte gFormat = LogFormat.text;
private shared bool gEnvRead;

/// Sets the level and the format for the whole process (any thread, any time; usually in `main`). `VELA_LOG_LEVEL` and
/// `VELA_LOG_FORMAT`, when set, still win.
void configureLog(LogLevel level, LogFormat format = LogFormat.text) nothrow
{
    atomicStore(gLevel, cast(ubyte) level);
    atomicStore(gFormat, cast(ubyte) format);
    applyEnvironment();
}

/// The current level.
LogLevel logLevel() nothrow @nogc
{
    readEnvironmentOnce();
    return cast(LogLevel) atomicLoad(gLevel);
}

/// The current format.
LogFormat logFormat() nothrow @nogc
{
    readEnvironmentOnce();
    return cast(LogFormat) atomicLoad(gFormat);
}

/// Whether a line of `level` would be written.
bool logEnabled(LogLevel level) nothrow @nogc => level != LogLevel.off && level >= logLevel();

/// A line at `level` with the message and fields given as pairs: `logAt(LogLevel.info, "done", "items", 3)`.
/// Field values: strings, numbers, booleans, enums, or anything `writeJson` writes (written as JSON).
void logAt(Args...)(LogLevel level, scope const(char)[] msg, auto ref Args fields)
{
    static if (fieldsError!Args.length)
        static assert(0, fieldsError!Args);
    else if (logEnabled(level))
        emit(level, null, false, msg, fields);
}

/// ditto, at each level.
void logDebug(Args...)(scope const(char)[] msg, auto ref Args fields)
{
    static if (fieldsError!Args.length)
        static assert(0, fieldsError!Args);
    else if (logEnabled(LogLevel.debug_))
        emit(LogLevel.debug_, null, false, msg, fields);
}

/// ditto
void logInfo(Args...)(scope const(char)[] msg, auto ref Args fields)
{
    static if (fieldsError!Args.length)
        static assert(0, fieldsError!Args);
    else if (logEnabled(LogLevel.info))
        emit(LogLevel.info, null, false, msg, fields);
}

/// ditto
void logWarn(Args...)(scope const(char)[] msg, auto ref Args fields)
{
    static if (fieldsError!Args.length)
        static assert(0, fieldsError!Args);
    else if (logEnabled(LogLevel.warn))
        emit(LogLevel.warn, null, false, msg, fields);
}

/// ditto
void logError(Args...)(scope const(char)[] msg, auto ref Args fields)
{
    static if (fieldsError!Args.length)
        static assert(0, fieldsError!Args);
    else if (logEnabled(LogLevel.error))
        emit(LogLevel.error, null, false, msg, fields);
}

/// One line saying what is wrong with the fields `Args`, or "".
private template fieldsError(Args...)
{
    enum string fieldsError = () {
        if (Args.length % 2)
            return "vela: log fields come in pairs (\"key\", value), but " ~ ctNum(Args.length) ~ " were given";
        static foreach (i; 0 .. Args.length / 2)
            static if (!is(Args[2 * i] : const(char)[]))
                return "vela: a log field key must be a string, but key " ~ ctNum(i + 1) ~ " is '"
                    ~ Args[2 * i].stringof ~ "'";
        return "";
    }();
}

/// For vela's own lines: in the `text` format `legacy` is written exactly as before (no fields, no request id); in `kv`
/// and `json` the line is `msg` with `fields`.
package(vela) void logVela(Args...)(LogLevel level, scope const(char)[] legacy, scope const(char)[] msg, auto ref Args fields)
{
    if (!logEnabled(level))
        return;
    emit(level, legacy, true, msg, fields);
}

// ------------------------------------------------------------ the request id

/// Per thread: the request id of the request whose fiber is running (installed by the server on each worker thread; true
/// when called from a request fiber, even when it has no id).
private bool function(out const(char)[] id) @safe nothrow fiberSource;
/// Per thread: the request being handled without fibers (`TestClient`, the development server), set by `App.handle`.
private const(char)[] delegate() @safe nothrow syncSource;

package(vela) void setLogFiberSource(bool function(out const(char)[] id) @safe nothrow src) nothrow @nogc
{
    fiberSource = src;
}

/// Sets the per-thread source and returns the previous one (to restore after the request).
package(vela) const(char)[] delegate() @safe nothrow setLogSyncSource(const(char)[] delegate() @safe nothrow src) nothrow @nogc
{
    auto prev = syncSource;
    syncSource = src;
    return prev;
}

private const(char)[] currentRequestId() nothrow
{
    const(char)[] id;
    if (fiberSource !is null && fiberSource(id))
        return id;
    return syncSource is null ? null : syncSource();
}

// ------------------------------------------------------------ writing

private ByteBuffer line; // per thread, reused: an emitted line allocates nothing after the first ones

private void emit(Args...)(LogLevel level, scope const(char)[] legacy, bool hasLegacy, scope const(char)[] msg,
    ref Args fields) nothrow
{
    try
    {
        line.clear();
        immutable fmt = logFormat();
        auto rid = currentRequestId();
        final switch (fmt)
        {
            case LogFormat.text:
                if (hasLegacy)
                {
                    line.put(legacy);
                    break;
                }
                line.put(msg);
                if (rid.length)
                {
                    line.put(" request_id=");
                    putText(line, rid, false);
                }
                static foreach (i; 0 .. Args.length / 2)
                {
                    line.put(' ');
                    line.put(fields[2 * i]);
                    line.put('=');
                    putValue(line, fields[2 * i + 1], false);
                }
                break;
            case LogFormat.kv:
                line.put("time=");
                putTime(line);
                line.put(" level=");
                line.put(levelName(level));
                line.put(" msg=");
                putText(line, msg, false);
                if (rid.length)
                {
                    line.put(" request_id=");
                    putText(line, rid, false);
                }
                static foreach (i; 0 .. Args.length / 2)
                {
                    line.put(' ');
                    line.put(fields[2 * i]);
                    line.put('=');
                    putValue(line, fields[2 * i + 1], false);
                }
                break;
            case LogFormat.json:
                line.put(`{"time":"`);
                putTime(line);
                line.put(`","level":"`);
                line.put(levelName(level));
                line.put(`","msg":`);
                writeJsonString(line, msg);
                if (rid.length)
                {
                    line.put(`,"request_id":`);
                    writeJsonString(line, rid);
                }
                static foreach (i; 0 .. Args.length / 2)
                {
                    line.put(',');
                    writeJsonString(line, fields[2 * i]);
                    line.put(':');
                    putValue(line, fields[2 * i + 1], true);
                }
                line.put('}');
                break;
        }
        line.put('\n');
        writeStderr(line.data);
        if (line.capacity > 64 << 10)
            line = ByteBuffer.init; // a huge stack trace does not stay pinned to the thread
    }
    catch (Exception)
    {
        // a value that cannot be written loses its line, never the request
    }
}

private string levelName(LogLevel l) pure nothrow @nogc
{
    final switch (l)
    {
        case LogLevel.debug_: return "debug";
        case LogLevel.info: return "info";
        case LogLevel.warn: return "warn";
        case LogLevel.error: return "error";
        case LogLevel.off: return "off";
    }
}

/// Text as a value: bare when it is a plain word, else a JSON string (always one in JSON).
private void putText(ref ByteBuffer o, scope const(char)[] s, bool json) nothrow
{
    bool bare = !json && s.length > 0;
    foreach (char c; s)
        if (c <= ' ' || c == '"' || c == '=' || c == '\\' || c == 0x7f)
        {
            bare = false;
            break;
        }
    if (bare)
        o.put(s);
    else
        writeJsonString(o, s);
}

private ByteBuffer scratchValue; // per thread: a value rendered as JSON before it is quoted for `kv`

private void putValue(T)(ref ByteBuffer o, ref T v, bool json)
{
    static if (is(T : const(char)[]))
        putText(o, v, json);
    else static if (is(T == bool))
        o.put(v ? "true" : "false");
    else static if (__traits(isIntegral, T) && !is(T == enum) && !is(T == char) && !is(T == wchar) && !is(T == dchar))
    {
        static if (__traits(isUnsigned, T))
            o.putUint(v);
        else
            o.putInt(v);
    }
    else static if (__traits(isFloating, T))
        o.putFloat(v);
    else if (json)
        writeJson(o, v);
    else
    {
        scratchValue.clear();
        writeJson(scratchValue, v);
        auto s = scratchValue.data;
        if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
            o.put(s); // already a quoted string (an enum, a text type)
        else
            putText(o, s, false);
    }
}

/// `2026-10-14T12:34:56.789Z` (UTC, milliseconds).
private void putTime(ref ByteBuffer o) nothrow @trusted
{
    // @trusted: clock_gettime writes one timespec
    import core.sys.posix.time : clock_gettime, timespec, CLOCK_REALTIME;

    timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long secs = ts.tv_sec;
    immutable ms = cast(int)(ts.tv_nsec / 1_000_000);
    long days = secs / 86_400;
    long rem = secs % 86_400;
    // civil date from days since 1970-01-01 (H. Hinnant's algorithm)
    immutable z = days + 719_468;
    immutable era = (z >= 0 ? z : z - 146_096) / 146_097;
    immutable doe = z - era * 146_097;
    immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    immutable mp = (5 * doy + 2) / 153;
    immutable d = doy - (153 * mp + 2) / 5 + 1;
    immutable m = mp < 10 ? mp + 3 : mp - 9;
    immutable y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    char[24] b;
    void two(size_t at, long v) { b[at] = cast(char)('0' + v / 10 % 10); b[at + 1] = cast(char)('0' + v % 10); }
    two(0, y / 100);
    two(2, y % 100);
    b[4] = '-';
    two(5, m);
    b[7] = '-';
    two(8, d);
    b[10] = 'T';
    two(11, rem / 3600);
    b[13] = ':';
    two(14, rem / 60 % 60);
    b[16] = ':';
    two(17, rem % 60);
    b[19] = '.';
    b[20] = cast(char)('0' + ms / 100);
    two(21, ms % 100);
    b[23] = 'Z';
    o.put(b[]);
}

private void writeStderr(scope const(char)[] s) nothrow @trusted
{
    // @trusted: write(2) reads at most s.length - off bytes from inside s
    import core.sys.posix.unistd : write;
    import core.stdc.errno : errno, EINTR;

    size_t off;
    while (off < s.length)
    {
        immutable n = write(2, s.ptr + off, s.length - off);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            return;
        }
        off += n;
    }
}

// ------------------------------------------------------------ the environment

private void readEnvironmentOnce() nothrow @nogc
{
    if (!atomicLoad(gEnvRead))
        applyEnvironment();
}

private void applyEnvironment() nothrow @nogc @trusted
{
    // @trusted: getenv returns a NUL-terminated string owned by the environment, read here and not kept
    import core.stdc.stdlib : getenv;

    static const(char)[] env(const(char)* name) nothrow @nogc @system
    {
        auto p = getenv(name);
        if (p is null)
            return null;
        size_t n;
        while (p[n])
            n++;
        return p[0 .. n];
    }

    switch (env("VELA_LOG_LEVEL"))
    {
        case "debug": atomicStore(gLevel, cast(ubyte) LogLevel.debug_); break;
        case "info": atomicStore(gLevel, cast(ubyte) LogLevel.info); break;
        case "warn", "warning": atomicStore(gLevel, cast(ubyte) LogLevel.warn); break;
        case "error": atomicStore(gLevel, cast(ubyte) LogLevel.error); break;
        case "off", "none": atomicStore(gLevel, cast(ubyte) LogLevel.off); break;
        default: break; // unset or unknown: keep the configured level
    }
    switch (env("VELA_LOG_FORMAT"))
    {
        case "text": atomicStore(gFormat, cast(ubyte) LogFormat.text); break;
        case "kv", "logfmt": atomicStore(gFormat, cast(ubyte) LogFormat.kv); break;
        case "json": atomicStore(gFormat, cast(ubyte) LogFormat.json); break;
        default: break;
    }
    atomicStore(gEnvRead, true);
}


// ------------------------------------------------------------ tests

version (unittest)
{
    /// Captures what `emit` would write (the unittests run without a terminal to read).
    private string render(Args...)(LogFormat fmt, LogLevel level, const(char)[] msg, Args fields)
    {
        immutable oldFmt = atomicLoad(gFormat);
        atomicStore(gFormat, cast(ubyte) fmt);
        atomicStore(gEnvRead, true);
        scope (exit)
            atomicStore(gFormat, oldFmt);
        // emit writes to stderr; render the same line by calling the formatter through a redirected fd
        import core.sys.posix.unistd : pipe, dup, dup2, close, read;

        int[2] p;
        string got;
        () @trusted {
            pipe(p);
            immutable saved = dup(2);
            dup2(p[1], 2);
            emit(level, null, false, msg, fields);
            dup2(saved, 2);
            close(saved);
            close(p[1]);
            char[4096] buf;
            auto n = read(p[0], buf.ptr, buf.length);
            close(p[0]);
            got = buf[0 .. n > 0 ? n : 0].idup;
        }();
        return got;
    }
}

unittest
{
    enum Plan { free, pro }
    struct Extra { int a; string b; }

    assert(render(LogFormat.text, LogLevel.info, "user created", "user_id", 7, "plan", Plan.pro, "note", "two words")
        == "user created user_id=7 plan=\"pro\" note=\"two words\"\n");
    auto kv = render(LogFormat.kv, LogLevel.warn, "slow", "ms", 12.5, "ok", false, "extra", Extra(1, "x"));
    assert(kv[0 .. 5] == "time=" && kv[29 .. $] == " level=warn msg=slow ms=12.5 ok=false extra=\"{\\\"a\\\":1,\\\"b\\\":\\\"x\\\"}\"\n", kv);
    auto js = render(LogFormat.json, LogLevel.error, "boom \"x\"\n", "n", -3L, "extra", Extra(1, "x"));
    assert(js[0 .. 9] == `{"time":"` && js[33 .. $] == `","level":"error","msg":"boom \"x\"\n","n":-3,"extra":{"a":1,"b":"x"}}` ~ "\n", js);
    auto t = js[9 .. 33];
    assert(t[4] == '-' && t[10] == 'T' && t[19] == '.' && t[23] == 'Z' && t[0 .. 2] == "20", t);

    // the request id comes from the current source
    auto prev = setLogSyncSource(() => "req-1");
    assert(render(LogFormat.text, LogLevel.info, "hi") == "hi request_id=req-1\n");
    assert(render(LogFormat.kv, LogLevel.info, "hi")[29 .. $] == " level=info msg=hi request_id=req-1\n");
    setLogSyncSource(prev);
    assert(render(LogFormat.text, LogLevel.info, "hi") == "hi\n");

    // levels
    immutable oldLevel = atomicLoad(gLevel);
    scope (exit)
        atomicStore(gLevel, oldLevel);
    atomicStore(gLevel, cast(ubyte) LogLevel.warn);
    assert(!logEnabled(LogLevel.info) && logEnabled(LogLevel.warn) && logEnabled(LogLevel.error) && !logEnabled(LogLevel.off));
    atomicStore(gLevel, cast(ubyte) LogLevel.off);
    assert(!logEnabled(LogLevel.error));
}
