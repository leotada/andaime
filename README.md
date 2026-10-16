# vela

**vela** is a fast, memory-safe web framework for D with FastAPI-style ergonomics: **a handler's function signature is its HTTP contract**.

Path parameters, query strings, headers, cookies, JSON payloads, forms, and multipart uploads are extracted and validated directly from parameter types and names by code generated at compile time. Invalid requests are rejected with a `422 Unprocessable Content` response before your handler ever runs, and the OpenAPI 3.1 schema and Swagger UI are generated from the exact same signatures.

> [!NOTE]
> The name **vela** is provisional (DUB package `vela`, `import vela;`); the repository is `dapi`.

```d
// check
@safe:

import vela;

struct UserInput { @minLength(2) string name; @inRange(0, 150) int age; }
struct User { long id; string name; int age; }

User getUser(long id) => User(id, "Ana", 31);                                 // GET /users/{id}

@status(201)
User createUser(JsonBody!UserInput body_) => User(1, body_.name, body_.age);  // POST /users

App buildApp()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.serveOpenApi(OpenApiInfo("Users API", "1.0.0"));                      // /openapi.json + Swagger UI at /docs
    return app;
}

void main() { serve(&buildApp, 8080); }
```

Query the running server or send invalid input to see every validation failure reported at once:

```sh
curl localhost:8080/users/7
# {"id":7,"name":"Ana","age":31}

curl -X POST localhost:8080/users -d '{"name":"A","age":200}'
# HTTP/1.1 422 Unprocessable Content
```

```json
{
  "detail": [
    {"type": "string_too_short", "loc": ["body", "name"], "msg": "expected at least 2 characters"},
    {"type": "less_than_equal",  "loc": ["body", "age"],  "msg": "must be <= 150"}
  ]
}
```

---

## Why vela

- **Zero-boilerplate endpoints.** No manual request parsing, no repetitive validation logic, and no separate schema files to keep in sync. Your D types and function signatures define routing, validation, serialization, and OpenAPI documentation in one place.
- **Plain sequential code, high concurrency.** One worker thread per CPU core (`SO_REUSEPORT`) runs an `epoll` event loop with one lightweight fiber per request. Database queries, HTTP client requests, WebSockets, and `sleep` suspend only the active fiber—never the worker thread.
- **Production server included.** Native HTTP/1.1, HTTP/2 (over TLS and cleartext `h2c`), WebSockets (RFC 6455 and RFC 8441 over HTTP/2), automatic HTTPS redirects and ACME challenge serving, live certificate reloading without restarts, request deadlines, and graceful shutdown. No reverse proxy required in front.
- **Small footprint and sub-second builds.** Around 25 MB RSS under 1,000 concurrent connections, zero GC allocations on the hot request path, and the core avoids heavy Phobos templates so an example application type-checks in under 400 ms on DMD.
- **One-line compile errors.** Mistakes in handler signatures fail at compile time with a single human-readable diagnostic instead of a deep template backtrace:
  ```text
  app.d(12): vela: handler 'getUser' in GET /users/{id}: the route declares {id}, but the function has no parameter named 'id'
  ```
- **Memory-safe by default (`@safe`).** The framework is checked with `@safe` and `-preview=dip1000`. Your handlers can be `@safe` too, or call `@system` C libraries directly without ceremony.

---

## Quickstart

### Requirements

- **OS:** Linux x86_64 for the production `epoll` server (other platforms fall back to a blocking development server).
- **Compiler:** DMD 2.109.1+ or LDC 1.40.1+, with DUB.
- **Optional runtime libraries** (loaded on demand via `dlopen`, never required to build): OpenSSL 3 (`libssl.so.3` / `libcrypto.so.3`), PostgreSQL (`libpq.so.5`), zlib (`libz.so.1`), and `libcrypt.so.1`.

### 1. Create a project

`vela` is not published on `code.dlang.org` yet; depend on a local checkout:

```sh
git clone https://github.com/leotada/dapi
mkdir my-api && cd my-api
```

Create `dub.sdl`:

```sdl
name "my-api"
targetType "executable"
dependency "vela" path="../dapi"
```

### 2. Write your first API and test

Create `source/app.d`:

```d
// check
@safe:

import vela;

string hello(string name = "world") => "hello, " ~ name;

App buildApp()
{
    auto app = new App;
    app.get!("/hello", hello);
    return app;
}

version (unittest) {} else
void main() { serve(&buildApp, 8080); }

unittest
{
    auto client = TestClient(buildApp());
    assert(client.get("/hello").body == "hello, world");
    assert(client.get("/hello?name=Ana").body == "hello, Ana");
}
```

### 3. Run and verify

