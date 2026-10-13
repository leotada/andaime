# dapi

The code uses the provisional name **vela** (DUB package and `import vela;`).

A micro web framework in D with FastAPI-style ergonomics: the function signature is the
HTTP contract, and the dispatch is generated at compile time.

```d
@safe:

import vela;

struct UserInput { @minLength(2) string name; @inRange(0, 150) int age; }
struct User { long id; string name; int age; }

User getUser(long id) { ... }                                   // GET /users/{id}
WithStatus!User createUser(JsonBody!UserInput body) { ... }     // POST /users -> 201

void main()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.serve(8080);
}
```

## Potential

**For whoever writes the API**
- The signature is the contract: path parameters, query, headers and a typed JSON body are extracted and validated
  from the function's types and names. Bad input becomes a 422 in FastAPI's format; the handler only runs with valid data.
- Documentation that does not go stale: `openapi.json` and the Swagger UI come from the same signatures that generate the dispatch.
- Fluent responses: return `string`, a struct, an array, `WithStatus!T` or `Response`; `throw new HttpError(...)` for failures.
- `@safe` by default, never in your way: the framework is `@safe`, the driver, HTTP client and `offload` are `@safe` to call,
  and `@trusted` is confined to small, commented façades. Your handlers may be `@safe` (recommended: `@safe:` at the top of the module)
  or `@system` when they call C; `versions "VelaStrictSafe"` makes `@system` handlers a one-line compile error.
- One-line compile errors that say what to fix, good for humans and for AI agents (no template *backtrace*),
  and predictable types that keep `serve-d` responsive.

**For whoever runs the server**
- It does not block: one fiber per request; database, external API and DNS suspend only the fiber, however many
  requests are in flight. Heavy work goes to a bounded thread pool (`offload`), which refuses with `PoolSaturated`
  instead of growing without a ceiling.
- Memory designed for cheap VPSs: reused network buffers, a per-fiber header table, an in-flight request ceiling
  (503 + `Retry-After`). Measured: 1,000 simultaneous requests in ~25 MB of RSS; the hot path does not allocate on the GC.
