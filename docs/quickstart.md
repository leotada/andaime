# Quickstart

From zero to an API with validation, middleware, OpenAPI and static files in a few minutes.
Everything here is compiled and tested with DMD 2.109.1 and LDC 1.40.1 (the minimum versions) on Linux x86_64.

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

void main() { serve(&buildApp, 8080); }
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
| `string[] tag`, `int[] ids`           | repeated query key (`?tag=a&tag=b`); absent = empty list, an error names the element (`["query","ids",1]`) |
| `JsonBody!UserInput body_`            | typed JSON body, validated by the struct's annotations |
| `Header!"Authorization" auth`         | header, copied into a `string` you may keep           |
| `Cookie!"session" s`                  | cookie, copied into a `string`; `Optional!(Cookie!"theme")` makes it optional |
| `Query!Filters f`                     | a struct bound from the query string, field by field (section 4a) |
| `Form!Login f`                        | a struct bound from an `application/x-www-form-urlencoded` body (415 for other types) |
| `Optional!X`                          | present or absent, no error                           |
| `Local!T`                             | value put by a middleware in `ctx.locals`             |
| `ClientIp ip`                         | the client's address (the real one behind `trustedProxies`) |
| `Context ctx`                         | direct access to request/response                     |

Conversion or validation failed? The client gets a **422** in FastAPI's format, and your handler does not even run:

```json
{"detail":[{"type":"string_too_short","loc":["body","items",1,"code"],"msg":"expected at least 3 characters"}]}
```

`loc` is where the problem is (`path`, `query`, `header`, `cookie` or `body`, then field names and array indexes), `type` is a stable
code for programs (`missing`, `int_parsing`, `float_parsing`, `bool_parsing`, `enum`, `string_type`, `list_type`,
`model_type`, `string_too_short`, `string_too_long`, `too_short`, `too_long`, `greater_than_equal`, `less_than_equal`,
`dict_type`, `value_error` (a text type refused the value), `json_invalid`, `string_unicode`, `percent_encoding`,
`too_many_errors`) and `msg` is for people. String lengths count
characters, not bytes; text that is not valid UTF-8 is rejected. At most 16 errors are listed, followed by a
`too_many_errors` entry with the count of the rest. A `bool` accepts `true`/`false` (and `1`/`0` in the query).

### 4a. Query and form models, cookies, maps

```d
struct Filters
{
    @minLength(2) string q;                                   // required
    @jsonKey("page_size") @inRange(1, 100) int pageSize = 20; // optional: it has an initializer
    Optional!Sort sort;                                       // optional
    string[] tag;                                             // ?tag=a&tag=b
}
Page list(Query!Filters f) { ... }            // GET /list?q=boots&page_size=50&tag=a&tag=b
string login(Form!Login f) { ... }            // POST with Content-Type: application/x-www-form-urlencoded
```

A `Query!T`/`Form!T` field is a scalar, a text type, an `Optional` of those or a list of them; it is optional when it is an
`Optional`, a list, marked `@optional` or has an initializer other than the type's default. `@jsonKey` is the external name,
the validation attributes apply, and OpenAPI lists each field as its own query parameter (or the form schema).

Cookies: `Cookie!"session"` is a parameter like a header. In code, `ctx.cookie("name")` reads (without allocating) and
`ctx.setCookie("session", token, CookieOptions(...))` writes. The defaults are the safe ones (`Path=/; Secure; HttpOnly;
SameSite=Lax`); for local development over plain `http://` pass `secure: false` in `CookieOptions`. `ctx.deleteCookie("session")`
removes one. An invalid name or value is a programming error and answers 500.

JSON objects with arbitrary keys are `V[string]` (`int[string] counts`): any value type works, a repeated key keeps its last
value, and the written order is the associative array's own (unspecified).

### Your own types in the signature (UUIDs, dates, amounts)

A struct that knows how to read and write itself as text can be used wherever a number or a string can: path, query, header,
JSON fields and database columns. No registration; the compiler checks the shape:

```d
struct Uuid
{
    ubyte[16] bytes;
    static bool fromString(scope const(char)[] text, out Uuid v) { ... }           // false = invalid
    void toString(scope void delegate(scope const(char)[]) @safe sink) const { ... }  // writes the text
    enum openApiFormat = "uuid";                                       // optional: the OpenAPI "format"
    enum invalidMessage = "expected a UUID like 123e4567-...";         // optional: the 422 message
}

Order getOrder(Uuid id) { ... }                  // GET /orders/{id}: a bad id is a 422 with type "value_error"
struct Order { Uuid id; Day placed; Optional!Uuid parent; }   // JSON strings, "format": "uuid" in the document
```

