# HTTP/2

andaime implements HTTP/2 as defined by RFC 9113 (with HPACK, RFC 7541): over TLS through ALPN, and in cleartext (h2c) by prior
knowledge or `Upgrade: h2c`. It passes h2spec (146/146 over TLS) and is tested against Chromium, curl, python-h2 and Caddy as
an h2c reverse proxy (see [Verification](#verification)); the optional parts it leaves out are listed under
[Behavior](#behavior).

HTTP/2 is on by default, on the same port as HTTP/1.1: over TLS when the server has a certificate (ALPN chooses, see
[tls.md](tls.md)), in cleartext (h2c) otherwise. Nothing changes in the application: the same handlers, middleware and
`TestClient`; `ctx.request.protocol` tells which protocol a request came on.

Cleartext HTTP/2 (h2c), without a certificate:

```sh
curl --http2-prior-knowledge http://localhost:8080/users/1   # prior knowledge: the "PRI *" preface
curl --http2 http://localhost:8080/users/1                   # HTTP/1.1 "Upgrade: h2c", answered on stream 1
```

```d
ServerConfig cfg;
cfg.http2 = true;               // default; false = HTTP/1.1 only
cfg.http2MaxStreams = 100;      // SETTINGS_MAX_CONCURRENT_STREAMS per connection
cfg.http2StreamWindowBytes = 256 << 10;   // per-stream receive window: upload throughput per stream
cfg.http2ConnectionWindowBytes = 1 << 20; // connection receive window: request bodies in flight
cfg.http2WebSockets = true;     // default; WebSockets as streams (RFC 8441), see websocket.md
```

A request body up to `bufferBodyBytes` (256 KiB) is buffered whole, as over HTTP/1.1. A larger one (announced by
`content-length`, or past that size without END_STREAM) is handed to `BodyStream` and `SpooledFile` as it arrives (see
[requests.md](requests.md#large-uploads-spooledfile-and-bodystream)), and then the stream window is the backpressure:
it reopens (WINDOW_UPDATE) only as the handler reads, so a stream never holds more than one window the handler has not
read, and a handler that stops reading stops the client. An answer before the body ended is followed by
RST_STREAM(NO_ERROR) for the rest (RFC 9113 §8.1); RST_STREAM from the client cancels a handler waiting for the body.
One stream uploads at most one stream window per round trip, so with a 50 ms round trip the default 256 KiB allows
about 5 MB/s per stream; raise it for large uploads over long distances (each streamed upload may then hold that much).
Values below 65,535 are raised to it.

## Behind a proxy or between services

Browsers only speak HTTP/2 over TLS: use h2c service to service, or behind a proxy that speaks h2c to its upstreams
(configuration checked against each one's docs):

- Caddy: `reverse_proxy h2c://127.0.0.1:8080` (tested: `tools/proxy_interop.sh`).
- HAProxy 1.9+: `server app 127.0.0.1:8080 proto h2`.
- Envoy: an upstream cluster with `explicit_http_config.http2_protocol_options` and no TLS transport socket.
- Google Cloud: Cloud Run with end-to-end HTTP/2 (container port named `h2c`); the Application Load Balancer with backend
  service protocol `H2C` (not on the classic Application Load Balancer; its `HTTP2` protocol requires TLS).
- AWS ALB: HTTP/2 target groups (protocol version `HTTP2`) only work behind an HTTPS listener. AWS does not document whether
  the hop to the target may be cleartext; users report h2c working, but it is untested here. An HTTPS target group pointing at
  andaime's TLS listener is the documented path.

## Behavior

- Each stream runs in its own fiber, exactly like an HTTP/1.1 request: `maxInFlight` counts streams (above it the stream is
  refused with `REFUSED_STREAM`, safe to retry), `requestTimeoutMs` applies per stream (504), a `RST_STREAM` from the client
  cancels only that handler, and closing the connection cancels all of them.
- Streamed responses ([streaming.md](streaming.md)) are DATA frames under flow control; a stalled stream suspends only its own
  handler.
- WebSockets (RFC 8441): andaime announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`, and a `CONNECT` with `:protocol websocket` reaches
  the `ws!` route of its `:path` as a GET; the stream then carries the WebSocket both ways, under the same flow control
  ([websocket.md](websocket.md#http2)). Other `:protocol` values get 501, a plain `CONNECT` (a proxy tunnel) too.
- Graceful stop sends `GOAWAY`; streams already accepted finish first (those still open after `shutdownGraceMs` are cancelled).
  Idle connections get `GOAWAY` after `idleTimeoutMs`.
- Limits are the same as HTTP/1.1 (`Limits`: header list, `:path`, body) and answer with the same statuses (431, 414, 413).
- Protection: `CONTINUATION` floods, rapid reset and control-frame floods (`PING`, `SETTINGS`, `PRIORITY`, empty frames) end the
  connection with `ENHANCE_YOUR_CALM`; reading pauses while a client does not read its responses.
- A connection that ends is closed with FIN first and its remaining input discarded for up to a second, so the peer never sees a
  reset instead of our last frames.
- Not for gRPC yet: gRPC needs response trailers (`grpc-status`), which andaime does not support.
- Not implemented: server push (clients disable it), priorities (accepted and ignored, as RFC 9113 allows), the HPACK dynamic
  table when encoding responses (decoding uses it as required).

## Verification

[h2spec](https://github.com/summerwind/h2spec) passes all 146 cases over TLS and 145 in cleartext. The remaining one (3.5/2, an
invalid preface) cannot pass on a cleartext port that also serves HTTP/1.1: there it is a malformed HTTP/1.1 request, which
correctly gets a 400. Also tested against curl (nghttp2) and python-h2, in cleartext and over TLS (`tools/h2_interop.sh`);
against Chromium over TLS, where a page with 26 assets and API calls loads entirely over h2 and its WebSocket opens as a
stream of the same connection (`tests/net/browser_test.py`); WebSockets over h2c and TLS against python-h2 carrying the python
`websockets` library's frames (`tools/ws_interop.sh`); and behind Caddy as an h2c reverse proxy, including concurrent
requests, Server-Sent Events and a 20 MiB stream (`tools/proxy_interop.sh`).

Measured: 1,000 in-flight streams over 10 connections peak at ~16 MB of RSS, 1,000 open WebSockets over 10 connections at
~19 MB; the HTTP/2 hot path (frames, HPACK, dispatch, framing the response, a WebSocket's messages) does not allocate on the
GC.
