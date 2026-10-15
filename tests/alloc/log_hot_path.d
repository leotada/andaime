/// vela.log on the hot path: a line below the level allocates nothing, and neither does an emitted `kv` or `json` line
/// (the access log, a handler's own line with the request id) once the per-thread buffer has grown.
import vela;
import vela.http : splitTarget;
import core.memory : GC;
import core.stdc.stdio : printf;

struct Out { long id; }

Out calc(long id) @safe
{
    logDebug("below the level", "id", id);          // filtered: must cost nothing
    logInfo("calc", "id", id, "ok", true, "f", 1.5); // emitted (to /dev/null)
    return Out(id);
}

ulong run(App app, LogFormat format)
{
    configureLog(LogLevel.info, format);
    auto ctx = new Context;
    Request req;
    req.method = Method.GET;
    req.target = "/calc/21";
    splitTarget(req.target, req.path, req.query);
    foreach (i; 0 .. 100) // warm-up: buffers grow once
    {
        ctx.reset(req);
        app.handle(ctx);
    }
    immutable before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 20_000)
    {
        ctx.reset(req);
        app.handle(ctx);
    }
    assert(ctx.response.body.data == `{"id":21}`);
    return GC.allocatedInCurrentThread - before;
}

void main()
{
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.sys.posix.unistd : dup, dup2, close;

    // the lines go to /dev/null; restored for the result
    immutable saved = dup(2);
    immutable devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, 2);

    auto app = new App;
    app.use(requestId());
    app.use(accessLog());
    app.get!("/calc/{id}", calc);
    immutable kv = run(app, LogFormat.kv);
    immutable js = run(app, LogFormat.json);
    // with a sink that keeps nothing: the record and its field values are built in reused buffers
    size_t seen, bytes;
    setLogSink((scope ref const LogRecord r) @safe { seen++; bytes += r.line.length + r.fields.length; });
    immutable kvSink = run(app, LogFormat.kv);
    immutable jsSink = run(app, LogFormat.json);
    immutable textSink = run(app, LogFormat.text);
    setLogSink(null);
    assert(seen > 0 && bytes > 0, "the sink got no lines");
    configureLog(LogLevel.warn); // everything below warn: filtered
    immutable off = run(app, LogFormat.text);

    dup2(saved, 2);
    close(devnull);
    printf("bytes allocated on the GC in 20k logged requests: kv %llu, json %llu, filtered %llu; to a sink: kv %llu, json %llu, text %llu\n",
        kv, js, off, kvSink, jsSink, textSink);
    assert(kv == 0 && js == 0 && off == 0, "logging allocated on the GC");
    assert(kvSink == 0 && jsSink == 0 && textSink == 0, "logging to a sink allocated on the GC");
}