The core uses no date library; inside `fromString`/`toString` use whatever you like (`std.datetime` in an application is
fine). The Postgres driver passes such a value as text (`$1::uuid`) and reads it back with `fromString`.

### `@safe` is recommended, not required

Handlers and middleware may be `@safe` or `@system`, so you can call a C library straight from a handler.
The framework itself is `@safe` and calls your code through one small `@trusted` call site. We recommend putting
`@safe:` at the top of your module (as above): the compiler then proves your handlers cannot corrupt memory, and
the few lines that cannot be proven safe (a C call, a `__gshared` variable) go in a small `@trusted` function with a
comment saying why it is sound. The database driver, the HTTP client and `offload` are `@safe` to call.

To make the whole app `@safe`-only, add `versions "VelaStrictSafe"` to your `dub.sdl` (or compile with
`-version=VelaStrictSafe`): a `@system` handler then fails with a one-line compile error.

## 5. A small CRUD with JSON

```d
// check
@safe:

import vela;

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;
}

struct User { long id; string name; int age; Optional!string email; }

private User[long] users;     // beware: a module variable is thread-local; see "Workers and state" in section 9
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

App buildApp()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.del!("/users/{id}", deleteUser);
    return app;
}

void main()
{
    ServerConfig cfg;
    cfg.port = 8080;
    cfg.workers = 1;          // the "database" is a module variable; with a real database, leave 0 (one per core)
    serve(&buildApp, cfg);
}
```

```sh
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'     # 201 {"id":1,...}
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'      # 422 with both errors
curl localhost:8080/users/1
```

**What each return becomes:** `void` → 204 · `string` → text · struct/array → JSON ·
`WithStatus!T` → JSON with the status you choose · `Response` → full control · `Stream`/`EventStream` → a body sent while it is produced (section 6a) · `throw new HttpError(status, msg)`.

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

Response headers: `ctx.setHeader(name, value)` replaces, `ctx.addHeader(name, value)` appends (several `Set-Cookie`),
`ctx.addVary("Origin")` merges into one `Vary`. A handler can also return `Response(status, contentType, body, headers)`.
vela checks every header once the middleware has unwound: a CR, LF, NUL or other control character in a name or value, an
invalid name, or more than 32 headers turns the response into a **500** with a log line that names the header (never its
value) instead of sending it. `Content-Length`, `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade`,
`Proxy-Connection` and `TE` belong to vela and are dropped if you set them; `Date` is added unless you set it.

Ready-made: `accessLog()`, `requestId()`, `cors(CorsConfig(...))`. Errors: `app.onError(...)`,
`app.onNotFound(...)`; `app.redirectTrailingSlash = true` turns on the 308 for a trailing slash.

## 6a. Streaming and Server-Sent Events

Return a `Stream` when the body is produced while it is sent (an export, a large download), or an `EventStream` for
Server-Sent Events (live updates, token-by-token output):

```d
import core.time : seconds;

Stream export_(string table)
{
    return Stream("text/csv", (scope StreamWriter w) {
        foreach (row; rowsOf(table))
            w.write(row);              // sent as it is written; waits if the client is slow
    });
}

EventStream clock()
{
    return EventStream((scope EventWriter w) {
        foreach (i; 0 .. 60)
        {
            w.send(timeNow());         // "data: ..." + a blank line, flushed at once
            sleep(1.seconds);          // the fiber waits; the worker serves others
        }
    });
}
```

What to know (details in [streaming.md](streaming.md)):

- `write` waits when the client is slow (up to `writeTimeoutMs`, then the connection is closed), so memory stays bounded however
  big the stream is. A client that leaves cancels the handler: the next `write` or `sleep` throws `RequestCancelled` and your
  `scope(exit)` runs.
- Status and headers go out with the first `write` or `flush`. Throw before writing anything and the client gets a normal error
  response; throw after, and the response is cut off and the error logged. Set the status first: `withStatus(201, Stream(...))`
  or `@status(202)`.
- Your middleware wraps the whole stream, so an access log measures its full duration.
- A stream holds a fiber and counts toward `maxInFlight` (1,024 per worker by default).
- `TestClient` sees what a client sees: `response.chunks` has one entry per `write`.

Static files above 256 KiB are streamed the same way, in 64 KiB pieces with a `Content-Length`.

## 7. Static files and automatic documentation

```d
app.serveStatic("/assets", "public");                       // ETag/304, index.html, blocks traversal
app.serveOpenApi(OpenApiInfo("My API", "1.0.0"));           // /openapi.json and /docs (Swagger UI)
```

The OpenAPI document is built from the **same signatures** that generate the dispatch: routes, parameters, bodies,
validations (`@minLength`, `@inRange`...) and `@summary("...")`. There is no second source of truth to go out of date.

