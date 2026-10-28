# Architecture: an optional clean template

andaime does not impose an architecture. A handler is a function, a controller method or a lambda, and everything else is
your code. Small services are often best as one module (`examples/hello`). For applications that will grow, this page
describes a ready-made structure based on Clean Architecture and SOLID. `andaime new` generates it ([cli.md](cli.md)), but
nothing in andaime depends on it: you can follow it by hand, change it, or ignore it.

`examples/clean` is a complete application in this structure: users over HTTP, Postgres and memory, companies with their
members (a tenant, the acting user, two tables in one unit of work), a background job scheduled through the transactional
outbox, and their tests. It is the exact output of `andaime new --tenant` and `andaime generate`.

## The layers

The folders are the circles of the Clean Architecture diagram, and a feature is the same file name in every layer:

```
source/
  domain/users.d            entities and business rules
  usecases/users.d          what the application does, and the ports it needs
  adapters/http/users.d     a controller, the JSON a client sends and receives
  adapters/postgres/users.d a repository over andaime:pg
  adapters/memory/users.d   the same repository in memory (tests, running without a database)
  adapters/jobs/users.d     background jobs
  app.d                     the composition root: which adapter implements each port, which routes the app serves
  main.d, jobs.d, config.d  the process: configuration, roles, serve
```

**The dependency rule**: source code points inward only.

| Layer | May import |
|-------|-----------|
| `domain/` | druntime, Phobos, `andaime.values` (`Optional`, `PatchField`, `JsonValue`, `Uuid`, `Timestamp`, `CalendarDate`: values with no I/O) |
| `usecases/` | `domain/`, `andaime.values` |
| `adapters/` | `usecases/`, `domain/`, andaime |
| `app.d`, `main.d`, `jobs.d`, `config.d` | anything |

So the business code compiles and is tested without a framework, a database or a network, and an adapter can be replaced
without touching it. `andaime check` verifies the rule from the compiler's own import graph ([below](#enforcing-the-rule)).

## A feature, layer by layer

**Domain**: plain structs and functions. No framework, no status codes.

```d
module domain.users 2025;

struct User { long id; string name; string email; }
struct NewUser { string name; string email; }

/// What the business decides; throws RuleViolation. The request's format is checked at the edge.
void checkRules(const NewUser user) { }
```

**Use cases and ports**: one `final class` per use case, with one `execute`. Its constructor takes the ports it needs;
the port is an `interface` declared next to the use cases that need it (the use cases own it, the adapters implement it).

```d
module usecases.users 2025;

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
module adapters.http.users 2025;

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
    api.mount(construct!UserController(a));   // its use cases, and their ports, are found in `a` by type
    app.serveOpenApi(OpenApiInfo("clean", "0.1.0"));
    return app;
}

App buildApp() => buildAppWith(currentAdapters());   // Postgres, or memory with STORE=memory
```

