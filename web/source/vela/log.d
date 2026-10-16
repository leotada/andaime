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
///
/// `setLogSink` sends the lines somewhere else, as a `LogRecord` (level, message, request id, fields, and the rendered
/// line); `vela.web.testing.captureLog` collects them in tests.
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

/// One field of a `LogRecord`: the key and the value as text (a string as it is; a number, `true`/`false` or an enum as
/// written; any other type as its JSON).
struct LogField
{
    const(char)[] key;
    const(char)[] value;
}

/// A log line before it is written, as a `LogSink` gets it. The slices point into per-thread buffers that the next line
/// reuses: they are valid only during the call, so copy what you keep.
struct LogRecord
{
    LogLevel level;
    const(char)[] message;
    /// The request id of the running request (empty outside one).
    const(char)[] requestId;
    /// The fields of the line, in order: the layer's (`job`, `job_id`, `attempt` in `perform`), then the call's.
    const(LogField)[] fields;
    /// The line exactly as it would be written to stderr (in the current format, newline included).
    const(char)[] line;
}

/// Where lines go instead of stderr. See `setLogSink`.
alias LogSink = void delegate(scope ref const LogRecord) @safe;

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

private __gshared LogSink gSink;
private LogSink threadSink; // per thread: takes precedence over gSink
private bool inSink; // per thread: a sink that logs would clobber the line it is handed

/// Sends every line to `sink` instead of stderr (to a log shipper, journald, a file...): the sink gets the level, the
/// message, the request id and the fields, and the rendered line. `null` goes back to stderr. Call it once before
/// `serve`: the workers read it without a lock. The sink runs on the thread that logged, so it must be thread-safe, and it
/// must not log (a line logged from inside a sink is dropped). Lines below the level never reach it, and neither do
/// the few engine messages that are still written straight to stderr (see `docs/logging.md`).
void setLogSink(LogSink sink) @system nothrow @nogc
{
    gSink = sink;
}

/// Sends the lines logged by the calling thread to `sink` (or back to the process-wide sink and stderr, for `null`) and
/// returns the previous one, to restore it. For tests: `vela.web.testing.captureLog` uses it.
LogSink setThreadLogSink(LogSink sink) nothrow @nogc
{
    auto prev = threadSink;
    threadSink = sink;
    return prev;
}

private LogSink currentSink() nothrow @nogc @trusted
{
    // @trusted: gSink is written by setLogSink before the workers start and only read afterwards
    return threadSink !is null ? threadSink : gSink;
}

/// Whether lines go to a sink (so a caller that formats a line itself for stderr must hand it over as text instead).
package(vela) bool logSinkActive() nothrow @nogc => currentSink() !is null;

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

/// Fields added to every line logged by the code a layer runs: the job runner adds `job`, `job_id` and `attempt` to the
/// lines of `perform`. Values are rendered when the scope is built.
final class LogScope
{
    private string[] keys, values;
    private bool[] numbers;

    /// Adds a text field.
    LogScope add(string key, string value) pure nothrow
    {
        keys ~= key;
        values ~= value;
        numbers ~= false;
        return this;
    }

    /// Adds a number field (bare in JSON).
    LogScope add(string key, long value) pure nothrow
    {
        import vela.web.numtext : itoa;

        keys ~= key;
        values ~= itoa(value);
        numbers ~= true;
        return this;
    }
}

/// Per thread: the request id (or the `LogScope`) of the code whose fiber is running, installed by the server and by
/// `runJobs` on each worker thread. True when called from such a fiber, even when it has neither.
private bool function(out const(char)[] id, out LogScope fields) @safe nothrow fiberSource;
/// Per thread: the request being handled without fibers (`TestClient`, the development server), set by `App.handle`.
private const(char)[] delegate() @safe nothrow syncSource;
/// Per thread: the scope of the code running without fibers (`TestJobStore.drainJobs`).
private LogScope syncScope;

package(vela) void setLogFiberSource(bool function(out const(char)[] id, out LogScope fields) @safe nothrow src) nothrow @nogc
{
    fiberSource = src;
}

