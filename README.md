<div align="center">

# 🏗️ andaime

**A fast, modular, memory-safe web framework for D. Your function signature *is* your HTTP contract.**

[![CI](https://github.com/leotada/andaime/actions/workflows/check.yml/badge.svg)](https://github.com/leotada/andaime/actions/workflows/check.yml)
![D edition 2025](https://img.shields.io/badge/D_edition-2025-B03931)
![DMD 2.112.0+](https://img.shields.io/badge/DMD-2.112.0%2B-informational)
![LDC 1.42.0+](https://img.shields.io/badge/LDC-1.42.0%2B-informational)
![@safe](https://img.shields.io/badge/%40safe-%2B_dip1000-success)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

[Quickstart](#quickstart) · [Features](#features) · [Examples](#examples) · [Architecture CLI](#architecture) · [Performance](#performance) · [Comparison](#comparison) · [Docs](docs/README.md)

</div>

> [!NOTE]
> **andaime** is Portuguese for *scaffolding*. Start with a small core (`import andaime;`) and attach modules (database, jobs, crypto) only when you need them.

---

## 💡 What it is, in 30 seconds

You write plain D functions. andaime reads their parameter names and types **at compile time** and generates the routing, extraction, validation, JSON serialization, and OpenAPI docs. No decorators to keep in sync, no schema files, no runtime reflection.

```d
// check
@safe:

import andaime;

struct NewUser                                   // JSON body, validated before your code runs
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;                       // may be absent or null
}

struct User { long id; string name; int age; Optional!string email; }

struct Page                                      // query string: ?limit=10&offset=20
{
    @inRange(1, 100) int limit = 20;
    @optional @inRange(0, int.max) int offset;
}

private User[] users;                            // stands in for a database
private long lastId;

User[] listUsers(Query!Page page)                                       // GET /users
{
    auto rest = page.offset < users.length ? users[page.offset .. $] : null;
    return rest.length > page.limit ? rest[0 .. page.limit] : rest;
}

@responds(404, "user not found")
User getUser(long id)                                                   // GET /users/{id}
{
    foreach (u; users)
        if (u.id == id) return u;
    throw new HttpError(404, "user not found");
}

@status(201)
User createUser(JsonBody!NewUser body_)                                 // POST /users
{
    users ~= User(++lastId, body_.name, body_.age, body_.email);
    return users[$ - 1];
}

@responds(404, "user not found")
void deleteUser(long id)                                                // DELETE /users/{id}: void is 204
{
    foreach (i, u; users)
        if (u.id == id) { users = users[0 .. i] ~ users[i + 1 .. $]; return; }
    throw new HttpError(404, "user not found");
}

App buildApp()                                   // runs once per worker
{
    auto app = new App;
    app.get!("/users", listUsers);
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.del!("/users/{id}", deleteUser);
    app.serveOpenApi(OpenApiInfo("Users API", "1.0.0"));                // /openapi.json + Swagger UI at /docs
    return app;
}

void main()
{
    // Module variables are per thread, so this in-memory store needs one worker.
    // With a real database, leave `workers` at 0 (one per CPU core).
    ServerConfig cfg = { port: 8080, workers: 1 };
    serve(&buildApp, cfg);
}
```

Bad input never reaches your handler—every validation error is reported at once:

```sh
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'
# HTTP/1.1 422 Unprocessable Content
# {"detail":[
#   {"type":"string_too_short","loc":["body","name"],"msg":"expected at least 2 characters"},
#   {"type":"less_than_equal", "loc":["body","age"], "msg":"must be <= 150"}
# ]}
```

And an invalid handler signature produces **one readable compiler error**, not a template backtrace:

```text
app.d(12): andaime: handler 'getUser' in GET /users/{id}: the route declares {id}, but the function has no parameter named 'id'
```

---

<a id="quickstart"></a>

## 🚀 Quickstart

**Requirements**
- 🐧 **Linux x86_64** for production (`epoll`). macOS (`kqueue`) and Windows (`WSAPoll`) backends compile in CI and are experimental at runtime.
- 🧑‍💻 **DMD 2.112.0+** or **LDC 1.42.0+** (includes DUB, D's package manager). The framework is written in **D Edition 2025** (`module x 2025;`) and type-checks with `-preview=dip1000`; your app can use edition 2025 or the baseline edition.
- 📦 **Zero build-time C dependencies**: OpenSSL 3, `libpq.so.5`, `zlib`, and `libcrypt.so.1` are loaded via `dlopen` at runtime only when used.

**1. Create a project**

```sh
dub init my-api --type=minimal -n --format=sdl
cd my-api
dub add andaime
```

*(Or scaffold a layered project with `dub run andaime:cli -- new my-api`; see [Architecture CLI](#architecture).)*

**2. Write a route and an in-memory test** in `source/app.d`:

```d
// check
module app 2025;

@safe:

import andaime;

string hello(string name = "world") => "hello, " ~ name;

App buildApp()
{
    auto app = new App;
    app.get!("/hello", hello);
    return app;
}

unittest
{
    auto client = TestClient(buildApp());
    assert(client.get("/hello").body == "hello, world");
    assert(client.get("/hello?name=Ana").body == "hello, Ana");
}

version (unittest) {} else
void main() { serve(&buildApp, 8080); }
```

**3. Test and run**

```sh
dub test                                   # runs in-memory tests, no socket opened
dub run                                    # starts on http://localhost:8080
curl 'http://localhost:8080/hello?name=Ana'
```

**Examples in this repository:**

```sh
cd examples/hello && dub test && dub run   # in-memory CRUD, controller, middleware, tests
cd examples/api   && dub run               # PostgreSQL, HTTP client, Bearer auth, CORS, static files, OpenAPI
cd examples/clean && dub test              # Clean Architecture (domain, use cases, adapters, jobs, tenant)
```

➡️ Full walkthrough: [Getting started](docs/getting-started.md).

---

<a id="features"></a>

## ✨ Features & Modularity

### 🎯 Ergonomics & TypeScript-friendly Contracts
- **Signature = contract**: path, query, headers, cookies, JSON, forms, and multipart bound by name and type.
- **Declarative validation** (`@minLength`, `@inRange`, ...) with automatic **422** responses and localizable messages (`app.validationMessages(...)`).
- **OpenAPI 3 + Swagger UI** generated from the same structs—pair with `npx openapi-typescript` for end-to-end type safety with zero manual schemas.
- **Domain value types** (`andaime.values`): `PatchField!T` (distinguishes omitted from `null` in `PATCH`), `Optional!T`, `JsonValue`, `Uuid` (v4/v7), `Timestamp`, and `CalendarDate`.
- **Project-wide conventions**: `app.errorBody(...)` for unified error responses (including ready-made RFC 9457), and `versions "AndaimeNamingSnakeCase"` to rename JSON, queries, OpenAPI, and SQL columns at once.
- **Middleware state & DTO helpers**: `Local!T` for request-scoped middleware values, `copyAs!Dst(src)` for mapping DTOs.

### 🌐 Protocols (No Reverse Proxy Needed)
- **HTTP/1.1** with pipelining, **HTTP/2** over TLS and cleartext (`h2c`), `h2spec` **146/146**.
- **HTTPS** with live certificate reload, HTTP → HTTPS redirect, and ACME HTTP-01 challenges.
- **WebSockets**: RFC 6455 with `permessage-deflate`, plus RFC 8441 over HTTP/2.
- **Streaming** responses and **Server-Sent Events (SSE)** with backpressure.

### 🧵 Concurrency & Safety
- **One worker per core** (`SO_REUSEPORT`), each running its own event loop.
- **One fiber per request**: write sequential code without `async`/`await`. I/O or `sleep` suspends only that fiber; `fiberLocal!T` holds per-request context.
- **`offload(...)`** runs CPU-heavy or blocking work on a bounded thread pool.
- **Deadlines**, cancellation of abandoned requests, and graceful shutdown.
- **`@safe` + `dip1000`** across the codebase (while still allowing `@system` user handlers), plus continuous **libFuzzer + ASan** on HTTP/1.1, HTTP/2, WebSocket, and JSON parsers.

### 🧩 Modular Packages

`import andaime;` gives you the web server. Add optional packages to `dub.sdl` only when needed:

| Package | Add / Build | Import | What you get |
|---|---|---|---|
| 🏗️ `andaime` | `dub add andaime` | `import andaime;` | Server (`http` + `web` + `engine`), `serve`, static files |
| 🐘 `andaime:pg` | `dub add andaime:pg` | `import andaime.db;` | Async PostgreSQL driver, connection pool, ambient transactions |
| ⏰ `andaime:jobs` | `dub add andaime:jobs` | `import andaime.jobs;` | Background jobs, retries, uniqueness, cron, in-memory & test stores |
| 🗄️ `andaime:pgjobs` | `dub add andaime:pgjobs` | `import andaime.jobs.pg;` | Durable Postgres job queue (`SKIP LOCKED`, `LISTEN`/`NOTIFY`) |
| 🔐 `andaime:crypto` | `dub add andaime:crypto` | `import andaime.crypto;` | bcrypt, SHA-256, HMAC, HKDF, AES-128-GCM, ES256 (JWT), ECDH, Web Push |
| 🛠️ `andaime:cli` | `dub build :cli` | *(CLI tool)* | `andaime` command: scaffolding, generators, route table, architecture checks |
| 🧱 `http` / `web` / `engine` | *(subpackages of `andaime`)* | `import andaime.http;` etc. | Use standalone if you only want the zero-copy parsers, `TestClient`, or event loop |

---

<a id="examples"></a>

## 🧪 Examples

### 🐘 PostgreSQL (`andaime:pg`)

Queries suspend only the calling fiber. Transactions (`db.transaction(...)`) are ambient: every query on the pool from that request automatically joins the active transaction.

```d
import andaime;
import andaime.db;

struct User { int id; string name; }
struct NewUser { @minLength(2) string name; }

PgPool db() => pgPool("host=localhost dbname=app user=app");   // one pool per worker, created on first use

User getUser(int id)                                            // GET /users/{id}
{
    auto rows = db.query("select id, name from users where id = $1", id).rowsAs!User;
    if (rows.length == 0)
        throw new HttpError(404, "user not found");
    return rows[0];
}

@status(201)
User createUser(JsonBody!NewUser body_)                         // POST /users
    => db.query("insert into users(name) values ($1) returning id, name", body_.name).one!User;
```

➡️ [Database guide](docs/database.md)

### 🔌 WebSockets & Server-Sent Events

WebSocket routes validate parameters like any HTTP route before upgrading, and work over both HTTP/1.1 and HTTP/2:

```d
import andaime;

WebSocket chat(string room, Header!"Authorization" auth)
{
    if (auth.value != "Bearer secret")
        throw new HttpError(403, "forbidden");                  // rejected before upgrade
    return WebSocket((scope WsConn ws) {
        ws.send("welcome to " ~ room);
        foreach (msg; ws)                                       // reads until client closes
            ws.send(msg.text);
    });
}

EventStream ticks() => EventStream((scope EventWriter w) {      // GET SSE stream
    foreach (i; 0 .. 10) { w.send("tick"); sleep(1.seconds); }
});
```

➡️ [WebSockets guide](docs/websocket.md) · [Streaming and SSE guide](docs/streaming.md)

### ⏰ Background Jobs & Cron (`andaime:jobs`)

Run API and workers in one binary (`--role=all`) or split them (`--role=api`, `--role=worker`). Inside a Postgres transaction, `enqueue` joins it automatically as a transactional outbox.

```d
import andaime;
import andaime.jobs;

@Job("mail") @Retry(5, BackoffStrategy.exponential) @UniqueJob(15.minutes)
struct SendWelcome
{
    string to;
    void perform(ref JobContext ctx) @safe { /* send email; throwing schedules a retry */ }
}

@Job("reports") @Cron("15 6 * * *")                             // every day at 06:15
struct DailyReport
{
    void perform(ref JobContext ctx) @safe { /* ... */ }
}
```

➡️ [Jobs and cron guide](docs/jobs-and-cron.md)

### 🛡️ Middleware, Auth, HTTP Client & TLS

```d
// Middleware & structured logging
app.use(requestId());
app.use(accessLog());
app.use(cors(CorsConfig(["https://app.example.com"])));
logInfo("order created", "order_id", order.id);                 // includes request_id automatically

// Non-blocking HTTP client & CPU thread-pool offload
auto quote = httpClient().get("https://api.example.com/quote").body;
auto hash  = bcryptHashOffload(password);

// Production HTTPS + HTTP/2 + automatic HTTP->HTTPS redirect
ServerConfig cfg;
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile  = "/etc/letsencrypt/live/example.com/privkey.pem";
cfg.tls.redirectPort = 80;
serve(&buildApp, cfg);
```

➡️ [Middleware](docs/middleware.md) · [HTTP client](docs/http-client.md) · [Cryptography](docs/crypto.md) · [HTTPS and TLS](docs/tls.md)

---

<a id="architecture"></a>

## 🏛️ Optional Clean Architecture CLI

andaime does not force a project layout. For larger apps, the optional `andaime` CLI scaffolds a layered Clean Architecture project (domain, use cases, HTTP/Postgres/in-memory adapters, unit of work, and transactional outbox) where dependencies point strictly inward:

```text
source/domain/users.d             entities & business rules (no framework or DB imports)
source/usecases/users.d           use cases & port interfaces
source/adapters/http/users.d      controllers & OpenAPI contracts
source/adapters/postgres/users.d  PostgreSQL repository (mirrored in adapters/memory/)
source/app.d                      composition root (built once per worker, no DI container; construct!T wires a class from its constructor)
```

```sh
andaime new my-api --jobs --tenant                          # also: --db none, --template minimal
andaime generate resource user name:string email:string:unique
andaime generate job users SendWelcome user_id:long
andaime routes                                              # print every route and handler
andaime openapi > openapi.json                              # export OpenAPI spec without starting the server
andaime check                                               # verify layer dependency rules via compiler imports
```

[`examples/clean`](examples/clean) is the exact output of these commands. ➡️ [Architecture guide](docs/architecture.md) · [CLI reference](docs/cli.md)

---

<a id="performance"></a>

## ⚡ Performance & Compile Speed

Measured on a single worker pinned to **one CPU core** (`tools/bench.sh` and `tools/check.sh`, guarded in CI):

| Metric | Value | Notes / CI Guard |
|---|---:|---|
| **Throughput (1 CPU core)** | **~95,000 req/s** | 1 request at a time per connection (~10 µs/req; web layer is ~5%) |
| **Throughput (1 core, pipelined)** | **~444,000 req/s** | 16 pipelined requests per connection |
| **GC allocations on hot path** | **0** | Buffers are pooled; enforced by `tests/alloc` across HTTP/1.1, HTTP/2, WS, logs |
| **Type-check `examples/hello`** | **335–430 ms** | DMD `-o-`; CI fails above 440 ms (core avoids heavy Phobos modules & deep templates) |
| **Incremental `dub build`** | **~0.8–1.0 s** | Edit one file and rebuild (debug) |

**Peak RSS memory with 1,000 concurrent connections (1 worker):**

| Workload | DMD | LDC | CI Limit |
|---|---:|---:|---:|
| 1,000 in-flight requests, HTTP/2 | 16.7 MB | 20.6 MB | 30 MB |
| 1,000 open WebSockets | ~21 MB | ~21 MB | 30 MB |
| 1,000 in-flight requests, HTTP/1.1 | 25.2 MB | 27.1 MB | 30 MB |
| 1,000 in-flight requests, HTTPS (HTTP/2) | 54.6 MB | 57.5 MB | 80 MB |
| 1,000 in-flight requests, HTTPS (HTTP/1.1) | 68.3 MB | 70.9 MB | 80 MB |

---

<a id="comparison"></a>

## 📊 How It Compares

Built-in features without third-party plugins (✅ built in · ⚠️ partial · ❌ external library or N/A):

| Feature | 🏗️ andaime (D) | vibe.d (D) | FastAPI (Python) | Express (Node) | Gin (Go) | Rails (Ruby) |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Signature-bound parameters | ✅ | ⚠️ REST interfaces | ✅ | ❌ | ⚠️ struct tags | ❌ `params` |
| Declarative validation + auto 422 | ✅ | ❌ | ✅ | ❌ | ⚠️ | ⚠️ models |
| OpenAPI + Swagger UI from code | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ |
| Compile-time signature checking | ✅ | ✅ | ❌ | ❌ | ⚠️ | ❌ |
| Native binary, sequential fibers | ✅ | ✅ | ❌ | ❌ | ✅ goroutines | ❌ |
| WebSockets, background jobs & cron | ✅ | ⚠️ WS only | ⚠️ basic tasks | ❌ | ❌ | ✅ |
| In-memory test client | ✅ | ⚠️ | ✅ | ❌ | ✅ `httptest` | ✅ |
| Project & layer generators | ✅ | ⚠️ `dub init` | ❌ | ⚠️ skeleton | ❌ | ✅ |

### 👋 New to D?

D compiles to native code like C++ or Go, has a garbage collector, and offers compile-time reflection that reads your function signatures directly:

| If you know... | In andaime |
|---|---|
| FastAPI path/query params & Pydantic | Function parameters & plain `struct`s with `@minLength(2)`, `@inRange(...)` |
| Express `(req, res, next)` / `req.locals` | `(Context ctx, Next next) { ...; next(); }` / `Local!T` parameter |
| Go goroutines / `async` & `await` | One fiber per request—write normal sequential code |
| Pydantic `Optional` / PATCH semantics | `Optional!T` / `PatchField!T` |

Install DMD or LDC (includes DUB): `curl -fsS https://dlang.org/install.sh | bash -s dmd`

---

## 📚 Documentation

Start at the [Documentation Index](docs/README.md) or jump to a guide:

| Category | Guides |
|---|---|
| 🎓 **Fundamentals** | [Getting started](docs/getting-started.md) · [Routing](docs/routing.md) · [Reading the request](docs/requests.md) · [Validation and errors](docs/validation.md) · [Responses](docs/responses.md) |
| 🧱 **Building APIs** | [Middleware](docs/middleware.md) · [Logging](docs/logging.md) · [Streaming and SSE](docs/streaming.md) · [WebSockets](docs/websocket.md) · [Static files and OpenAPI](docs/static-files-and-openapi.md) |
| 🔌 **Async, data, auth** | [Concurrency](docs/concurrency.md) · [Database](docs/database.md) · [Jobs and cron](docs/jobs-and-cron.md) · [HTTP client](docs/http-client.md) · [Cryptography](docs/crypto.md) |
| 🧪 **Quality & structure** | [Testing](docs/testing.md) · [Memory safety](docs/safety.md) · [Architecture](docs/architecture.md) · [The andaime command](docs/cli.md) |
| 🚢 **Production** | [Deploying](docs/deploy.md) · [HTTPS and TLS](docs/tls.md) · [HTTP/2](docs/http2.md) · [Configuration](docs/configuration.md) |

---

## 🚧 Status & Roadmap

andaime is **pre-1.0**: APIs may evolve before `1.0.0`, though all existing modules are tested in CI on DMD and LDC against real PostgreSQL, Chromium, `curl`, `python-h2`, `websockets`, Caddy, and `h2spec`.

**Not there yet:**
- 🔜 Runtime CI testing for macOS (`kqueue`) and Windows (`WSAPoll`); `io_uring` backend
- 🔜 Unbuffered request body streaming (currently buffered up to `limits.maxBodyBytes`, default 1 MiB) and `Range` requests
- 🔜 HTTP/2 trailers (gRPC) and WebSocket client over HTTP/2
- 🔜 IPv6 listeners and OCSP stapling

## 🤝 Contributing & License

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, `tools/check.sh`, fuzzing, and architecture rules. Licensed under [MIT](LICENSE).
