/// Server for the HTTP/2 interoperability checks (h2spec, curl, python-h2): `tools/h2_interop.sh`.
/// Usage: h2_serve <port> [cert.pem key.pem]   (with a certificate: HTTPS, ALPN h2/http1.1)
module h2_serve 2025;

import andaime;
import andaime.engine : ServerConfig;

@safe:

string root() => "hello from andaime";

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

    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 8080;
    cfg.host = "127.0.0.1";
    cfg.workers = 1;
    if (args.length > 3)
    {
        cfg.tls.certFile = args[2];
        cfg.tls.keyFile = args[3];
    }
    serve(() {
        auto app = new App;
        app.get!("/", root);
        app.post!("/", echo);
        app.post!("/echo", echo);
        app.get!("/big/{kib}", big);
        app.get!("/nap/{ms}", nap);
        app.get!("/proto", proto);
        return app;
    }, cfg);
}
