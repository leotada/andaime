/// vela.log lines written inside `perform` carry `job`, `job_id` and `attempt`, like a request's lines carry its id.
module job_logging;

import vela.jobs;
import vela.log;
import std.string : splitLines, indexOf;

@Job("default")
struct Greet
{
    string who;

    void perform(ref JobContext ctx) @safe
    {
        logInfo("greeting", "who", who);
    }
}

/// What `dg` wrote to stderr.
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
    auto store = new TestJobStore;
    enqueue(store, Greet("Ana"));
    enqueue(store, Greet("Bia"));

    configureLog(LogLevel.info, LogFormat.kv);
    scope (exit) configureLog(LogLevel.info, LogFormat.text);
    auto lines = captureStderr(() { store.drainJobs!Greet(); });
    assert(lines.length == 2, lines.length ? lines[0] : "no lines");
    assert(lines[0].indexOf(`msg=greeting job=job_logging.Greet job_id=1 attempt=1 who=Ana`) > 0, lines[0]);
    assert(lines[1].indexOf(`job_id=2 attempt=1 who=Bia`) > 0, lines[1]);

    // JSON: numbers stay numbers
    enqueue(store, Greet("Cid"));
    configureLog(LogLevel.info, LogFormat.json);
    lines = captureStderr(() { store.drainJobs!Greet(); });
    assert(lines.length == 1 && lines[0].indexOf(`"job":"job_logging.Greet","job_id":3,"attempt":1,"who":"Cid"`) > 0,
        lines[0]);

    // outside perform the scope is gone
    lines = captureStderr(() { logInfo("after"); });
    assert(lines.length == 1 && lines[0].indexOf("job") < 0, lines[0]);
}