```sh
dub test                                 # runs in-memory tests without opening a socket
dub run                                  # starts the server on http://localhost:8080
curl 'http://localhost:8080/hello?name=Ana'
```

Want to explore working applications right away? Run the included examples in the repository:

```sh
cd examples/hello && dub test && dub run # in-memory CRUD, controller, middleware, tests
cd examples/api   && dub run             # PostgreSQL, external HTTP client, Bearer auth, CORS, static files, OpenAPI
```

See the full [Getting started guide](docs/getting-started.md) for a step-by-step walkthrough.

---

## Feature tour

### Requests, validation, and responses

Parameters are bound automatically by type and name from the URL path, query string, headers, cookies, JSON or form bodies, or middleware state:

```d
// GET /items?q=book&tag=dlang&tag=web&limit=10
Item[] search(string q, string[] tag, Header!"Accept-Language" lang, int limit = 20) { ... }

// PATCH /users/{id} — PatchField distinguishes omitted fields from explicit null
User updateUser(long id, JsonBody!UserPatch patch, Local!Caller caller) { ... }
```

Return values become HTTP responses automatically:
- `void` returns `204 No Content`.
- `string` returns `text/plain`; structs, associative arrays, and slices serialize to `application/json`.
- `@status(201)`, `WithStatus!T`, and `Response` customize status codes, headers, and cookies.
- `throw new HttpError(404, "user not found")` aborts the request with a structured JSON error.

### Middleware, route groups, and structured logging

Wrap the entire application or specific route groups with middleware, pass request-scoped values via `Local!T`, and emit structured logs (`text`, `kv`, or `json`) that automatically carry the current `request_id`:

```d
app.use(requestId());
app.use(accessLog());
app.use(cors(CorsConfig(["https://app.example.com"])));

auto api = app.group("/api");
api.use((Context ctx, Next next) {
    if (bearerToken(ctx) != secret)
        throw new HttpError(401, "invalid or missing token");
    next();
});

logInfo("order created", "order_id", order.id, "plan", order.plan);
```

### Streaming, Server-Sent Events, and WebSockets

Stream chunked responses or Server-Sent Events with automatic backpressure, or upgrade to WebSockets (over HTTP/1.1 or multiplexed HTTP/2 streams per RFC 8441) after middleware and parameter validation have run:

```d
EventStream ticks() => EventStream((scope EventWriter w) {
    foreach (i; 0 .. 10)
    {
        w.send("tick");
        sleep(1.seconds); // suspends only this fiber
    }
});

WebSocket chat(string room, Header!"Authorization" auth)
{
    if (!allowed(auth.value))
        throw new HttpError(403, "forbidden");
    return WebSocket((scope WsConn ws) {
        foreach (msg; ws)
            ws.send(room ~ ": " ~ msg.text); // pings and close handshakes are handled automatically
    });
}
```

### Non-blocking I/O: PostgreSQL, HTTP client, and CPU offload

Query PostgreSQL asynchronously (`vela-pg`), call upstream HTTP/HTTPS services, or offload CPU-intensive tasks to a bounded thread pool without blocking the event loop:

```d
User u = pgPool(dsn).query("SELECT id, name, age FROM users WHERE id = $1", id).one!User;
auto quote = httpClient().get("https://api.example.com/quote").body;
auto png = offload(() => renderChart(data));
```

### Background jobs and cron (`vela:jobs`)

Define background jobs as structs with `@Job("queue")` and a `perform` method. Configure retries, uniqueness locks, and `@Cron` schedules with attributes, and run the same binary as an API server, a job worker, or both (`--role=api|worker|all`), backed by in-memory or durable PostgreSQL queues (`vela-pg-jobs`):

```d
@Job("mail") @Retries(5)
struct SendWelcomeEmail
{
    string to;
    long userId;

    void perform(ref JobContext ctx) @safe
    {
        // runs on a worker fiber; enqueued with enqueue(store, SendWelcomeEmail("ana@example.com", 7))
    }
}
```

### Cryptography (`vela:crypto`)

Hash passwords with bcrypt on the offload pool, compute SHA-256 / HMAC / HKDF, encrypt with AES-128-GCM, sign ES256 JWTs, or encrypt RFC 8291 Web Push notifications:

```d
string hash = bcryptHashOffload(password);
bool ok = bcryptVerifyOffload(password, hash);
auto sig = es256Sign(vapidKey, jwtSigningInput);
```

### Production HTTPS and HTTP/2

Serve HTTPS and HTTP/2 directly from `vela`, with automatic port 80 redirects, ACME HTTP-01 challenge handling, and zero-downtime certificate reloading:

