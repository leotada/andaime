# PostgreSQL (`andaime:pg`)

`andaime:pg` is a PostgreSQL driver over asynchronous libpq: a query suspends only the request's fiber, and the worker keeps
serving other requests meanwhile. It is a separate DUB package, and libpq is loaded at run time, so applications that do not
use it neither link nor install it.

## Setup

`dub.sdl`:

```sdl
dependency "andaime" path="../andaime"
dependency "andaime:pg" path="../andaime"
```

The machine needs libpq (`libpq5` on Debian/Ubuntu, `libpq5` or `postgresql-libs` elsewhere). `pgAvailable()` says whether
it loaded and `pgLoadError()` returns the reason (an `Optional!string`), for a startup or image check; neither connects
to anything. Without libpq, `PgConn.connect` throws `PgError` with the same message.

## Queries

```d
import andaime;
import andaime.db;

struct User { int id; string name; Optional!string email; }

PgPool db() => pgPool("host=db.example.com dbname=app user=app");   // this worker's pool, created on first use

User getUser(int id)
{
    auto users = db.query("select id, name, email from users where id = $1", id).rowsAs!User;
    if (users.length == 0)
        throw new HttpError(404, "user not found");
    return users[0];
}

@status(201)
User createUser(JsonBody!NewUser body_)
{
    return db.query("insert into users(name, email) values ($1, $2) returning id, name, email",
        body_.name, body_.email).one!User;
}

void touch(int id) { db.exec("update users set seen_at = now() where id = $1", id); }
```

