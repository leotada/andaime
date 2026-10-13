# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.
The code uses the provisional name **vela** (DUB package `vela`, `import vela;`); the repository is `dapi`.

## What this is

A micro web framework in D with FastAPI-style ergonomics: a handler's signature is its HTTP contract, and the
extraction/validation/dispatch code is generated at compile time (CTFE, `__traits`, shallow `static foreach`).
Targets: compile time under 400 ms for an example app on DMD, low RSS on cheap VPSs (15–30 MB under traffic),
one fiber per request on an epoll loop, readable one-line compile errors.

## Language and style rules

- **Write everything in English**: code, identifiers, comments, error messages, log lines, test names, docs, commit messages.
- **Use `@safe` wherever possible.** New code is `@safe` (and `nothrow`/`pure`/`@nogc` where it is natural, never forced).
  Escape hatches (`@trusted`) are small, named, and carry a one-line comment saying why they are sound. `@system` only where
  unavoidable (C bindings, raw pointers, fiber/context switching).
- Idiomatic D in handlers and middleware (slices, strings, delegates, DTOs). Do not add defensive `@nogc` to user-facing code.
  The runtime assumes a low-latency GC; the hot path is nevertheless GC-free and a test enforces it.
- Keep the core free of heavy Phobos: no `std.format`, `std.conv`, `std.json`, `std.regex`, `std.algorithm`, `std.range`
  in `http/`, `web/` and `engine/` (they cost compile time). Tests and examples may use them.
- Prefer shallow constructs (`static foreach`, `static if`) over deep recursive templates.
- Every invalid handler signature must produce a **one-line `static assert` message** that says exactly what to fix
  (see `handlerError` in `web/source/vela/web/handler_traits.d`). Add a case to `tests/compile_fail/` when you add a rule.
- Error messages from the library start with `vela:` (`vela.db:`, `vela.http:` for the drivers/client).

## Safety model (`@safe`)

