/// andaime.log through real requests: the default `text` format keeps andaime's lines as they were; `kv` and `json` add time,
/// level, the request id and structured fields; levels filter; the environment overrides the code.
module logging_test;

import andaime;
import andaime.web.testing;
import std.json : parseJSON, JSONValue;
import std.string : splitLines, indexOf, startsWith;

string hello(Context ctx) @safe
{
    logInfo("saying hello", "who", "Ana", "n", 2);
    logDebug("hidden at info");
    return "hi";
}

string boom() @safe { throw new Exception("kaput"); }

App build()
{
    auto app = new App;
    app.use(requestId());
    app.use(accessLog());
    app.get!("/hello", hello);
    app.get!("/boom", boom);
    return app;
}

version (Windows)
{
    private extern (C) nothrow @nogc
    {
        int _pipe(int* pfds, uint psize, int textmode);
        int _dup(int fd);
        int _dup2(int fd1, int fd2);
        int _close(int fd);
        int _read(int fd, void* buffer, uint count);
        int _putenv_s(const(char)* name, const(char)* value);
    }
}

/// What the requests in `dg` wrote to stderr.
string[] captureStderr(void delegate() dg) @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : pipe, dup, dup2, close, read;
        import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

        int[2] p;
        pipe(p);
        fcntl(p[0], F_SETFL, O_NONBLOCK);
        immutable saved = dup(2);
        dup2(p[1], 2);
        dg();
        dup2(saved, 2);
        close(saved);
        close(p[1]);
        char[] all;
        char[4096] buf;
        for (;;)
        {
            auto n = read(p[0], buf.ptr, buf.length);
            if (n <= 0)
                break;
            all ~= buf[0 .. n];
        }
        close(p[0]);
        return (cast(string) all).splitLines;
    }
    else version (Windows)
    {
        int[2] p;
        _pipe(p.ptr, 65_536, 0x8000 /*_O_BINARY*/);
        immutable saved = _dup(2);
        _dup2(p[1], 2);
        dg();
        _dup2(saved, 2);
        _close(saved);
        _close(p[1]);
        char[] all;
        char[4096] buf;
        for (;;)
        {
            auto n = _read(p[0], buf.ptr, cast(uint) buf.length);
            if (n <= 0)
                break;
            all ~= buf[0 .. n];
        }
        _close(p[0]);
        return (cast(string) all).splitLines;
    }
}

unittest
{
    // the default: today's lines, byte for byte (no time, no level), and the user's line with its request id
    configureLog(LogLevel.info, LogFormat.text);
    auto c = TestClient(build());
    auto lines = captureStderr({
        c.get("/hello", hdr("X-Request-Id", "req-42"));
        c.get("/boom", hdr("X-Request-Id", "req-43"));
    });
    assert(lines[0] == "saying hello request_id=req-42 who=Ana n=2", lines[0]);
    assert(lines[1].startsWith("GET /hello 200 ") && lines[1].indexOf("ms ip=127.0.0.1 rid=req-42") > 0, lines[1]);
    assert(lines[2].startsWith("andaime: error in GET /boom: object.Exception@") && lines[2].indexOf("kaput") > 0, lines[2]);
    assert(lines[$ - 1].startsWith("GET /boom 500 ") && lines[$ - 1].indexOf("rid=req-43") > 0, lines[$ - 1]);
}

unittest
{
    // json: one object per line, with the request id of the request that wrote it
    configureLog(LogLevel.info, LogFormat.json);
    scope (exit)
        configureLog(LogLevel.info, LogFormat.text);
    auto c = TestClient(build());
    auto lines = captureStderr({
        c.get("/hello", hdr("X-Request-Id", "req-1"));
        c.get("/boom", hdr("X-Request-Id", "req-2"));
    });
    assert(lines.length == 4, lines.length ? lines[$ - 1] : "nothing");
    auto mine = parseJSON(lines[0]);
    assert(mine["level"].str == "info" && mine["msg"].str == "saying hello" && mine["request_id"].str == "req-1");
    assert(mine["who"].str == "Ana" && mine["n"].integer == 2 && mine["time"].str.length == 24);
    auto access = parseJSON(lines[1]);
    assert(access["msg"].str == "request" && access["method"].str == "GET" && access["target"].str == "/hello");
    assert(access["status"].integer == 200 && access["request_id"].str == "req-1" && access["ip"].str == "127.0.0.1");
    assert("duration_us" in access.object);
    auto err = parseJSON(lines[2]);
    assert(err["level"].str == "error" && err["msg"].str == "error in handler" && err["path"].str == "/boom");
    assert(err["error"].str.indexOf("kaput") > 0 && err["request_id"].str == "req-2", lines[2]);
    assert(parseJSON(lines[3])["status"].integer == 500);
}

