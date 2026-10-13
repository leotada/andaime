# Quickstart

From zero to an API with validation, middleware, OpenAPI and static files in a few minutes.
Everything here was compiled and tested with DMD 2.113 and LDC 1.43 on Linux x86_64.

> The code uses the provisional name **vela** (`import vela;`); the repository is called `dapi`.

## 1. Prerequisites

- A D compiler (DMD or LDC) and DUB.
- Linux for the production server (epoll). On other systems, `serve` falls back to a blocking development server.
- Nothing else. A database is an optional package (see section 8).

## 2. A new project

```sh
git clone https://github.com/leotada/dapi
mkdir my-api && cd my-api
```

`dub.sdl`:

```sdl
name "my-api"
targetType "executable"
dependency "vela" path="../dapi"
```

## 3. First route

`source/app.d`:

```d
@safe:

import vela;

string hello(string name = "world") => "hello, " ~ name;

void main()
{
    auto app = new App;
    app.get!("/hello", hello);
    app.serve(8080);
}
```

```sh
dub run
curl 'localhost:8080/hello?name=Ana'     # hello, Ana
```

There is no `req.query["name"]` here: **the function signature is the HTTP contract**. The `name`
parameter is not in the route, so it comes from the query string; the default value makes it optional.

## 4. Where each parameter comes from

| In the signature                      | vela extracts                                         |
|---------------------------------------|-------------------------------------------------------|
| `long id` with `{id}` in the route    | path parameter, converted and validated               |
| `int limit = 20` (outside the route)  | query string; the default makes it optional           |
| `JsonBody!UserInput body_`            | typed JSON body, validated by the struct's annotations |
| `Header!"Authorization" auth`         | header, without copying (a slice of the network buffer) |
| `Optional!X`                          | present or absent, no error                           |
| `Local!T`                             | value put by a middleware in `ctx.locals`             |
| `Context ctx`                         | direct access to request/response                     |

### `@safe` is recommended, not required

Handlers and middleware may be `@safe` or `@system`, so you can call a C library straight from a handler.
The framework itself is `@safe` and calls your code through one small `@trusted` call site. We recommend putting
`@safe:` at the top of your module (as above): the compiler then proves your handlers cannot corrupt memory, and
the few lines that cannot be proven safe (a C call, a `__gshared` variable) go in a small `@trusted` function with a
comment saying why it is sound. The database driver, the HTTP client and `offload` are `@safe` to call.

To make the whole app `@safe`-only, add `versions "VelaStrictSafe"` to your `dub.sdl` (or compile with
`-version=VelaStrictSafe`): a `@system` handler then fails with a one-line compile error.

Conversion or validation failed? The client gets a **422** in FastAPI's format, and your handler does not even run.

## 5. A small CRUD with JSON

```d
@safe:

import vela;

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;
}

struct User { long id; string name; int age; Optional!string email; }

private User[long] users;     // beware: a module variable is thread-local; see "Pitfalls" in the README
private long nextId = 1;

User getUser(long id)
{
    if (auto u = id in users) return *u;
    throw new HttpError(404, "user not found");
}

WithStatus!User createUser(JsonBody!UserInput body_)      // 201
{
    auto u = User(nextId++, body_.name, body_.age, body_.email);
    users[u.id] = u;
    return withStatus(201, u);
}

void deleteUser(long id)                                   // void => 204
{
    if (!users.remove(id)) throw new HttpError(404, "user not found");
}

void main()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.del!("/users/{id}", deleteUser);

    ServerConfig cfg;
    cfg.port = 8080;
    cfg.workers = 1;          // the "database" is a module variable; with a real database, leave 0 (one per core)
    app.serve(cfg);
}
```

```sh
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'     # 201 {"id":1,...}
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'      # 422 with both errors
curl localhost:8080/users/1
```

**What each return becomes:** `void` → 204 · `string` → text · struct/array → JSON ·
`WithStatus!T` → JSON with the status you choose · `Response` → full control · `throw new HttpError(status, msg)`.

## 6. Middleware, groups and per-request data

Middleware is a `void(Context, Next)` function, in onion layers:

```d
void logger(Context ctx, Next next)
{
    next();
    // after the response: ctx.response.status is already set
}

auto api = app.group("/api/v1");
api.use((Context ctx, Next next) {
    auto token = bearerToken(ctx);
    if (token.length == 0) throw new HttpError(401, "missing token");
    ctx.locals.set(Caller(token.idup));     // stored, typed, for this request
    next();
});

string whoAmI(Local!Caller c) => c.token;   // the handler receives the ready value
api.get!("/whoami", whoAmI);
```

