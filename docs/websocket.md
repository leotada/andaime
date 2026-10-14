# WebSockets

A WebSocket route is a GET whose handler returns a `WebSocket`. The parameters are bound and the middleware runs first,
exactly as for any other route, so authentication, validation errors and refusals are ordinary HTTP responses. Then the
connection is upgraded (`101 Switching Protocols`) and the body talks to the client. Over HTTP/2 the WebSocket is a stream
of the connection instead (RFC 8441); the handler is the same, see [HTTP/2](#http2).

```d
// check
@safe:

import vela;

WebSocket echo(string room, Header!"Authorization" auth)
{
    if (auth.value != "Bearer secret")
        throw new HttpError(403, "forbidden");     // a plain 403: no upgrade
    return WebSocket((scope WsConn ws) {
        ws.send("welcome to " ~ room);
        foreach (msg; ws)                          // every message until the client closes
        {
            if (msg.isText)
                ws.send(msg.text);
            else
                ws.sendBinary(msg.data);
        }
    });                                            // returning closes the connection (1000)
}

App buildApp()
{
    auto app = new App;
    app.ws!("/rooms/{room}", echo);
    return app;
}

void main() { serve(&buildApp, 8080); }
```

## The route

- `app.ws!("/path/{param}", handler)` on an `App` or a `Group`, or `@Ws("/path")` on a controller method. The handler must return
  `WebSocket`, and a `get!`/`post!` handler cannot (both are one-line compile errors). `@status` does not apply.
- Parameters work as for a GET: path, query, `Header!`, `Cookie!`, `Local!` (set by middleware), `ClientIp`, `Context`. A
  missing or invalid one is a 422, before any upgrade.
- Headers the handler sets on the context go out with the 101 (the 200 on HTTP/2):
  `ctx.setHeader("Sec-WebSocket-Protocol", "chat.v1")` picks a subprotocol (read the client's offer with
  `Header!"Sec-WebSocket-Protocol"`), `setCookie` works too.
- A request that is not a WebSocket upgrade gets a 426; a wrong `Sec-WebSocket-Version` gets a 426 with
  `Sec-WebSocket-Version: 13`; a missing or malformed `Sec-WebSocket-Key` gets a 400. An HTTP/2 WebSocket request (an
  extended CONNECT) on a route that is not a WebSocket route gets a 400.
- WebSocket routes are not in the OpenAPI document (OpenAPI cannot describe them).
- A function of your own named `ws` hides vela's (like `get`); use `vela.ws!(...)(app)` then.

## The connection: `WsConn`

| Member | What it does |
|---|---|
| `receive()` | The next message: text (`isText`, `text`; vela has checked it is UTF-8), binary (`isBinary`, `data`), or the close (`isClose`, `closeCode`, the reason in `text`). After the close it returns the close again. |
| `tryReceive(out msg, timeout)` | The same, waiting at most `timeout`: false when nothing came. One fiber can mix receiving with periodic pushes. |
| `foreach (msg; ws)` | Every text and binary message until the close. |
| `send(text)`, `sendBinary(bytes)` | A whole message. Waits while the client is slow (backpressure). |
| `ping(payload)` | A ping; the pong is consumed by `receive`. |
| `close(code, reason)` | Starts the close handshake and returns at once; the owner's `receive` then returns the client's answer. |
| `isOpen`, `closeCode` | Whether neither side closed yet; the close code once it is closing. |
| `disconnect()`, `abort()` | Close and wait for the answer / close at once. The server calls `disconnect` for you when the body returns. |

`msg.data` and `msg.text` are views into the connection's buffer, valid until the next `receive`: copy them (`.idup`) to keep
them. Pings are answered, fragmented messages are reassembled and the protocol's checks are done for you: a violation closes
the connection with the right code (1002 protocol error, 1007 invalid UTF-8, 1009 message too big), and `receive` returns that
close.

## Contract

- The 101 (200 on HTTP/2) is sent when the handler returns the `WebSocket`; the body runs inside the middleware chain, so
  middleware sees the whole session (an access log records 101 or 200 and its duration) and its `scope(exit)` runs after
  the connection ends.
- When the body returns, the connection is closed with 1000 (if it is still open) and vela waits up to a second for the client's
  answer. When it throws, the client gets a close with 1011 and the error is logged, as any handler error. A client that
  disappears ends `receive` with a close whose code is 1006.
- Receiving belongs to the fiber that runs the body. `send`, `sendBinary`, `ping` and `close` may be called from any fiber of
  the same worker: see the next section.
- The protocol is RFC 6455, over HTTP/1.1 or as an HTTP/2 stream (RFC 8441), cleartext and TLS (`wss://`).

## HTTP/2

A browser that loaded the page over HTTP/2 opens its WebSockets on the same connection, as streams (RFC 8441, "extended
CONNECT"): vela announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`, the browser sends a `CONNECT` with `:protocol websocket`, and
vela answers `200` instead of `101`. Chromium and Firefox do it; a client that does not simply uses HTTP/1.1.

- Nothing changes for the handler: the same route, parameters, middleware, `WsConn`, limits and compression.
  `ctx.request.protocol` is `Protocol.http2` and `ctx.request.connectProtocol` is `"websocket"`; the request's method is GET.
- No TCP handshake, no TLS handshake: opening a WebSocket costs one round trip on a page that is already open.
- The stream's flow control is the backpressure: the client can send at most one stream window
  (`http2StreamWindowBytes`, 256 KiB) that the handler has not read yet, and a `send` waits while the client has not opened
  its window for more than `streamHighWaterBytes`. A client that reads nothing for `writeTimeoutMs` gets its stream reset
  (`CANCEL`), not the whole connection.
- A WebSocket counts as a stream: at most `http2MaxStreams` (100) per connection, together with the page's own requests.
- Closing is the WebSocket close handshake, then `END_STREAM` both ways. A stream reset by the client ends `receive` with
  1006, like a TCP connection that vanished; if the whole connection drops, the handler gets `RequestCancelled`.
- `ServerConfig.http2WebSockets = false` stops announcing it: browsers then open their own HTTP/1.1 connection for each
  WebSocket, as before.
- `wsConnect` (the client) always uses HTTP/1.1.

## Sending from other fibers (a chat room)

A connection can be written to by any request fiber of the worker that owns it: keep the open connections of a room in a list
and send to each.

```d
// check
@safe:

import vela;

WsConn[] room; // module variables are per worker (thread-local): this is the room of one worker

WebSocket chat()
{
    return WebSocket((scope WsConn ws) {
        room ~= ws;
        scope (exit)
            foreach (i, x; room)
                if (x is ws) { room = room[0 .. i] ~ room[i + 1 .. $]; break; }
        foreach (msg; ws)
            foreach (peer; room.dup)
                if (peer !is ws)
                {
                    try
                        peer.send(msg.text);
                    catch (WsClosed)
                    {
                    } // that peer is leaving: its own fiber removes it
                }
    });
}

App buildApp()
{
    auto app = new App;
    app.ws!("/chat", chat);
    return app;
}

void main() { serve(&buildApp, 8080); }
```

- A send to a connection that already ended throws `WsClosed` in the sending fiber. The fiber that owns the connection gets
  `RequestCancelled` instead (it unwinds like a request whose client left). A `WsConn` kept after its connection ended never
  reaches another client.
- Frames of two fibers never interleave: every `send` hands its whole frame to the connection before it can wait.
- **Workers do not share connections** (one App per worker). With `workers > 1` a room has one list per worker; to reach the
  clients of every worker, publish through something all workers read (a database `LISTEN/NOTIFY`, a message broker) and let
  each worker send to its own clients.

## Limits, timing and memory

| `WebSocket` field | Default | Meaning |
|---|---|---|
| `maxMessageBytes` | 1 MiB | A larger message (after decompression) closes the connection with 1009. |
| `pingInterval` | 30 s | While the body waits in `receive`, a ping goes out after this long without input, and the connection is dropped (1006) after as long again without an answer. `Duration.zero` disables both. |
| `compression` | false | permessage-deflate, see below. |

- Backpressure: a `send` waits once more than `ServerConfig.streamHighWaterBytes` (64 KiB) is queued for the connection; a client
  that reads nothing for `writeTimeoutMs` is dropped.
- `requestTimeoutMs` ends at the 101. The protocol's own liveness check is the ping; there is no other limit on a session.
- Each open WebSocket holds a fiber and counts toward `maxInFlight` (1,024 per worker by default) and `maxConnections`. An idle
  one holds no input buffer: 1,000 open WebSockets take about 21 MB of RSS on one worker (`tools/check.sh` checks it stays under
  30 MB).
- Graceful stop: open WebSockets get a close with 1001 (going away) and the server stops once they answer, or after
  `shutdownGraceMs`.
- `LoopStats.webSockets` counts the open ones, `webSocketsTotal` every one since the start.

## Compression (permessage-deflate)

Set `compression = true` on the `WebSocket` and messages are compressed when the client offers permessage-deflate (browsers
always do). zlib is loaded at run time (`libz.so.1`); without it the extension is simply not negotiated. It costs about 300 KB of
zlib state per connection that sends compressed messages (the compressor keeps its 32 KB window between messages, which is
what makes small JSON messages compress well), so it is off by default. Messages under 64 bytes are sent uncompressed.

## The client: `wsConnect`

```d
// check
import vela;

void main()
{
    WsClientOptions opts;
    opts.compression = true;
    auto ws = wsConnect("wss://echo.example.com/ws", [HeaderPair("Authorization", "Bearer secret")], opts);
    scope (exit)
        ws.disconnect();
    ws.send("hello");
    auto reply = ws.receive();
}
```

- `ws://` and `wss://`; TLS uses `httpClient()`'s settings (certificate and host name checks, `caFile`).
- Inside a request every wait suspends only the fiber; outside one (a script, `main`) it blocks.
- The connection belongs to the fiber that opened it (it receives); other fibers of the worker may `send`. A send that finds the
  socket full while the owner is waiting stays queued until the owner's next wait.
- `WsClientOptions`: `connectTimeout` (DNS, TCP, TLS and the handshake; 10 s), `maxMessageBytes`, `pingInterval`, `writeTimeout`,
  `compression`. Failures are `HttpClientError` (`HttpClientTimeout` past `connectTimeout`).

## Testing

`TestClient.websocket` runs the handler in memory: it sends a script of client frames and returns what the server sent.

```d
auto c = TestClient(buildApp());
auto r = c.websocket("/rooms/a", WsScript().text("hi").ping("p").close(), hdr("Authorization", "Bearer secret"));
assert(r.status == 101);
assert(r.texts == ["welcome to a", "hi"]);
assert(r.pongs == ["p"] && r.closeCode == 1000);
```

A refused upgrade shows up as `r.status` (403, 422, 426) with `r.response` holding the HTTP answer. Once the script is used up
the client's input ends (the server sees 1006 unless the script ended with `close`). Set `c.http2 = true` to send the
requests as HTTP/2 ones: `websocket` then opens the WebSocket as a browser does on an HTTP/2 connection (an extended
CONNECT), and a successful one has `r.status == 200`.

## Behind a proxy

The proxy must forward the upgrade. nginx:

```nginx
location /ws/ {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 120s;          # longer than pingInterval: the pings keep the connection alive
}
```

Caddy's `reverse_proxy` forwards WebSockets without extra configuration. A proxy terminates the browser's HTTP/2 itself:
whether the browser's WebSocket rides its HTTP/2 connection is between the browser and the proxy, and the proxy then speaks
HTTP/1.1 (the upgrade) to vela.