unittest
{
    // kv, and the level: warn hides info (the access log too) but keeps errors
    configureLog(LogLevel.warn, LogFormat.kv);
    scope (exit)
        configureLog(LogLevel.info, LogFormat.text);
    auto c = TestClient(build());
    auto lines = captureStderr({
        c.get("/hello", hdr("X-Request-Id", "r1"));
        c.get("/boom", hdr("X-Request-Id", "r2"));
    });
    assert(lines.length == 1, lines.length ? lines[0] : "nothing");
    assert(lines[0].startsWith("time=") && lines[0].indexOf(" level=error msg=\"error in handler\" request_id=r2 method=GET path=/boom error=\"") > 0,
        lines[0]);
}

unittest
{
    // the environment wins over the code
    version (Posix)
    {
        import core.sys.posix.stdlib : setenv, unsetenv;

        () @trusted { setenv("ANDAIME_LOG_LEVEL", "error", 1); setenv("ANDAIME_LOG_FORMAT", "json", 1); }();
    }
    else version (Windows)
    {
        () @trusted { _putenv_s("ANDAIME_LOG_LEVEL", "error"); _putenv_s("ANDAIME_LOG_FORMAT", "json"); }();
    }
    configureLog(LogLevel.debug_, LogFormat.text);
    assert(logLevel == LogLevel.error && logFormat == LogFormat.json);
    version (Posix)
    {
        import core.sys.posix.stdlib : unsetenv;

        () @trusted { unsetenv("ANDAIME_LOG_LEVEL"); unsetenv("ANDAIME_LOG_FORMAT"); }();
    }
    else version (Windows)
    {
        () @trusted { _putenv_s("ANDAIME_LOG_LEVEL", ""); _putenv_s("ANDAIME_LOG_FORMAT", ""); }();
    }
    configureLog(LogLevel.info, LogFormat.text);
    assert(logLevel == LogLevel.info && logFormat == LogFormat.text);

    // outside a request there is no request id
    auto lines = captureStderr({ logWarn("startup", "port", 8080); });
    assert(lines == ["startup port=8080"], lines.length ? lines[0] : "nothing");
}

// ------------------------------------------------------------ the sink

enum Plan { free, pro }
struct Extra { int a; string b; }

void fields(Context ctx) @safe
{
    logWarn("shaped", "n", 7, "f", 1.5, "ok", true, "plan", Plan.pro, "name", "Ana Maria", "extra", Extra(1, "x"), "u", 3UL);
}

unittest
{
    // captureLog: level, message, request id and fields, without touching stderr
    configureLog(LogLevel.info, LogFormat.text);
    auto app = new App;
    app.use(requestId());
    app.get!("/fields", fields);
    app.get!("/hello", hello);
    auto c = TestClient(app);
    string[] onStderr;
    CapturedLog[] logs;
    onStderr = captureStderr({
        logs = captureLog({ c.get("/fields", hdr("X-Request-Id", "r-9")); c.get("/hello"); });
    });
    assert(onStderr.length == 0, onStderr[0]);
    assert(logs.length == 2, "two lines expected");
    assert(logs[0].level == LogLevel.warn && logs[0].message == "shaped" && logs[0].requestId == "r-9");
    assert(logs[0].field("n") == "7" && logs[0].field("f") == "1.5" && logs[0].field("ok") == "true");
    assert(logs[0].field("plan") == "pro", logs[0].field("plan"));
    assert(logs[0].field("name") == "Ana Maria" && logs[0].field("u") == "3");
    assert(logs[0].field("extra") == `{"a":1,"b":"x"}`, logs[0].field("extra"));
    assert(logs[0].has("n") && !logs[0].has("nope") && logs[0].field("nope") is null);
    // fields keep their order, and the rendered line is what stderr would have got
    assert(logs[0].fields[0][0] == "n" && logs[0].fields[$ - 1][0] == "u");
    assert(logs[0].line == `shaped request_id=r-9 n=7 f=1.5 ok=true plan="pro" name="Ana Maria" extra="{\"a\":1,\"b\":\"x\"}" u=3` ~ "\n",
        logs[0].line);
    assert(logs[1].message == "saying hello" && logs[1].requestId.length > 0 && logs[1].field("who") == "Ana");
}

