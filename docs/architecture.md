# Architecture: an optional clean template

andaime does not impose an architecture. A handler is a function, a controller method or a lambda, and everything else is
your code. Small services are often best as one module (`examples/hello`). For applications that will grow, this page
describes a ready-made structure based on Clean Architecture and SOLID. `andaime new` generates it ([cli.md](cli.md)), but
nothing in andaime depends on it: you can follow it by hand, change it, or ignore it.

`examples/clean` is a complete application in this structure: users over HTTP, Postgres and memory, a background job and
its tests. It is the exact output of `andaime new` and `andaime generate`.

## The layers

The folders are the circles of the Clean Architecture diagram, and a feature is the same file name in every layer:

```
source/
  domain/users.d            entities and business rules
  usecases/users.d          what the application does, and the ports it needs
  adapters/http/users.d     a controller, the JSON a client sends and receives
  adapters/postgres/users.d a repository over andaime-pg
  adapters/memory/users.d   the same repository in memory (tests, running without a database)
  adapters/jobs/users.d     background jobs
  app.d                     the composition root: which adapter implements each port, which routes the app serves
  main.d, jobs.d, config.d  the process: configuration, roles, serve
```

**The dependency rule**: source code points inward only.

| Layer | May import |
|-------|-----------|
| `domain/` | druntime, Phobos, `andaime.http.optional` (a value type with no I/O) |
| `usecases/` | `domain/`, `andaime.http.optional` |
| `adapters/` | `usecases/`, `domain/`, andaime |
| `app.d`, `main.d`, `jobs.d`, `config.d` | anything |

So the business code compiles and is tested without a framework, a database or a network, and an adapter can be replaced
without touching it. `andaime check` verifies the rule from the compiler's own import graph ([below](#enforcing-the-rule)).

## A feature, layer by layer

**Domain**: plain structs and functions. No framework, no status codes.

```d
module domain.users;

struct User { long id; string name; string email; }
struct NewUser { string name; string email; }

/// What the business decides; throws RuleViolation. The request's format is checked at the edge.
void checkRules(const NewUser user) { }
```

**Use cases and ports**: one `final class` per use case, with one `execute`. Its constructor takes the ports it needs;
the port is an `interface` declared next to the use cases that need it (the use cases own it, the adapters implement it).

```d
module usecases.users;

interface UserRepository
{
    Optional!User find(long id);
    User add(NewUser user);           // throws Conflict when a unique value is taken
    // ...
}

final class GetUser
{
    private UserRepository users;

    this(UserRepository users) { this.users = users; }

    User execute(long id)
    {
        auto found = users.find(id);
        if (!found.has)
            throw new NotFound("user not found");
        return found.get;
    }
}
```

**Adapters**: the HTTP adapter is a controller. Its DTOs are the HTTP contract (validation attributes, wire names,
OpenAPI), mapped to and from the domain:

```d
module adapters.http.users;

struct UserIn { string name; string email; }
struct UserOut { long id; string name; string email; }

final class UserController
{
    private GetUser getUser;
    // ...
    @Get("/users/{id}") @responds(404, "user not found")
    UserOut get(long id) => toOut(getUser.execute(id));
}
```

The Postgres and memory repositories both implement `UserRepository`; the Postgres one turns a unique violation into the
domain's `Conflict`.

**Composition root**: `app.d` builds the adapters, the use cases and the routes. `buildApp` runs once per worker, so each
worker gets its own repositories and pool, and nothing needs a lock:

```d
App buildAppWith(Adapters a)
{
    auto app = new App;
    app.mapError!NotFound(404);
    app.mapError!Conflict(409);
    app.mapError!RuleViolation(422);
    auto api = app.group("/api/v1");
    api.mount(new UserController(new ListUsers(a.users), new GetUser(a.users), /* ... */));
    app.serveOpenApi(OpenApiInfo("clean", "0.1.0"));
    return app;
}

App buildApp() => buildAppWith(currentAdapters());   // Postgres, or memory with STORE=memory
```

## What is kept from Clean Architecture, and what is changed

Kept: the dependency rule; entities and use cases without the framework; the core owning its interfaces (dependency
inversion); one use case per class, with only the ports it needs (single responsibility, interface segregation); thin
controllers; one contract test that every implementation of a port passes (Liskov substitution).

Changed, because of andaime and D:

- **No presenters or output boundaries.** In andaime a handler's return type is the HTTP contract and produces the OpenAPI
  document. A presenter writing to an output port would make handlers return `void` and lose the response schema. Use
  cases return values; controllers map them to response DTOs.