- Parameters are `$1..$n` and are sent separately from the SQL: **never build SQL from user input**.
- Parameter types: integers, `bool`, floating point, strings, enums, `Optional!T` (empty = `NULL`) and your
  [text types](requests.md#your-own-types-uuids-dates-money) (a `Uuid` goes to a `uuid` column as text: `$1::uuid`).
- An enum travels as its [wire name](requests.md#wire-names-naming-and-wirename), the same text as in JSON: it fits a
  Postgres enum (`$1::task_type`, whose labels are the wire names) or a `text` column, and a column reads back the same way
  (a label that is no wire name throws).
- Dates and times: a [`Timestamp`](requests.md#dates-and-times-timestamp-and-calendardate) is a `timestamptz` parameter
  (`$1::timestamptz`; it is sent with its offset) and a `CalendarDate` a `date` one.
- Arrays of those are Postgres arrays: `db.query("select * from users where id = any($1::uuid[])", ids)`. Every element is
  quoted and escaped, an empty `Optional` element is `NULL`, and an empty array is `{}` (it matches nothing). Cast the
  parameter (`$1::int[]`, `$1::text[]`) so the server knows the element type. `ubyte[]` is refused at compile time (bytea
  or an array of numbers?), and so are nested arrays.
- `rowsAs!T` maps every row to a struct, matching fields to columns by name (a missing column throws). `one!T` returns the
  first row and throws when there is none.
- Column names: `@naming(Naming.snakeCase)` on the struct reads `first_name` into `firstName` (the same policy names the
  struct's JSON, see [wire names](requests.md#wire-names-naming-and-wirename)); `@column("mail") string email;` names one
  field. A `@prefix` goes before the nested struct's own names (`author_first_name`). A struct without `@naming` uses the
  project's default (`versions "AndaimeNamingSnakeCase"`, see [one policy for the whole project](requests.md#one-policy-for-the-whole-project)),
  so a domain type with no attribute reads `created_at` into `createdAt`. `rowsAs!(T, Naming.snakeCase)` and
  `one!(T, Naming.snakeCase)` set the policy for one query, for `T` and its `@prefix` structs.
- A column that may be NULL is an `Optional!T`; the same type is `null` in JSON, so rows serialize with no conversion.
- A joined row goes into a nested struct with `@prefix`: its fields come from the columns with that prefix. On an
  `Optional` struct, all of its columns NULL (a LEFT JOIN that found nothing) gives an empty `Optional`:

  ```d
  struct UserSummary { int id; string email; }
  struct Post { int id; string title; @prefix("author_") Optional!UserSummary author; }

  auto posts = db.query("select p.id, p.title, u.id as author_id, u.email as author_email"
      ~ " from posts p left join users u on u.id = p.author_id").rowsAs!Post;
  ```

  Prefixes nest (`post_owner_id` for an `owner` inside a `post`). A missing prefixed column throws like any other, and a
  NULL in a non-`Optional` field of a struct that is there is the usual error.
- <a id="dates-and-times"></a>`timestamptz` and `date` columns read into `Timestamp` and `CalendarDate` (and `Optional!` of them, and
  `Timestamp[]` / `CalendarDate[]` for `timestamptz[]` / `date[]`). Postgres prints a `timestamptz` in the session's time
  zone (`2026-10-19 09:00:00.123456-03`), and the `Timestamp` keeps that offset; since `==` compares the instant, the value
  you stored equals the one you read back whatever the zone. `timestamp` (without zone), `infinity` and `-infinity` are
  not instants and throw like any value that does not fit. A microsecond is what Postgres keeps, so nothing is lost.
- Array columns read into `T[]` (`int[]`, `string[]`, `Uuid[]`, an enum...): `uuid[]`, `text[]`, `int[]`, and
  `array_agg(...)`. A `NULL` element needs `Optional!T[]`; a multidimensional array throws (read it as `string`).
- A `json`/`jsonb` column reads into `Json!T` (from `andaime.web`): `Json!(TagRef[]) tags` decodes the text with the rules of a
  request body, and `Json!JsonValue` takes anything. In a response it is plain JSON (not a string), OpenAPI shows `T`, and it
  is also a parameter (`$1::jsonb`). With `array_agg` and `json_agg` a list endpoint loads its relations in one query:

  ```d
  struct TagRef { int id; string name; }
  @naming(Naming.snakeCase) struct TaskOut { int id; Uuid[] tagIds; Json!(TagRef[]) tags; }

  auto tasks = db.query("select t.id,"
      ~ " coalesce(array_agg(g.uid) filter (where g.id is not null), '{}') as tag_ids,"
      ~ " coalesce(json_agg(json_build_object('id', g.id, 'name', g.name)) filter (where g.id is not null), '[]') as tags"
      ~ " from tasks t left join task_tags l on l.task_id = t.id left join tags g on g.id = l.tag_id"
      ~ " group by t.id").rowsAs!TaskOut;
  ```
- Lower level: `r.rows`, `r.cols`, `r.get!T(row, col)`, `r.isNull(row, col)`, `r.column("name")`, `r.affected()`.

## Transactions

```d
long transfer(long from, long to, long cents)
{
    return db.transaction((PgConn c) {
        c.exec("update accounts set cents = cents - $2 where id = $1", from, cents);
        c.exec("update accounts set cents = cents + $2 where id = $1", to, cents);
        return c.query("insert into transfers(src, dst, cents) values ($1, $2, $3) returning id", from, to, cents)
            .get!long(0, 0);
    });
}
```

`BEGIN` and `COMMIT` on one connection; `ROLLBACK` if the delegate throws.

Transactions nest: `transaction` on a connection that is already in one (`PgConn.transaction`, or `db.transaction` on a
pinned connection, below) becomes a savepoint. `c.savepoint((PgConn c) { ... })` is the explicit form: `SAVEPOINT`, then
`RELEASE`, or `ROLLBACK TO SAVEPOINT` if it throws, so the outer transaction goes on without what the savepoint did (an
insert that may hit a unique constraint, say). Outside a transaction it throws `PgError`. `c.inTransaction` tells whether
one is open.

`db.transaction(work, TxMode.readOnly)` begins with `BEGIN READ ONLY`: a write inside fails with SQLSTATE `25006` (and the
transaction rolls back). Nested in another transaction it is a savepoint, which keeps the outer
mode; so under `rollbackAfter` (a read-write harness) a read-only block does not refuse writes.

### One transaction across repositories

`db.transaction` is **ambient**: until it ends, every `query`, `exec`, `lease` and `transaction` on the same pool from the
same fiber runs on its connection. Code that holds only the pool joins it, so two repositories built once per worker write
in one transaction, and a use case decides where it begins without seeing a connection:

```d
final class PgOrders : Orders { PgPool db; void add(Order o) { db.exec("insert into orders ...", o.id); } }
final class PgLines : Lines { PgPool db; void add(Line l) { db.exec("insert into lines ...", l.orderId); } }

db.transaction((PgConn _) {
    orders.add(order);   // same connection,
    lines.add(line);     // same transaction: a throw rolls back both
});
```

- A nested `transaction` is a savepoint. `db.inTransaction` tells whether this fiber has one open on this pool.
- The transaction belongs to the fiber: another request, a `spawn`ed fiber or a job gets its own. Work sent to `offload`
  runs on another thread and does not see it; with asserts on (a non-release build), a pooled query inside `offload` while
  the sending fiber has a transaction open fails with an `andaime.db:` assertion. Run the query before or after `offload`.
- A statement outside any transaction autocommits, as before. `PgConfig.requireTransaction = true` makes `query` and `exec`
  on the pool throw instead, for an application that wants every statement inside a unit of work.
- andaime:pgjobs' `enqueue(store, job)` joins it too when the store uses the same pool (`new PgJobStore(db)`): the job exists
  only if the transaction commits (see [Background jobs](jobs-and-cron.md)). `db.transactionOnSiblingPool` tells whether
  this fiber holds a transaction on another pool of the same database, which statements on `db` cannot join.

### After the commit: `afterCommit`

`db.afterCommit(() { cache.purge(id); })` runs the delegate once the outermost transaction of this fiber on this pool has
committed, on the same fiber and in the order registered, after the connection went back to the pool. It never runs after a
rollback, nor when the savepoint that registered it rolls back. Outside a transaction it runs at once. A callback that
throws does not undo the commit nor stop the others: the exception goes to `PgConfig.onCallbackError` (one line on stderr
when it is null; point it at `andaime.log`). Under `rollbackAfter`, the app's outermost transaction is a savepoint and its
callbacks run when it ends. Use it for effects outside the database (a cache, a webhook); a job that must not be lost goes
in the transaction itself.

### Tests that roll back

`db.rollbackAfter(() { ... })` runs the delegate with the pool pinned to one connection inside a transaction that is
always rolled back: everything the code under test writes through that pool, including its own transactions (they become
savepoints), disappears afterwards. `pin(conn)`/`unpin()` are the building blocks, for a harness that opens the outer
transaction itself. Run one request at a time while pinned: a connection runs one query at a time.

```d
unittest
{
    auto c = TestClient(buildApp());
    db.rollbackAfter(() {
        assert(c.post("/users", `{"name":"Ana"}`).status == 201);
        assert(c.get("/users").body == `[{"id":1,"name":"Ana"}]`);
    });   // the user is gone
}
```

## Errors

| Exception | When |
|-----------|------|
| `PgError` | the server refused the query; `sqlState` has the code, `isUniqueViolation()`, `isForeignKeyViolation()` |
| `PgTimeout` (a `PgError`) | `queryTimeout` passed; the server was asked to cancel |

They are not `HttpError`s, so by default they become a 500. Map them in `app.onError` (a 409 for a unique violation, a 504 for a
timeout); `examples/api` shows how.

## Pool and configuration

```d
PgPool db()
{
    PgConfig cfg;
    cfg.conninfo = "host=db.example.com dbname=app user=app";   // or a postgresql:// URI
    cfg.maxConns = 8;                     // per worker
    cfg.connectTimeout = 10.seconds;
    cfg.acquireTimeout = 5.seconds;       // waiting for a free connection
    cfg.queryTimeout = 30.seconds;
    cfg.idleTimeout = 5.minutes;
    cfg.pingAfter = 1.seconds;            // check an idle connection before reusing it
    cfg.cacheStatements = false;          // prepared statements; not behind PgBouncer in transaction mode
    return pgPool(cfg);
}
```

- **One pool per worker** (`pgPool` is per thread): the database sees up to workers x `maxConns` connections. Never pass a
  connection to another worker.
- `cacheStatements = true` prepares each SQL text once per connection (up to 128), and retries when the plan was invalidated.
- If the client goes away or the deadline passes during a query, the driver asks the server to cancel and discards the
  connection.
- **Stale connections**: a connection idle for longer than `pingAfter` is checked before it is handed out (one
  non-blocking `poll`). When the server closed it meanwhile (a restart, a failover, `pg_terminate_backend`, a proxy's idle
  timeout), it is dropped and another one is used, so no request fails on it. The driver never repeats a statement that was
  sent. A peer that vanishes without closing the socket (a dead host, a dropped NAT entry) is not seen by that check: add
  TCP keepalives to the conninfo (`keepalives_idle=30 keepalives_interval=10 keepalives_count=3`).

### Watching queries: `onQuery`

`cfg.onQuery` is called after every statement of the pool's connections, with a `QueryEvent`: `sql` (valid during the call),
`duration`, `rows` (-1 on failure), `error` and `sqlState` of a failure, and `internal` for the `BEGIN`, `COMMIT`,
`ROLLBACK` and `SAVEPOINT` statements andaime sends itself. It runs on the request's fiber, so a log line carries the request id:

```d
cfg.onQuery = (ref const QueryEvent e) @safe {
    if (e.duration > 200.msecs)
        logWarn("slow query", "sql", e.sql, "ms", e.duration.total!"msecs");
};
```

In a test, count what an endpoint runs (`rollbackAfter` reports the app's statements, not its own `BEGIN` and `ROLLBACK`):

```d
size_t queries;
cfg.onQuery = (ref const QueryEvent e) @safe { if (!e.internal) queries++; };
```

The hook is `@safe`; an exception it throws reaches the code that ran the query. A plain `PgConn` has its own `onQuery`
field. A cancelled query (the client went away) is not reported.

## Outside a request

In `main` (migrations, a schema check before `serve`), the same calls block instead of suspending a fiber:

```d
auto c = PgConn.connect(databaseUrl, 10.seconds, 30.seconds);
scope (exit) c.shutdown();
c.exec("create table if not exists users(id serial primary key, name text not null)");
```

## Other databases

There is no driver for other databases yet. A blocking client library can be used through `offload`
([concurrency.md](concurrency.md#offload-the-thread-pool)); a new cooperative driver is built on `awaitFd`.
