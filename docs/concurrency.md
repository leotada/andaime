# Concurrency: workers, fibers and waiting

## The model

- **One worker per CPU core** (`ServerConfig.workers = 0`), each a thread with its own event loop (epoll) and its own listening
  socket (`SO_REUSEPORT`).
- **One fiber per request.** A fiber is a lightweight thread with its own stack. When a handler waits (a database query, an
  HTTP call, `sleep`), only its fiber is suspended; the worker serves other requests meanwhile.
- **One `App` per worker.** `serve(&buildApp, cfg)` calls `buildApp` once in each worker, on that worker's thread.

So you write plain sequential code (no `async`/`await`, no callbacks) and still serve thousands of concurrent requests.

## Workers and state

> Everything the build function creates belongs to one worker.

A controller with a counter, a cache in a closure, the database pool and the App itself are never touched by two threads, so
they need no locks. The flip side: **workers do not share memory through the App.** Module-level variables in D are also
thread-local: each worker has its own copy.

```d
App buildApp()
{
    auto app = new App;
    auto cache = new ProductCache;             // one per worker
    app.mount(new ProductController(cache));
    return app;
}
```

To share state between workers:

- **A database** (the usual answer). Pools are per worker too: with `PgConfig.maxConns = 10` and 4 workers, the database sees up
  to 40 connections.
- **`__gshared` data behind a lock**, read through a small `@trusted` function:

  ```d
  import core.sync.mutex : Mutex;

  __gshared Mutex lock;           // created in main, before serve
  __gshared long[string] hits;    // only touched with `lock` held

  void count(string key) @trusted { synchronized (lock) hits[key]++; }   // sound: always under `lock`
  ```

  Keep critical sections short and **never wait (a query, `sleep`, an HTTP call) while holding the lock**: it would block
  every other request of the worker.
- **Read-only configuration**: fill a `__gshared` value in `main` before `serve`, and read it through a `@trusted` accessor
  that returns `const` (see `examples/api/source/app.d`).

The build function must return a **new** `App` each time; returning one shared App (`serve(() => app, ...)`) is refused at
startup. If it throws (a bad route, for example), the server prints one line and exits. `tryServe` returns `false` instead.

To run a single worker (an in-memory example, a test): `cfg.workers = 1`.

## Waiting without blocking

Inside a handler, everything that waits must go through andaime:

| To | Use |
|----|-----|
| pause | `sleep(500.msecs)` (from `core.time`), not `Thread.sleep` |
| query PostgreSQL | `andaime:pg` ([database.md](database.md)) |
| call an HTTP API | `httpClient()` ([http-client.md](http-client.md)) |
| wait for a file descriptor (your own driver) | `awaitFd(fd, IoEvent.readable, timeout)` |
| run CPU-heavy work or a blocking C library | `offload(...)` (below) |

A blocking call (`Thread.sleep`, a synchronous socket, a slow C function) stalls **every** request of the worker. andaime logs a
warning when a handler holds the worker for more than `stallWarnMs` (50 ms) without yielding.

Outside a request (in `main`, in unittests) the same functions just block, so the same code works in both places.

## `offload`: the thread pool

```d
string thumbnail(long id) => offload(() => resizeImage(load(id)));     // runs on a pool thread
```

- The calling fiber is suspended until the work finishes; the result (or the exception) comes back to it.
- The delegate must be `@safe` (wrap C calls in a `@trusted` function that says why it is sound).
- The pool is bounded: when its queue is full, `offload` throws `PoolSaturated` right away. Decide whether that becomes a 503.
- Size it once, before `serve`: `configureOffload(threads, queueMax)`.
- The work must not touch the request or the App: it runs on another thread. Pass it what it needs, return a result.
  It does not see the fiber's per-request state either (`fiberLocal`), so a database transaction the fiber has open does not
  extend to it; andaime:pg asserts (in a non-release build) when the work queries the pool in that case.
- If the request is cancelled meanwhile, the work still finishes and its result is discarded.

## Cancellation

A request is cancelled when the client disconnects, when `requestTimeoutMs` (30 s) passes before the response starts (the
client gets a 504), or on a graceful stop after `shutdownGraceMs`. The handler learns it at its next wait or write:
`RequestCancelled` is thrown there.

- It is a `Throwable`, not an `Exception`: `catch (Exception)` does not swallow it, and `scope(exit)` blocks and destructors
  run as usual.
- The PostgreSQL driver cancels the query on the server; the HTTP client closes its connection.
- A handler that only computes (never waits) cannot be cancelled until it waits again.

## Limits per worker

`maxInFlight` (1,024) requests at once, above which new requests get **503** with `Retry-After` (HTTP/2 streams are refused
with `REFUSED_STREAM`). Streaming responses count too. `maxConnections` (10,000) connections. All the fields are in
[configuration.md](configuration.md).

## Graceful stop

SIGINT or SIGTERM stops accepting connections, lets in-flight requests finish for up to `shutdownGraceMs` (10 s), sends HTTP/2
`GOAWAY`, and cancels what is left.