- Robust by default: head/idle/write/request deadlines, slowloris protection, cancellation when the
  client goes away (the handler's `scope(exit)` runs), graceful stop, a zero-copy HTTP/1.1 parser fuzzed with ASan.
- HTTPS and HTTP/2 on the same port: TLS with ALPN (browsers get HTTP/2) and certificate reload without restarts,
  or cleartext h2c behind a proxy. Multiplexed streams, each in its own fiber, with flow control, per-stream
  deadlines and cancellation, protection against rapid reset and control-frame floods. Your handlers do not change.
- Fast compilation: the example's `app.d` compiles in ~250 ms on DMD, because the dispatch uses shallow `static foreach` and
  `static if` instead of deep template chains.

**For growing**
- Separate layers (`http` without I/O, `web`, `engine`) and optional drivers outside the core (`drivers/pg`): `vela`
  does not depend on libpq. New drivers and backends (kqueue, io_uring) plug in without touching the application layer.
- Onion-style middleware with route groups, `ctx.locals`, CORS, static files and `onError`, all in idiomatic D
  (slices, strings, delegates, DTOs), with no defensive `@nogc` annotations.

Start with [docs/quickstart.md](docs/quickstart.md). If you are an AI agent working on this repository, read [AGENTS.md](AGENTS.md).

## Status

The web layer is complete and tested (M1). M2 is closed on Linux: `EpollLoop` with edge-triggered
epoll, one fiber per request, `SO_REUSEPORT`, deadlines, an in-flight request ceiling, cancellation, the `Date` header,
a stalled-loop detector, memory cleanup after bursts and graceful stop. kqueue (M5) and io_uring (M6) are still to
come. Outside Linux, `serve` falls back to the blocking development server.

M3 is also done on Linux: a bounded thread pool (`offload`), a PostgreSQL driver over asynchronous
libpq (the separate package `vela-pg`, in `drivers/pg`) and a cooperative HTTP/HTTPS client (`httpClient()`). All three suspend
only the request's fiber.

HTTP/2 over cleartext (h2c) is served by the epoll engine next to HTTP/1.1; see [HTTP/2](#http2-h2c) below.

Inside a handler, wait without blocking the worker:

```d
import core.time : msecs;
string slow() { sleep(500.msecs); return "ok"; }   // the worker serves other connections meanwhile
```

### Database, external APIs and heavy work (M3)

```d
import vela.db;                       // dependency "vela-pg" path="drivers/pg"; needs libpq5 installed

struct User { int id; string name; Maybe!string email; }

string user(int id)
{
    auto db = pgPool("host=my-rds.example.rds.amazonaws.com dbname=app user=app");   // one pool per worker
    auto u = db.query("select id, name, email from users where id = $1", id).rowsAs!User;
    return u.length ? u[0].name : "?";
}

string quote()
{
    auto r = httpClient().get("https://api.example.com/v1/quote");   // verified HTTPS, keep-alive
    return r.ok ? r.body : "unavailable";
}

string heavy()
{
    return offload(() => workThatCannotBeDoneCooperatively());   // thread pool (configureOffload)
}
```

- Queries use `$1..$n` text parameters: never build SQL from user-supplied values.
- If the client goes away or the deadline expires midway through a query, the driver asks the server to cancel and
  discards the connection. The same goes for outgoing HTTP calls (the connection is closed).
- libpq and OpenSSL are loaded at run time (dlopen): vela builds without them installed.
- `offload` throws `PoolSaturated` when the queue fills up; decide whether that becomes a 503.

### Real application: groups, locals, errors, CORS, static files, OpenAPI

A complete example (Postgres + external API + static files + docs): `examples/api`.

```d
auto app = new App;
app.use(accessLog());                       // access log; requestId("X-Request-Id") propagates the id
app.use(cors(CorsConfig(["https://app.example.com"])));   // 204 preflight before routing
app.onError((Context ctx, Exception e) { /* your own error response */ });
app.onNotFound((Context ctx) { /* your own 404 */ });
app.redirectTrailingSlash = true;           // /users/ -> 308 /users (query preserved)

auto admin = app.group("/admin");           // literal prefix (no {param}); middlewares only apply to routes registered afterwards
admin.use((Context ctx, Next next) { ctx.locals.set(User(bearerToken(ctx))); next(); });
admin.get!("/me", me);                      // UserResponse me(Local!User u) { ... }  -> missing Local = 500

app.serveStatic("/assets", "./public");     // ETag/304, Last-Modified, index, blocks .., dotfiles and symlinks that leave the root
app.serveOpenApi(OpenApiInfo("My API", "1.0"));   // /openapi.json (generated from the handlers) and /docs (Swagger UI via CDN)
```

- Annotations for OpenAPI/validation: `@summary`, `@jsonKey`, `@jsonIgnore`, `@optional`, `@minLength`, `@maxLength`, `@inRange`.
- `Expect: 100-continue` is answered by the engine; any other `Expect` value gets a 417.
- `PgConfig.cacheStatements = true` uses prepared statements (up to 128 per connection, with a retry
  if the plan is invalidated). It is off by default: do not use it behind PgBouncer in transaction mode.
- Parser: `tests/fuzz/corpus/` (55 attack requests, `<name>.<ok|incomplete|status>.http`),
  a mutation fuzzer with invariants (`fuzz_parse.d [iterations] [seed]`) and libFuzzer+ASan with `tools/fuzz.sh [seconds]`.
- Known limits: chunked request bodies are not supported (501); `/docs` loads the Swagger UI from a CDN;
  static files up to 256 KiB are read on the worker (larger ones go to `offload`); a CPU-only handler cannot be cancelled.

### HTTP/2 and HTTPS

HTTP/2 is on by default, on the same port as HTTP/1.1: over TLS when the server has a certificate (ALPN
chooses), in cleartext (h2c) otherwise. Nothing changes in the application: the same handlers, middleware
and `TestClient`; `ctx.request.protocol` tells which protocol a request came on.

```d
ServerConfig cfg;
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile = "/etc/letsencrypt/live/example.com/privkey.pem";
app.serve(cfg);   // browsers get HTTP/2; clients without ALPN or without h2 get HTTP/1.1
```

- With a certificate the listener speaks TLS only. There is no second, cleartext listener yet: for an
  HTTP-to-HTTPS redirect on port 80 (and ACME HTTP-01 challenges), run a second process or use DNS-01.
- TLS 1.2 and 1.3; for TLS 1.2 only ECDHE with AEAD ciphers (Mozilla's "intermediate" list, which also meets
  HTTP/2's requirements); no compression, no renegotiation. Session resumption uses stateless tickets, with
  keys shared by all workers and kept for the life of the process.
- Certificate renewal needs no restart: each worker checks both files every `tls.reloadCheckMs` (10 s) and
  reloads them when they change (certbot's symlink swaps included). New connections get the new certificate;
  open ones keep theirs. A file that fails to load is logged and the previous certificate stays.
- The handshake must finish within `headerTimeoutMs`. Prior knowledge and `Upgrade: h2c` are cleartext
  features: over TLS, HTTP/2 is only chosen through ALPN.
- OpenSSL 3 is loaded at run time, as for the HTTP client (`libssl3`); without a certificate it is never loaded.
  Loading it sets SIGPIPE to ignored (unless the application installed a handler), because OpenSSL writes to
  sockets with write(2) and a client that resets the connection would otherwise kill the process.
- Memory: OpenSSL keeps about 15 KiB per connection, on top of the request. 1,000 in-flight HTTPS requests on
  1,000 connections peak at ~44 MB (HTTP/1.1) and ~38 MB (h2), against ~25 MB in cleartext; the in-flight
  ceiling (`maxInFlight`) is what bounds it on a small VPS.

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
```

The windows only limit upload throughput: request bodies are buffered whole either way (up to `maxBodyBytes`),
so memory does not depend on them. One stream uploads at most one stream window per round trip, so with a 50 ms
round trip the default 256 KiB allows about 5 MB/s per stream; raise it for large uploads over long distances.
Values below 65,535 are raised to it.

- Browsers only speak HTTP/2 over TLS: use h2c service to service, or behind a proxy that speaks h2c to its
  upstreams (configuration checked against each one's docs):
  - Caddy: `reverse_proxy h2c://127.0.0.1:8080`.
  - HAProxy 1.9+: `server app 127.0.0.1:8080 proto h2`.
  - Envoy: an upstream cluster with `explicit_http_config.http2_protocol_options` and no TLS transport socket.
  - Google Cloud: Cloud Run with end-to-end HTTP/2 (container port named `h2c`); the Application Load Balancer with
    backend service protocol `H2C` (not on the classic Application Load Balancer; its `HTTP2` protocol requires TLS).
  - AWS ALB: HTTP/2 target groups (protocol version `HTTP2`) only work behind an HTTPS listener. AWS does not document
    whether the hop to the target may be cleartext; users report h2c working, but it is untested here. An HTTPS
    target group pointing at vela's TLS listener is the documented path.
- Not for gRPC yet: gRPC needs response trailers (`grpc-status`) and streamed bodies, which vela does not support.
- Each stream runs in its own fiber, exactly like an HTTP/1.1 request: `maxInFlight` counts streams (above it the
  stream is refused with `REFUSED_STREAM`, safe to retry), `requestTimeoutMs` applies per stream (504), a
  `RST_STREAM` from the client cancels only that handler, and closing the connection cancels all of them.
- Graceful stop sends `GOAWAY`; streams already accepted finish first. Idle connections get `GOAWAY` after `idleTimeoutMs`.
- Limits are the same as HTTP/1.1 (`Limits`: header list, `:path`, body) and answer with the same statuses (431, 414, 413).
- Protection: `CONTINUATION` floods, rapid reset and control-frame floods (`PING`, `SETTINGS`, `PRIORITY`, empty
  frames) end the connection with `ENHANCE_YOUR_CALM`; reading pauses while a client does not read its responses.
- Not implemented: server push (clients disable it), priorities (accepted and ignored, as RFC 9113 allows), the HPACK
  dynamic table when encoding responses (decoding uses it as required).
- Conformance: [h2spec](https://github.com/summerwind/h2spec) passes all 146 cases over TLS and 145 in cleartext.
  The remaining one (3.5/2, an invalid preface) cannot pass on a cleartext port that also serves HTTP/1.1: there
  it is a malformed HTTP/1.1 request, which correctly gets a 400. Also tested against curl (nghttp2) and python-h2,
  in cleartext and over TLS.
- Measured: 1,000 in-flight streams over 10 connections peak at ~16 MB of RSS; the HTTP/2 hot path (frames, HPACK,
  dispatch, framing the response) does not allocate on the GC.

## Commands

```sh
tools/check.sh                       # everything: unittests, example, allocation, network, Postgres, HTTP client, memory, compile-fail, budget
                                     # (starts a throwaway PostgreSQL and a Python upstream; without them, those tests are skipped)
DC=ldmd2 tools/check.sh              # the same with LDC
tools/h2_interop.sh                  # HTTP/2 and HTTPS against curl, python-h2 and h2spec (H2SPEC=/path/to/h2spec); part of check.sh
tools/fuzz.sh 600 h2                 # libFuzzer + ASan on the HTTP/2 session (or "parse" for the HTTP/1 parser)

cd examples/hello && dub run         # starts the example at http://localhost:8080
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'
```

Tested with DMD 2.113 and LDC 1.43 (Linux x86_64).

Requirements: a D compiler (DMD or LDC) and DUB. The core (`vela`) needs no database. Only whoever uses the optional `vela-pg` driver needs `libpq5` at run time; HTTPS (the server's TLS listener and the HTTP client's outgoing calls) needs OpenSSL 3 (both loaded by dlopen).

## Packages

| Package       | Role                                                        | Depends on |
|---------------|-------------------------------------------------------------|------------|
| `vela:http`   | types, zero-copy HTTP/1.1 parser and writer, HTTP/2 session and HPACK. No I/O. | — |
| `vela:web`    | App, router, handler introspection, JSON, middleware        | http       |
| `vela:engine` | event loop, buffers, connections, `offload`, HTTP/TLS client. Knows nothing about routes. | http |
| `vela-pg` (`drivers/pg`) | cooperative PostgreSQL driver (async libpq). **An independent DUB package**: the core depends neither on it nor on libpq | vela:engine |
| `vela`        | `import vela;` and `vela.server` (glue between web and engine) | all     |

## Rules the tests guarantee

- The framework's hot path does not allocate on the GC, over HTTP/1.1 and HTTP/2 (`tests/alloc/`).
- An invalid signature = a one-line compile error (`tests/compile_fail/`).
- The example's `app.d` compiles in under 400 ms on DMD (`tools/check.sh`).
- The engine handles cancellation, the request ceiling, deadlines and partial writes (`tests/net/epoll_net.d`).
- The Postgres driver does not block the worker, respects the pool, cancels on the server and discards the connection (`tests/db/pg_net.d`).
- The HTTP/HTTPS client does not block, reuses connections, retries on a stale one and respects deadlines (`tests/net/client_net.d`).
- The parser survives the attack corpus and the fuzzer (`tests/fuzz/`), and the `examples/api` example passes 31 end-to-end checks (`tests/example/api_e2e.py`).
- 1,000 in-flight requests fit in under 30 MB of RSS, over HTTP/1.1 and over HTTP/2; over HTTPS, under 56 MB
  (`tools/check.sh`, memory section).
- HTTPS: ALPN, HTTP/1.1 and HTTP/2 over TLS, handshake deadline, refused cleartext and untrusted clients, cancellation,
  clients resetting mid-response, certificate reload and configuration errors (`tests/net/tls_net.d`).
- The HTTP/2 session handles every frame, stream state, flow-control and error case in `tests/h2/session_test.d`, survives
  the mutation fuzzer and its regressions (`tests/fuzz/fuzz_h2.d`), and the engine passes `tests/net/h2_net.d` (multiplexing,
  cancellation, deadlines, flow control, upgrade, timeouts, graceful stop).

## Spikes

- `spikes/epoll_fibers/`: epoll + one fiber per request, 10,000 in-flight requests (see the README there).

## Pitfalls

- Function tables loaded through dlopen live in a `struct`, never in loose `extern (C)` variables:
  an `extern (C)` variable named `ERR_clear_error` becomes a global symbol and libssl itself starts calling it.
- A `Group.use` only affects routes registered after it (Express semantics).
- `pgPool`/`httpClient` are thread-local (one per worker); do not pass connections between workers.
- Module variables in D are thread-local: with several workers, each has its own copy.
- A `get`/`post` of your own in the same unit hides vela's `get`/`post`; use `vela.get!(...)(app)`.
- Blocking code in a handler (a `Thread.sleep`, a synchronous C lib) stalls the whole worker.
  The loop warns in the log when a handler goes past `stallWarnMs` (50 ms) without yielding.
  I/O waits go through `sleep`/`awaitFd`. A handler that goes past `requestTimeoutMs` without waiting
  for anything is only cancelled when it waits again.
- D's GC interrupts blocking `read`/`send` calls (test clients, tools) with `EINTR`; handle it.
- `Header!"X"` and `const(char)[]` are slices of the network buffer, valid only during the
  request. Use `string` (copied) or `.idup` to keep them.
- Handlers and middleware may be `@safe` (recommended) or `@system`; `-version=VelaStrictSafe` requires `@safe`.
  Wrap C calls and `__gshared` access in a small `@trusted` function. `epoll.d` and `devserver.d` stay `@system`
  by design (raw syscalls) behind the `@trusted` `serve`.
- Handlers are module functions, lambdas (which may capture local variables) or
  controller methods with `@Get(...)` mounted through `app.mount(obj)`.

## License

[MIT](LICENSE).