/// Sets the per-thread scope (code that runs without fibers) and returns the previous one.
package(vela) LogScope setLogSyncScope(LogScope s) nothrow @nogc
{
    auto prev = syncScope;
    syncScope = s;
    return prev;
}

/// Sets the per-thread source and returns the previous one (to restore after the request).
package(vela) const(char)[] delegate() @safe nothrow setLogSyncSource(const(char)[] delegate() @safe nothrow src) nothrow @nogc
{
    auto prev = syncSource;
    syncSource = src;
    return prev;
}

/// The request id and the scope of the running code.
private void currentContext(out const(char)[] id, out LogScope fields) nothrow
{
    if (fiberSource !is null && fiberSource(id, fields))
        return;
    id = syncSource is null ? null : syncSource();
    fields = syncScope;
}

// ------------------------------------------------------------ writing

private ByteBuffer line; // per thread, reused: an emitted line allocates nothing after the first ones

private void emit(Args...)(LogLevel level, scope const(char)[] legacy, bool hasLegacy, scope const(char)[] msg,
    ref Args fields) nothrow
{
    if (inSink)
        return; // logged from inside a sink: the line the sink holds must stay intact (see setLogSink)
    try
    {
        line.clear();
        immutable fmt = logFormat();
        const(char)[] rid;
        LogScope scoped;
        currentContext(rid, scoped);
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
                putScope(line, scoped, false);
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
                putScope(line, scoped, false);
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
                putScope(line, scoped, true);
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
        if (auto sink = currentSink())
            deliver(sink, level, msg, rid, scoped, line.data, fields);
        else
            writeStderr(line.data);
        if (line.capacity > 64 << 10)
            line = ByteBuffer.init; // a huge stack trace does not stay pinned to the thread
    }
    catch (Exception)
    {
        // a value that cannot be written loses its line, never the request
    }
}

private LogField[] recFields; // per thread, reused by `deliver`
private ByteBuffer recValues; // per thread: the values of `recFields` that are not strings

/// Hands the line to `sink` with its parts. Allocates only while the per-thread buffers grow.
private void deliver(Args...)(LogSink sink, LogLevel level, scope const(char)[] msg, scope const(char)[] rid,
    LogScope scoped, scope const(char)[] text, ref Args fields)
{
    inSink = true;
    scope (exit)
        inSink = false;

    enum n = Args.length / 2;
    immutable ns = scoped is null ? 0 : scoped.keys.length;
    if (recFields.length < ns + n)
        recFields = new LogField[ns + n];
    recValues.clear();
    size_t[2][n] spans;
    if (scoped !is null)
        foreach (i, k; scoped.keys)
            setField(i, k, scoped.values[i]);
    static foreach (i; 0 .. n)
    {
        static if (is(Args[2 * i + 1] : const(char)[]))
            setField(ns + i, fields[2 * i], fields[2 * i + 1]);
        else
        {
            spans[i][0] = recValues.length;
            putRaw(recValues, fields[2 * i + 1]);
            spans[i][1] = recValues.length;
        }
    }
    // the values were written first because the buffer may move while it grows
    static foreach (i; 0 .. n)
    {
        static if (!is(Args[2 * i + 1] : const(char)[]))
            setField(ns + i, fields[2 * i], recValues.data[spans[i][0] .. spans[i][1]]);
    }
    const rec = LogRecord(level, msg, rid, recFields[0 .. ns + n], text);
    sink(rec);
}

private void setField(size_t i, scope const(char)[] key, scope const(char)[] value) nothrow @nogc @trusted
{
    // @trusted: the field is read only during the sink call, which `LogRecord` documents; the next line overwrites it
    recFields[i] = LogField(key, value);
}

/// A field value as plain text: numbers and booleans as written, a JSON string without its quotes, anything else as JSON.
private void putRaw(T)(ref ByteBuffer o, ref T v)
{
    static if (is(T == bool))
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
    else
    {
        scratchValue.clear();
        writeJson(scratchValue, v);
        auto s = scratchValue.data;
        bool plain = s.length >= 2 && s[0] == '"' && s[$ - 1] == '"';
        if (plain)
            foreach (c; s)
                if (c == '\\')
                {
                    plain = false;
                    break;
                }
        o.put(plain ? s[1 .. $ - 1] : s);
    }
}