- Framework-internal delegate types (`RequestCallback`, `HandlerFactory`, `HandlerFn`, `offload`'s work delegate) are `@safe`.
- **User-facing callbacks accept `@system`** (`Middleware`, `ErrorHandler`, `UserHandler`, route handlers): user code may call C
  libraries without ceremony, and `@safe` code converts to them implicitly. The framework invokes user code only through
  `callMiddleware`, `callUser` and the `@trusted` lambda in `dispatch`; add no other call sites.
- `-version=VelaStrictSafe` (dub: `versions "VelaStrictSafe"`) makes `handlerError` reject `@system` handlers with a one-line
  message (`tests/compile_fail/system_handler.d`, which declares its flag with a `// FLAGS:` line). `tests/web/system_code.d`
  proves that `@system` handlers, middleware and error handlers work by default.
- Every module starts with `@safe:` except the raw-syscall ones: `engine/.../epoll.d` and `devserver.d` stay `@system`;
  `EventLoop.run` is `@system` and `vela.server.serve` is the single `@trusted` entry point into them.
  Their overrides of `@safe` interfaces (`stop`, `awaitFd`, `sleepMs`) are small `@trusted` bodies.
- FFI modules (`drivers/pg`, `engine/.../httpclient.d`, `tls.d`, `libpq.d`) expose `@trusted` façades; raw pointers never leave them.
  Anything that hands out a raw view (`PgResult.text`) is `@system`.
- `__gshared` data is `@system`: read it through a small `@trusted` accessor and say why it is sound (usually "written once before the workers start").
- A new `@trusted` needs a one-line comment saying why it is sound. When unsure, keep it `@system`.

## Layout

| Path | Role |
|------|------|
| `http/` (`vela:http`) | HTTP types, zero-copy HTTP/1.1 parser, response writer, byte buffer, HTTP/2 session (`h2.d`) and HPACK (`hpack.d`). No I/O. |
| `web/` (`vela:web`) | `App`, `Group`, router (segment tree), handler introspection, JSON, OpenAPI, CORS, middleware, `TestClient`. No sockets. |
| `engine/` (`vela:engine`) | epoll loop, fibers (`sleep`/`awaitFd`), buffer pool, `offload` thread pool, HTTP/HTTPS client, TLS (dlopen). No routes or DTOs. |
| `drivers/pg/` (`vela-pg`) | PostgreSQL driver over async libpq (dlopen). **Independent package; the core must never depend on it.** |
| `source/vela/` (`vela`) | `import vela;`, `server.d` (the only glue between web and engine), `staticfiles.d`. |
| `examples/hello`, `examples/api` | In-memory CRUD; a real API with Postgres, external API, CORS, static files, OpenAPI. |
| `tests/` | `web/` (no network), `h2/` (HTTP/2 session, no network), `net/` (real sockets), `db/` (needs Postgres), `fuzz/`, `alloc/`, `compile_fail/`, `example/`. |
| `tools/` | `check.sh` (everything), `fuzz.sh`, `h2_interop.sh` (curl, python-h2, h2spec), and the helpers that start a throwaway Postgres / test upstream. |
| `docs/quickstart.md`, `README.md` | User-facing docs. Keep them in sync with behavior. |

Dependency direction: `http` ← `web`, `http` ← `engine` ← `drivers/*`; `source/vela/server.d` is the only module that knows both
`web` and `engine`. Do not introduce a dependency from the core to any driver.

## Commands

```sh
tools/check.sh                 # full verification (DMD); starts a throwaway Postgres and a Python upstream when available
DC=ldmd2 tools/check.sh        # the same with LDC
tools/fuzz.sh [seconds] [parse|h2]  # libFuzzer + ASan on the HTTP/1 parser or the HTTP/2 session (needs LDC)
tools/h2_interop.sh            # HTTP/2 against curl, python-h2 and h2spec (H2SPEC=/path); also run by check.sh
cd examples/api && dub build   # build an example
```

Before declaring a change done, `tools/check.sh` must pass on **both** DMD and LDC. It covers unit tests, web-layer tests,
the parser corpus and fuzzer, network tests, the Postgres and HTTP-client tests, the end-to-end example, a memory test
(1,000 in-flight requests, peak RSS under 30 MB), the compile-fail tests and the compile-time budget.
Tests that need PostgreSQL, Python or OpenSSL skip themselves with a warning when those are missing.

## Concurrency model (read before touching `engine/` or `drivers/`)

- One worker per core (`SO_REUSEPORT`), each with its own epoll loop. **One fiber per request.**
- Waiting for I/O inside a handler must go through `awaitFd`/`sleep` (or a library built on them: the Postgres driver, the HTTP client).
  Any blocking call (a real `Thread.sleep`, a synchronous C library) stalls the whole worker; the loop logs a warning past `stallWarnMs`.
- CPU-heavy or blocking-library work goes through `offload(...)` (bounded thread pool; throws `PoolSaturated` when the queue is full).
- Cancellation (client gone, deadline) is delivered as `RequestCancelled` (a `Throwable`, not an `Exception`) at the handler's next wait;
  `scope(exit)` and destructors run normally.
- Module-level variables in D are **thread-local**. Share across workers only with `__gshared`/`shared` and a clear reason.
- Per-worker singletons: `pgPool(...)` and `httpClient()` are thread-local; never pass connections between workers.

## HTTP/2 (read before touching `http/.../h2.d` or the h2 part of `epoll.d`)

- Protocol logic lives in `H2Session` (`vela.http.h2`), which does no I/O: the engine feeds it bytes (`receive`), runs
  what `popReady` hands out (one fiber per stream, like an HTTP/1 request), cancels what `popReset` hands out, gives back
  each response with `respond` (the handler's HTTP/1.1-format output, transcoded to HEADERS/DATA there), and writes
  `pendingOutput`. Keep that split: anything about frames, HPACK, stream states or flow control belongs in the session,
  where `tests/h2/session_test.d` and the fuzzers can reach it without sockets.
- A stream object the engine holds (`task` set) is never recycled by the session; the engine gives it back with
  `respond` or `detach`. Stream and session objects are pooled: reset every field in `H2Stream.reset`/`H2Session.reset`
  (a stale field on a recycled stream once crashed the session; libFuzzer found it).
- Never send RST_STREAM for a stream that was never opened (idle, or even-numbered): use a connection error.
- An HTTP/2 change: add a case to `tests/h2/session_test.d`, run `tools/h2_interop.sh` (h2spec must stay at 145/146:
  3.5/2 cannot pass on a mixed HTTP/1.1 port), and `tools/fuzz.sh 300 h2`. Inputs that once broke the session go in
  `tests/fuzz/h2_regressions/`; `fuzz_h2.d` replays them on every check.

## Pitfalls that already cost time

- dlopen function tables must live in a `struct` held by a `__gshared` instance (`pq`, `tls`). Loose `extern (C)` variables named like
  the C functions become global symbols that the C library then calls itself, which segfaults.
- Never use `pkill -f` with a pattern that appears in your own command line.
- A user helper named `get`/`put`/`post` hides vela's free functions; use `vela.get!(...)(app)`.
- Slices of the network buffer (`Header!"X"`, `const(char)[]`) are valid only during the request; copy with `.idup` to keep them.
- Group middleware only applies to routes registered after `use`; group prefixes cannot contain `{param}`.
- `real` is a reserved word in D.

## Adding things

- **A new handler parameter kind**: add the wrapper in `web/.../params.d`, bind it in `handler_traits.d` (dispatch and `handlerError`),
  describe it in `openapi.d`, and add tests in `tests/web/` plus a `tests/compile_fail/` case for its misuse.
- **A new driver** (MySQL, Redis...): a new package under `drivers/`, depending only on `vela:engine`, using `awaitFd`/`offload`;
  load native libraries at run time (dlopen) so the framework still builds without them.
- **A new event-loop backend** (kqueue, io_uring): implement the `EventLoop` interface in `engine/source/vela/engine/loop.d`.
- **A parser change**: add a file to `tests/fuzz/corpus/` named `<name>.<ok|incomplete|status>.http` and run the fuzzer.
- **A new `Request` field**: every producer must set it — the HTTP/1 parser (`parseRequestHead`) and the HTTP/2 session
  (`finishRequest`) — because the fiber's `Request` is reused across protocols.

## Out of scope for now

Performance work (M4: benchmarks, SIMD head search, GC tuning, `sendfile`), kqueue (M5) and io_uring (M6), chunked request bodies,
TLS termination in the server (HTTP/2 over TLS with ALPN, for browsers). Do not start these unless asked.
