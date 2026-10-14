/// Load server: a route that "waits for an external API" for N ms (default 3000).
/// Usage: serve_slow [port] [waitMs] [cert.pem key.pem] — see the memory test in tools/check.sh.
module serve_slow;

import vela;
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
    if (args.length > 4)
    {
        cfg.tls.certFile = args[3];
        cfg.tls.keyFile = args[4];
    }
    serve(() {
        auto app = new App;
        app.get!("/slow", slow);
        app.post!("/len", bodyLen);
        app.ws!("/ws", wsEcho);
        return app;
    }, cfg);
}
