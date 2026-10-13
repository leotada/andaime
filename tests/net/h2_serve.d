/// Server for the HTTP/2 interoperability checks (h2spec, curl, python-h2): `tools/h2_interop.sh`.
/// Usage: h2_serve <port>
module h2_serve;

import vela;
import vela.engine : ServerConfig;

@safe:

string root() => "hello from vela";

string echo(Context c) => cast(string) c.request.body.idup;

string big(int kib)
{
    auto s = new char[kib * 1024];
    foreach (i, ref ch; s)
        ch = cast(char)('a' + i % 26);
    return s.idup;
}

string nap(int ms)
{
    import core.time : msecs;

    sleep(msecs(ms));
    return "slept";
}

string proto(Context c) => c.request.protocol == Protocol.http2 ? "h2" : "http/1.1";

void main(string[] args) @system
{
    import std.conv : to;

    auto app = new App;
    app.get!("/", root);
    app.post!("/", echo);
    app.post!("/echo", echo);
    app.get!("/big/{kib}", big);
    app.get!("/nap/{ms}", nap);
    app.get!("/proto", proto);
    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 8080;
    cfg.host = "127.0.0.1";
    cfg.workers = 1;
    serve(app, cfg);
}
