/// vela.log through real requests: the default `text` format keeps vela's lines as they were; `kv` and `json` add time,
/// level, the request id and structured fields; levels filter; the environment overrides the code.
module logging_test;

import vela;
import vela.web.testing;
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

/// What the requests in `dg` wrote to stderr.
string[] captureStderr(void delegate() dg) @trusted
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
    assert(lines[2].startsWith("vela: error in GET /boom: object.Exception@") && lines[2].indexOf("kaput") > 0, lines[2]);
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
    import core.sys.posix.stdlib : setenv, unsetenv;

    () @trusted { setenv("VELA_LOG_LEVEL", "error", 1); setenv("VELA_LOG_FORMAT", "json", 1); }();
    configureLog(LogLevel.debug_, LogFormat.text);
    assert(logLevel == LogLevel.error && logFormat == LogFormat.json);
    () @trusted { unsetenv("VELA_LOG_LEVEL"); unsetenv("VELA_LOG_FORMAT"); }();
    configureLog(LogLevel.info, LogFormat.text);
    assert(logLevel == LogLevel.info && logFormat == LogFormat.text);

    // outside a request there is no request id
    auto lines = captureStderr({ logWarn("startup", "port", 8080); });
    assert(lines == ["startup port=8080"], lines.length ? lines[0] : "nothing");
}
