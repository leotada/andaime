# Getting started

From an empty folder to a running API. Everything here is tested with DMD 2.109.1 and LDC 1.40.1 (the minimum versions) on
Linux x86_64.

> The framework is called **andaime** (Portuguese for "scaffolding"; `import andaime;`); the repository is called `andaime`.

## Requirements

- A D compiler (DMD 2.109.1+ or LDC 1.40.1+) and DUB. The code also type-checks as language edition 2025 (DMD 2.112+), and
  your application may be written in that edition (see [Memory safety](safety.md)).
- Linux for the production server (epoll). The event loop also has macOS (kqueue) and Windows (WSAPoll) backends: CI
  type-checks them, but does not run them yet.
- Optional, loaded at run time only when used: OpenSSL 3 for HTTPS, libpq5 for the PostgreSQL driver.

## A new project

Create a folder with DUB and add andaime:

```sh
dub init my-api --type=minimal -n --format=sdl
cd my-api
dub add andaime
```

`dub.sdl`:

```sdl
name "my-api"
targetType "executable"
dependency "andaime" version="~>0.1.0"
```

The other packages are subpackages of it: `dub add andaime:jobs`, `andaime:pg`, `andaime:pgjobs`, `andaime:crypto`. To work
on andaime itself, depend on a checkout instead (`dependency "andaime" path="../andaime"`).

This page builds a project by hand, to show how andaime works. The optional `andaime` command can also create one:
`andaime new my-api --template minimal` for a single module, or `andaime new my-api` for a project in layers
([The andaime command](cli.md), [Architecture](architecture.md)).

## The first route

`source/app.d`:

```d
// check
@safe:

import andaime;

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
curl 'localhost:8080/hello'              # hello, world
```

There is no `req.query["name"]`: **the function signature is the HTTP contract**. `name` is not in the route, so it comes from
the query string, and its default value makes it optional. andaime reads the signature at compile time and generates the code
that extracts, converts and validates every parameter.

Two things in this program matter later:

- `serve` takes the **function that builds the app**, not an app. Each worker (one per CPU core by default) calls it once on
  its own thread, so nothing in an App is shared between threads. See [concurrency.md](concurrency.md).
- `@safe:` at the top asks the compiler to prove your handlers memory-safe. It is recommended, not required
  ([safety.md](safety.md)).

## A small CRUD with JSON

```d
// check
@safe:

import andaime;

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;
}

struct User { long id; string name; int age; Optional!string email; }

private User[long] users;     // a module variable is per thread: see the note below
private long nextId = 1;

User getUser(long id)
{
    if (auto u = id in users) return *u;
    throw new HttpError(404, "user not found");
}

@status(201)
User createUser(JsonBody!UserInput body_)
{
    auto u = User(nextId++, body_.name, body_.age, body_.email);
    users[u.id] = u;
    return u;
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
    app.serveOpenApi(OpenApiInfo("Users", "1.0.0"));       // /openapi.json and /docs
    return app;
}

void main()
{
    ServerConfig cfg;
    cfg.port = 8080;
    cfg.workers = 1;          // the "database" is a module variable; with a real database leave 0 (one per core)
    serve(&buildApp, cfg);
}
```

```sh
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'     # 201 {"id":1,"name":"Ana","age":31,"email":null}
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'      # 422, both errors listed
curl localhost:8080/users/1
curl -X DELETE localhost:8080/users/1                              # 204
open http://localhost:8080/docs                                    # Swagger UI
```

The invalid request never reaches `createUser`; the client gets a 422 in FastAPI's format:

```json
{"detail":[{"type":"string_too_short","loc":["body","name"],"msg":"expected at least 2 characters"},
           {"type":"less_than_equal","loc":["body","age"],"msg":"must be <= 150"}]}
```

Module variables in D are thread-local: with several workers, each would have its own `users`. That is why this example runs
one worker. Real applications keep shared state in a database ([database.md](database.md)).

## A test, without a network

`TestClient` drives the app in memory. Put this in the same file and run `dub test`:

```d
unittest
{
    auto c = TestClient(buildApp());
    auto r = c.post("/users", `{"name":"Ana","age":31}`);
    assert(r.status == 201, r.body);
    assert(c.get("/users/1").status == 200);
    assert(c.get("/users/abc").status == 422);
}
```

With a `unittest` block in `app.d`, wrap `main` in `version (unittest) {} else` so `dub test` does not start the server. More in
[testing.md](testing.md).

## When the signature is wrong

An invalid handler signature is a one-line compile error that says what to fix, not a template backtrace:

```
app.d(4): andaime: handler 'getUser' in GET /users/{id}: the route declares {id}, but the function has no parameter named 'id'
```

## The examples in the repository

```sh
cd examples/hello && dub run     # in-memory CRUD, a controller, middleware, tests (dub test)
cd examples/api   && dub run     # Postgres, an external API, Bearer auth, CORS, static files, OpenAPI
```

## Next

[routing.md](routing.md) and [requests.md](requests.md) cover what a handler can take; [responses.md](responses.md) what it can
return. The full list is in the [documentation index](README.md).
