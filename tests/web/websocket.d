/// WebSocket routes through TestClient: the handshake and its refusals, messages both ways, fragments, pings, the close
/// handshake, the protocol checks (masking, UTF-8, sizes, close codes), errors in the body, middleware, controllers and
/// the OpenAPI document.
module websocket_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.algorithm : canFind;
import core.time : msecs;

WebSocket echo()
{
    return WebSocket((scope WsConn ws) @system {
        foreach (msg; ws)
        {
            if (msg.isText)
                ws.send(msg.text);
            else
                ws.sendBinary(msg.data);
        }
    });
}

WebSocket room(string name, Header!"Authorization" auth, Context ctx)
{
    if (auth.value != "Bearer ok")
        throw new HttpError(403, "forbidden");
    ctx.setHeader("Sec-WebSocket-Protocol", "chat.v1");
    return WebSocket((scope WsConn ws) @system {
        ws.send("welcome to " ~ name);
        auto m = ws.receive();
        if (!m.isClose)
            ws.send("got " ~ m.text);
        ws.close(4001, "bye");
        assert(ws.receive().isClose);
    });
}

WebSocket small()
{
    auto w = WebSocket((scope WsConn ws) @system {
        foreach (msg; ws)
            ws.send(msg.text);
    });
    w.maxMessageBytes = 8;
    return w;
}

WebSocket fails()
{
    return WebSocket((scope WsConn ws) @system {
        ws.send("starting");
        throw new Exception("the database went away");
    });
}

WebSocket returnsAtOnce() => WebSocket((scope WsConn ws) @system { ws.send("hi"); });

WebSocket timed()
{
    return WebSocket((scope WsConn ws) @system {
        WsMessage m;
        // the script ends without a close: tryReceive sees the end of input, not a timeout
        assert(ws.tryReceive(m, 50.msecs) && m.isClose && m.closeCode == 1006);
    });
}

class Live
{
    @Ws("/live") WebSocket live() => WebSocket((scope WsConn ws) @system { ws.send("from a controller"); });
    @Get("/plain") string plain() => "plain";
}

string[] log;

App buildApp()
{
    auto app = new App;
    app.use((Context ctx, Next next) @system {
        next();
        log ~= ctx.request.path.idup ~ " " ~ (cast(int) ctx.response.status).stringOf;
    });
    app.ws!("/echo", echo);
    app.ws!("/rooms/{name}", room);
    app.ws!("/small", small);
    app.ws!("/fails", fails);
    app.ws!("/once", returnsAtOnce);
    app.ws!("/timed", timed);
    app.mount(new Live);
    app.serveOpenApi();
    return app;
}

string stringOf(int v) @trusted
{
    import std.conv : to;

    return v.to!string;
}

