# dapi

A micro web framework in D with FastAPI-style ergonomics: the function signature is the HTTP contract, and the extraction,
validation and dispatch code is generated at compile time. The code uses the provisional name **vela** (DUB package `vela`,
`import vela;`); the repository is `dapi`.

```d
// check
@safe:

import vela;

struct UserInput { @minLength(2) string name; @inRange(0, 150) int age; }
struct User { long id; string name; int age; }

User getUser(long id) => User(id, "Ana", 31);                                       // GET /users/{id}
WithStatus!User createUser(JsonBody!UserInput body_) => withStatus(201, User(1, body_.name, body_.age)); // POST /users

App buildApp()                       // each worker calls this once, on its own thread
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    return app;
}

void main() { serve(&buildApp, 8080); }
```

Start with [docs/quickstart.md](docs/quickstart.md). To deploy: [docs/deploy.md](docs/deploy.md). If you are an AI agent working
on this repository, read [AGENTS.md](AGENTS.md).

## What it does

- **The signature is the contract.** Path, query (including lists and `Query!T` structs), headers, cookies, JSON and form
  bodies, `ClientIp` and your own text types (UUIDs, dates) are extracted and validated from the types and names. Bad input is a
  422 in FastAPI's format (`type`, `loc`, `msg`); the handler runs only with valid data.
- **Documentation from the same signatures:** `openapi.json` and a Swagger UI page; `@status`, `@responds` and `@summary` refine it.
- **Responses:** return `string`, a struct, an array, `WithStatus!T` or `Response`; `Stream` and `EventStream` (Server-Sent
  Events) are sent as they are produced, with backpressure ([docs/streaming.md](docs/streaming.md)). Response headers are
  validated (no CR/LF injection), several `Set-Cookie` work.
- **One fiber per request** on an epoll loop, one worker per core, each with its own `App`. Database, HTTP client and DNS calls
  suspend only the fiber; heavy work goes to a bounded thread pool (`offload`). A client that leaves cancels the handler.
- **HTTP/1.1, HTTP/2 and TLS** on one port (ALPN), certificate reload without restarts, request deadlines, a zero-copy HTTP/1.1
  parser (chunked uploads included) fuzzed with ASan. HTTP/2 (RFC 9113) over TLS and in cleartext (h2c): h2spec 146/146 over
  TLS, tested with Chromium, curl, python-h2 and behind Caddy. See [docs/http2.md](docs/http2.md) and [docs/tls.md](docs/tls.md).
- **Safety:** the framework is `@safe`; handlers may be `@safe` (recommended) or `@system`. Request data you keep is
  memory-safe: `string` and `Header!"X"` are copies, and a kept `const(char)[]` view lives on the GC heap (it may show a later
  request's bytes, never freed memory). A handler that throws an `Error` gets a 500, a full stack trace in the log, and its fiber
  is retired.
- **Memory and speed targets, all checked by `tools/check.sh`:** the hot path does not allocate on the GC; 1,000 simultaneous
  requests fit in about 25 MB of RSS (HTTP/1.1 and h2); the example's `app.d` type-checks in under 400 ms on DMD; every invalid
  handler signature is a one-line compile error with a `compile_fail` test.
- **Layers:** `http` (no I/O), `web` (no sockets), `engine` (no routes), and optional drivers outside the core
  ([docs/database.md](docs/database.md)): `vela` does not depend on libpq.

## Status and limits

Linux only for the real server (epoll; other systems fall back to a blocking development server). Working: the web layer, the
epoll engine, HTTP/2 (h2spec 146/146 over TLS), HTTPS, streaming, a PostgreSQL driver, a cooperative HTTP/HTTPS client.
Not done: kqueue and io_uring backends, IPv6 listeners, response trailers (so no gRPC), WebSockets, `multipart/form-data` and
streamed request bodies (bodies are buffered up to `limits.maxBodyBytes`, 1 MiB by default), Range requests, OCSP stapling.
HTTP/2 and TLS are frozen for new features until the owner decides otherwise (bug fixes only).

Workers do not share the `App`: state shared between workers lives in a database or behind a lock
([quickstart](docs/quickstart.md), "Workers and state"). A CPU-only handler cannot be cancelled until it waits again.

## Requirements and commands

DMD 2.109.1 or newer, or LDC 1.40.1 or newer (DUB prints a clear message with an older one), and DUB; Linux x86_64. libpq5 only
for `vela-pg` and OpenSSL 3 only for HTTPS, both loaded at run time.

```sh
tools/check.sh                  # everything, on DMD (DC=ldmd2 for LDC); a section whose tool is missing is skipped and listed
                                # in the summary; VELA_STRICT=1 makes a skip fail the run
tools/fuzz.sh 300 parse         # libFuzzer + ASan on the HTTP/1 parser ("h2" for the HTTP/2 session); needs LDC
cd examples/hello && dub run    # http://localhost:8080
```

`tools/check.sh` reports the type-check time of the example (`-o- -c`, no code generation: about 350-400 ms on DMD) and, apart,
the edit-and-rebuild time (`touch app.d` + `dub build`, about 1 s).

## Packages

| Package       | Role                                                        | Depends on |
|---------------|-------------------------------------------------------------|------------|
| `vela:http`   | types, zero-copy HTTP/1.1 parser and writer, chunked decoder, HTTP/2 session and HPACK. No I/O. | — |
| `vela:web`    | App, router, handler introspection, JSON, OpenAPI, middleware, cookies, streaming | http |
| `vela:engine` | event loop, buffers, connections, `offload`, HTTP/TLS client. Knows nothing about routes. | http |
| `vela-pg` (`drivers/pg`) | cooperative PostgreSQL driver (async libpq). **An independent DUB package** | vela:engine |
| `vela`        | `import vela;` and `vela.server` (glue between web and engine) | all     |

More: [docs/configuration.md](docs/configuration.md) (every `ServerConfig` field), [PLAN.md](PLAN.md) (the improvement plan and
its decisions).

## Pitfalls

- A `get`/`post` of your own in the same unit hides vela's; use `vela.get!(...)(app)`.
- Blocking code in a handler (a `Thread.sleep`, a synchronous C library) stalls the whole worker; the loop logs a warning past
  `stallWarnMs`. Wait with `sleep`/`awaitFd`, or use `offload`.
- Module variables in D are thread-local: with several workers each has its own copy.
- Middleware applies to every route of its App or Group whenever the route is registered; once the app is serving, registering
  anything throws `RouteError`.
- D's GC interrupts blocking `read`/`send` calls in test clients with `EINTR`; handle it.

## License

[MIT](LICENSE).
