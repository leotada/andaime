# vela

A micro web framework for D with FastAPI-style ergonomics: **the function signature is the HTTP contract**. Path, query,
headers, cookies, JSON and form bodies (including file uploads) are extracted and validated from the parameter types and
names, by code generated at compile time. Bad input is a 422 before your handler runs, and the OpenAPI document comes from
the same signatures.

```d
// check
@safe:

import vela;

struct UserInput { @minLength(2) string name; @inRange(0, 150) int age; }
struct User { long id; string name; int age; }

User getUser(long id) => User(id, "Ana", 31);                                // GET /users/{id}

@status(201)
User createUser(JsonBody!UserInput body_) => User(1, body_.name, body_.age);  // POST /users

App buildApp()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.serveOpenApi(OpenApiInfo("Users", "1.0.0"));     // /openapi.json and Swagger UI at /docs
    return app;
}

void main() { serve(&buildApp, 8080); }
```

```sh
curl localhost:8080/users/7                                     # {"id":7,"name":"Ana","age":31}
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'   # 422, every problem listed
```

```json
{"detail":[{"type":"string_too_short","loc":["body","name"],"msg":"expected at least 2 characters"},
           {"type":"less_than_equal","loc":["body","age"],"msg":"must be <= 150"}]}
```

> The name **vela** is provisional (DUB package `vela`, `import vela;`); the repository is `dapi`.

## Why vela

- **Little code per endpoint.** No request parsing, no manual validation, no separate schema: the signature says it all.
- **Plain sequential code, high concurrency.** Each request runs in a fiber. A database query, an HTTP call or `sleep`
  suspends only that request; one worker per core serves thousands of connections.
- **Production server included.** HTTP/1.1, HTTP/2 and HTTPS on one port, certificate reload without restarts, request
  deadlines, graceful stop, rate-limited logs. No proxy required in front.
- **Small and fast.** About 25 MB of memory for 1,000 simultaneous requests; no GC allocation on the request path; the example
  app type-checks in under 400 ms.
- **Readable compile errors.** A wrong handler signature is one line that says what to fix.
- **`@safe`.** The framework is memory-safe D; your handlers can be too (recommended, not required).

## Install

vela is not on code.dlang.org yet; depend on a checkout. Requirements: Linux x86_64, DMD 2.109.1+ or LDC 1.40.1+, DUB.

```sh
git clone https://github.com/leotada/dapi
```

```sdl
# your project's dub.sdl
dependency "vela" path="../dapi"
```

Then follow [Getting started](docs/getting-started.md).

## A tour

**Parameters** come from the route, the query string, headers, cookies or the body, by type and name:

```d
Item[] search(string q, string[] tag, Header!"Accept-Language" lang, int limit = 20) { ... }  // GET /search?q=x&tag=a&tag=b
Order create(JsonBody!NewOrder body_, Local!Caller who) { ... }                              // POST, a value from middleware
```

**Returns** become responses: `void` is 204, `string` is text, structs and arrays are JSON; `@status(201)`, `WithStatus!T`
and `Response` choose the status; `throw new HttpError(404, "not found")` for errors.

**Middleware** wraps requests, for the whole app or a group:

```d
auto api = app.group("/api");
api.use((Context ctx, Next next) {
    if (bearerToken(ctx) != secret) throw new HttpError(401, "missing token");
    next();
});
app.use(requestId());
app.use(accessLog());
app.use(cors(CorsConfig(["https://app.example.com"])));
```

**Streaming** and Server-Sent Events, with backpressure:

```d
EventStream ticks() => EventStream((scope EventWriter w) {
    foreach (i; 0 .. 10) { w.send("tick"); sleep(1.seconds); }   // the fiber waits; the worker does not
});
```

**WebSockets**: the handler returns one after its parameters and middleware ran, so refusing is an ordinary response:

```d
WebSocket chat(string room, Header!"Authorization" auth)
{
    if (!allowed(auth.value)) throw new HttpError(403, "forbidden");
    return WebSocket((scope WsConn ws) {
        foreach (msg; ws) ws.send(room ~ ": " ~ msg.text);    // pings and the close handshake are handled
    });
}
app.ws!("/chat/{room}", chat);
```

**Waiting without blocking**: PostgreSQL (`vela-pg`), an HTTP client and a thread pool:

```d
User u = pgPool(dsn).query("select id, name, age from users where id = $1", id).one!User;
auto quote = httpClient().get("https://api.example.com/quote").body;
auto png = offload(() => renderChart(data));        // CPU-heavy work on a bounded thread pool
```

**Tests** run in memory, without sockets:

```d
unittest
{
    auto c = TestClient(buildApp());
    assert(c.post("/users", `{"name":"Ana","age":31}`).status == 201);
    assert(c.get("/users/abc").status == 422);
}
```

**HTTPS and HTTP/2** with a certificate, or h2c behind a proxy:

```d
ServerConfig cfg;
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile = "/etc/letsencrypt/live/example.com/privkey.pem";
cfg.tls.redirectPort = 80;                       // ACME challenges + redirect to HTTPS
serve(&buildApp, cfg);
```

## Documentation

| | |
|-|-|
| [Getting started](docs/getting-started.md) | install, first route, CRUD, first test |
| [Routing](docs/routing.md) · [Reading the request](docs/requests.md) · [Validation](docs/validation.md) · [Responses](docs/responses.md) | the handler contract |
| [Middleware and errors](docs/middleware.md) · [Streaming](docs/streaming.md) · [WebSockets](docs/websocket.md) · [Static files and OpenAPI](docs/static-files-and-openapi.md) | building an API |
| [Concurrency](docs/concurrency.md) · [Database](docs/database.md) · [HTTP client](docs/http-client.md) | waiting without blocking |
| [Testing](docs/testing.md) · [Memory safety](docs/safety.md) | |
| [Deploying](docs/deploy.md) · [HTTPS](docs/tls.md) · [HTTP/2](docs/http2.md) · [Configuration](docs/configuration.md) | production |

All of it starts from the [documentation index](docs/README.md). Two complete applications are in `examples/hello` (in-memory
CRUD, controller, tests) and `examples/api` (Postgres, external API, auth, CORS, static files, OpenAPI).

## Status and limits

vela is young: the API may still change before a first release. What works is tested (see [CONTRIBUTING.md](CONTRIBUTING.md)):
the web layer, the epoll server, HTTP/2 (RFC 9113; h2spec 146/146 over TLS; tested with Chromium, curl, python-h2 and Caddy),
HTTPS, streaming, WebSockets (RFC 6455 with permessage-deflate, over HTTP/1.1 and as HTTP/2 streams per RFC 8441; tested
with Chromium, python's `websockets` and python-h2), the PostgreSQL driver and the HTTP and WebSocket clients.

Not supported yet:

- Linux only for the real server (epoll); elsewhere `serve` runs a blocking development server.
- Streamed request bodies (bodies, including multipart uploads, are buffered up to `limits.maxBodyBytes`, 1 MiB by default),
  Range requests; the WebSocket client speaks HTTP/1.1 only.
- Response trailers, so no gRPC; HTTP/2 server push and priorities.
- IPv6 listeners, OCSP stapling, kqueue/io_uring backends.

## Contributing

Building, running the test suite and the project's rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
