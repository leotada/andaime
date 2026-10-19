# Concurrency model

Read before touching `engine/` or `drivers/`.

- One worker per core (`SO_REUSEPORT`), each with its own epoll loop. **One fiber per request.**
- **One `App` per worker** (D1): `serve(build)` takes a build function; each worker calls it once, on its own thread (`WorkerInit`
  in `loop.d`; worker 0 first, alone). Everything the build function creates belongs to that worker, so no App state needs a lock.
  `serve` refuses a build function that returns the same App twice. Never hand an `App`, a controller or a connection to another worker.
- Waiting for I/O inside a handler must go through `awaitFd`/`sleep` (or a library built on them: the Postgres driver, the HTTP
  client). Any blocking call stalls the whole worker; the loop logs a warning past `stallWarnMs`.
- CPU-heavy or blocking-library work goes through `offload(...)` (bounded thread pool; `PoolSaturated` when the queue is full).
- Cancellation (client gone, deadline, a reader that stopped reading) is delivered as `RequestCancelled` (a `Throwable`) at the
  handler's next wait or write; `scope(exit)` and destructors run normally.
- Module-level variables in D are **thread-local**. Share across workers only with `__gshared`/`shared` and a reason, behind a lock
  that is never held across an I/O wait. `pgPool(...)` and `httpClient()` are per worker.
- **Per-request state that the code below a handler needs** (the logger's request id, a job's log scope, andaime:pg's open
  transaction) lives with the request's fiber: `Worker` is a `LocalFiber` (`fiberio.d`) with a small table of values keyed
  by class type (`fiberLocal!T`, `setFiberLocal`, `clearFiberLocal`). `server.d` keeps the request's `Context` there.
  `releaseWorker` and `armBackground` clear the table, so a pooled fiber starts empty. Never keep such state in a
  thread-local variable: requests interleave on one thread at every wait. Outside a `LocalFiber` (`TestClient`, the
  devserver, `WorkerInit`, an offload thread) the same calls use a per-thread table; an offload thread therefore never sees
  the values of the fiber that sent it work. Without fibers `App.handle` also sets `andaime.log`'s per-thread source.
- **Errors inside handlers** (D4): an `Exception` becomes a 500 through the app (logged with a stack trace, 5 traces per second per
  App); an `Error` (RangeError, AssertError...) also gets a 500, a full trace in the log (5 per second per worker, the rest
  counted), and the fiber is retired (`LoopStats.fibersPoisoned`): after an `Error`, cleanup may not have run. A fiber stack
  overflow is a SIGSEGV that kills the process; `onCrash` in `epoll.d` prints which request was running first.