unittest // echo: text, binary, a fragmented message, ping; the close is echoed
{
    auto c = TestClient(buildApp());
    auto r = c.websocket("/echo", WsScript().text("hello").binary([1, 2, 3]).text("frag", false).ping("p")
        .continuation("ment").close(1000, "done"));
    assert(r.status == 101);
    assert(r.response.header("Sec-WebSocket-Accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    assert(r.response.header("Date").length && r.response.header("Content-Length") is null);
    assert(r.texts == ["hello", "\x01\x02\x03", "fragment"]);
    assert(r.messages[1].isBinary && r.messages[2].isText);
    assert(r.pongs == ["p"]);
    assert(r.closeCode == 1000 && r.closeReason == "");
}

unittest // refusals are ordinary HTTP responses
{
    auto c = TestClient(buildApp());
    auto r = c.websocket("/rooms/a", WsScript().close(), hdr("Authorization", "Bearer no"));
    assert(r.status == 403 && r.messages.length == 0 && r.closeCode == 0);
    assert(r.response.body.canFind("forbidden"));

    auto g = c.get("/echo");
    assert(g.status == 426, "a plain GET on a WebSocket route");
    auto v = c.get("/echo", hdr("Upgrade", "websocket"), hdr("Connection", "upgrade"),
        hdr("Sec-WebSocket-Version", "8"), hdr("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="));
    assert(v.status == 426 && v.header("Sec-WebSocket-Version") == "13");
    auto k = c.get("/echo", hdr("Upgrade", "websocket"), hdr("Connection", "upgrade"),
        hdr("Sec-WebSocket-Version", "13"), hdr("Sec-WebSocket-Key", "nope"));
    assert(k.status == 400);
    assert(c.post("/echo", "x").status == 405);

    auto missing = c.websocket("/rooms/a", WsScript().close());
    assert(missing.status == 422, "a missing header is a validation error, before any upgrade");
}

unittest // headers the handler set go out with the 101; the server closes first
{
    auto c = TestClient(buildApp());
    auto r = c.websocket("/rooms/lobby", WsScript().text("hi").close(4001), hdr("Authorization", "Bearer ok"));
    assert(r.status == 101 && r.response.header("Sec-WebSocket-Protocol") == "chat.v1");
    assert(r.texts == ["welcome to lobby", "got hi"]);
    assert(r.closeCode == 4001 && r.closeReason == "bye");
}

unittest // protocol violations close the connection with the right code
{
    auto c = TestClient(buildApp());
    assert(c.websocket("/echo", WsScript().text("\xff")).closeCode == 1007, "invalid UTF-8");
    assert(c.websocket("/small", WsScript().text("123456789")).closeCode == 1009, "too big");
    auto fits = c.websocket("/small", WsScript().text("12345678").close());
    assert(fits.texts == ["12345678"] && fits.closeCode == 1000);
    assert(c.websocket("/echo", WsScript().continuation("x")).closeCode == 1002, "a continuation without a message");
    assert(c.websocket("/echo", WsScript().raw([0x81, 0x02, 'h', 'i'])).closeCode == 1002, "an unmasked client frame");
    assert(c.websocket("/echo", WsScript().close(1005)).closeCode == 1002, "1005 is not allowed on the wire");
    auto unclean = c.websocket("/echo", WsScript().text("a"));
    assert(unclean.texts == ["a"], "input ended without a close: nothing more to send");
}

unittest // the body throws: close 1011, the error is logged, middleware still runs
{
    auto c = TestClient(buildApp());
    log = null;
    auto r = c.websocket("/fails", WsScript().close());
    assert(r.status == 101 && r.texts == ["starting"] && r.closeCode == 1011);
    assert(r.response.aborted);
    assert(log == ["/fails 101"], log[0]);
}

unittest // the body returns: the server closes with 1000; tryReceive; controllers
{
    auto c = TestClient(buildApp());
    auto r = c.websocket("/once", WsScript().close());
    assert(r.texts == ["hi"] && r.closeCode == 1000);
    assert(c.websocket("/timed").status == 101);
    auto l = c.websocket("/live", WsScript().close());
    assert(l.texts == ["from a controller"] && l.closeCode == 1000);
    assert(c.get("/plain").body == "plain");
}

unittest // WebSocket routes are not in the OpenAPI document
{
    auto c = TestClient(buildApp());
    auto doc = c.get("/openapi.json").body;
    assert(doc.canFind(`"/plain"`) && !doc.canFind(`"/echo"`) && !doc.canFind(`"/live"`), doc);
}

unittest // HTTP/2 (RFC 8441): the extended CONNECT is answered with 200, no accept key; the rest is the same
{
    auto c = TestClient(buildApp());
    c.http2 = true;
    auto r = c.websocket("/echo", WsScript().text("hello").ping("p").close(1000));
    assert(r.status == 200 && r.response.header("Sec-WebSocket-Accept") is null);
    assert(r.texts == ["hello"] && r.pongs == ["p"] && r.closeCode == 1000);

    auto room_ = c.websocket("/rooms/h2", WsScript().text("hi").close(4001), hdr("Authorization", "Bearer ok"));
    assert(room_.status == 200 && room_.response.header("Sec-WebSocket-Protocol") == "chat.v1");
    assert(room_.texts == ["welcome to h2", "got hi"] && room_.closeCode == 4001);
    assert(c.websocket("/rooms/h2", WsScript().close(), hdr("Authorization", "Bearer no")).status == 403);
    assert(c.websocket("/live", WsScript().close()).texts == ["from a controller"]);

    log = null;
    assert(c.websocket("/fails", WsScript().close()).closeCode == 1011);
    assert(log == ["/fails 200"], log[0]);

    // a plain HTTP/2 GET on a WebSocket route, and a wrong version
    assert(c.get("/echo").status == 426);
    // an extended CONNECT on a route that is not a WebSocket: refused before the handler runs
    auto p = c.websocket("/plain", WsScript().close());
    assert(p.status == 400 && p.messages.length == 0, p.response.body);
    assert(c.websocket("/nowhere").status == 404);
    assert(c.get("/plain").body == "plain");
}