/// The fields of `s`, after the request id: ` key=value` (text, kv) or `,"key":value` (json).
private void putScope(ref ByteBuffer o, LogScope s, bool json) nothrow
{
    if (s is null)
        return;
    foreach (i, k; s.keys)
    {
        if (json)
        {
            o.put(',');
            writeJsonString(o, k);
            o.put(':');
            if (s.numbers[i])
                o.put(s.values[i]);
            else
                writeJsonString(o, s.values[i]);
        }
        else
        {
            o.put(' ');
            o.put(k);
            o.put('=');
            putText(o, s.values[i], false);
        }
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
    long secs;
    int ms;
    version (linux)
    {
        // @trusted: clock_gettime writes one timespec
        import core.sys.posix.time : clock_gettime, timespec, CLOCK_REALTIME;

        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        secs = ts.tv_sec;
        ms = cast(int)(ts.tv_nsec / 1_000_000);
    }
    else version (Posix)
    {
        import core.sys.posix.sys.time : gettimeofday, timeval;

        timeval tv;
        gettimeofday(&tv, null);
        secs = tv.tv_sec;
        ms = cast(int)(tv.tv_usec / 1_000);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : FILETIME, GetSystemTimeAsFileTime;

        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        ulong t100ns = (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime;
        // Intervals between 1601-01-01 and 1970-01-01: 11644473600 seconds
        long unix100ns = cast(long)(t100ns - 116_444_736_000_000_000UL);
        secs = unix100ns / 10_000_000L;
        ms = cast(int)((unix100ns % 10_000_000L) / 10_000L);
        if (ms < 0) ms = 0;
    }
    else
    {
        import core.stdc.time : time;
        secs = time(null);
        ms = 0;
    }
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
    import core.stdc.errno : errno, EINTR;

    size_t off;
    while (off < s.length)
    {
        ptrdiff_t n;
        version (Posix)
        {
            import core.sys.posix.unistd : write;
            n = write(2, s.ptr + off, s.length - off);
        }
        else version (Windows)
        {
            extern (C) int _write(int fd, const(void)* buffer, uint count) nothrow @nogc;
            n = _write(2, s.ptr + off, cast(uint)(s.length - off));
        }
        else
        {
            import core.stdc.stdio : fwrite, stderr;
            n = fwrite(s.ptr + off, 1, s.length - off, stderr);
        }
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
    version (Windows)
    {
        private extern (C) nothrow @nogc
        {
            int _pipe(int* pfds, uint psize, int textmode);
            int _dup(int fd);
            int _dup2(int fd1, int fd2);
            int _close(int fd);
            int _read(int fd, void* buffer, uint count);
        }
    }

    /// Captures what `emit` would write (the unittests run without a terminal to read).
    private string render(Args...)(LogFormat fmt, LogLevel level, const(char)[] msg, Args fields)
    {
        immutable oldFmt = atomicLoad(gFormat);
        atomicStore(gFormat, cast(ubyte) fmt);
        atomicStore(gEnvRead, true);
        scope (exit)
            atomicStore(gFormat, oldFmt);
        version (Posix)
        {
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
        else version (Windows)
        {
            int[2] p;
            string got;
            () @trusted {
                _pipe(p.ptr, 4096, 0x8000 /*_O_BINARY*/);
                immutable saved = _dup(2);
                _dup2(p[1], 2);
                emit(level, null, false, msg, fields);
                _dup2(saved, 2);
                _close(saved);
                _close(p[1]);
                char[4096] buf;
                auto n = _read(p[0], buf.ptr, cast(uint) buf.length);
                _close(p[0]);
                got = buf[0 .. n > 0 ? n : 0].idup;
            }();
            return got;
        }
        else
        {
            return "";
        }
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