- **No interfaces for the use cases.** Tests replace the ports, not the use cases, and `final` methods are not virtual.
- **No dependency injection container.** `buildApp` already runs once per worker: it is the composition root, written by
  hand ("pure DI"). A compile-time container would cost compile time and hide the wiring; D has no runtime reflection for
  a runtime one.
- **Interfaces, not templates, for ports.** Templated use cases would be compiled again for each use, slow the build and
  make the error messages worse. A virtual call costs nanoseconds next to a database round trip.
- **Exceptions for business errors.** `domain/errors.d` has `NotFound`, `Conflict` and `RuleViolation`; `app.mapError`
  answers each with its status and `{"detail": "..."}`, without logging them as failures
  ([middleware.md](middleware.md#error-handling)).

## Validation: format at the edge, rules in the domain

- The format of a request (types, required fields, lengths, ranges) belongs to the HTTP DTO: `@minLength`, `@inRange` and
  the rest answer 422 before any use case runs ([validation.md](validation.md)).
- What the business decides (an e-mail that must be unique, an order that cannot be cancelled once shipped) belongs to the
  domain and the use cases: they throw `RuleViolation` or `Conflict`.

## Background jobs

A job is an entry point, like a controller: its fields are the payload, and `perform` hands them to a use case. andaime:jobs
builds a job from its JSON, so a job has no constructor to receive the use case through. `adapters/jobs/provider.d` fills
the gap: `jobs.d` registers how to build each use case before serving, and each thread that runs jobs builds its own on
first use, with its own pool.

```d
@Job("default")
struct SendWelcomeJob
{
    long userId;

    void perform(ref JobContext ctx) @safe
    {
        provided!SendWelcome.get().execute(userId);
    }
}

// jobs.d, before serving
provided!SendWelcome.provide(() => new SendWelcome(currentAdapters().users));
```

The other direction, a use case that schedules a job, is a port like any other effect on the outside world:

```d
// usecases/users.d
interface WelcomeMail { void schedule(long userId); }

// adapters/jobs/users.d
final class QueuedWelcomeMail : WelcomeMail
{
    private JobStore store;
    this(JobStore store) { this.store = store; }
    void schedule(long userId) { enqueue(store, SendWelcomeJob(userId)); }
}
```

`jobs.d` also holds the process roles: `--role=api` serves HTTP, `--role=worker` runs the jobs, `--role=all` does both
([jobs-and-cron.md](jobs-and-cron.md#process-roles)).

## Tests

- **HTTP end to end, in memory**: `TestClient(buildAppWith(memoryAdapters()))` runs the real routes, validation, use cases
  and error mapping, without a database.
- **The repository contract**: one function of assertions runs on `MemoryUserRepository` always, and on
  `PgUserRepository` when `TEST_DATABASE_URL` names a test database. Both adapters then behave the same, so tests in memory
  say something about production.
- **Jobs**: `TestJobStore` enqueues and drains them on the test's thread ([jobs-and-cron.md](jobs-and-cron.md)).

`dub test` runs `source/` and `tests/`; `source/main.d` holds only `main`, so the tests can import the composition root.

## Enforcing the rule

`andaime.json` lists the layers and what each may import:

```json
"layers": {
  "domain":   { "modules": ["domain.*"],   "may_import": ["andaime.http.optional"] },
  "usecases": { "modules": ["usecases.*"], "may_import": ["domain", "andaime.http.optional"] },
  "adapters": { "modules": ["adapters.*"], "may_import": ["usecases", "domain", "andaime.*"] },
  "main":     { "modules": ["main", "app", "config", "jobs"], "may_import": ["*"] }
}
```

`andaime check` compiles `source/` with `-deps` (no code is generated) and prints one line for each import that breaks
a rule, for example `andaime check: domain.users imports andaime.web.application (domain may import:
andaime.http.optional)`. A layer may always import its own modules, druntime and Phobos are always allowed, and a module
that is in no layer is reported too. Edit the rules to fit your own architecture: hexagonal, layered or anything else.

## Growing

- **A feature that outgrows one file per layer** becomes a D package: `usecases/users.d` turns into
  `usecases/users/package.d` plus `usecases/users/*.d`. The rules do not change.
- **One feature using another** goes through a port of the caller: `usecases/orders.d` declares what it needs from users,
  and an adapter (or the composition root) implements it with the users' use cases or repository.
- **Writes across repositories in one transaction**: the generated repositories each use the worker's pool, so one
  transaction cannot span two of them yet. Put such a write in one repository method that opens `db.transaction`.
- **When not to use this**: a service with a handful of routes and no business rules gains little from four layers.
  `andaime new --template minimal` keeps the routes, handlers and tests in one module.
