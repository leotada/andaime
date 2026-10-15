# PostgreSQL (`vela-pg`)

`vela-pg` is a PostgreSQL driver over asynchronous libpq: a query suspends only the request's fiber, and the worker keeps
serving other requests meanwhile. It is a separate DUB package, and libpq is loaded at run time, so applications that do not
use it neither link nor install it.

## Setup

`dub.sdl`:

```sdl
dependency "vela" path="../dapi"
dependency "vela-pg" path="../dapi/drivers/pg"
```

The machine needs libpq (`libpq5` on Debian/Ubuntu, `libpq5` or `postgresql-libs` elsewhere).

## Queries

```d
import vela;
import vela.db;

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
- Parameter types: integers, `bool`, floating point, strings, `Optional!T` (empty = `NULL`) and your
  [text types](requests.md#your-own-types-uuids-dates-money) (a `Uuid` goes to a `uuid` column as text: `$1::uuid`).
- Arrays of those are Postgres arrays: `db.query("select * from users where id = any($1::uuid[])", ids)`. Every element is
  quoted and escaped, an empty `Optional` element is `NULL`, and an empty array is `{}` (it matches nothing). Cast the
  parameter (`$1::int[]`, `$1::text[]`) so the server knows the element type. `ubyte[]` is refused at compile time (bytea
  or an array of numbers?), and so are nested arrays.
- `rowsAs!T` maps every row to a struct, matching fields to columns by name (a missing column throws). `one!T` returns the
  first row and throws when there is none.
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
    cfg.cacheStatements = false;          // prepared statements; not behind PgBouncer in transaction mode
    return pgPool(cfg);
}
```

- **One pool per worker** (`pgPool` is per thread): the database sees up to workers x `maxConns` connections. Never pass a
  connection to another worker.
- `cacheStatements = true` prepares each SQL text once per connection (up to 128), and retries when the plan was invalidated.
- If the client goes away or the deadline passes during a query, the driver asks the server to cancel and discards the
  connection.

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