`construct!T(a)` reads the constructor of `T` and fills each parameter from the field of `Adapters` with that type, or by
building it the same way when it is a concrete class (the controller's use cases). A value that is not a port, such as a
JWT secret, is an extra argument: `construct!Login(a, secret)`. It is resolved at compile time: a parameter with no
value, two fields of one type, a cycle or a class with several constructors is a one-line compile error that names the
class and the parameter. Writing the `new` lines by hand still works; `construct!` only removes the lines that repeat the
constructor.

## What is kept from Clean Architecture, and what is changed

Kept: the dependency rule; entities and use cases without the framework; the core owning its interfaces (dependency
inversion); one use case per class, with only the ports it needs (single responsibility, interface segregation); thin
controllers; one contract test that every implementation of a port passes (Liskov substitution).

Changed, because of andaime and D:

- **No presenters or output boundaries.** In andaime a handler's return type is the HTTP contract and produces the OpenAPI
  document. A presenter writing to an output port would make handlers return `void` and lose the response schema. Use
  cases return values; controllers map them to response DTOs.
- **No interfaces for the use cases.** Tests replace the ports, not the use cases, and `final` methods are not virtual.
- **No dependency injection container.** `buildApp` already runs once per worker: it is the composition root ("pure
  DI"). `construct!T(adapters)` only fills a constructor by type at compile time, from a struct you wrote; there is no
  registry, nothing is looked up at run time, and a missing port does not build. D has no runtime reflection for a
  runtime container.
- **Interfaces, not templates, for ports.** Templated use cases would be compiled again for each use, slow the build and
  make the error messages worse. A virtual call costs nanoseconds next to a database round trip.
- **Exceptions for business errors.** `domain/errors.d` has `NotFound`, `Conflict` and `RuleViolation`, each with a
  `code`; `app.mapError` answers each with its status, without logging them as failures, and `app.errorBody(&apiError)`
  (`adapters/http/errors.d`) gives every error the API answers one body, `{"message": "...", "code": "..."}`
  ([validation.md](validation.md#one-body-format-for-every-error-errorbody)).
- **Wire names are the adapters' business.** `dub.sdl` sets `versions "AndaimeNamingSnakeCase"`: JSON, query strings,
  OpenAPI and columns spell `createdAt` as `created_at`, and the domain's structs carry no andaime attribute
  ([requests.md](requests.md#one-policy-for-the-whole-project)). Where a DTO differs from a domain type by a few fields,
  `copyAs!UserOut(user)` copies the rest.
- **Time, identifiers and tokens are ports.** `usecases/system.d` declares `Clock` (it returns a `Timestamp`),
  `IdGenerator` and `TokenGenerator`;
  `adapters/system/` implements them over the system (`uuid7()`, the secure random generator) and `tests/fakes.d` gives
  fixed ones, so a use case that stamps a date or creates an id is tested exactly.

## Validation: format at the edge, rules in the domain

- The format of a request (types, required fields, lengths, ranges) belongs to the HTTP DTO: `@minLength`, `@inRange` and
  the rest answer 422 before any use case runs ([validation.md](validation.md)).
- What the business decides (an e-mail that must be unique, an order that cannot be cancelled once shipped) belongs to the
  domain and the use cases: they throw `RuleViolation` or `Conflict`.

## Transactions: the unit of work

A use case that writes through two repositories, or writes and schedules a job, owns the boundary of its transaction
through a port, `usecases/uow.d`:

```d
interface UnitOfWork
{
    void run(scope void delegate() @safe work);       // all of it, or none of it
    void readOnly(scope void delegate() @safe work);  // one consistent view
}
T inUnitOfWork(T)(UnitOfWork uow, scope T delegate() @safe work);   // for work that returns a value

final class CreateCompany
{
    // ... the constructor takes uow, companies, memberships
    Company execute(Actor actor, NewCompany input)
    {
        return inUnitOfWork(uow, () {
            auto company = companies.add(input);
            memberships.add(Membership(company.id, actor.userId, Role.owner));
            return company;
        });
    }
}
```

The use case sees no connection and no framework. The adapters decide what a transaction is:

- `PgUnitOfWork` (`adapters/postgres/uow.d`) runs `work` in `db.transaction`. andaime:pg's transactions are ambient: while
  `work` runs, every repository built over the worker's pool, and the job store over the same conninfo, runs its
  statements on that transaction's connection ([database.md](database.md#one-transaction-across-repositories)). So the
  composition root still builds the repositories once per worker, and a nested `run` is a savepoint.
- `MemoryUnitOfWork` (`adapters/memory/uow.d`) snapshots every store it tracks (`uow.track(new MemoryUserRepository)`,
  and the in-memory job store) and puts them back when `work` throws, so the tests in memory see the same rollback.

What does not join: a query inside `offload` (another thread; andaime asserts on it), and another fiber (`spawn`, another
request). `PgConfig.requireTransaction` makes a statement outside any unit of work an error, for teams that want every
write inside one.

**Why ambient, and not a typed transaction per feature.** The other design hands the work an interface of repositories
bound to one transaction (`interface CompanyTx { CompanyRepository companies(); MembershipRepository memberships(); }`,
`UnitOfWork!CompanyTx.run((CompanyTx tx) { tx.companies.add(...); })`), so the compiler checks that the repositories
used are the transaction's. Both were built on the companies feature and measured:

| | ambient (kept) | typed `Tx` |
|---|---|---|
| code of the feature (use cases, both adapters, tests) | 307 lines | 367 lines (+20%) |
| per feature, on top | nothing | a `Tx` interface, a Postgres and a memory implementation, a `Tx` fake per test |
| read use cases | call the repository | wrap the call in `uow.readOnly((tx) { result = ...; })` |
| a transaction across two features | any repositories join | a new `Tx` interface combining both |
| type-check of the app (source and tests) | 371 ms | 371 ms |
| 3,000 `CreateCompany` on Postgres | 942 ms | 944 ms |

Same speed and compile time; the typed design costs code in every feature and makes cross-feature transactions a new
interface each time. What it buys, the compiler refusing a repository from outside the transaction, the ambient design
gets from the pool itself (a repository over the worker's pool always joins), with an assertion for `offload` and
`requireTransaction` for statements outside any unit of work.

## Tenants and the acting user

`andaime new --tenant` adds what a multi-tenant application needs from the start, and a feature that uses it
(companies and their members):

- **`Tenant`** (`domain/tenancy.d`) is a typed value: the company that owns some data. A repository method over data a
  company owns takes it (`memberships.list(actor.tenant)`), so every query names whose data it reads: forgetting the
  filter does not compile, where an implicit, scoped repository would leak data between companies when one is missed.
- **`Actor`** is the user acting on a request: id, active tenant, role. The controller builds it from the request's
  authentication (`Local!AuthContext`, set by a middleware) and passes it to `execute`; the use case decides with the
  domain's policies (`require(canSeeMembers(actor), "...")`), which throw `Forbidden` (403). Permissions are business
  rules, not status codes.
- **`adapters/http/auth.d`** is a development stand-in that trusts three headers. Replace it with real authentication
  (a session, a verified token) before production; it only has to set the same `AuthContext`.
- **`CreateCompany`** writes the company and the owner's membership in one unit of work, with `Clock` and `IdGenerator`
  for its timestamp and its UUID.

## Read models

A query use case does not have to return entities. When a screen needs a list with data from several tables (tasks with
their tags and assignees), declare its shape in `usecases/` (`struct TaskListItem { ...; TagRef[] tags; }`) and let the
Postgres adapter fill it in one statement, with `json_agg`/`array_agg` into `Json!(TagRef[])` or array fields and
`rowsAs` ([database.md](database.md)). The memory adapter builds the same shape from its stores. One round trip instead of
one per row, and the entity stays what the business rules need.

## Background jobs

A job is an entry point, like a controller. It comes in two parts: the payload (the `@Job` struct: what is stored) and its
handler (a class that receives the use case through its constructor and hands it the payload). `jobs.d` is the jobs'
composition root: `buildJobs` builds the handlers over `currentAdapters()`, once, on the thread that runs the jobs, as
`buildApp` builds the routes. A job of `AllJobs` without a handler stops the start.

```d
// adapters/jobs/users.d
@Job("default")
struct SendWelcomeJob { long userId; }

final class SendWelcomeHandler
{
    private SendWelcome useCase;
    this(SendWelcome useCase) { this.useCase = useCase; }
    void perform(const SendWelcomeJob job, ref JobContext ctx) @safe { useCase.execute(job.userId); }
}

// jobs.d
JobHandlers buildJobs()
{
    auto handlers = new JobHandlers;
    handlers.handle!SendWelcomeJob(new SendWelcomeHandler(new SendWelcome(currentAdapters().users)));
    return handlers;
}
```

No global, no `@trusted`: the tests build a handler over in-memory adapters and pass it to `drainJobs`
([jobs-and-cron.md](jobs-and-cron.md#jobs-that-receive-their-dependencies-handlers)).

The other direction, a use case that schedules a job, is a port like any other effect on the outside world. `generate job`
writes it next to the use case, and its adapter next to the job:

```d
// usecases/users.d
interface SendWelcomeScheduler { void schedule(long userId); }

// adapters/jobs/users.d
final class QueuedSendWelcome : SendWelcomeScheduler
{
    private JobStore store;
    this(JobStore store) { this.store = store; }
    void schedule(long userId) { SendWelcomeJob job; job.userId = userId; enqueue(store, job); }
}
```

Called inside a unit of work (below), the job is part of the transaction: the transactional outbox, with no connection in
sight. A rollback leaves no job; a commit stores it and wakes a worker.

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
`tests/openapi.d` keeps a snapshot of the API contract in `tests/openapi.json` (`UPDATE_OPENAPI=1 dub test` accepts a change,
[static-files-and-openapi.md](static-files-and-openapi.md#the-document-as-a-file-for-a-typed-frontend)).

## Enforcing the rule

`andaime.json` lists the layers and what each may import:

```json
"layers": {
  "domain":   { "modules": ["domain.*"],   "may_import": ["andaime.values.*"] },
  "usecases": { "modules": ["usecases.*"], "may_import": ["domain", "andaime.values.*"] },
  "adapters": { "modules": ["adapters.*"], "may_import": ["usecases", "domain", "andaime.*"] },
  "main":     { "modules": ["main", "app", "config", "jobs"], "may_import": ["*"] }
}
```

`andaime check` compiles `source/` with `-deps` (no code is generated) and prints one line for each import that breaks
a rule, for example `andaime check: domain.users imports andaime.web.application (domain may import:
andaime.values.*)`. A layer may always import its own modules, druntime and Phobos are always allowed, and a module
that is in no layer is reported too. Edit the rules to fit your own architecture: hexagonal, layered or anything else.

## Growing

- **A feature that outgrows one file per layer** becomes a D package: `usecases/users.d` turns into
  `usecases/users/package.d` plus `usecases/users/*.d`. The rules do not change.
- **One feature using another** goes through a port of the caller: `usecases/orders.d` declares what it needs from users,
  and an adapter (or the composition root) implements it with the users' use cases or repository.
- **Writes across repositories in one transaction**: run them in the use case's unit of work ([above](#transactions-the-unit-of-work)).
- **One class per file**: when a feature's use cases outgrow one file, make `usecases/companies/` a package with one
  module per use case (`create_company.d`, `list_members.d`) and the ports in `usecases/companies/package.d` or
  `ports.d`. The generators still write one file per layer; move the classes by hand when the file gets long (the rules
  and the imports of `app.d` do not change if `package.d` imports the modules publicly).
- **A large `app.d`**: give each feature a composition function next to it (`compose/companies.d`:
  `void mountCompanies(Group api, ref Adapters a)`), and keep `buildAppWith` a list of calls. Add the folder to the `main`
  layer of `andaime.json`.
- **A package prefix**: an application whose modules are `visto.domain.users`, `visto.usecases.users`... uses globs with
  it in `andaime.json` (`"modules": ["visto.domain.*"]`); the longest matching glob decides a module's layer.
- **A composition root with many use cases**: the generators emit `construct!X(a)` for controllers and job handlers, so a
  hundred use cases are not a hundred hand-written `new` lines, and a changed constructor needs no edit at the call
  sites. Two ports of one type (two `Clock`s, say) are told apart by giving one of them as an extra argument.
- **When not to use this**: a service with a handful of routes and no business rules gains little from four layers.
  `andaime new --template minimal` keeps the routes, handlers and tests in one module.

## Why andaime has its own JSON

andaime reads and writes JSON with its own code (`web/source/andaime/web/json.d` and `jsonvalue.d`), not with `std.json`.
`std.json` is only used in tests, as an independent parser that checks what andaime writes. The reasons:

- **Typed decoding and encoding.** `std.json` parses a tree and leaves copying it into your struct to you (and building a
  tree to write). andaime decodes a body straight into a DTO, with its validation attributes and one error per field, and
  writes a DTO straight into the response buffer.
- **No garbage on the hot path.** A handler's return value is written into a pooled buffer, and `tests/alloc` fails the
  build if serving a request allocates. A tree-based writer cannot do that.
- **`@safe` and bounded input.** `std.json`'s accessors are `@system`. andaime's reader is `@safe`, limits nesting
  (`JsonLimits.maxDepth`) and is fuzzed (`tools/fuzz.sh json`).
- **Compile time.** Pulling in `std.json` and the Phobos modules around it costs more than the 400 ms budget can spare.

Measured with `tools/json_bench.sh` and `tools/json_load.sh` (LDC `-O`, a 1.7 KB order with 20 items, one worker on one
core, 64 connections, 60 s). The `std.json` side does what a handler would have to do by hand: parse, then copy.

| | andaime | `std.json` |
|---|---:|---:|
| Decode into a struct | 23 µs, 8.9 KB garbage | 74 µs, 37 KB garbage |
| Encode a struct | 7.4 µs, 5.9 KB garbage | 50 µs, 25 KB garbage |
| Parse to a generic tree | 42 µs, 45 KB garbage | 60 µs, 30 KB garbage |
| Compile time of one decode call | 181 ms | 373 ms |
| POST that decodes and encodes the order | **23,300 req/s**, p99 3.1 ms | 7,300 req/s, p99 12.5 ms |

What this does not show: generic `JsonValue` trees allocate more than `std.json`'s, so the memory gain is for typed DTOs.
Peak RSS was the same in the one-minute run (9 MB), and the long-run effect of less garbage (fewer GC pauses) is reasoned,
not measured. If most of your handlers wait on a database, JSON is a small part of each request. Numbers depend on the
machine: run the scripts twice and compare before/after, not across machines.