unittest
{
    // the format only changes `line`; a filtered line never reaches the sink
    configureLog(LogLevel.info, LogFormat.json);
    scope (exit)
        configureLog(LogLevel.info, LogFormat.text);
    auto c = TestClient(build());
    auto logs = captureLog({ c.get("/hello", hdr("X-Request-Id", "j1")); });
    assert(logs.length == 2); // the user's line, then the access log
    auto parsed = parseJSON(logs[0].line);
    assert(parsed["msg"].str == logs[0].message && parsed["who"].str == "Ana" && parsed["level"].str == "info");
    assert(logs[1].message == "request" && logs[1].field("status") == "200" && logs[1].field("method") == "GET");
    assert(logs[1].has("duration_us") && logs[1].requestId == "j1");

    configureLog(LogLevel.error, LogFormat.json);
    assert(captureLog({ c.get("/hello"); }).length == 0);
}

unittest
{
    // andaime's own lines in the text format reach the sink as the legacy text, with fields: the access log and a 500
    configureLog(LogLevel.info, LogFormat.text);
    auto c = TestClient(build());
    auto logs = captureLog({ c.get("/boom", hdr("X-Request-Id", "e1")); });
    assert(logs.length == 2, "the 500 line and the access line");
    assert(logs[0].level == LogLevel.error && logs[0].message == "error in handler" && logs[0].field("path") == "/boom");
    assert(logs[0].line.startsWith("andaime: error in GET /boom: "), logs[0].line);
    assert(logs[1].message == "request" && logs[1].field("status") == "500");
    assert(logs[1].line.startsWith("GET /boom 500 ") && logs[1].line.indexOf("rid=e1") > 0, logs[1].line);
}

unittest
{
    // an invalid response header is logged as a warning that names the header, never its value
    configureLog(LogLevel.info, LogFormat.text);
    auto app = new App;
    app.get!("/bad", (Context ctx) @safe { ctx.setHeader("X-Bad", "a\r\nInjected: 1"); return "x"; });
    auto c = TestClient(app);
    TestResponse r;
    auto logs = captureLog({ r = c.get("/bad"); });
    assert(r.status == 500);
    assert(logs.length == 1 && logs[0].level == LogLevel.warn);
    assert(logs[0].line.indexOf("X-Bad") > 0 && logs[0].line.indexOf("Injected") < 0, logs[0].line);
}

unittest
{
    // setLogSink: the process-wide sink gets the lines; a thread sink wins over it; null goes back to stderr
    configureLog(LogLevel.info, LogFormat.text);
    string[] seen;
    () @trusted { setLogSink((scope ref const LogRecord r) @safe { seen ~= r.message.idup; }); }();
    scope (exit)
        () @trusted { setLogSink(null); }();
    assert(captureStderr({ logInfo("to the sink"); }).length == 0);
    assert(seen == ["to the sink"]);

    string[] mine;
    auto prev = setThreadLogSink((scope ref const LogRecord r) @safe { mine ~= r.message.idup; });
    logInfo("to the thread sink");
    setThreadLogSink(prev);
    assert(mine == ["to the thread sink"] && seen.length == 1);

    () @trusted { setLogSink(null); }();
    assert(captureStderr({ logInfo("back"); }) == ["back"]);
    assert(seen.length == 1);
}

unittest
{
    // a sink that logs does not recurse and does not corrupt the line it was handed
    configureLog(LogLevel.info, LogFormat.text);
    string first;
    auto prev = setThreadLogSink((scope ref const LogRecord r) @safe {
        first = r.line.idup;
        logInfo("from inside the sink"); // dropped
        assert(r.line == first, "the line was clobbered");
    });
    scope (exit)
        setThreadLogSink(prev);
    logInfo("outer", "k", 1);
    assert(first == "outer k=1\n", first);
}
