/// Server for tools/ws_interop.sh: WebSocket echo routes for other implementations to talk to. Usage: ws_serve <port>
module ws_serve;

import vela;
import std.conv : to;

@safe:

WebSocket echoWith(bool compression)
{
    auto w = WebSocket((scope WsConn ws) @system {
        foreach (m; ws)
        {
            if (m.isText)
                ws.send(m.text);
            else
                ws.sendBinary(m.data);
        }
    });
    w.compression = compression;
    w.maxMessageBytes = 16 << 20;
    return w;
}

WebSocket echo() => echoWith(false);
WebSocket echoZ() => echoWith(true);

/// Sends `n` messages of growing size, then closes with 4000.
WebSocket burst(int n)
{
    auto w = WebSocket((scope WsConn ws) @system {
        foreach (i; 0 .. n)
        {
            auto s = new char[i * 100 + 1];
            s[] = cast(char)('a' + i % 26);
            ws.send(s);
        }
        ws.close(4000, "done");
        ws.receive();
    });
    w.compression = true;
    return w;
}

void main(string[] args) @system
{
    ServerConfig cfg;
    cfg.port = args[1].to!ushort;
    cfg.host = "127.0.0.1";
    cfg.workers = 1;
    serve(() {
        auto app = new App;
        app.ws!("/echo", echo);
        app.ws!("/echo-z", echoZ);
        app.ws!("/burst/{n}", burst);
        app.get!("/ready", () => "ok");
        return app;
    }, cfg);
}
