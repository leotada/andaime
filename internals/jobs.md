# Background jobs

Read before touching `jobs/` or `drivers/pgjobs/`.

- `perform` is `@safe`. A missing `perform`, an `@system` `perform`, a payload `writeJson` cannot encode, or a bad `@Cron` is one
  line from `jobError`, asserted by `JobSet`. Cover a new rule with `tests/compile_fail/job_*.d` (`// FLAGS: -Ijobs/source`).
- I/O that waits (`sleep`, `awaitFd`, the Postgres driver, the HTTP client) runs on the fiber. CPU-heavy work and blocking C go
  through `@Offload` or `offload`.
- A Postgres claim is `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)` and that transaction commits before `perform`.
  Do not hold the row lock across the work.
- Cron dedupe across processes is `INSERT ... ON CONFLICT` on `(job_name, scheduled_slot)` in `andaime_cron_executions`
  (`claimCron` / `claimCronSlot`). The supervisor enqueues only when that insert wins. `PgJobStore.startServices`
  starts `LISTEN` and the reaper on worker 0; an empty claim waits for a notification or 5 seconds.
- Shutdown stops calling `claimBatch`. `release` returns an in-flight row to `retryable` without spending the attempt: a claimed
  row not yet run, `RequestCancelled` inside `perform`, and an `Error`. `--role=worker` and `--role=all` (`applyJobGrace`)
  raise `shutdownGraceMs` from the 10 second default to 30 seconds. A value the application already set is kept.
- The cron parser (`cronError`, `parseCron`) is `@safe pure nothrow @nogc`. Keep it that way.
- `InMemoryJobStore` is one thread. `runJobs` forces `workers = 1` by default. Several cores or processes use `PgJobStore`, one
  store per worker thread, and only worker 0 consumes. Queue concurrency is how many jobs that worker runs at once, not per core.
  One fiber per queue claims. `WorkerHooks.extra` runs on worker 0 before the loop polls: `spawn` from there, and do not call
  `sleep` or `awaitFd` in `extra` itself. A store failure is logged (`andaime.jobs:`) and the fiber continues.
