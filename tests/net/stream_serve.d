/// Server for tools/stream_interop.sh: streamed responses for curl to read. Usage: stream_serve <port>
module stream_serve;

import andaime;
import std.conv : to;
import core.time : msecs;

@safe:

EventStream ticks()
{
    return EventStream((scope EventWriter w) @system {
        foreach (i; 0 .. 5)
        {
            w.send("tick " ~ i.to!string);
            sleep(msecs(200));
        }
    });
}

Stream megabytes(int n)
{
    return Stream("application/octet-stream", (scope StreamWriter w) @system {
        auto piece = new char[64 << 10];
        piece[] = 'x';
        foreach (i; 0 .. n * 16)
            w.write(piece);
    });
}

void main(string[] args) @system
{
    ServerConfig cfg;
    cfg.port = args[1].to!ushort;
    cfg.host = "127.0.0.1";
    cfg.workers = 1;
    serve(() {
        auto app = new App;
        app.get!("/ticks", ticks);
        app.get!("/mb/{n}", megabytes);
        return app;
    }, cfg);
}
