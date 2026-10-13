# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.
The code uses the provisional name **vela** (DUB package `vela`, `import vela;`); the repository is `dapi`.
`PLAN.md` holds the improvement plan with its decision log (owner decisions D1-D4, planner decisions P1-P9) and what was done.

## What this is

A micro web framework in D with FastAPI-style ergonomics: a handler's signature is its HTTP contract, and the
extraction/validation/dispatch code is generated at compile time (CTFE, `__traits`, shallow `static foreach`).
Targets: compile time under 400 ms for an example app on DMD, low RSS on cheap VPSs (15-30 MB under traffic),
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
- Use only one import of a name per module (a private selective import next to a `public import` of the same name made
  `is(T == X!U, U)` false on DMD 2.109).
- Never use `pkill -f` with a pattern that appears in your own command line.
- `real` is a reserved word in D.

## Safety model (`@safe`)

- Framework-internal delegate types (`RequestCallback`, `HandlerFactory`, `WorkerInit`, `HandlerFn`, `offload`'s work delegate) are `@safe`.
- **User-facing callbacks accept `@system`** (`Middleware`, `ErrorHandler`, `UserHandler`, route handlers, a text type's methods):
  user code may call C libraries without ceremony, and `@safe` code converts to them implicitly. The framework invokes user code
  only through `callMiddleware`, `callUser`, `callBuild` (the app build function, `server.d`), `callStream`/`callEvents` (stream
  bodies, `stream.d`), `textFromString`/`textToString` (a user's text type, `vela.http.texttype`) and the `@trusted` lambda in
  `dispatch`. Add no other call sites.
- `-version=VelaStrictSafe` (dub: `versions "VelaStrictSafe"`) makes `handlerError` reject `@system` handlers with a one-line
  message (`tests/compile_fail/system_handler.d` declares its flag with a `// FLAGS:` line). `tests/web/system_code.d` proves
  that `@system` handlers, middleware and error handlers work by default.
- Every module starts with `@safe:` except the raw-syscall ones: `engine/.../epoll.d` and `devserver.d` stay `@system`;
  `EventLoop.run` is `@system` and `vela.server.serve` is the single `@trusted` entry point into them. Their overrides of
  `@safe` interfaces (`stop`, `awaitFd`, `sleepMs`, the `ResponseSink` methods) are small `@trusted` bodies.
- FFI modules (`drivers/pg`, `engine/.../httpclient.d`, `tls.d`, `tlsserver.d`, `libpq.d`) expose `@trusted` facades; raw
  pointers never leave them (`tlsserver.d`'s per-connection functions take an `SSL*` and are `@system`; only `epoll.d` calls
  them). Tests that need raw OpenSSL (`tests/net/tls_net.d`, `tls_loadgen.d`) declare a `vela.engine.*` module name to reach the
  package-protected table. Anything that hands out a raw view (`PgResult.text`) is `@system`.
- **Memory model of request data**: every slice vela hands to user code points into GC memory (`NO_SCAN` blocks from
  `BufferPool` and `ByteBuffer`; never `NO_INTERIOR`, never freed or `realloc`'d by hand; `GC.malloc` is `extern (C)`, so a
  function-pointer cast must say so). A slice kept past the request is memory-safe -- it keeps its block alive -- but it may show
  bytes of a later request that reused the buffer. `Header!"X"` and `Cookie!"x"` hold copies. Never reintroduce `free`/`realloc`
  on a buffer user code can reach. Buffers are still pooled, so the hot path allocates nothing after warm-up (`tests/alloc`).
  A pooled worker must not pin a big buffer: `releaseWorker` clears `req` and the header table, `server.d` clears `ctx.request`.
- `__gshared` data is `@system`: read it through a small `@trusted` accessor and say why it is sound (usually "written once before
  the workers start"). The accessor returns `const` or `immutable` data, never a mutable `ref`; writes go through a separate
  `@system` setter that `main` calls before `serve` (see `examples/api`).
- A new `@trusted` needs a one-line comment saying why it is sound. When unsure, keep it `@system`.

## Layout

| Path | Role |
|------|------|
| `http/` (`vela:http`) | HTTP types, `Optional`, text types, IP/CIDR, UTF-8, zero-copy HTTP/1.1 parser, chunked decoder, response head/sink, writer, byte buffer, HTTP/2 session (`h2.d`) and HPACK. No I/O. |
| `web/` (`vela:web`) | `App`, `Group`, router, handler introspection, JSON, OpenAPI, CORS, cookies, streaming, models, middleware, `TestClient`. No sockets. |
| `engine/` (`vela:engine`) | epoll loop, fibers (`sleep`/`awaitFd`), buffer pool, `offload`, HTTP/HTTPS client, OpenSSL (dlopen, `tls.d`), the server's TLS listener (`tlsserver.d`). No routes or DTOs. |
| `drivers/pg/` (`vela-pg`) | PostgreSQL driver over async libpq (dlopen). **Independent package; the core must never depend on it.** |
| `source/vela/` (`vela`) | `import vela;`, `server.d` (the only glue between web and engine), `staticfiles.d`. |
| `examples/hello`, `examples/api` | In-memory CRUD; a real API with Postgres, external API, CORS, static files, OpenAPI. |
| `tests/` | `web/` (no network; helper modules in `web/support/`), `h2/` (HTTP/2 session), `net/` (real sockets), `db/` (needs Postgres), `fuzz/`, `alloc/`, `compile_fail/`, `example/`. |
| `tools/` | `check.sh` (everything), `fuzz.sh`, `h2_interop.sh`, `stream_interop.sh`, `crash_check.sh`, `openapi_validate.sh`, `doc_examples.sh`, and the helpers that start a throwaway Postgres / test upstream. |
| `docs/`, `README.md` | User-facing docs (quickstart, deploy, streaming, http2, tls, database, configuration). Keep them in sync with behavior; code blocks whose first line is `// check` are compiled by `tools/doc_examples.sh`. |
| `.github/workflows/check.yml` | CI: DMD and LDC at the minimum and latest versions, strict mode; browser test and nightly fuzzing in their own jobs. |

Dependency direction: `http` <- `web`, `http` <- `engine` <- `drivers/*`; `source/vela/server.d` is the only module that knows both
`web` and `engine`. Do not introduce a dependency from the core to any driver.

## Commands and the definition of done

```sh
tools/check.sh                 # full verification (DMD); DC=ldmd2 for LDC
VELA_STRICT=1 tools/check.sh   # a skipped section fails the run (CI does this)
VELA_ONLY="memory" tools/check.sh   # only the sections whose name contains the text
tools/fuzz.sh [seconds] [parse|h2]  # libFuzzer + ASan on the HTTP/1 parser or the HTTP/2 session (needs LDC)
tools/h2_interop.sh            # HTTP/2 against curl, python-h2 and h2spec (H2SPEC=/path); also run by check.sh
```

- A change is done when `tools/check.sh` passes on **both** DMD and LDC (minimum supported: DMD 2.109.1, LDC 1.40.1), with new
  tests, a `compile_fail` case for every new signature rule, the hot path still GC-free and the memory numbers within their limits.
- **Skips**: a test or helper that cannot run prints `skip: <reason>` to stderr and exits **77**; `check.sh` lists the skips in its
  summary. `dmd -run` turns every non-zero code into 1, so tests that can skip are built first and run afterwards.
- Timing checks are noisy: the compile budget fails above 440 ms (target 400), the HTTPS memory ceiling is 80 MB (OpenSSL 3.5).
- Parser changes: add corpus files and run `tools/fuzz.sh 300 parse`. HTTP/2 changes: see below.

## Concurrency model (read before touching `engine/` or `drivers/`)

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
- **Errors inside handlers** (D4): an `Exception` becomes a 500 through the app (logged with a stack trace, 5 traces per second per
  App); an `Error` (RangeError, AssertError...) also gets a 500, a full trace in the log (5 per second per worker, the rest
  counted), and the fiber is retired (`LoopStats.fibersPoisoned`): after an `Error`, cleanup may not have run. A fiber stack
  overflow is a SIGSEGV that kills the process; `onCrash` in `epoll.d` prints which request was running first.

## The response contract (read before touching `engine/`, `server.d` or `web/.../stream.d`)

- The engine calls `RequestCallback(ref Request, ResponseSink)` (`vela.http.response`): `sink.start(ResponseHead)`, any number of
  `sink.write(bytes)`, `sink.end()`. The web layer never produces HTTP/1.1 text and the HTTP/2 session never parses it: both
  protocols encode from the structured head.
- `Worker` is the sink. Output goes to `w.output`; on HTTP/1.1 the loop sends it after the handler returns (the buffered case), or
  the fiber sends it itself once `streamHighWaterBytes` are buffered or on `flush` (waiting for `EPOLLOUT` in `waitWritable`,
  `writeTimeoutMs` at most; `awaitFd` is not used for the connection's own fd). Known `contentLength` -> `Content-Length`; unknown ->
  chunked (HTTP/1.1) or close-delimited (HTTP/1.0); HEAD, 204 and 304 discard writes. On HTTP/2 the stream is *committed* (HEADERS +
  the bytes so far) at the high-water mark or on `flush`; `H2Session.beginResponse/sendData/endResponse` carry the rest and
  `pendingBytes` suspends the handler. Before the commit a failure is a clean 500; after it only a cut-off is possible
  (`ResponseAborted`: connection closed without the last chunk / `RST_STREAM(INTERNAL_ERROR)`).
- `requestTimeoutMs` ends at `start`; then `writeTimeoutMs` bounds each blocked write and `streamTimeoutMs` (0 = none) the stream.
  A streaming handler keeps its fiber and counts toward `maxInFlight`.
- The sink copies: never hold the caller's slice past `write`. Never call `closeConn` from inside the fiber: mark
  `cancelled`/`failed` and let `finish`/`finishH2` act.
- Web layer: `Stream`/`EventStream` run inside `dispatch`; the head is committed lazily by `commit()` in `stream.d`, which runs the
  same `checkResponse` (owned headers, validation, `Date`) as `App.handle` and locks the headers. `server.d` and `TestClient` both
  finish with `sendResponse`.
- Request bodies: HTTP/1 chunked bodies are decoded in place by `ChunkedDecoder` (`tryParse`); the decoded body ends up right after
  the head and the next pipelined request right behind it, so `compact(c.total)` is unchanged.

## HTTP/2 (read before touching `http/.../h2.d` or the h2 part of `epoll.d`)

**Frozen (D3).** No new HTTP/2 or TLS features until the owner says so. Allowed: bug fixes, and the changes other plan items
require (response sink, memory model). Everything below still applies to those.

- Protocol logic lives in `H2Session` (`vela.http.h2`), which does no I/O: the engine feeds it bytes (`receive`), runs what
  `popReady` hands out (one fiber per stream), cancels what `popReset` hands out, hands each response back with `respond` (or
  `beginResponse`/`sendData`/`endResponse` for a streamed body), and writes `pendingOutput`. Anything about frames, HPACK, stream
  states or flow control belongs in the session, where `tests/h2/session_test.d` and the fuzzers can reach it without sockets.
- A stream object the engine holds (`task` set) is never recycled by the session; the engine gives it back with `respond`,
  `endResponse`, `cancelStream` or `detach`. Stream and session objects are pooled: reset every field in `H2Stream.reset`/`H2Session.reset`.
- Never send RST_STREAM for a stream that was never opened (idle, or even-numbered): use a connection error.
- A connection that ends is closed with `lingerClose` (FIN, then discard input for up to a second): closing with unread input makes
  the kernel send RST and the peer can lose our last frames.
- An HTTP/2 change: a case in `tests/h2/session_test.d`, `tools/h2_interop.sh` (h2spec at 146/146 over TLS and 145/146 in cleartext:
  3.5/2 cannot pass on a mixed HTTP/1.1 port), and `tools/fuzz.sh 300 h2`. Inputs that once broke the session go in
  `tests/fuzz/h2_regressions/`.

## TLS (read before touching `tlsserver.d` or the TLS parts of `epoll.d`; also frozen, see above)

- Every read and write on a connection goes through `ioRead`/`ioSend` in `epoll.d`, never `read`/`send` on the fd: with TLS they
  go through OpenSSL with read(2)/send(2) semantics (EAGAIN for WANT_READ/WANT_WRITE).
- A short TLS read does not mean the socket is drained (one record at a time): keep reading until EAGAIN (edge-triggered epoll).
- OpenSSL writes with write(2): SIGPIPE must stay ignored (`loadOpenSsl` does it).
- Never call `SSL_shutdown` after a fatal TLS error (`Conn.tlsFatal`) or during the handshake.
- Each worker has its own `SSL_CTX` (no locks); ticket keys are shared so resumption works across workers.
- The redirect port (`tls.redirectPort`) is answered in `answerRedirectPort`, never by the app (no fibers, no handlers). ACME
  tokens are validated as base64url before touching the file system.
- Connection logs go through `logConnError` (rate-limited). Do not log clients that just close mid-handshake.
- The deploy config example in `docs/deploy.md` is compiled by `tools/doc_examples.sh`; its deploy hook must work with the reload
  logic. Re-check both when changing `TlsConfig` or the reload.

## Pitfalls

- dlopen function tables must live in a `struct` held by a `__gshared` instance (`pq`, `tls`), never in loose `extern (C)` variables
  (they become global symbols that the C library then calls itself).
- A user helper named `get`/`put`/`post` hides vela's free functions; use `vela.get!(...)(app)`.
- Middleware applies to every route of its App/Group whatever the registration order; the app freezes when it starts serving
  (`App.freeze`) and registration then throws `RouteError`. Group prefixes cannot contain `{param}`.
- D's `args[i].ptr` of `main(string[] args)` is not NUL-terminated: use `std.conv` in tools, not `atoi`.
- A lambda mentioned inside `typeof` still makes older compilers allocate a closure for the variables it names: get return types
  from `typeof(fn)`, not from a probe lambda (`tests/alloc` caught it).

## Adding things

- **A new handler parameter kind**: add the wrapper in `web/.../params.d`, bind it in `handler_traits.d` (dispatch and `handlerError`),
  describe it in `openapi.d`, and add tests in `tests/web/` plus a `tests/compile_fail/` case for its misuse.
- **A new driver** (MySQL, Redis...): a new package under `drivers/`, depending only on `vela:engine`, using `awaitFd`/`offload`;
  load native libraries at run time (dlopen) so the framework still builds without them.
- **A new event-loop backend** (kqueue, io_uring): implement the `EventLoop` interface in `engine/source/vela/engine/loop.d`.
- **A new `Request` field**: every producer must set it -- the HTTP/1 parser (`parseRequestHead`), the HTTP/2 session
  (`finishRequest`), and for fields that do not come from the bytes (`peer`) the engine at both entry points -- because the
  fiber's `Request` is reused across protocols.
- **A new documented example**: start its code block with `// check` and make it a complete program; `tools/doc_examples.sh`
  compiles it.

## Out of scope for now

Performance work (M4: benchmarks, SIMD head search, GC tuning, `sendfile`), kqueue (M5) and io_uring (M6), streamed (unbuffered)
request bodies and multipart uploads, WebSockets, Range requests, serving the app in cleartext next to TLS, IPv6 listeners, OCSP
stapling, response trailers (gRPC), streaming responses in the HTTP client. Do not start these unless asked.
