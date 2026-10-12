/// Load server: a route that "waits for an external API" for N ms (default 3000).
/// Usage: serve_slow [port] [waitMs] — see the memory test in tools/check.sh.
module serve_slow;

import vela;
import core.time : msecs;

__gshared long gWaitMs = 3000;

@safe:

long waitMs() @trusted => gWaitMs; // set in main before serving, read-only afterwards

string slow()
{
    sleep(msecs(waitMs));
    return "ok";
}

@system:

void main(string[] args)
{
    import std.conv : to;

    if (args.length > 2)
        gWaitMs = args[2].to!long;
    auto app = new App;
    app.get!("/slow", slow);
    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 18090;
    cfg.workers = 1;
    cfg.maxConnections = 15_000;
    cfg.maxInFlight = 15_000;
    app.serve(cfg);
}
