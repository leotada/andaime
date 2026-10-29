/// Load server: a route that "waits for an external API" for N ms (default 3000).
/// Usage: serve_slow [port] [waitMs] [cert.pem key.pem] — see the memory test in tools/check.sh.
module serve_slow 2025;

import andaime;
import core.time : msecs;

__gshared long gWaitMs = 3000;

@safe:

long waitMs() @trusted => gWaitMs; // set in main before serving, read-only afterwards

/// Holds the request for the configured wait (like /slow), so all the bodies are in memory at the same time.
string bodyLen(Context c)
{
    import core.stdc.stdio : snprintf;

    sleep(msecs(waitMs));
    char[24] t;
    auto n = (() @trusted => snprintf(t.ptr, t.length, "%zu", c.request.body.length))();
    return t[0 .. n].idup;
}

string slow()
{
    sleep(msecs(waitMs));
    return "ok";
}

struct OneFile
{
    SpooledFile file;
}

/// A form upload read as it arrives (the file goes to a temporary file), then held for the wait.
string spooled(Form!OneFile form)
{
    import core.stdc.stdio : snprintf;

    sleep(msecs(waitMs));
    char[24] t;
    auto n = (() @trusted => snprintf(t.ptr, t.length, "%llu", form.file.size))();
    return t[0 .. n].idup;
}

/// A raw body read as it arrives and dropped, then held for the wait.
string streamed(BodyStream body)
{
    import core.stdc.stdio : snprintf;

    ubyte[64 << 10] buf;
    ulong total;
    size_t n;
    while ((n = body.read(buf[])) > 0)
        total += n;
    sleep(msecs(waitMs));
    char[24] t;
    auto k = (() @trusted => snprintf(t.ptr, t.length, "%llu", total))();
    return t[0 .. k].idup;
}

/// An echo that stays open: the memory test holds 1,000 of them at once.
WebSocket wsEcho()
{
    return WebSocket((scope WsConn c) @system {
        foreach (m; c)
            c.send(m.text);
    });
}

@system:

void main(string[] args)
{
    import std.conv : to;

    if (args.length > 2)
        gWaitMs = args[2].to!long;
    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 18090;
    cfg.workers = 1;
    cfg.maxConnections = 15_000;
    cfg.maxInFlight = 15_000;
    cfg.limits.maxBodyBytes = 32 << 20; // the streamed-upload test sends 16 MiB
    if (args.length > 4)
    {
        cfg.tls.certFile = args[3];
        cfg.tls.keyFile = args[4];
    }
    serve(() {
        auto app = new App;
        app.get!("/slow", slow);
        app.post!("/len", bodyLen);
        app.post!("/spooled", spooled);
        app.post!("/streamed", streamed);
        app.ws!("/ws", wsEcho);
        return app;
    }, cfg);
}