```d
ServerConfig cfg;
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile  = "/etc/letsencrypt/live/example.com/privkey.pem";
cfg.tls.redirectPort = 80; // serves ACME challenges and redirects HTTP to HTTPS
serve(&buildApp, cfg);
```

---

## Packages

The core framework has zero external DUB dependencies. Optional capabilities live in separate subpackages or driver packages so you only pull in what you use:

| Package | Import | Description |
|---------|--------|-------------|
| `vela` | `import vela;` | Root package: re-exports `vela:http`, `vela:web`, `vela:engine`, the server (`serve`), and static file serving. |
| `vela:http` | `import vela.http;` | HTTP types, zero-copy HTTP/1.1 parser, HTTP/2 session & HPACK, WebSocket codec & `WsConn`, `Optional`, `PatchField`. |
| `vela:web` | `import vela.web;` | `App`, router, compile-time handler introspection, JSON codec, OpenAPI, middleware, `vela.log`, `TestClient`. |
| `vela:engine` | `import vela.engine;` | `epoll` loop, fibers, buffer pool, `offload` pool, HTTP/HTTPS and WebSocket clients, OpenSSL & zlib loaders. |
| `vela:jobs` | `import vela.jobs;` | Background jobs, retries, uniqueness, cron schedules, `InMemoryJobStore`, and `TestJobStore`. |
| `vela:crypto` | `import vela.crypto;` | Bcrypt, SHA-256, HMAC, HKDF, AES-128-GCM, P-256 (ES256 & ECDH), and RFC 8291 Web Push encryption. |
| `vela-pg` (`drivers/pg`) | `import vela.db.pg;` | Asynchronous PostgreSQL driver & connection pool over `libpq` (`dlopen`). |
| `vela-pg-jobs` (`drivers/pgjobs`) | `import vela.jobs.pg;` | Durable PostgreSQL `JobStore` using `FOR UPDATE SKIP LOCKED`, `LISTEN`/`NOTIFY`, lease reaping, and distributed cron deduplication. |

---

## Documentation

Start with the [Documentation index](docs/README.md) or jump directly to a guide:

| Category | Guides |
|----------|--------|
| **Fundamentals** | [Getting started](docs/getting-started.md) · [Routing](docs/routing.md) · [Reading the request](docs/requests.md) · [Validation and errors](docs/validation.md) · [Responses](docs/responses.md) |
| **Building APIs** | [Middleware and error handling](docs/middleware.md) · [Logging](docs/logging.md) · [Streaming & SSE](docs/streaming.md) · [WebSockets](docs/websocket.md) · [Static files and OpenAPI](docs/static-files-and-openapi.md) |
| **Async, Data & Auth** | [Concurrency](docs/concurrency.md) · [Database (`vela-pg`)](docs/database.md) · [Jobs and cron](docs/jobs-and-cron.md) · [HTTP client](docs/http-client.md) · [Cryptography (`vela:crypto`)](docs/crypto.md) |
| **Quality & Safety** | [Testing (`TestClient`)](docs/testing.md) · [Memory safety (`@safe`)](docs/safety.md) |
| **Production** | [Deploying](docs/deploy.md) · [HTTPS & TLS](docs/tls.md) · [HTTP/2](docs/http2.md) · [Configuration reference](docs/configuration.md) |

---

## Status and current limitations

`vela` is in active pre-1.0 development, and APIs may still evolve before the first tagged release. Everything included is heavily tested in CI across DMD and LDC (see [CONTRIBUTING.md](CONTRIBUTING.md)):
- **HTTP/1.1 & HTTP/2:** RFC 9113 compliant (`h2spec` 146/146 over TLS), tested against Chromium, `curl`, `python-h2`, and Caddy (`h2c`), plus continuous `libFuzzer` + ASan coverage.
- **WebSockets:** RFC 6455 with `permessage-deflate` over HTTP/1.1 and RFC 8441 extended `CONNECT` over HTTP/2, tested against Chromium, Python's `websockets`, and `python-h2`.
- **PostgreSQL, Jobs, Crypto & Clients:** Tested end-to-end against real PostgreSQL instances, TLS upstreams, and official cryptographic test vectors.

**Not supported yet:**
- Non-Linux event loops (`kqueue`, `io_uring`): the production `epoll` server requires Linux; other OSes use a single-threaded blocking development server.
- Unbuffered request body streaming (request bodies, including multipart uploads, are buffered in memory up to `limits.maxBodyBytes`, 1 MiB by default) and `Range` requests.
- HTTP/2 response trailers (required for gRPC), server push, and stream priorities; the WebSocket client speaks HTTP/1.1 only.
- IPv6 listeners and OCSP stapling.

---

## Contributing

Instructions for building, running `tools/check.sh` and the fuzzers, and the project's architectural rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
