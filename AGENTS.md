# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.
The framework is called **andaime** (Portuguese for "scaffolding": a modular web framework where you attach modules as you need them; DUB package `andaime`, `import andaime;`); the repository is `andaime`.
`PLAN.md` holds the improvement plan with its decision logs (owner decisions D1-D4, planner decisions P1-P9, Phase 11's F1-F30
and Phase 12's G1-G14) and what was done.

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
  in `http/`, `web/` and `engine/` (they cost compile time). Tests, examples and `version (unittest)` blocks may use them: unittest
  code is not part of a normal build (`web/source/andaime/web/json.d` imports `std.conv` inside one).
- Prefer shallow constructs (`static foreach`, `static if`) over deep recursive templates.
- Every invalid handler signature must produce a **one-line `static assert` message** that says exactly what to fix
  (see `handlerError` in `web/source/andaime/web/handler_traits.d`). Add a case to `tests/compile_fail/` when you add a rule.
- Error messages start with the prefix of their package: `andaime:` in `http/`, `web/`, the root package and the engine's server
  modules (`epoll.d`, `tlsserver.d`, `random.d`...); `andaime.http:` in the HTTP and WebSocket clients (`httpclient.d`, `httpfake.d`,
  `wsclient.d`) and `tls.d`; `andaime.crypto:`, `andaime.jobs:` (also `drivers/pgjobs`) and `andaime.db:` (the Postgres driver).
- Code also type-checks under language edition 2025 (the `edition` section of `check.sh`: a scratch copy with `module x 2025;`;
  the repository stays on the baseline edition because DMD 2.109 / LDC 1.40 cannot read it; CI runs it on DMD 2.112.0, the
  oldest compiler with editions, and older compilers skip it).
- Code type-checks with `-preview=dip1000` (the `dip1000` section of `check.sh`, on DMD and LDC). A parameter that is only
  read is `scope`; one whose result points into it is `return scope`; one the callee stores views of (the parser's buffer,
  the multipart body) is a plain slice. Where the compiler cannot see that a view never outlives its source, a small named
  `@trusted` helper says why (`unscoped` in `jsonvalue.d`, `readToken` in `multipart.d`, `unpad` in `h2.d`). Tests that keep
  such views (a parsed `Request`, a middleware that captures state) use heap or module-level storage, not stack locals.
- Use only one import of a name per module (a private selective import next to a `public import` of the same name made
  `is(T == X!U, U)` false on DMD 2.109).
- Never use `pkill -f` with a pattern that appears in your own command line.
- `real` is a reserved word in D.

## Safety model (`@safe`)

- Framework-internal delegate types (`RequestCallback`, `HandlerFactory`, `WorkerInit`, `HandlerFn`, `offload`'s work delegate) are `@safe`.
- **User-facing callbacks accept `@system`** (`Middleware`, `ErrorHandler`, `UserHandler`, `ValidationErrorHandler`, route
  handlers, a text type's methods): user code may call C libraries without ceremony, and `@safe` code converts to them implicitly.
  The framework invokes user code only through `callMiddleware`, `callUser` (one overload per handler type, `application.d`;
  a validation handler is reached from `dispatch` through the `@safe` `Context.onValidation` that `App.freeze` sets),
  `callBuild` (the app build function, `server.d`), `callStream`/`callEvents` (stream bodies, `stream.d`), `callWebSocket`
  (a WebSocket body, `web/.../websocket.d`), `textFromString`/`textToString` (a user's text type, `andaime.http.texttype`)
  and the `@trusted` lambda in `dispatch`. Add no other call sites.
- `-version=AndaimeStrictSafe` (dub: `versions "AndaimeStrictSafe"`) makes `handlerError` reject `@system` handlers with a one-line
  message (`tests/compile_fail/system_handler.d` declares its flag with a `// FLAGS:` line). `tests/web/system_code.d` proves
  that `@system` handlers, middleware and error handlers work by default.
- Every module that declares code starts with `@safe:`. Exceptions: `engine/.../epoll.d` and `devserver.d` have no module attribute
  (D's default, `@system`; raw syscalls); `EventLoop.run` is `@system` and `andaime.server.serve` is the single `@trusted` entry point into them. Their overrides of
  `@safe` interfaces (`stop`, `awaitFd`, `sleepMs`, the `ResponseSink` methods) are small `@trusted` bodies. `crypto/.../libcrypto.d`
  is `@system:` (a table of C prototypes) and exposes `@trusted` functions. `engine/.../httpclient.d` has no module attribute: each
  declaration is marked `@safe` or `@trusted`. Re-export modules (`package.d`) have no code and need neither.
- FFI modules (`drivers/pg`, `engine/.../httpclient.d`, `wsclient.d`, `tls.d`, `tlsserver.d`, `zlib.d`, `random.d`, `libpq.d`,
  `crypto/.../libcrypto.d`, `ec.d`, `aead.d`, `hash.d`, `bcrypt.d`) expose `@trusted` facades; raw
  pointers never leave them (`tlsserver.d`'s per-connection functions take an `SSL*` and are `@system`; only `epoll.d` calls
  them). Tests that need raw OpenSSL (`tests/net/tls_net.d`, `tls_loadgen.d`) declare a `andaime.engine.*` module name to reach the
  package-protected table. Anything that hands out a raw view (`PgResult.text`) is `@system`.
- **Memory model of request data**: every slice andaime hands to user code points into GC memory (`NO_SCAN` blocks from
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
| `http/` (`andaime:http`) | HTTP types, `Optional`, `PatchField`, text types, wire names (`@naming`, `@wireName`: `naming.d`, shared by JSON, OpenAPI and andaime-pg), IP/CIDR, UTF-8, zero-copy HTTP/1.1 parser, chunked decoder, response head/sink, writer, byte buffer, HTTP/2 session (`h2.d`) and HPACK, WebSocket frames/handshake/`WsConn` (`websocket.d`), SHA-1 and base64, base64url (`base64url.d`). No I/O. |
| `web/` (`andaime:web`) | `App`, `Group`, router, handler introspection, JSON and `JsonValue`, OpenAPI, CORS, cookies, streaming, WebSocket routes, models, middleware, `TestClient`, and the logger `andaime.log` (`web/source/andaime/log.d`: in `andaime:web` so `jobs` and the root package use it; it writes to fd 2 unless a `LogSink` is set (`setLogSink`, or `setThreadLogSink` for tests): the sink gets a `LogRecord` whose slices are valid only during the call, and a line logged from inside a sink is dropped). No sockets. |
| `engine/` (`andaime:engine`) | epoll loop, fibers (`sleep`/`awaitFd`), buffer pool, `offload`, `randomBytes` (getrandom, `random.d`), HTTP/HTTPS client (and `httpfake.d`, a scripted `HttpTransport` for tests), WebSocket client (`wsclient.d`), OpenSSL (dlopen, `tls.d`), zlib (dlopen, `zlib.d`), the server's TLS listener (`tlsserver.d`). No routes or DTOs. |
| `crypto/` (`andaime:crypto`) | Cryptographic primitives over OpenSSL 3's libcrypto and libxcrypt (both dlopen, own `__gshared` tables): SHA-256, HMAC, HKDF, AES-128-GCM, P-256 ECDSA (ES256) and ECDH, Web Push encryption (RFC 8291), bcrypt. Depends on `andaime:http` and `andaime:engine` (`random.d`, `offload`). Nothing else depends on it. |
| `jobs/` (`andaime:jobs`) | Background jobs: `@Job` / `perform`, in-memory and test queues, cron, `--role` and `--queues`. Depends on `andaime:web` and `andaime:engine`. The root package does not depend on it. |
| `drivers/pg/` (`andaime-pg`) | PostgreSQL driver over async libpq (dlopen). **Independent package; the core must never depend on it.** |
| `drivers/pgjobs/` (`andaime-pg-jobs`) | Postgres `JobStore` (`PgJobStore`): `SKIP LOCKED` claims, `LISTEN`/`NOTIFY`, a lease reaper, one cron slot across processes. Depends on `andaime:jobs` and `andaime-pg`. |
| `source/andaime/` (`andaime`) | `import andaime;`, `server.d` (the only glue between web and engine), `staticfiles.d`. |
| `examples/hello`, `examples/api` | In-memory CRUD; a real API with Postgres, external API, CORS, static files, OpenAPI. |
| `tests/` | `web/` (no network; helper modules in `web/support/`), `jobs/` (no network), `h2/` (HTTP/2 session), `net/` (real sockets), `db/` (needs Postgres), `crypto/` (exits 77 without libcrypto), `fuzz/`, `alloc/`, `compile_fail/`, `example/`. |
| `tools/` | `check.sh` (everything), `fuzz.sh`, `h2_interop.sh`, `stream_interop.sh`, `ws_interop.sh` (python `websockets`), `proxy_interop.sh` (behind Caddy over h2c), `crash_check.sh`, `openapi_validate.sh`, `doc_examples.sh`, `api_e2e.sh` (`examples/api` end to end), `bench.sh`, and the helpers that start a throwaway Postgres / test upstream. |
| `internals/` | Contributor notes per subsystem (concurrency, jobs, response contract, WebSockets, HTTP/2, TLS); see [Subsystem notes](#subsystem-notes). |
| `docs/`, `README.md` | User-facing docs: `docs/README.md` is the index (guides: getting-started, routing, requests, validation, responses, middleware, streaming, websocket, static files/OpenAPI, concurrency, database, jobs and cron, http-client, logging, crypto, testing, safety; reference: deploy, tls, http2, configuration). Keep them in sync with behavior; code blocks whose first line is `// check` are compiled by `tools/doc_examples.sh`. Contributor material goes in `CONTRIBUTING.md`, not the README. |
| `.github/workflows/check.yml` | CI: DMD and LDC at the minimum and latest versions, strict mode; the `edition` section on DMD 2.112.0 in its own job; the browser test and fuzzing in their own jobs, nightly or on a manual run only. |

Dependency direction: `http` <- `web`, `http` <- `engine` <- `drivers/pg`. `jobs` depends on `web` and `engine`, not on `pg`.
`drivers/pgjobs` depends on `jobs` and `andaime-pg`. `crypto` depends on `http` and `engine`; nothing in the core or `jobs`
imports it (`check.sh` greps for it). The root `andaime` package does not depend on `jobs`. `web` does not depend on
`engine`. `source/andaime/server.d` is the only module that knows both `web` and `engine`. Do not introduce a dependency from the
core to any driver.

## Commands and the definition of done

```sh
tools/check.sh                 # full verification (DMD); DC=ldmd2 for LDC
ANDAIME_STRICT=1 tools/check.sh   # a skipped section fails the run (CI does this)
ANDAIME_ONLY="memory" tools/check.sh   # only the sections whose name contains the text
tools/fuzz.sh [seconds] [parse|h2|ws|json]  # libFuzzer + ASan on the HTTP/1 parser, the HTTP/2 session, WebSockets or the JSON reader (needs LDC)
tools/ws_interop.sh            # WebSockets against python's `websockets` (server and client, permessage-deflate); also run by check.sh
tools/bench.sh [seconds]       # throughput (req/s) of one worker, with and without pipelining; for before/after, not a gate
tools/h2_interop.sh            # HTTP/2 against curl, python-h2 and h2spec (H2SPEC=/path); also run by check.sh
```

- A change is done when `tools/check.sh` passes on **both** DMD and LDC (minimum supported: DMD 2.109.1, LDC 1.40.1), with new
  tests, a `compile_fail` case for every new signature rule, the hot path still GC-free and the memory numbers within their limits.
- **Skips**: a test or helper that cannot run prints `skip: <reason>` to stderr and exits **77**; `check.sh` lists the skips in its
  summary. `dmd -run` turns every non-zero code into 1, so tests that can skip are built first and run afterwards.
- Timing checks are noisy: the compile budget fails above 440 ms (target 400), the HTTPS memory ceiling is 80 MB (OpenSSL 3.5).
- Parser changes: add corpus files and run `tools/fuzz.sh 300 parse`. JSON reader changes (`json.d`, `jsonvalue.d`): run
  `tools/fuzz.sh 300 json` (`JsonValue` recursion is bounded by `JsonLimits.maxDepth`; keep it so). HTTP/2 and WebSocket
  changes: see [Subsystem notes](#subsystem-notes).

## Subsystem notes

Read the matching file before touching its area. The rules in those files are not repeated here.

| Area | Read before touching | Covers |
|------|----------------------|--------|
| `engine/`, `drivers/` | [internals/concurrency.md](internals/concurrency.md) | workers, fibers, `offload`, cancellation, errors inside handlers |
| `jobs/`, `drivers/pgjobs/` | [internals/jobs.md](internals/jobs.md) | job claims, cron, shutdown |
| `engine/`, `server.d`, `web/.../stream.d` | [internals/response-contract.md](internals/response-contract.md) | the response sink, streaming, pipelining, upgrades |
| `http/.../websocket.d`, `web/.../websocket.d`, `wsclient.d`, `Phase.upgraded` in `epoll.d` | [internals/websockets.md](internals/websockets.md) | WebSocket codec, takeover, RFC 8441 tunnels |
| `http/.../h2.d`, the h2 part of `epoll.d` | [internals/http2.md](internals/http2.md) | HTTP/2 session (frozen, D3) |
| `tlsserver.d`, the TLS parts of `epoll.d` | [internals/tls.md](internals/tls.md) | TLS listener and reads/writes (frozen, D3) |

## Pitfalls

- dlopen function tables must live in a `struct` held by a `__gshared` instance (`pq`, `tls`, `z`), never in loose `extern (C)` variables
  (they become global symbols that the C library then calls itself).
- A user helper named `get`/`put`/`post`/`ws` hides andaime's free functions; use `andaime.get!(...)(app)`.
- DMD 2.109 segfaults on a call that relies on a default argument placed before a variadic parameter (`f(string a, S s = S.init,
  T[] rest...)`): use an overload instead (`TestClient.websocket`, `TestClient.request`), and test the short call on DMD.
  It also crashes, instead of reporting it, on some name clashes between imported enums: when DMD dies with a segfault, try
  LDC for the real error message.
- A libFuzzer target has no D `main`: one that needs druntime (the monotonic clock, say) calls `rt_init` in
  `LLVMFuzzerInitialize` (`tests/fuzz/libfuzzer_ws.d`).
- Middleware applies to every route of its App/Group whatever the registration order; the app freezes when it starts serving
  (`App.freeze`) and registration then throws `RouteError`. Group prefixes cannot contain `{param}`.
- D's `args[i].ptr` of `main(string[] args)` is not NUL-terminated: use `std.conv` in tools, not `atoi`.
- A lambda mentioned inside `typeof` still makes older compilers allocate a closure for the variables it names: get return types
  from `typeof(fn)`, not from a probe lambda (`tests/alloc` caught it).

## Adding things

- **A new handler parameter kind**: add the wrapper in `web/.../params.d`, bind it in `handler_traits.d` (dispatch and `handlerError`),
  describe it in `openapi.d`, and add tests in `tests/web/` plus a `tests/compile_fail/` case for its misuse.
- **A new job rule**: extend `jobError` in `jobs/source/andaime/jobs/job.d` with one `andaime.jobs:` line, and add
  `tests/compile_fail/job_*.d` (`// FLAGS: -Ijobs/source`).
- **A new driver** (MySQL, Redis...): a new package under `drivers/`, depending only on `andaime:engine`, using `awaitFd`/`offload`;
  load native libraries at run time (dlopen) so the framework still builds without them.
- **A new crypto primitive**: in `crypto/`, through `CryptoApi` in `libcrypto.d` (add the symbol to the table; OpenSSL 3
  non-deprecated API), a small `@trusted` body with a soundness comment, no raw pointer in the signature, an official
  test vector in `tests/crypto/` (which exits 77 when the library is missing), and a line in `docs/crypto.md`.
- **A new event-loop backend** (kqueue, io_uring): implement the `EventLoop` interface in `engine/source/andaime/engine/loop.d`.
- **A new `Request` field**: every producer must set it -- the HTTP/1 parser (`parseRequestHead`), the HTTP/2 session
  (`finishRequest`), and for fields that do not come from the bytes (`peer`) the engine at both entry points -- because the
  fiber's `Request` is reused across protocols.
- **A new documented example**: start its code block with `// check` and make it a complete program; `tools/doc_examples.sh`
  compiles it.

## Out of scope for now

The rest of the performance work (M4: SIMD head search, GC tuning, `sendfile`; the benchmark, single parse and pipelined-response
coalescing are done, see `PLAN.md` Phase 8), kqueue (M5) and io_uring (M6), streamed (unbuffered)
request bodies, the WebSocket client over HTTP/2, Range requests, serving the app in cleartext next to TLS, IPv6 listeners, OCSP
stapling, response trailers (gRPC), streaming responses in the HTTP client. Do not start these unless asked.
