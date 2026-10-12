# dapi

The code uses the provisional name **vela** (DUB package and `import vela;`).

A micro web framework in D with FastAPI-style ergonomics: the function signature is the
HTTP contract, and the dispatch is generated at compile time.

```d
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

## Commands

```sh
tools/check.sh                       # everything: unittests, example, allocation, network, Postgres, HTTP client, memory, compile-fail, budget
                                     # (starts a throwaway PostgreSQL and a Python upstream; without them, those tests are skipped)
DC=ldmd2 tools/check.sh              # the same with LDC

cd examples/hello && dub run         # starts the example at http://localhost:8080
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'
```

Tested with DMD 2.113 and LDC 1.43 (Linux x86_64).

Requirements: a D compiler (DMD or LDC) and DUB. The core (`vela`) needs no database. Only whoever uses the optional `vela-pg` driver needs `libpq5` at run time; the HTTP client's outgoing HTTPS needs OpenSSL 3 (both loaded by dlopen).

## Packages

| Package       | Role                                                        | Depends on |
|---------------|-------------------------------------------------------------|------------|
| `vela:http`   | types, zero-copy HTTP/1.1 parser, writer. No I/O.           | —          |
| `vela:web`    | App, router, handler introspection, JSON, middleware        | http       |
| `vela:engine` | event loop, buffers, connections, `offload`, HTTP/TLS client. Knows nothing about routes. | http |
| `vela-pg` (`drivers/pg`) | cooperative PostgreSQL driver (async libpq). **An independent DUB package**: the core depends neither on it nor on libpq | vela:engine |
| `vela`        | `import vela;` and `vela.server` (glue between web and engine) | all     |

## Rules the tests guarantee

- The framework's hot path does not allocate on the GC (`tests/alloc/hot_path.d`).
- An invalid signature = a one-line compile error (`tests/compile_fail/`).
- The example's `app.d` compiles in under 400 ms on DMD (`tools/check.sh`).
- The engine handles cancellation, the request ceiling, deadlines and partial writes (`tests/net/epoll_net.d`).
- The Postgres driver does not block the worker, respects the pool, cancels on the server and discards the connection (`tests/db/pg_net.d`).
- The HTTP/HTTPS client does not block, reuses connections, retries on a stale one and respects deadlines (`tests/net/client_net.d`).
- The parser survives the attack corpus and the fuzzer (`tests/fuzz/`), and the `examples/api` example passes 31 end-to-end checks (`tests/example/api_e2e.py`).
- 1,000 in-flight requests fit in under 30 MB of RSS (`tools/check.sh`, memory section).

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
- Handlers are module functions, lambdas (which may capture local variables) or
  controller methods with `@Get(...)` mounted through `app.mount(obj)`.

## License

[MIT](LICENSE).