Ready-made: `accessLog()`, `requestId()`, `cors(CorsConfig(...))`. Errors: `app.onError(...)`,
`app.onNotFound(...)`; `app.redirectTrailingSlash = true` turns on the 308 for a trailing slash.

## 7. Static files and automatic documentation

```d
app.serveStatic("/assets", "public");                       // ETag/304, index.html, blocks traversal
app.serveOpenApi(OpenApiInfo("My API", "1.0.0"));           // /openapi.json and /docs (Swagger UI)
```

The OpenAPI document is built from the **same signatures** that generate the dispatch: routes, parameters, bodies,
validations (`@minLength`, `@inRange`...) and `@summary("...")`. There is no second source of truth to go out of date.

## 8. Database, external API and heavy work without stalling the server

Each request runs in a *fiber*. Waiting on the network suspends only that fiber, never the worker:

```d
// dub.sdl:  dependency "vela-pg" path="../dapi/drivers/pg"     (optional package; needs libpq5)
import vela.db;

string user(int id)
{
    auto db = pgPool("host=my-rds.example.com dbname=app user=app");
    auto rows = db.query("select name from users where id = $1", id);   // $1..$n parameters: no SQL injection
    return rows.rows ? rows.get!string(0, 0) : "?";
}

Response quote()
{
    auto r = httpClient().get("https://api.example.com/v1/quote");      // verified HTTPS, keep-alive
    return Response(r.status, "application/json", r.body);
}

string heavy() => offload(() => expensiveComputation());               // bounded thread pool; the delegate must be @safe (wrap C calls in @trusted)
```

Did the client disconnect or the deadline expire midway through a query? The driver cancels on the server and discards the connection.

## 9. Server configuration

```d
ServerConfig cfg;
cfg.port = 8080;
cfg.workers = 0;            // 0 = one per core (SO_REUSEPORT)
cfg.maxInFlight = 1024;     // above this: 503 + Retry-After
cfg.requestTimeoutMs = 30_000;
app.serve(cfg);
```

There are deadlines for head, idle, write and request; graceful stop on SIGINT/SIGTERM; and a log warning
when a handler holds the worker for more than 50 ms without yielding (blocking code).

The same port also speaks HTTP/2 over cleartext (h2c), with no change to your code:

```sh
curl --http2-prior-knowledge http://localhost:8080/users   # or --http2 to upgrade from HTTP/1.1
```

Each stream gets its own fiber, so one slow request does not hold up the others on the connection.
`cfg.http2 = false` turns it off.

For browsers, give the server a certificate: it then speaks HTTPS only, and ALPN chooses HTTP/2 or HTTP/1.1.

```d
cfg.port = 443;
cfg.tls.certFile = "/etc/letsencrypt/live/example.com/fullchain.pem";
cfg.tls.keyFile = "/etc/letsencrypt/live/example.com/privkey.pem";
```

Renewed certificates are picked up without a restart, and `cfg.tls.redirectPort = 80` answers Let's Encrypt
challenges and redirects to HTTPS. [deploy.md](deploy.md) is the step-by-step guide for a VPS. Without a certificate, use cleartext HTTP/2 between
services or behind a proxy that speaks h2c (Caddy, HAProxy, Envoy, Cloud Run); the README has the details.

## 10. Readable compile errors

An invalid signature becomes one line explaining what to fix, with no template *backtrace*:

```
web/source/vela/web/application.d(398): Error: static assert:  "app.d(4): vela: handler 'getUser' in GET /users/{id}: the route declares {id}, but the function has no parameter named 'id'"
app.d(4):        instantiated from here: `get!("/users/{id}", getUser, ...)`
```

The cases live in `tests/compile_fail/` (each one checks the message and that it takes no more than 2 error lines).

## 11. Running the tests and the examples

```sh
tools/check.sh                 # everything: unittests, network, Postgres, HTTP client, fuzz, e2e, memory, compile-fail
DC=ldmd2 tools/check.sh        # the same with LDC
cd examples/hello && dub run   # in-memory CRUD
cd examples/api   && dub run   # real API: Postgres + external API + CORS + static files + OpenAPI
```

Without PostgreSQL, Python or OpenSSL on the machine, the tests that depend on them declare themselves skipped;
the same goes for the HTTP/2 interoperability checks without curl, python-h2 (`pip install h2`) or h2spec.

## Next steps

- `examples/api/source/app.d`: the complete application, with authentication, a database and `onError` mapping errors.
- `README.md`: reference for features, packages and pitfalls.