Say what the success status is, and which errors a handler can produce, with attributes (FastAPI's `status_code=` and
`responses=`):

```d
@status(201) @responds(409, "e-mail already registered")
User createUser(JsonBody!NewUser body_) { ... }          // answers 201; OpenAPI documents 201, 409 and 422

@status(202) void startJob() { ... }                     // void normally means 204; this one answers 202
```

`@status` applies to a normal return; a handler that returns `WithStatus` or `Response` picks its own (documented as
`2XX`). `@responds` only documents: the handler still produces the error by throwing `HttpError`. Two structs with the same
name in different modules get different schema names (the second one uses its module path); template instances become
`Page_User`; `@schemaName("UserOut")` on a struct chooses the name. The routes of the whole app are documented, including
those registered after `serveOpenApi`. `/docs` loads Swagger UI from a pinned CDN release with Subresource Integrity;
`OpenApiInfo.swaggerUiBase` points it to your own copy.

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
More in [database.md](database.md).

## 9. Server configuration

```d
ServerConfig cfg;
cfg.port = 8080;
cfg.workers = 0;            // 0 = one per core (SO_REUSEPORT)
cfg.maxInFlight = 1024;     // above this: 503 + Retry-After
cfg.requestTimeoutMs = 30_000;
serve(&buildApp, cfg);
```

Every field is described in [configuration.md](configuration.md). There are deadlines for head, idle, write and request; graceful stop on SIGINT/SIGTERM; and a log warning
when a handler holds the worker for more than 50 ms without yielding (blocking code).

### Workers and state

`serve(&buildApp, cfg)` does not take an `App`: it takes the **function that builds it**. Each worker (one per core by
default) calls that function once, **on its own thread**, and serves the App it returns. That gives one rule:

> Everything the build function creates belongs to one worker.

So a controller with a counter, a cache in a closure, `pgPool(...)`, `httpClient()` and the App itself need no locks and
cannot race. Module-level variables are thread-local in D, so each worker also has its own copy of those. The flip side:
**workers do not share memory through the App.** The in-memory `users` table in the CRUD example is per worker, which is
why that example runs one worker.

To share state between workers:

- **A database** (the usual answer). Connections are per worker too: with `PgConfig.maxConns = 10` and 4 workers the
  database sees up to 40.
- **`__gshared` or `shared` data behind a lock**, read through a small `@trusted` accessor that returns `const` data:

  ```d
  import core.sync.mutex : Mutex;
  __gshared Mutex lock;           // created in main, before serve
  __gshared long[string] hits;    // only touched with `lock` held

  void count(string key) @trusted { synchronized (lock) hits[key]++; }
  ```

  Keep critical sections short and **never wait for I/O (a query, `sleep`, a call to another service) while holding the
  lock**: the lock would stall every other fiber of that worker, and with it the connections it serves.

The build function may run on several threads at the same time, and it must return a **new** `App` each time: returning
one shared App (`serve(() => app, ...)`) is refused at startup with an explanation. If it throws (a bad route, for
example), the server prints one line and does not start.

### HTTP/2 and HTTPS

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
services or behind a proxy that speaks h2c (Caddy, HAProxy, Envoy, Cloud Run); [http2.md](http2.md) has the details.

## 10. Readable compile errors

An invalid signature becomes one line explaining what to fix, with no template *backtrace*:

```
web/source/vela/web/application.d(398): Error: static assert:  "app.d(4): vela: handler 'getUser' in GET /users/{id}: the route declares {id}, but the function has no parameter named 'id'"
app.d(4):        instantiated from here: `get!("/users/{id}", getUser, ...)`
```

The cases live in `tests/compile_fail/` (each one checks the message and that it takes no more than 2 error lines).

## 11. Running the tests and the examples

```sh
tools/check.sh                 # everything: unittests, network, streaming, Postgres, HTTP client, fuzz, e2e, memory, compile-fail, docs
DC=ldmd2 tools/check.sh        # the same with LDC
cd examples/hello && dub run   # in-memory CRUD
cd examples/api   && dub run   # real API: Postgres + external API + CORS + static files + OpenAPI
```

Without PostgreSQL, Python or OpenSSL on the machine, the tests that depend on them declare themselves skipped (exit code 77)
and the summary at the end lists them; the same goes for the HTTP/2 interoperability checks without curl, python-h2
(`pip install h2`) or h2spec. `VELA_STRICT=1` turns a skip into a failure (CI does).

## Next steps

- `examples/api/source/app.d`: the complete application, with authentication, a database and `onError` mapping errors.
- [streaming.md](streaming.md), [http2.md](http2.md), [tls.md](tls.md), [database.md](database.md) and
  [configuration.md](configuration.md): the reference for each area; `README.md` for the overview and the pitfalls.
