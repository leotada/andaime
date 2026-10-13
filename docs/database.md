# Database, external APIs and heavy work

Every wait below suspends only the request's fiber; the worker keeps serving other connections.

```d
import vela.db;                       // dependency "vela-pg" path="drivers/pg"; needs libpq5 installed

struct User { int id; string name; Optional!string email; }

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

## PostgreSQL (`vela-pg`)

- A separate DUB package over asynchronous libpq, loaded with dlopen: the core depends neither on it nor on libpq.
- Queries use `$1..$n` text parameters: never build SQL from user-supplied values.
- A column that may be NULL is an `Optional!T` (the same type the web layer uses, so a row serializes to JSON `null`).
- Your own types work as parameters and columns when they follow the text-type protocol (`fromString`/`toString`, see
  `vela.http.texttype`): a `Uuid` goes to a `uuid` column as text and comes back through `fromString`.
- If the client goes away or the deadline expires midway through a query, the driver asks the server to cancel and discards the
  connection. The same goes for outgoing HTTP calls (the connection is closed).
- `PgConfig.cacheStatements = true` uses prepared statements (up to 128 per connection, with a retry if the plan is
  invalidated). It is off by default: do not use it behind PgBouncer in transaction mode.
- Each worker has its own pool (`pgPool` is thread-local): total connections = workers x `PgConfig.maxConns`. Never pass a
  connection between workers.

## HTTP client

`httpClient()` is cooperative, with verified HTTPS, keep-alive, retry on a stale connection and deadlines. It returns whole
bodies (streaming an upstream response is not supported yet). One client per worker.

## `offload`

CPU-heavy or blocking-library work goes through `offload(...)`, a bounded thread pool (`configureOffload`). It throws
`PoolSaturated` when the queue is full; decide whether that becomes a 503. Cancellation of the request is delivered at the next
wait; the offloaded work finishes by itself.
